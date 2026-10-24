@testable import EXIFKit
import Foundation
import Testing

struct EXIFKitTests {
    // MARK: - ByteReader / ByteWriter round-trip

    @Test func byteReaderWriterRoundTrip() throws {
        var writer = ByteWriter(byteOrder: .littleEndian)
        writer.writeUInt16(0x1234)
        writer.writeUInt32(0xDEAD_BEEF)
        writer.writeURational(URational(numerator: 22, denominator: 7))

        var reader = ByteReader(data: writer.data, byteOrder: .littleEndian)
        #expect(try reader.readUInt16() == 0x1234)
        #expect(try reader.readUInt32() == 0xDEAD_BEEF)
        let rational = try reader.readURational()
        #expect(rational.numerator == 22)
        #expect(rational.denominator == 7)
    }

    @Test func byteOrderMatters() throws {
        var writer = ByteWriter(byteOrder: .bigEndian)
        writer.writeUInt16(0x0102)

        var reader = ByteReader(data: writer.data, byteOrder: .bigEndian)
        #expect(try reader.readUInt16() == 0x0102)

        var readerLE = ByteReader(data: writer.data, byteOrder: .littleEndian)
        #expect(try readerLE.readUInt16() == 0x0201)
    }

    @Test func boundsChecking() throws {
        let data = Data([0x01, 0x02])
        var reader = ByteReader(data: data, byteOrder: .bigEndian)
        _ = try reader.readUInt16()
        #expect(throws: (any Error).self) { try reader.readByte() } // should fail - at end
    }

    @Test func seekValidation() throws {
        var reader = ByteReader(data: Data([0x01]), byteOrder: .bigEndian)
        #expect(throws: (any Error).self) { try reader.seek(to: -1) }
        #expect(throws: (any Error).self) { try reader.seek(to: 100) }
        _ = try reader.seek(to: 0)
        _ = try reader.seek(to: 1) // seek to end is valid
    }

    // MARK: - IFD

    @Test func iFDSetAndGet() {
        var ifd = IFD()
        ifd.set(tagID: Tag.make, value: .ascii("Apple"))
        ifd.set(tagID: Tag.model, value: .ascii("iPhone 15 Pro"))

        #expect(ifd.value(for: Tag.make)?.stringValue == "Apple")
        #expect(ifd.value(for: Tag.model)?.stringValue == "iPhone 15 Pro")
    }

    @Test func iFDSortedInsertion() {
        var ifd = IFD()
        ifd.set(tagID: 0x0200, value: .short(1))
        ifd.set(tagID: 0x0100, value: .short(2))
        ifd.set(tagID: 0x0150, value: .short(3))
        #expect(ifd.entries.map(\.tagID) == [0x0100, 0x0150, 0x0200])
    }

    @Test func iFDRemove() {
        var ifd = IFD()
        ifd.set(tagID: Tag.make, value: .ascii("Apple"))
        #expect(ifd.value(for: Tag.make) != nil)
        ifd.remove(tagID: Tag.make)
        #expect(ifd.value(for: Tag.make) == nil)
    }

    @Test func iFDReplace() {
        var ifd = IFD()
        ifd.set(tagID: Tag.make, value: .ascii("Apple"))
        ifd.set(tagID: Tag.make, value: .ascii("Canon"))
        #expect(ifd.entries.count == 1)
        #expect(ifd.value(for: Tag.make)?.stringValue == "Canon")
    }

    // MARK: - TagValue

    @Test func tagValueSizes() {
        #expect(TagValue.byte(0).totalSize == 1)
        #expect(TagValue.short(0).totalSize == 2)
        #expect(TagValue.long(0).totalSize == 4)
        #expect(TagValue.rational(URational(numerator: 1, denominator: 1)).totalSize == 8)
        #expect(TagValue.ascii("Hello").totalSize == 6) // 5 chars + null
        #expect(TagValue.signedByte(0).totalSize == 1)
        #expect(TagValue.signedShort(0).totalSize == 2)
        #expect(TagValue.float(0).totalSize == 4)
        #expect(TagValue.double(0).totalSize == 8)
    }

    @Test func tagValueAccessors() throws {
        #expect(TagValue.byte(42).intValue == 42)
        #expect(TagValue.signedShort(-100).intValue == -100)
        #expect(TagValue.signedLong(-999).intValue == -999)
        #expect(try abs(#require(TagValue.float(3.14).doubleValue) - 3.14) <= 0.01)
        #expect(try abs(#require(TagValue.double(2.718).doubleValue) - 2.718) <= 0.001)
        #expect(TagValue.ascii("test").stringValue == "test")
        #expect(TagValue.long(0).stringValue == nil)

        let data = Data([0x01, 0x02, 0x03])
        #expect(TagValue.undefined(data).rawData == data)
    }

    @Test func tagValueDataTypes() {
        #expect(TagValue.signedByte(0).dataType == .sbyte)
        #expect(TagValue.signedShort(0).dataType == .sshort)
        #expect(TagValue.float(0).dataType == .float)
        #expect(TagValue.double(0).dataType == .double)
    }

    // MARK: - All data type round-trips through IFD

    @Test func allDataTypeSerializationRoundTrip() async throws {
        var ifd = IFD()
        ifd.set(tagID: 0x0001, value: .byte(42))
        ifd.set(tagID: 0x0002, value: .ascii("Hello"))
        ifd.set(tagID: 0x0003, value: .short(1000))
        ifd.set(tagID: 0x0004, value: .long(100_000))
        ifd.set(tagID: 0x0005, value: .rational(URational(numerator: 22, denominator: 7)))
        ifd.set(tagID: 0x0006, value: .signedByte(-42))
        ifd.set(tagID: 0x0007, value: .undefined(Data([0xDE, 0xAD])))
        ifd.set(tagID: 0x0008, value: .signedShort(-500))
        ifd.set(tagID: 0x0009, value: .signedLong(-100_000))
        ifd.set(tagID: 0x000A, value: .srational(SRational(numerator: -22, denominator: 7)))

        let byteOrder = ByteOrder.littleEndian
        let written = IFDWriter.writeIFD(ifd, baseOffset: 0, byteOrder: byteOrder)
        let parsed = try await IFDReader.readIFD(from: written, at: 0, byteOrder: byteOrder)

        #expect(parsed.entries.count == 10)
        #expect(parsed.value(for: 0x0001)?.intValue == 42)
        #expect(parsed.value(for: 0x0002)?.stringValue == "Hello")
        #expect(parsed.value(for: 0x0003)?.intValue == 1000)
        #expect(parsed.value(for: 0x0004)?.intValue == 100_000)
        #expect(try abs(#require(parsed.value(for: 0x0005)?.doubleValue) - (22.0 / 7.0)) <= 0.0001)
        #expect(parsed.value(for: 0x0006)?.intValue == -42)
        #expect(parsed.value(for: 0x0008)?.intValue == -500)
        #expect(parsed.value(for: 0x0009)?.intValue == -100_000)
        #expect(try abs(#require(parsed.value(for: 0x000A)?.doubleValue) - (-22.0 / 7.0)) <= 0.0001)
    }

