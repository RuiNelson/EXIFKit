@testable import EXIFKit
import Foundation
import Testing

private enum Segments {
    /// JPEG scan bytes and all non-EXIF segments must remain identical, including XMP/IPTC.
    static func preservedRanges(_ file: LocalFileHandle) async throws -> [Range<UInt64>] {
        let size = try await file.size
        #expect(try await file.read(at: 0, count: 2) == Data([0xFF, 0xD8]))
        var ranges: [Range<UInt64>] = [0 ..< 2]
        var position: UInt64 = 2
        while position < size {
            let start = position
            let marker = try await file.read(at: position, count: 2)
            #expect(marker[0] == 0xFF)
            if marker[1] == 0xDA {
                ranges.append(start ..< size); return ranges
            }
            let lengthBytes = try await file.read(at: position + 2, count: 2)
            let length = UInt64(lengthBytes[0]) << 8 | UInt64(lengthBytes[1])
            #expect(length >= 2)
            position += 2 + length
            if marker[1] == 0xE1, length >= 8,
               try await file.read(at: start + 4, count: 6) == Data("Exif\0\0".utf8)
            {
                continue
            }
            ranges.append(start ..< position)
        }
        Issue.record("JPEG scan not found")
        return ranges
    }

    static func assertImageAndNonEXIFSegmentsPreserved(_ original: URL, _ output: URL) async throws {
        let lhs = try LocalFileHandle(url: original), rhs = try LocalFileHandle(url: output)
        let left = try await preservedRanges(lhs), right = try await preservedRanges(rhs)
        #expect(left.count == right.count)
        for (a, b) in zip(left, right) {
            let length = a.upperBound - a.lowerBound
            #expect(length == b.upperBound - b.lowerBound)
            var offset: UInt64 = 0
            while offset < length {
                let count = Int(min(65536, length - offset))
                let expected = try await lhs.read(at: a.lowerBound + offset, count: count)
                #expect(try await rhs.read(at: b.lowerBound + offset, count: count) == expected)
                offset += UInt64(count)
            }
        }
    }
}

struct ReferenceEditTests {
    private func temporaryURL(_ name: String = "out.jpg") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    @Test
    func savedReferenceMatchesLibrary() async throws {
        let fixture = try NikonFixture.url()
        try await EXIFOracleTag.assertMatches(EXIFKit.read(from: fixture), tags: NikonFixture.tags())
    }

    @Test
    func editsPersistAndImageDataIsPreserved() async throws {
        let fixture = try NikonFixture.url()
        let output = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        let source = try LocalFileHandle(url: fixture)
        var metadata = try await EXIFKit.read(from: source)
        metadata.ifd0.set(tagID: Tag.artist, value: .ascii("EXIFKit test"))
        metadata.exifIFD?.set(tagID: Tag.isoSpeedRatings, value: .short(800))
        metadata.setGPSCoordinates(latitude: 38.7223, longitude: -9.1393, altitude: 12.5)
        try await EXIFKit.write(metadata, from: source, to: LocalFileHandle(url: output, createIfNeeded: true))
        let reparsed = try await EXIFKit.read(from: output)
        #expect(reparsed.artist == "EXIFKit test")
        #expect(reparsed.iso == 800)
        #expect(reparsed.gpsIFD != nil)
        let relocated: Set = ["Exif.Image.ExifTag", "Exif.Thumbnail.JPEGInterchangeFormat", "Exif.Photo.ISOSpeedRatings",
                              "Exif.Image.Artist", "Exif.Image.GPSTag"]
        let expected = try NikonFixture.tags().filter { !relocated.contains($0.key) }
        let directories: [String: IFD?] = ["Image": reparsed.ifd0, "Photo": reparsed.exifIFD,
                                           "Thumbnail": reparsed.ifd1, "GPSInfo": reparsed.gpsIFD, "Iop": reparsed.interopIFD]
        for tag in expected {
            let entry = try #require((directories[tag.group] ?? nil)?.entry(for: tag.id), "Missing \(tag.key)")
            #expect(entry.count == tag.count, "Count of \(tag.key)")
        }
        #expect(try await reparsed.readThumbnail() == NikonFixture.thumbnail())
        try await Segments.assertImageAndNonEXIFSegmentsPreserved(fixture, output)
    }

    @Test
    func strippingRemovesEXIFAndPreservesOtherSegments() async throws {
        let fixture = try NikonFixture.url()
        let output = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        try await EXIFKit.strip(from: LocalFileHandle(url: fixture), to: LocalFileHandle(url: output, createIfNeeded: true))
        await #expect(throws: EXIFError.self) { try await EXIFKit.read(from: output) }
        try await Segments.assertImageAndNonEXIFSegmentsPreserved(fixture, output)
    }

    @Test
    func libraryReadsFileEditedByExiv2() async throws {
        let fixture = try NikonFixture.url("NikonD90.exiv2-edited")
        let metadata = try await EXIFKit.read(from: fixture)
        let tags = try EXIFOracleTag.parse(Data(contentsOf: NikonFixture.url("NikonD90.exiv2-edited", extension: "txt")))
        try EXIFOracleTag.assertMatches(metadata, tags: tags)
        #expect(metadata.artist == "exiv2 oracle test")
        #expect(metadata.orientation == 6)
        #expect(metadata.iso == 1600)
        #expect(try await metadata.readThumbnail() == NikonFixture.thumbnail())
    }
}
