@testable import EXIFKit
import Foundation
import Testing

struct WebPTests {
    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var writer = ByteWriter(byteOrder: .littleEndian)
        writer.writeBytes(Data(type.utf8))
        writer.writeUInt32(UInt32(payload.count))
        writer.writeBytes(payload)
        if payload.count & 1 == 1 { writer.writeByte(0) }
        return writer.data
    }

    private static func riff(_ chunks: Data...) -> Data {
        let body = Data("WEBP".utf8) + chunks.reduce(Data(), +)
        var writer = ByteWriter(byteOrder: .littleEndian)
        writer.writeBytes(Data("RIFF".utf8))
        writer.writeUInt32(UInt32(body.count))
        writer.writeBytes(body)
        return writer.data
    }

    /// 40x30 lossless image header with alpha.
    private static let lossless = chunk("VP8L", Data([0x2F]) + Data([39, 0x40, 0x07, 0x10]) + Data([1, 2, 3]))
    private static let lossy = chunk(
        "VP8 ", Data([0x10, 0, 0, 0x9D, 0x01, 0x2A, 40, 0, 30, 0]) + Data([1, 2, 3])
    )

    private static func structure(_ make: String = "Sony") -> TIFFStructure {
        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii(make))
        return structure
    }

    @Test func detectsFormat() {
        let data = Self.riff(Self.lossy)
        #expect(ImageFormat.detect(from: data) == .webp)
        #expect(ImageFormat.detect(fromExtension: "WEBP") == .webp)
        #expect(ImageFormat.detect(from: Data("RIFF\0\0\0\0WAVE".utf8)) == nil)
    }

    @Test func simpleLosslessGainsExtendedHeader() async throws {
        let plain = Self.riff(Self.lossless)
        let written = try await WebPContainer.writeEXIF(Self.structure(), to: plain)
        #expect(try await EXIFKit.read(from: written).make == "Sony")
        let vp8x = written.subdata(in: 12 ..< 30)
        #expect(vp8x.prefix(4) == Data("VP8X".utf8))
        #expect(vp8x[8] == 0x18) // EXIF + alpha
        #expect(Array(vp8x[12 ..< 15]) == [39, 0, 0])
        #expect(Array(vp8x[15 ..< 18]) == [29, 0, 0])
        let size = written.subdata(in: 4 ..< 8).reversed().reduce(0) { $0 << 8 | Int($1) }
        #expect(size == written.count - 8)
        // VP8 + EXIF chunk order: image data precedes EXIF.
        #expect(written.range(of: Data("VP8L".utf8))!.lowerBound < written.range(of: Data("EXIF".utf8))!.lowerBound)
    }

    @Test func simpleLossyUsesBitstreamDimensions() async throws {
        let written = try await WebPContainer.writeEXIF(Self.structure(), to: Self.riff(Self.lossy))
        #expect(Array(written[24 ..< 27]) == [39, 0, 0])
        #expect(Array(written[27 ..< 30]) == [29, 0, 0])
        #expect(written[20] == 0x08)
    }

    @Test func replacesGrowsAndStrips() async throws {
        let vp8x = Self.chunk("VP8X", Data([0, 0, 0, 0, 39, 0, 0, 29, 0, 0]))
        let xmp = Self.chunk("XMP ", Data("<x/>".utf8))
        let plain = Self.riff(vp8x, Self.lossy, xmp)
        let small = try await WebPContainer.writeEXIF(Self.structure("A"), to: plain)
        #expect(small[20] == 0x08)
        #expect(small.range(of: Data("EXIF".utf8))!.lowerBound < small.range(of: Data("XMP ".utf8))!.lowerBound)
        var large = Self.structure("A")
        large.ifd0.set(tagID: Tag.model, value: .ascii(String(repeating: "m", count: 5001)))
        let grown = try await WebPContainer.writeEXIF(large, to: small)
        #expect(try await EXIFKit.read(from: grown).model?.count == 5001)
        let shrunk = try await WebPContainer.writeEXIF(Self.structure("A"), to: grown)
        #expect(shrunk == small)
        let stripped = try await WebPContainer.stripEXIF(from: shrunk)
        #expect(stripped == plain)
        await #expect(throws: (any Error).self) { try await WebPContainer.readEXIF(from: stripped) }
    }

    @Test func readsExifWithJPEGStylePrefix() async throws {
        let tiff = try await EditPlanner.serialized(Self.structure("Nikon"))
        let data = Self.riff(Self.lossy, Self.chunk("EXIF", Data([0x45, 0x78, 0x69, 0x66, 0, 0]) + tiff))
        #expect(try await EXIFKit.read(from: data).make == "Nikon")
    }

    @Test func rejectsMalformedFiles() async {
        var truncated = Self.riff(Self.lossy)
        truncated.replaceSubrange(16 ..< 20, with: Data([0xFF, 0xFF, 0, 0]))
        await #expect(throws: (any Error).self) { try await WebPContainer.readEXIF(from: truncated) }
        await #expect(throws: (any Error).self) {
            try await WebPContainer.writeEXIF(Self.structure(), to: Self.riff(Self.chunk("ALPH", Data([1]))))
        }
    }
}

struct WebPRealFileTests {
    private static var url: URL {
        get throws { try NikonFixture.url("NikonD90", extension: "webp") }
    }

    @Test func readsEncoderWrittenFile() async throws {
        let metadata = try await EXIFKit.read(from: Self.url)
        #expect(metadata.make == "NIKON CORPORATION")
        #expect(metadata.model == "NIKON D90")
        #expect(metadata.dateTimeOriginal == "2010:08:20 15:57:07")
    }

    @Test func rewriteAndStripKeepImageData() async throws {
        let original = try Data(contentsOf: Self.url)
        var metadata = try await EXIFKit.read(from: original)
        metadata.setGPSCoordinates(latitude: 38.7223, longitude: -9.1393)
        let written = try await EXIFKit.write(metadata, to: original)
        let reread = try await EXIFKit.read(from: written)
        #expect(reread.model == "NIKON D90")
        #expect(try abs(#require(reread.latitude) - 38.7223) < 0.001)
        let stripped = try await EXIFKit.strip(from: written)
        let image = try #require(original.range(of: Data("VP8 ".utf8)))
        #expect(stripped.range(of: original[image.lowerBound ..< image.lowerBound + 64]) != nil)
        await #expect(throws: (any Error).self) { try await EXIFKit.read(from: stripped) }
    }
}

extension WebPRealFileTests {
    @Test func losslessFileWithoutExtendedHeaderGainsExif() async throws {
        let plain = try Data(contentsOf: NikonFixture.url("NikonD90.lossless", extension: "webp"))
        #expect(plain.subdata(in: 12 ..< 16) == Data("VP8L".utf8))
        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Nikon"))
        let written = try await EXIFKit.write(structure, to: plain)
        #expect(try await EXIFKit.read(from: written).make == "Nikon")
        #expect(written.subdata(in: 12 ..< 16) == Data("VP8X".utf8))
        #expect(try await EXIFKit.strip(from: written).count == plain.count + 18)
    }
}
