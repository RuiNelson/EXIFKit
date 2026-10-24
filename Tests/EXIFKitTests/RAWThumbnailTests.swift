@testable import EXIFKit
import Foundation
import Testing

/// Local RAW samples in `Fixtures/RAW`, which are too large for git. Tests are skipped without them.
enum RAWFixture {
    static var directory: URL? {
        Bundle.module.resourceURL?.appendingPathComponent("Fixtures/RAW")
    }

    static var available: [String] {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    static func url(_ name: String) throws -> URL {
        try #require(directory).appendingPathComponent(name)
    }
}

struct RAWThumbnailTests {
    private func temporaryURL(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    /// Byte range of the IFD table at `offset`, read from the original file.
    private func tableRange(_ data: Data, at offset: UInt32, order: ByteOrder) throws -> Range<Int> {
        var reader = ByteReader(data: data, byteOrder: order)
        reader.offset = Int(offset)
        let count = try Int(reader.readUInt16())
        return Int(offset) ..< Int(offset) + 2 + count * 12 + 4
    }

    /// Ranges of `original` whose bytes differ in `edited`, in 64 KiB blocks narrowed to exact bytes.
    private func differences(_ original: Data, _ edited: Data) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var block = 0
        while block < original.count {
            let end = min(block + 65536, original.count)
            if original[block ..< end] != edited[block ..< end] {
                for index in block ..< end where original[index] != edited[index] {
                    if let last = ranges.last, last.upperBound == index {
                        ranges[ranges.count - 1] = last.lowerBound ..< index + 1
                    } else {
                        ranges.append(index ..< index + 1)
                    }
                }
            }
            block = end
        }
        return ranges
    }

    private func assertSameTags(_ lhs: IFD?, _ rhs: IFD?, ignoring: Set<UInt16> = []) {
        let left = (lhs?.entries ?? []).filter { !ignoring.contains($0.tagID) }
        let right = (rhs?.entries ?? []).filter { !ignoring.contains($0.tagID) }
        #expect(left.map(\.tagID) == right.map(\.tagID))
        for (a, b) in zip(left, right) {
            #expect(a.value == b.value, "Tag 0x\(String(a.tagID, radix: 16))")
        }
    }

    @Test(.enabled(if: !RAWFixture.available.isEmpty), arguments: RAWFixture.available)
    func replacingThumbnailOnlyTouchesThumbnailMetadata(_ name: String) async throws {
        let source = try RAWFixture.url(name)
        let output = try temporaryURL(name)
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        let thumbnail = try NikonFixture.thumbnail()

        let metadata = try await EXIFKit.read(from: source)
        var edited = metadata
        try edited.setThumbnail(thumbnail)
        try await EXIFKit.write(
            edited, from: LocalFileHandle(url: source), to: LocalFileHandle(url: output, createIfNeeded: true)
        )

        let reparsed = try await EXIFKit.read(from: output)
        #expect(try await reparsed.readThumbnail() == thumbnail)
        #expect(reparsed.ifd1?.value(for: Tag.compression) == .short(6))
        #expect(reparsed.ifd1?.nextIFDOffset == metadata.ifd1?.nextIFDOffset ?? 0)
        assertSameTags(metadata.ifd0, reparsed.ifd0)
        assertSameTags(metadata.exifIFD, reparsed.exifIFD)
        assertSameTags(metadata.gpsIFD, reparsed.gpsIFD)
        assertSameTags(metadata.interopIFD, reparsed.interopIFD)

        // Everything but IFD0's next pointer, the IFD1 table and the superseded thumbnail is byte-identical.
        let original = try Data(contentsOf: source, options: .alwaysMapped)
        let written = try Data(contentsOf: output, options: .alwaysMapped)
        let order = metadata.byteOrder
        var header = ByteReader(data: original, byteOrder: order)
        header.offset = 4
        var allowed = try [tableRange(original, at: header.readUInt32(), order: order)]
        if let ifd1 = metadata.ifd1 {
            try allowed.append(tableRange(original, at: metadata.ifd0.nextIFDOffset, order: order))
            let offset = try #require(ifd1.value(for: Tag.jpegInterchangeFormat)?.uint32Value)
            let length = try #require(ifd1.value(for: Tag.jpegInterchangeFormatLength)?.uint32Value)
            allowed.append(Int(offset) ..< Int(offset + length))
            #expect(written[Int(offset) ..< Int(offset + length)].allSatisfy { $0 == 0 })
        }
        #expect(written.count > original.count)
        for range in differences(original, written) {
            #expect(allowed.contains { $0.contains(range.lowerBound) && $0.upperBound >= range.upperBound },
                    "Unexpected change at \(range)")
        }
    }

    @Test(.enabled(if: RAWFixture.available.contains("Canon5DMk2.cr2")))
    func removingRAWThumbnailIsRejected() async throws {
        let source = try RAWFixture.url("Canon5DMk2.cr2")
        let output = try temporaryURL("out.cr2")
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        var metadata = try await EXIFKit.read(from: source)
        #expect(try await metadata.readThumbnail()?.prefix(2) == Data([0xFF, 0xD8]))
        try metadata.setThumbnail(nil)
        await #expect(throws: EXIFError.self) {
            try await EXIFKit.write(
                metadata, from: LocalFileHandle(url: source), to: LocalFileHandle(url: output, createIfNeeded: true)
            )
        }
    }
}
