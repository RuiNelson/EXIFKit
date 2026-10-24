@testable import EXIFKit
import Foundation
import Testing

struct JXLTests {
    private static func topLevel(_ data: Data) async throws -> [(type: String, bytes: Data)] {
        try await ISOBMFFParser.parse(data).map {
            ($0.type, data.subdata(in: Int($0.fileOffset) ..< Int($0.fileOffset + $0.totalSize)))
        }
    }

    private static func fixture() throws -> Data {
        try Data(contentsOf: NikonFixture.url("Houses", extension: "jxl"))
    }

    private static func minimal(exif: Data? = nil) -> Data {
        let box = { HandleTests.box($0, $1) }
        var data = JXLContainer.signature + box("ftyp", Data("jxl ".utf8) + Data(count: 4) + Data("jxl ".utf8))
        if let exif {
            data += box("Exif", Data(count: 4) + exif)
        }
        return data + box("jxlc", Data([0xFF, 0x0A, 1, 2, 3]))
    }

    @Test func detectsContainerAndExtension() throws {
        let data = try Self.fixture()
        #expect(ImageFormat.detect(from: data) == .jxl)
        #expect(ImageFormat.detect(fromExtension: "JXL") == .jxl)
        #expect(ImageFormat.jxl.isISOBMFF)
        #expect(ImageFormat.detect(from: Data([0xFF, 0x0A, 0, 0, 0, 0, 0, 0, 0, 0])) == nil)
    }

    @Test func readsRealFile() async throws {
        let metadata = try await EXIFKit.read(from: NikonFixture.url("Houses", extension: "jxl"))
        #expect(metadata.make == "NIKON CORPORATION")
        #expect(metadata.model == "NIKON D3")
        #expect(metadata.dateTimeOriginal == "2008:01:24 14:00:59")
    }

    @Test func extractsEmbeddedThumbnail() async throws {
        let metadata = try await EXIFKit.read(from: NikonFixture.url("Houses", extension: "jxl"))
        let thumbnail = try #require(await metadata.readThumbnail())
        #expect(thumbnail.count == 11450) // exiftool: ThumbnailLength
        #expect(thumbnail.prefix(2) == Data([0xFF, 0xD8]))
        #expect(thumbnail.suffix(2) == Data([0xFF, 0xD9]))
    }

    @Test func rewritingRealFileKeepsEveryOtherBox() async throws {
        let original = try Self.fixture()
        var metadata = try await EXIFKit.read(from: original)
        metadata.setGPSCoordinates(latitude: 38.7223, longitude: -9.1393)
        let written = try await EXIFKit.write(metadata, to: original)
        let reread = try await EXIFKit.read(from: written)
        #expect(reread.make == "NIKON CORPORATION")
        #expect(try abs(#require(reread.latitude) - 38.7223) < 0.001)
        let before = try await Self.topLevel(original)
        let after = try await Self.topLevel(written)
        #expect(before.map(\.type) == after.map(\.type))
        for (a, b) in zip(before, after) where a.type != "Exif" {
            #expect(a.bytes == b.bytes)
        }
    }

    @Test func stripRemovesOnlyExif() async throws {
        let original = try Self.fixture()
        let stripped = try await EXIFKit.strip(from: original)
        let before = try await Self.topLevel(original)
        let after = try await Self.topLevel(stripped)
        #expect(after.map(\.type) == before.map(\.type).filter { $0 != "Exif" })
        await #expect(throws: (any Error).self) { try await EXIFKit.read(from: stripped) }
    }

    @Test func insertsMissingExifAfterFileType() async throws {
        let plain = Self.minimal()
        var structure = TIFFStructure(byteOrder: .bigEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Sony"))
        let written = try await EXIFKit.write(structure, to: plain)
        #expect(try await Self.topLevel(written).map(\.type) == ["JXL ", "ftyp", "Exif", "jxlc"])
        #expect(try await EXIFKit.read(from: written).make == "Sony")
        // Round trip through strip restores the original bytes exactly.
        #expect(try await EXIFKit.strip(from: written) == plain)
    }

    @Test func replacementMayGrowAndShrink() async throws {
        var small = TIFFStructure(byteOrder: .littleEndian)
        small.ifd0.set(tagID: Tag.make, value: .ascii("A"))
        var large = small
        large.ifd0.set(tagID: Tag.model, value: .ascii(String(repeating: "m", count: 5000)))
        let withSmall = try await EXIFKit.write(small, to: Self.minimal())
        let grown = try await EXIFKit.write(large, to: withSmall)
        #expect(try await EXIFKit.read(from: grown).model?.count == 5000)
        let shrunk = try await EXIFKit.write(small, to: grown)
        #expect(shrunk == withSmall)
    }

    @Test func rejectsCompressedExifOnReadButReplacesOnWrite() async throws {
        let box = { HandleTests.box($0, $1) }
        let data = JXLContainer.signature + box("ftyp", Data("jxl ".utf8) + Data(count: 8))
            + box("brob", Data("Exif".utf8) + Data([1, 2, 3])) + box("jxlc", Data([0xFF, 0x0A]))
        await #expect(throws: (any Error).self) { try await EXIFKit.read(from: data) }
        var structure = TIFFStructure(byteOrder: .bigEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Sony"))
        let written = try await EXIFKit.write(structure, to: data)
        #expect(try await Self.topLevel(written).map(\.type) == ["JXL ", "ftyp", "Exif", "jxlc"])
        #expect(try await EXIFKit.read(from: written).make == "Sony")
    }

    @Test func rejectsTruncatedOrMissingSignature() async throws {
        await #expect(throws: (any Error).self) { try await EXIFKit.read(from: Self.minimal().dropLast(), format: .jxl) }
        await #expect(throws: (any Error).self) { try await EXIFKit.read(from: Data(count: 32), format: .jxl) }
    }
}