    // MARK: - GPS helpers

    @Test func gPSCoordinateRoundTrip() throws {
        var structure = TIFFStructure(byteOrder: .bigEndian)
        structure.setGPSCoordinates(latitude: 51.5074, longitude: -0.1278, altitude: 11.0)

        #expect(structure.latitude != nil)
        #expect(structure.longitude != nil)
        #expect(try abs(#require(structure.latitude) - 51.5074) <= 0.0001)
        #expect(try abs(#require(structure.longitude) - -0.1278) <= 0.0001)
        #expect(try abs(#require(structure.altitude) - 11.0) <= 0.01)
    }

    @Test func gPSNegativeAltitude() throws {
        var structure = TIFFStructure(byteOrder: .bigEndian)
        structure.setGPSCoordinates(latitude: 31.5, longitude: 35.5, altitude: -400.0)
        #expect(try abs(#require(structure.altitude) - -400.0) <= 0.1)
    }

    @Test func gPSSouthernHemisphere() throws {
        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.setGPSCoordinates(latitude: -33.8688, longitude: 151.2093)
        #expect(try abs(#require(structure.latitude) - -33.8688) <= 0.001)
        #expect(try abs(#require(structure.longitude) - 151.2093) <= 0.001)
    }

    // MARK: - Format Detection

    @Test func formatDetection() {
        let jpeg = Data([
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        #expect(ImageFormat.detect(from: jpeg) == .jpeg)

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(ImageFormat.detect(from: png) == .png)

        let tiffLE = Data([
            0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        #expect(ImageFormat.detect(from: tiffLE) == .tiff)

        let tiffBE = Data([
            0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        #expect(ImageFormat.detect(from: tiffBE) == .tiff)

        // CR2: TIFF + "CR" at bytes 8-9
        let cr2 = Data([0x49, 0x49, 0x2A, 0x00, 0x10, 0x00, 0x00, 0x00, 0x43, 0x52, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(ImageFormat.detect(from: cr2) == .cr2)

        // ORF: magic 0x4F52
        let orf = Data([0x49, 0x49, 0x52, 0x4F, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(ImageFormat.detect(from: orf) == .orf)

        // RW2: magic 0x0055
        let rw2 = Data([0x49, 0x49, 0x55, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(ImageFormat.detect(from: rw2) == .rw2)

        let unknown = Data([
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        #expect(ImageFormat.detect(from: unknown) == nil)
    }

    @Test func extensionDetection() {
        #expect(ImageFormat.detect(fromExtension: "jpg") == .jpeg)
        #expect(ImageFormat.detect(fromExtension: "JPEG") == .jpeg)
        #expect(ImageFormat.detect(fromExtension: "png") == .png)
        #expect(ImageFormat.detect(fromExtension: "tif") == .tiff)
        #expect(ImageFormat.detect(fromExtension: "dng") == .dng)
        #expect(ImageFormat.detect(fromExtension: "cr2") == .cr2)
        #expect(ImageFormat.detect(fromExtension: "cr3") == .cr3)
        #expect(ImageFormat.detect(fromExtension: "nef") == .nef)
        #expect(ImageFormat.detect(fromExtension: "arw") == .arw)
        #expect(ImageFormat.detect(fromExtension: "raf") == .raf)
        #expect(ImageFormat.detect(fromExtension: "orf") == .orf)
        #expect(ImageFormat.detect(fromExtension: "rw2") == .rw2)
        #expect(ImageFormat.detect(fromExtension: "pef") == .pef)
        #expect(ImageFormat.detect(fromExtension: "heic") == .heif)
        #expect(ImageFormat.detect(fromExtension: "avif") == .heif)
        #expect(ImageFormat.detect(fromExtension: "bmp") == nil)
    }

    @Test func imageFormatProperties() {
        #expect(ImageFormat.cr2.isTIFFBased)
        #expect(ImageFormat.nef.isTIFFBased)
        #expect(ImageFormat.orf.isTIFFBased)
        #expect(!(ImageFormat.jpeg.isTIFFBased))
        #expect(!(ImageFormat.cr3.isTIFFBased))

        #expect(ImageFormat.cr3.isISOBMFF)
        #expect(ImageFormat.heif.isISOBMFF)
        #expect(!(ImageFormat.jpeg.isISOBMFF))
    }

    // MARK: - IFD Writer round-trip

    @Test func iFDWriteReadRoundTrip() async throws {
        var ifd = IFD()
        ifd.set(tagID: Tag.make, value: .ascii("TestCamera"))
        ifd.set(tagID: Tag.model, value: .ascii("Model X"))
        ifd.set(tagID: Tag.orientation, value: .short(1))
        ifd.set(tagID: Tag.xResolution, value: .rational(URational(numerator: 72, denominator: 1)))

        let byteOrder = ByteOrder.littleEndian
        let written = IFDWriter.writeIFD(ifd, baseOffset: 0, byteOrder: byteOrder)
        let parsed = try await IFDReader.readIFD(from: written, at: 0, byteOrder: byteOrder)

        #expect(parsed.entries.count == 4)
        #expect(parsed.value(for: Tag.make)?.stringValue == "TestCamera")
        #expect(parsed.value(for: Tag.model)?.stringValue == "Model X")
        #expect(parsed.value(for: Tag.orientation)?.uint32Value == 1)
        #expect(parsed.value(for: Tag.xResolution)?.doubleValue == 72.0)
    }

    // MARK: - TIFF Structure round-trip

    @Test func tIFFSerializeParseRoundTrip() async throws {
        var structure = TIFFStructure(byteOrder: .bigEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Apple"))
        structure.ifd0.set(tagID: Tag.model, value: .ascii("iPhone 15 Pro"))
        structure.ifd0.set(tagID: Tag.orientation, value: .short(1))

        structure.exifIFD = IFD()
        structure.exifIFD?.set(tagID: Tag.isoSpeedRatings, value: .short(100))
        structure.exifIFD?.set(tagID: Tag.fNumber, value: .rational(URational(numerator: 18, denominator: 10)))
        structure.exifIFD?.set(tagID: Tag.lensModel, value: .ascii("iPhone 15 Pro back triple camera 6.765mm f/1.78"))

        structure.setGPSCoordinates(latitude: 37.7749, longitude: -122.4194)

        let tiffData = TIFFSerializer.encode(structure)
        let parsed = try await TIFFParser.parse(tiffData)

        #expect(parsed.make == "Apple")
        #expect(parsed.model == "iPhone 15 Pro")
        #expect(parsed.orientation == 1)
        #expect(parsed.iso == 100)
        #expect(parsed.fNumber != nil)
        #expect(try abs(#require(parsed.fNumber) - 1.8) <= 0.01)
        #expect(parsed.lensModel == "iPhone 15 Pro back triple camera 6.765mm f/1.78")
        #expect(try abs(#require(parsed.latitude) - 37.7749) <= 0.001)
        #expect(try abs(#require(parsed.longitude) - -122.4194) <= 0.001)
    }

    // MARK: - Convenience accessors

    @Test func convenienceAccessors() throws {
        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("NIKON CORPORATION"))
        structure.ifd0.set(tagID: Tag.model, value: .ascii("NIKON Z 8"))
        structure.ifd0.set(tagID: Tag.imageDescription, value: .ascii("Test Photo"))
        structure.ifd0.set(tagID: Tag.artist, value: .ascii("Photographer"))
        structure.ifd0.set(tagID: Tag.copyright, value: .ascii("2024"))
        structure.ifd0.set(tagID: Tag.software, value: .ascii("EXIFKit"))

        structure.exifIFD = IFD()
        structure.exifIFD?.set(tagID: Tag.dateTimeOriginal, value: .ascii("2024:01:15 14:30:00"))
        structure.exifIFD?.set(tagID: Tag.dateTimeDigitized, value: .ascii("2024:01:15 14:30:00"))
        structure.exifIFD?.set(tagID: Tag.offsetTimeOriginal, value: .ascii("+09:00"))
        structure.exifIFD?.set(tagID: Tag.focalLength35mm, value: .short(50))
        structure.exifIFD?.set(tagID: Tag.exposureBias, value: .srational(SRational(numerator: -1, denominator: 3)))
        structure.exifIFD?.set(tagID: Tag.lensMake, value: .ascii("NIKKOR"))
        structure.exifIFD?.set(tagID: Tag.flash, value: .short(0x0001)) // fired
        structure.exifIFD?.set(tagID: Tag.colorSpace, value: .short(1)) // sRGB
        structure.exifIFD?.set(tagID: Tag.pixelXDimension, value: .long(8256))
        structure.exifIFD?.set(tagID: Tag.pixelYDimension, value: .long(5504))

        #expect(structure.imageDescription == "Test Photo")
        #expect(structure.artist == "Photographer")
        #expect(structure.copyright == "2024")
        #expect(structure.dateTimeDigitized == "2024:01:15 14:30:00")
        #expect(structure.offsetTimeOriginal == "+09:00")
        #expect(structure.focalLength35mm == 50)
        #expect(try abs(#require(structure.exposureBias) - (-1.0 / 3.0)) <= 0.001)
        #expect(structure.lensMake == "NIKKOR")
        #expect(structure.flashFired == true)
        #expect(structure.colorSpace == 1)
        #expect(structure.pixelWidth == 8256)
        #expect(structure.pixelHeight == 5504)
    }

    // MARK: - Error descriptions

    @Test func errorDescriptions() {
        let err1 = EXIFError.invalidJPEG("no SOI")
        #expect(err1.description.contains("JPEG"))
        #expect(err1.errorDescription != nil)

        let err2 = EXIFError.invalidHEIF("no meta")
        #expect(err2.description.contains("HEIF"))

        let err3 = EXIFError.writeFailed("size mismatch")
        #expect(err3.description.contains("Write"))
    }

    // MARK: - Rational number edge cases

    @Test func rationalZeroDenominator() {
        let r = URational(numerator: 1, denominator: 0)
        #expect(r.doubleValue == 0) // Not NaN or crash

        let sr = SRational(numerator: -1, denominator: 0)
        #expect(sr.doubleValue == 0)
    }

    @Test func rationalFromDouble() {
        let r = URational(3.14159)
        #expect(abs((r.doubleValue) - 3.14159) <= 0.001)

        let sr = SRational(-2.5)
        #expect(abs((sr.doubleValue) - -2.5) <= 0.001)
    }

    // MARK: - CRC32 (PNG)

    @Test func pNGRoundTrip() async throws {
        // Build a minimal valid PNG
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var png = signature

        // IHDR chunk (13 bytes of data)
        let ihdrData = Data([
            0x00, 0x00, 0x00, 0x01, // width = 1
            0x00, 0x00, 0x00, 0x01, // height = 1
            0x08, // bit depth = 8
            0x02, // color type = RGB
            0x00, 0x00, 0x00, // compression, filter, interlace
        ])
        png.append(buildPNGChunk(type: "IHDR", data: ihdrData))

        // Minimal IDAT
        let idatData = Data([0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01])
        png.append(buildPNGChunk(type: "IDAT", data: idatData))

        // IEND
        png.append(buildPNGChunk(type: "IEND", data: Data()))

        // Create EXIF structure and write it into the PNG
        var structure = TIFFStructure(byteOrder: .bigEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("TestCam"))
        let withExif = try await PNGContainer.writeEXIF(
            TIFFStructure(byteOrder: .bigEndian, ifd0: structure.ifd0),
            to: png
        )

        // Read it back
        let parsed = try await PNGContainer.readEXIF(from: withExif)
        #expect(parsed.make == "TestCam")

        // Strip and verify
        let stripped = try await PNGContainer.stripEXIF(from: withExif)
        await #expect(throws: (any Error).self) { try await PNGContainer.readEXIF(from: stripped) }
    }

    private func buildPNGChunk(type: String, data: Data) -> Data {
        var chunk = Data()
        var length = UInt32(data.count).bigEndian
        chunk.append(Data(bytes: &length, count: 4))
        let typeBytes = Array(type.utf8)
        chunk.append(contentsOf: typeBytes)
        chunk.append(data)
        // CRC32
        var crcInput = Data(typeBytes)
        crcInput.append(data)
        var crc = crc32(crcInput).bigEndian
        chunk.append(Data(bytes: &crc, count: 4))
        return chunk
    }

    private func crc32(_ data: Data) -> UInt32 {
        let table: [UInt32] = (0 ..< 256).map { n -> UInt32 in
            var c = UInt32(n)
            for _ in 0 ..< 8 {
                c = (c & 1 != 0) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - Dump

    @Test func dumpOutput() {
        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Apple"))
        structure.ifd0.set(tagID: Tag.model, value: .ascii("iPhone"))
        structure.exifIFD = IFD()
        structure.exifIFD?.set(tagID: Tag.isoSpeedRatings, value: .short(800))
        structure.setGPSCoordinates(latitude: 37.0, longitude: -122.0)

        let dump = EXIFKit.dump(structure)
        #expect(dump.contains("Apple"))
        #expect(dump.contains("iPhone"))
        #expect(dump.contains("800"))
        #expect(dump.contains("37.0"))
        #expect(dump.contains("Byte Order"))
    }

    // MARK: - JPEG Full Round-Trip

    private func buildMinimalJPEG() -> Data {
        var jpeg = Data()
        jpeg.append(contentsOf: [0xFF, 0xD8]) // SOI
        jpeg.append(contentsOf: [0xFF, 0xE0]) // APP0
        let jfifPayload = Data([0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
        let jfifLen = UInt16(jfifPayload.count + 2)
        jpeg.append(UInt8(jfifLen >> 8))
        jpeg.append(UInt8(jfifLen & 0xFF))
        jpeg.append(jfifPayload)
        jpeg.append(contentsOf: [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x00, 0x00, 0x3F, 0x00, 0x7B])
        jpeg.append(contentsOf: [0x00, 0x01, 0x02, 0x03])
        jpeg.append(contentsOf: [0xFF, 0xD9]) // EOI
        return jpeg
    }

    @Test func jPEGWriteReadRoundTrip() async throws {
        let jpeg = buildMinimalJPEG()
        #expect(ImageFormat.detect(from: jpeg) == .jpeg)

        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("TestCamera"))
        structure.ifd0.set(tagID: Tag.model, value: .ascii("Model X"))
        structure.ifd0.set(tagID: Tag.orientation, value: .short(1))

        structure.exifIFD = IFD()
        structure.exifIFD?.set(tagID: Tag.isoSpeedRatings, value: .short(400))
        structure.exifIFD?.set(tagID: Tag.fNumber, value: .rational(URational(numerator: 28, denominator: 10)))
        structure.exifIFD?.set(tagID: Tag.dateTimeOriginal, value: .ascii("2024:06:15 10:30:00"))

        let withExif = try await EXIFKit.write(structure, to: jpeg)
        let parsed = try await EXIFKit.read(from: withExif)

        #expect(parsed.make == "TestCamera")
        #expect(parsed.model == "Model X")
        #expect(parsed.orientation == 1)
        #expect(parsed.iso == 400)
        #expect(try abs(#require(parsed.fNumber) - 2.8) <= 0.01)
        #expect(parsed.dateTimeOriginal == "2024:06:15 10:30:00")
    }

    @Test func jPEGWriteWithGPSThenModify() async throws {
        let jpeg = buildMinimalJPEG()

        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Camera"))
        structure.setGPSCoordinates(latitude: 51.5074, longitude: -0.1278, altitude: 30.0)

        let withGPS = try await EXIFKit.write(structure, to: jpeg)
        let parsed = try await EXIFKit.read(from: withGPS)
        #expect(try abs(#require(parsed.latitude) - 51.5074) <= 0.001)
        #expect(try abs(#require(parsed.longitude) - -0.1278) <= 0.001)
        #expect(try abs(#require(parsed.altitude) - 30.0) <= 0.1)

        // Modify GPS
        var modified = parsed
        modified.setGPSCoordinates(latitude: 48.8566, longitude: 2.3522)
        modified.ifd0.set(tagID: Tag.software, value: .ascii("EXIFKit"))

        let rewritten = try await EXIFKit.write(modified, to: withGPS)
        let reparsed = try await EXIFKit.read(from: rewritten)
        #expect(reparsed.software == "EXIFKit")
        #expect(try abs(#require(reparsed.latitude) - 48.8566) <= 0.001)
        #expect(try abs(#require(reparsed.longitude) - 2.3522) <= 0.001)
    }

    @Test func jPEGStripEXIF() async throws {
        let jpeg = buildMinimalJPEG()

        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Camera"))
        let withExif = try await EXIFKit.write(structure, to: jpeg)

        // Verify EXIF exists
        _ = try await EXIFKit.read(from: withExif)

        // Strip
        let stripped = try await EXIFKit.strip(from: withExif)
        await #expect(throws: (any Error).self) { try await EXIFKit.read(from: stripped) }
    }

    // MARK: - TIFF Container Round-Trip

    @Test func tIFFContainerAddGPS() async throws {
        // Build a minimal TIFF
        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Nikon"))
        structure.ifd0.set(tagID: Tag.model, value: .ascii("Z 8"))
        structure.exifIFD = IFD()
        structure.exifIFD?.set(tagID: Tag.isoSpeedRatings, value: .short(200))
        let tiff = TIFFSerializer.encode(structure)

        let parsed = try await EXIFKit.read(from: tiff, format: .tiff)
        #expect(parsed.make == "Nikon")
        #expect(parsed.gpsIFD == nil)

        // Add GPS
        var modified = parsed
        modified.setGPSCoordinates(latitude: 35.6762, longitude: 139.6503)
        let written = try await EXIFKit.write(modified, to: tiff)
        let reparsed = try await EXIFKit.read(from: written, format: .tiff)

        #expect(reparsed.make == "Nikon")
        #expect(reparsed.model == "Z 8")
        #expect(reparsed.iso == 200)
        #expect(try abs(#require(reparsed.latitude) - 35.6762) <= 0.001)
        #expect(try abs(#require(reparsed.longitude) - 139.6503) <= 0.001)
    }

    // MARK: - Big Endian Round-Trip

    @Test func bigEndianTIFFRoundTrip() async throws {
        var structure = TIFFStructure(byteOrder: .bigEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Canon"))
        structure.exifIFD = IFD()
        structure.exifIFD?.set(
            tagID: Tag.lensSpecification,
            value: .rationals([
                URational(numerator: 24, denominator: 1),
                URational(numerator: 105, denominator: 1),
                URational(numerator: 40, denominator: 10),
                URational(numerator: 40, denominator: 10),
            ])
        )
        structure.exifIFD?.set(tagID: Tag.exifVersion, value: .undefined(Data([0x30, 0x32, 0x33, 0x32])))

        let tiffData = TIFFSerializer.encode(structure)
        let parsed = try await TIFFParser.parse(tiffData)

        #expect(parsed.make == "Canon")
        if case let .rationals(rats) = parsed.exifIFD?.value(for: Tag.lensSpecification) {
            #expect(rats.count == 4)
            #expect(rats[0].doubleValue == 24.0)
            #expect(rats[1].doubleValue == 105.0)
        } else {
            Issue.record("Expected rationals for lens spec")
        }
        if case let .undefined(data) = parsed.exifIFD?.value(for: Tag.exifVersion) {
            #expect(String(data: data, encoding: .ascii) == "0232")
        } else {
            Issue.record("Expected undefined for exif version")
        }
    }

    // MARK: - All IFD Array Types Round-Trip

    @Test func arrayDataTypesRoundTrip() async throws {
        var ifd = IFD()
        ifd.set(tagID: 0xF001, value: .float(3.14))
        ifd.set(tagID: 0xF002, value: .double(2.71828))
        ifd.set(tagID: 0xF003, value: .floats([1.0, 2.0, 3.0]))
        ifd.set(tagID: 0xF004, value: .doubles([4.0, 5.0]))
        ifd.set(tagID: 0xF005, value: .shorts([100, 200, 300]))
        ifd.set(tagID: 0xF006, value: .longs([1000, 2000]))
        ifd.set(tagID: 0xF007, value: .signedShorts([-1, -2, -3]))
        ifd.set(tagID: 0xF008, value: .signedLongs([-100, -200]))
        ifd.set(
            tagID: 0xF009,
            value: .srationals([
                SRational(numerator: -1, denominator: 3),
                SRational(numerator: 2, denominator: 3),
            ])
        )
        ifd.set(tagID: 0xF00A, value: .bytes([0x01, 0x02, 0x03, 0x04, 0x05]))
        ifd.set(tagID: 0xF00B, value: .signedBytes([-1, -2, 3, 4]))

        let written = IFDWriter.writeIFD(ifd, baseOffset: 0, byteOrder: .littleEndian)
        let parsed = try await IFDReader.readIFD(from: written, at: 0, byteOrder: .littleEndian)

        if case let .float(f) = parsed.value(for: 0xF001) {
            #expect(abs(f - 3.14) <= 0.001)
        } else {
            Issue.record("float")
        }

        if case let .double(d) = parsed.value(for: 0xF002) {
            #expect(abs(d - 2.71828) <= 0.0001)
        } else {
            Issue.record("double")
        }

        if case let .floats(fs) = parsed.value(for: 0xF003) {
            #expect(fs == [1.0, 2.0, 3.0])
        } else {
            Issue.record("floats")
        }

        if case let .doubles(ds) = parsed.value(for: 0xF004) {
            #expect(ds == [4.0, 5.0])
        } else {
            Issue.record("doubles")
        }

        if case let .shorts(ss) = parsed.value(for: 0xF005) {
            #expect(ss == [100, 200, 300])
        } else {
            Issue.record("shorts")
        }

        if case let .longs(ls) = parsed.value(for: 0xF006) {
            #expect(ls == [1000, 2000])
        } else {
            Issue.record("longs")
        }

        if case let .signedShorts(ss) = parsed.value(for: 0xF007) {
            #expect(ss == [-1, -2, -3])
        } else {
            Issue.record("signedShorts")
        }

        if case let .signedLongs(sl) = parsed.value(for: 0xF008) {
            #expect(sl == [-100, -200])
        } else {
            Issue.record("signedLongs")
        }

        if case let .srationals(srs) = parsed.value(for: 0xF009) {
            #expect(srs.count == 2)
            #expect(srs[0].numerator == -1)
            #expect(srs[0].denominator == 3)
        } else {
            Issue.record("srationals")
        }

        if case let .bytes(bs) = parsed.value(for: 0xF00A) {
            #expect(bs == [0x01, 0x02, 0x03, 0x04, 0x05])
        } else {
            Issue.record("bytes")
        }

        if case let .signedBytes(sbs) = parsed.value(for: 0xF00B) {
            #expect(sbs == [-1, -2, 3, 4])
        } else {
            Issue.record("signedBytes")
        }
    }

    // MARK: - PNG Write + Modify Round-Trip

    @Test func pNGWriteModifyRoundTrip() async throws {
        // Build minimal PNG
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var png = signature
        let ihdrData = Data([
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00,
        ])
        png.append(buildPNGChunk(type: "IHDR", data: ihdrData))
        let idatData = Data([0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01])
        png.append(buildPNGChunk(type: "IDAT", data: idatData))
        png.append(buildPNGChunk(type: "IEND", data: Data()))

        // Write initial EXIF
        var s = TIFFStructure(byteOrder: .bigEndian)
        s.ifd0.set(tagID: Tag.make, value: .ascii("TestCam"))
        s.exifIFD = IFD()
        s.exifIFD?.set(tagID: Tag.isoSpeedRatings, value: .short(100))
        s.setGPSCoordinates(latitude: 37.0, longitude: -122.0)

        let withExif = try await PNGContainer.writeEXIF(s, to: png)
        let parsed = try await PNGContainer.readEXIF(from: withExif)
        #expect(parsed.make == "TestCam")
        #expect(parsed.iso == 100)
        #expect(try abs(#require(parsed.latitude) - 37.0) <= 0.01)

        // Modify
        var modified = parsed
        modified.setGPSCoordinates(latitude: 48.0, longitude: 2.0)
        let rewritten = try await PNGContainer.writeEXIF(modified, to: withExif)
        let reparsed = try await PNGContainer.readEXIF(from: rewritten)
        #expect(reparsed.make == "TestCam")
        #expect(try abs(#require(reparsed.latitude) - 48.0) <= 0.01)
        #expect(try abs(#require(reparsed.longitude) - 2.0) <= 0.01)
    }

    // MARK: - EXIFKit Auto-Detection Integration

    @Test func autoDetectJPEG() async throws {
        let jpeg = buildMinimalJPEG()
        var s = TIFFStructure(byteOrder: .littleEndian)
        s.ifd0.set(tagID: Tag.make, value: .ascii("Auto"))
        let withExif = try await EXIFKit.write(s, to: jpeg)
        let parsed = try await EXIFKit.read(from: withExif)
        #expect(parsed.make == "Auto")
    }

    @Test func autoDetectPNG() async throws {
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var png = signature
        let ihdr = Data([0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00])
        png.append(buildPNGChunk(type: "IHDR", data: ihdr))
        let idat = Data([0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01])
        png.append(buildPNGChunk(type: "IDAT", data: idat))
        png.append(buildPNGChunk(type: "IEND", data: Data()))

        var s = TIFFStructure(byteOrder: .bigEndian)
        s.ifd0.set(tagID: Tag.make, value: .ascii("PNGCam"))
        let withExif = try await EXIFKit.write(s, to: png)
        let parsed = try await EXIFKit.read(from: withExif)
        #expect(parsed.make == "PNGCam")
    }

    @Test func unsupportedFormat() async throws {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        await #expect(throws: (any Error).self) { try await EXIFKit.read(from: garbage) }
    }

    // MARK: - Tag Name Lookup

    @Test func tagNameLookup() {
        #expect(Tag.name(for: Tag.make) == "Make")
        #expect(Tag.name(for: Tag.model) == "Model")
        #expect(Tag.name(for: 0xFFFF).contains("Unknown"))
        #expect(Tag.gpsName(for: Tag.gpsLatitude) == "GPSLatitude")
        #expect(Tag.gpsName(for: 0xFFFF).contains("Unknown"))
    }

    // MARK: - IFD Writer Big Endian

    @Test func iFDWriteReadBigEndian() async throws {
        var ifd = IFD()
        ifd.set(tagID: Tag.make, value: .ascii("BigEndianCam"))
        ifd.set(tagID: Tag.orientation, value: .short(6))
        ifd.set(tagID: Tag.xResolution, value: .rational(URational(numerator: 300, denominator: 1)))

        let written = IFDWriter.writeIFD(ifd, baseOffset: 0, byteOrder: .bigEndian)
        let parsed = try await IFDReader.readIFD(from: written, at: 0, byteOrder: .bigEndian)

        #expect(parsed.value(for: Tag.make)?.stringValue == "BigEndianCam")
        #expect(parsed.value(for: Tag.orientation)?.uint32Value == 6)
        #expect(parsed.value(for: Tag.xResolution)?.doubleValue == 300.0)
    }

    // MARK: - MakerNote Passthrough

    @Test func makerNotePreservedAsUndefined() async throws {
        // Simulate a MakerNote blob surviving a TIFF round-trip
        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Canon"))
        structure.exifIFD = IFD()
        let fakeNote = Data(repeating: 0xAB, count: 256)
        structure.exifIFD?.set(tagID: Tag.makerNote, value: .undefined(fakeNote))

        let tiffData = TIFFSerializer.encode(structure)
        let parsed = try await TIFFParser.parse(tiffData)

        if case let .undefined(data) = parsed.exifIFD?.value(for: Tag.makerNote) {
            #expect(data.count == 256)
            #expect(data[0] == 0xAB)
        } else {
            Issue.record("MakerNote should be preserved as undefined")
        }
    }

    // MARK: - Regression: shared parsing

    @Test func readBytesRejectsNegativeCount() throws {
        var reader = ByteReader(data: Data([0x01, 0x02]), byteOrder: .bigEndian)
        #expect(throws: (any Error).self) { try reader.readBytes(-1) }
    }

    @Test func nonASCIIStringsRoundTrip() async throws {
        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.artist, value: .ascii("José Müller"))
        structure.ifd0.set(tagID: Tag.copyright, value: .ascii("© 2024"))

        let parsed = try await TIFFParser.parse(TIFFSerializer.encode(structure))
        #expect(parsed.artist == "José Müller")
        #expect(parsed.copyright == "© 2024")
    }

    @Test func iFDTypedSubIFDPointerResolves() async throws {
        var structure = TIFFStructure(byteOrder: .bigEndian)
        structure.exifIFD = IFD()
        structure.exifIFD?.set(tagID: Tag.isoSpeedRatings, value: .short(640))
        var tiff = TIFFSerializer.encode(structure)

        // IFD0 (at 8) holds only the EXIF pointer; retype it from LONG (4) to IFD (13)
        #expect(tiff[12 ... 13] == Data([0x00, 0x04]))
        tiff[13] = 13
        #expect(try await TIFFParser.parse(tiff).iso == 640)
    }

    // MARK: - Regression: JPEG

    /// Camera-style EXIF block: IFD0 → ExifIFD → InteropIFD, and IFD1 whose JPEG thumbnail sits after all IFDs.
    private func buildCameraTIFF(thumbnail: Data) -> Data {
        let byteOrder = ByteOrder.littleEndian
        func size(_ ifd: IFD) -> Int {
            IFDWriter.writeIFD(ifd, baseOffset: 0, byteOrder: byteOrder).count
        }

        var ifd0 = IFD()
        ifd0.set(tagID: Tag.make, value: .ascii("Canon"))
        ifd0.set(tagID: Tag.exifIFDPointer, value: .long(0))
        var ifd1 = IFD()
        ifd1.set(tagID: 0x0201, value: .long(0)) // JPEGInterchangeFormat
        ifd1.set(tagID: 0x0202, value: .long(UInt32(thumbnail.count)))
        var exif = IFD()
        exif.set(tagID: Tag.isoSpeedRatings, value: .short(100))
        exif.set(tagID: 0xA005, value: .long(0)) // InteropIFDPointer
        var interop = IFD()
        interop.set(tagID: 0x0001, value: .ascii("R98"))

        let ifd1Offset = 8 + size(ifd0)
        let exifOffset = ifd1Offset + size(ifd1)
        let interopOffset = exifOffset + size(exif)
        ifd0.set(tagID: Tag.exifIFDPointer, value: .long(UInt32(exifOffset)))
        ifd0.nextIFDOffset = UInt32(ifd1Offset)
        ifd1.set(tagID: 0x0201, value: .long(UInt32(interopOffset + size(interop))))
        exif.set(tagID: 0xA005, value: .long(UInt32(interopOffset)))

        var writer = ByteWriter(byteOrder: byteOrder)
        writer.writeBytes([0x49, 0x49])
        writer.writeUInt16(42)
        writer.writeUInt32(8)
        for (ifd, offset) in [(ifd0, 8), (ifd1, ifd1Offset), (exif, exifOffset), (interop, interopOffset)] {
            writer.writeBytes(IFDWriter.writeIFD(ifd, baseOffset: UInt32(offset), byteOrder: byteOrder))
        }
        writer.writeBytes(thumbnail)
        return writer.data
    }

    /// buildMinimalJPEG with an EXIF APP1 holding `tiff` right after SOI
    private func buildJPEG(exif tiff: Data) -> Data {
        let payload = Data("Exif".utf8) + [0, 0] + tiff
        let length = payload.count + 2
        return Data([0xFF, 0xD8, 0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)])
            + payload + buildMinimalJPEG().dropFirst(2)
    }

    @Test func jPEGRewriteKeepsThumbnailAndInteropIFD() async throws {
        let thumbnail = Data([0xFF, 0xD8]) + Data(repeating: 0x5A, count: 300) + Data([0xFF, 0xD9])
        let jpeg = buildJPEG(exif: buildCameraTIFF(thumbnail: thumbnail))
        var structure = try await EXIFKit.read(from: jpeg)
        #expect(try await structure.thumbnailData == thumbnail)

        structure.ifd0.set(tagID: Tag.software, value: .ascii("EXIFKit"))
        let rewritten = try await EXIFKit.read(from: await EXIFKit.write(structure, to: jpeg))

        #expect(rewritten.software == "EXIFKit")
        #expect(try await rewritten.thumbnailData == thumbnail)
        let interop = try #require(rewritten.interopIFD)
        #expect(interop.value(for: 0x0001)?.stringValue == "R98")
    }

    @Test func jPEGWriteRejectsOversizedEXIF() async throws {
        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.exifIFD = IFD()
        structure.exifIFD?.set(tagID: Tag.makerNote, value: .undefined(Data(count: 70000)))
        await #expect(throws: (any Error).self) { try await EXIFKit.write(structure, to: buildMinimalJPEG()) }
    }

    @Test func jPEGInsertsEXIFAfterJFIFAndSkipsFillBytes() async throws {
        var jpeg = buildMinimalJPEG()
        jpeg.insert(0xFF, at: 2) // fill byte before APP0

        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Camera"))
        let written = try await EXIFKit.write(structure, to: jpeg)

        #expect([UInt8](written.prefix(5)) == [0xFF, 0xD8, 0xFF, 0xFF, 0xE0]) // JFIF APP0 stays first
        #expect(try await EXIFKit.read(from: written).make == "Camera")
    }

    @Test func jPEGWriteWithoutImageDataThrows() async throws {
        // SOI + APP0 only, e.g. a truncated download: there is no SOS to carry over
        let headerOnly = buildMinimalJPEG().prefix(20)
        await #expect(throws: (any Error).self) {
            try await EXIFKit.write(TIFFStructure(byteOrder: .littleEndian), to: headerOnly)
        }
    }

    // MARK: - Regression: TIFF

    @Test func tIFFWriteKeepsIFDsWordAligned() async throws {
        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Nikon"))
        let tiff = TIFFSerializer.encode(structure) + [0x00] // odd length, like trailing image data

        var modified = try await EXIFKit.read(from: tiff, format: .tiff)
        modified.setGPSCoordinates(latitude: 1, longitude: 2)
        let written = try await EXIFKit.write(modified, to: tiff, format: .tiff)

        var reader = ByteReader(data: written, byteOrder: .littleEndian)
        try reader.seek(to: 4)
        #expect(try reader.readUInt32() % 2 == 0)
        let gpsPointer = try #require(
            await EXIFKit.read(from: written, format: .tiff).ifd0.value(for: Tag.gpsIFDPointer)
        )
        #expect(try #require(gpsPointer.uint32Value) % 2 == 0)
    }

    @Test func tIFFRewriteReusesOriginalBytes() async throws {
        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Canon"))
        structure.exifIFD = IFD()
        structure.exifIFD?.set(tagID: Tag.isoSpeedRatings, value: .short(100))
        structure.exifIFD?.set(tagID: Tag.makerNote, value: .undefined(Data(repeating: 0xAB, count: 4096)))
        let tiff = TIFFSerializer.encode(structure)

        // An unchanged write is byte-identical
        #expect(try await EXIFKit.write(await EXIFKit.read(from: tiff), to: tiff) == tiff)

        // An edit appends only what changed; the 4 KB MakerNote stays where it was
        var edited = try await EXIFKit.read(from: tiff)
        edited.exifIFD?.set(tagID: Tag.isoSpeedRatings, value: .short(200))
        edited.ifd0.set(tagID: Tag.artist, value: .ascii("Someone"))
        let once = try await EXIFKit.write(edited, to: tiff)
        #expect(once.count - tiff.count < 256)
        #expect(try await EXIFKit.read(from: once).iso == 200)
        #expect(
            once.range(of: Data(repeating: 0xAB, count: 4096)) == tiff.range(of: Data(repeating: 0xAB, count: 4096))
        )

        // Saving the same metadata again doesn't grow the file
        #expect(try await EXIFKit.write(edited, to: once).count == once.count)
    }

    @Test func tIFFStripErasesOldGPSBytes() async throws {
        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Nikon"))
        structure.setGPSCoordinates(latitude: 35.6762, longitude: 139.6503)
        structure.gpsIFD?.set(tagID: Tag.gpsMapDatum, value: .ascii("SECRET-DATUM"))
        let tiff = TIFFSerializer.encode(structure)
        #expect(tiff.range(of: Data("SECRET-DATUM".utf8)) != nil)

        let stripped = try await EXIFKit.strip(from: tiff)
        let parsed = try await EXIFKit.read(from: stripped)
        #expect(parsed.gpsIFD == nil)
        #expect(parsed.make == "Nikon")
        #expect(stripped.range(of: Data("SECRET-DATUM".utf8)) == nil)
    }

    // MARK: - Regression: ISOBMFF (HEIF / CR3)

    private func box(_ type: String, _ payload: Data) -> Data {
        var writer = ByteWriter(byteOrder: .bigEndian)
        writer.writeUInt32(UInt32(payload.count + 8))
        writer.writeBytes(Data(type.utf8))
        writer.writeBytes(payload)
        return writer.data
    }

    /// Exif item per ISO 23008-12: big-endian offset to the TIFF header, "Exif\0\0", TIFF
    private func exifItem(_ tiff: Data) -> Data {
        Data([0, 0, 0, 6]) + Data("Exif".utf8) + [0, 0] + tiff
    }

    /// Minimal HEIF: ftyp + meta{iinf{infe "Exif"}, iloc} + mdat holding the Exif item.
    /// iloc uses 8-byte extent offsets so tests can point them anywhere.
    private func buildMinimalHEIF(
        item: Data, baseOffset: UInt32 = 0, iinfVersion: UInt8 = 0,
        extentOffset: UInt64? = nil
    ) -> Data {
        let ftyp = box("ftyp", Data("heic".utf8) + Data(count: 4) + Data("mif1heic".utf8))
        let infe = box("infe", Data([2, 0, 0, 0, 0, 1, 0, 0]) + Data("Exif".utf8) + [0])
        let entryCount = iinfVersion == 0 ? Data([0, 1]) : Data([0, 0, 0, 1])
        let iinf = box("iinf", Data([iinfVersion, 0, 0, 0]) + entryCount + infe)

        func meta(extentOffset: UInt64) -> Data {
            var iloc = ByteWriter(byteOrder: .bigEndian)
            iloc.writeBytes([0, 0, 0, 0]) // version 0, flags
            iloc.writeBytes([0x84, 0x40]) // offset_size 8, length_size 4, base_offset_size 4
            iloc.writeUInt16(1) // item_count
            iloc.writeUInt16(1) // item_ID
            iloc.writeUInt16(0) // data_reference_index
            iloc.writeUInt32(baseOffset)
            iloc.writeUInt16(1) // extent_count
            iloc.writeUInt32(UInt32(extentOffset >> 32))
            iloc.writeUInt32(UInt32(truncatingIfNeeded: extentOffset))
            iloc.writeUInt32(UInt32(item.count))
            return box("meta", Data(count: 4) + iinf + box("iloc", iloc.data))
        }

        let itemStart = UInt64(ftyp.count + meta(extentOffset: 0).count + 8)
        return ftyp + meta(extentOffset: extentOffset ?? itemStart - UInt64(baseOffset)) + box("mdat", item)
    }

    @Test func hEIFInPlaceWriteUsesBigEndianHeaderOffset() async throws {
        var structure = TIFFStructure(byteOrder: .bigEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Apple"))
        let heif = buildMinimalHEIF(item: exifItem(TIFFSerializer.encode(structure)) + Data(count: 64))
        #expect(ImageFormat.detect(from: heif) == .heif)

        structure.ifd0.set(tagID: Tag.model, value: .ascii("iPhone"))
        let written = try await EXIFKit.write(structure, to: heif)

        #expect(written.count == heif.count) // fit in place
        #expect(written.range(of: Data([0, 0, 0, 6]) + Data("Exif".utf8)) != nil)
        #expect(try await EXIFKit.read(from: written).model == "iPhone")
    }

    @Test func hEIFWriteThatGrowsAppendsMdat() async throws {
        // A nonzero base_offset makes the patched extent offset relative to it
        for baseOffset: UInt32 in [0, 16] {
            var structure = TIFFStructure(byteOrder: .bigEndian)
            structure.ifd0.set(tagID: Tag.make, value: .ascii("Apple"))
            let heif = buildMinimalHEIF(item: exifItem(TIFFSerializer.encode(structure)), baseOffset: baseOffset)

            structure.ifd0.set(tagID: Tag.imageDescription, value: .ascii(String(repeating: "x", count: 200)))
            let written = try await EXIFKit.write(structure, to: heif)

            #expect(try await ISOBMFFParser.parse(written).map(\.type) == ["ftyp", "meta", "mdat", "mdat"])
            #expect(try await EXIFKit.read(from: written).imageDescription?.count == 200)
        }
    }

    @Test func hEIFReadsIinfVersion1AndZeroHeaderOffset() async throws {
        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Sony"))
        // Header offset 0: TIFF starts right after the 4-byte field
        let heif = buildMinimalHEIF(item: Data(count: 4) + TIFFSerializer.encode(structure), iinfVersion: 1)
        #expect(try await EXIFKit.read(from: heif).make == "Sony")
    }

    @Test func hEIFOutOfRangeItemOffsetThrows() async throws {
        let heif = buildMinimalHEIF(item: exifItem(Data(count: 16)), extentOffset: UInt64.max - 1)
        await #expect(throws: (any Error).self) { try await EXIFKit.read(from: heif) }
        await #expect(throws: (any Error).self) {
            try await EXIFKit.write(TIFFStructure(byteOrder: .bigEndian), to: heif)
        }
        await #expect(throws: (any Error).self) { try await EXIFKit.strip(from: heif) }
    }

    /// Minimal CR3: ftyp("crx ") + moov{uuid(Canon){CMT1, CMT2}} + mdat
    private func buildMinimalCR3(ifd0: IFD, exif: IFD) -> Data {
        func cmt(_ type: String, _ ifd: IFD) -> Data {
            box(type, TIFFSerializer.encode(TIFFStructure(byteOrder: .littleEndian, ifd0: ifd)))
        }
        let uuid = box("uuid", CR3Container.canonUUID + cmt("CMT1", ifd0) + cmt("CMT2", exif))
        return box("ftyp", Data("crx ".utf8) + Data(count: 4) + Data("crx isom".utf8))
            + box("moov", uuid) + box("mdat", Data("RAWDATA".utf8))
    }

    @Test func cR3WriteNeverMovesMdat() async throws {
        var ifd0 = IFD()
        ifd0.set(tagID: Tag.make, value: .ascii("Canon"))
        ifd0.set(tagID: Tag.model, value: .ascii("Canon EOS R5"))
        var exif = IFD()
        exif.set(tagID: Tag.isoSpeedRatings, value: .short(100))
        let cr3 = buildMinimalCR3(ifd0: ifd0, exif: exif)
        #expect(ImageFormat.detect(from: cr3) == .cr3)

        // Shrinking metadata is padded in place, so mdat keeps its offset
        var structure = try await EXIFKit.read(from: cr3)
        structure.ifd0.set(tagID: Tag.model, value: .ascii("R5"))
        let written = try await EXIFKit.write(structure, to: cr3)
        #expect(written.count == cr3.count)
        #expect(written.suffix(7) == Data("RAWDATA".utf8))
        let reparsed = try await EXIFKit.read(from: written)
        #expect(reparsed.model == "R5")
        #expect(reparsed.iso == 100)

        // Growing would shift mdat (and every absolute offset into it)
        structure.ifd0.set(tagID: Tag.model, value: .ascii(String(repeating: "x", count: 100)))
        await #expect(throws: (any Error).self) { try await EXIFKit.write(structure, to: cr3) }

        // No CMT4 box to hold GPS: must not be silently dropped
        structure = try await EXIFKit.read(from: cr3)
        structure.setGPSCoordinates(latitude: 1, longitude: 2)
        await #expect(throws: (any Error).self) { try await EXIFKit.write(structure, to: cr3) }

        // Strip leaves valid empty TIFFs (decoders reject zero-filled CMT boxes) and moves nothing
        let stripped = try await EXIFKit.strip(from: cr3)
        #expect(stripped.count == cr3.count)
        #expect(try await EXIFKit.read(from: stripped).ifd0.entries.count == 0)
    }
}
