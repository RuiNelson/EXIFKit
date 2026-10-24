@testable import EXIFKit
import Foundation
import Testing

/// Represents a huge file using small regions; rejects reads through image payloads when requested.
actor SparseFile: AbstractFileHandle {
    let length: UInt64
    let regions: [(UInt64, Data)]
    let allowed: [Range<UInt64>]?
    var reads: [Range<UInt64>] = []
    var size: UInt64 {
        get async throws { length }
    }

    init(size: UInt64, regions: [(UInt64, Data)], allowed: [Range<UInt64>]? = nil) {
        length = size
        self.regions = regions
        self.allowed = allowed
    }

    func read(at offset: UInt64, count: Int) async throws -> Data {
        try validateRange(offset, count, size: length)
        let range = offset ..< offset + UInt64(count)
        if let allowed, !allowed.contains(where: { $0.lowerBound <= offset && $0.upperBound >= range.upperBound }) {
            throw EXIFError.writeFailed("Attempt to read image payload at \(range)")
        }
        reads.append(range)
        var result = Data(repeating: 0xA5, count: count)
        for (start, bytes) in regions {
            let end = start + UInt64(bytes.count)
            let lower = max(start, offset)
            let upper = min(end, range.upperBound)
            if lower < upper {
                result.replaceSubrange(
                    Int(lower - offset) ..< Int(upper - offset),
                    with: bytes.subdata(in: Int(lower - start) ..< Int(upper - start))
                )
            }
        }
        return result
    }

    var transferred: Int {
        reads.reduce(0) { $0 + Int($1.count) }
    }
}

struct HandleTests {
    static func metadata(_ order: ByteOrder = .littleEndian) -> TIFFStructure {
        var structure = TIFFStructure(byteOrder: order)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Range Camera"))
        structure.ifd0.set(tagID: Tag.model, value: .ascii("Test model"))
        structure.exifIFD = IFD()
        structure.exifIFD!.set(tagID: Tag.isoSpeedRatings, value: .short(640))
        structure.exifIFD!.set(tagID: Tag.makerNote, value: .undefined(Data(repeating: 0xBB, count: 256)))
        structure.setGPSCoordinates(latitude: 38.7223, longitude: -9.1393)
        return structure
    }

    static func box(_ type: String, _ data: Data, extended: Bool = false) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32(extended ? 1 : UInt32(data.count + 8))
        writer.writeBytes(Data(type.utf8))
        if extended {
            writer.writeUInt32(0)
            writer.writeUInt32(UInt32(data.count + 16))
        }
        writer.writeBytes(data)
        return writer.data
    }

    static func chunk(_ type: String, _ data: Data) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32(UInt32(data.count))
        writer.writeBytes(Data(type.utf8))
        writer.writeBytes(data)
        writer.writeUInt32(CRC32.calculate(Data(type.utf8) + data))
        return writer.data
    }

    static func jpeg(_ tiff: Data? = nil) -> Data {
        var data = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 7]) + Data("JFIF\0".utf8)
        if let tiff {
            var writer = ByteWriter()
            writer.writeBytes([0xFF, 0xE1])
            writer.writeUInt16(UInt16(tiff.count + 8))
            writer.writeBytes(Data("Exif\0\0".utf8))
            writer.writeBytes(tiff)
            data.append(writer.data)
        }
        return data + Data([0xFF, 0xDA, 0, 2]) + Data(repeating: 0xDD, count: 5000) + Data([0xFF, 0xD9])
    }

    static func png(_ tiff: Data? = nil) -> Data {
        var data = Data([137, 80, 78, 71, 13, 10, 26, 10])
        data.append(chunk("IHDR", Data([0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0])))
        data.append(chunk("IDAT", Data(repeating: 0xDD, count: 5000)))
        if let tiff {
            data.append(chunk("eXIf", tiff))
        } // metadata after image data must still work
        data.append(chunk("IEND", Data()))
        return data
    }

    static func heif(_ tiff: Data, fragmented: Bool = false, idat: Bool = false, extended: Bool = false) -> Data {
        let item = Data([0, 0, 0, 6]) + Data("Exif\0\0".utf8) + tiff
        let ftyp = box("ftyp", Data("heic".utf8) + Data(count: 4) + Data("mif1heic".utf8))
        let infe = box("infe", Data([2, 0, 0, 0, 0, 1, 0, 0]) + Data("Exif\0".utf8))
        let iinf = box("iinf", Data([1, 0, 0, 0, 0, 0, 0, 1]) + infe)
        func meta(_ start: UInt32) -> Data {
            var iloc = ByteWriter()
            iloc.writeBytes([1, 0, 0, 0, 0x44, 0])
            iloc.writeUInt16(1)
            iloc.writeUInt16(1)
            iloc.writeUInt16(idat ? 1 : 0)
            iloc.writeUInt16(0)
            iloc.writeUInt16(fragmented ? 2 : 1)
            iloc.writeUInt32(start)
            iloc.writeUInt32(fragmented ? 7 : UInt32(item.count))
            if fragmented {
                iloc.writeUInt32(start + 18)
                iloc.writeUInt32(UInt32(item.count - 7))
            }
            return box(
                "meta", Data(count: 4) + iinf + box("iloc", iloc.data) + (idat ? box("idat", item) : Data()),
                extended: extended
            )
        }
        if idat {
            return ftyp + meta(0) + box("mdat", Data(repeating: 0xCC, count: 5000))
        }
        let start = UInt32(ftyp.count + meta(0).count + 8)
        let payload = fragmented ? item.prefix(7) + Data(repeating: 0xCC, count: 11) + item.dropFirst(7) : item
        return ftyp + meta(start) + box("mdat", payload)
    }

    static func cr3(_ tiff: Data) -> Data {
        let cmt =
            box("CMT1", tiff + Data(count: 200), extended: true)
                + box(
                    "CMT2",
                    TIFFSerializer.encode(TIFFStructure(byteOrder: .littleEndian, ifd0: metadata().exifIFD!))
                        + Data(count: 128)
                )
                + box(
                    "CMT4",
                    TIFFSerializer.encode(TIFFStructure(byteOrder: .littleEndian, ifd0: metadata().gpsIFD!))
                        + Data(count: 128)
                )
        return box("ftyp", Data("crx ".utf8) + Data(count: 4) + Data("isom".utf8))
            + box("moov", box("uuid", CR3Container.canonUUID + cmt)) + box("mdat", Data(repeating: 0xCC, count: 5000))
    }

    static func raf(_ jpeg: Data) -> Data {
        var header = Data("FUJIFILMCCD-RAW ".utf8) + Data(count: 92)
        var fields = ByteWriter()
        fields.writeUInt32(108)
        fields.writeUInt32(UInt32(jpeg.count))
        fields.writeUInt32(UInt32(108 + jpeg.count))
        fields.writeUInt32(8)
        fields.writeUInt32(UInt32(116 + jpeg.count))
        fields.writeUInt32(16)
        header.replaceSubrange(84 ..< 108, with: fields.data)
        return header + jpeg + Data(repeating: 0xCC, count: 24)
    }

    @Test func memoryAndLocalHandleRanges() async throws {
        let data = Data([0, 1, 2, 3, 4])
        let memory = WritableInMemoryFileHandle(data: data)
        #expect(try await memory.read(at: 2, count: 2) == Data([2, 3]))
        await #expect(throws: FileAccessError.self) { try await memory.read(at: UInt64.max, count: 1) }
        await #expect(throws: FileAccessError.self) { try await memory.read(at: 0, count: -1) }
        #expect(try await memory.read(at: 5, count: 0).isEmpty)
        try await memory.write(Data([9]), at: 7)
        #expect(await memory.data == data + [0, 0, 9])
        try await memory.truncate(to: 3)
        #expect(await memory.data == Data([0, 1, 2]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let local = try WritableLocalFileHandle(url: url)
        try await local.write(data, at: 0)
        #expect(try await local.read(at: 2, count: 2) == Data([2, 3]))
        let readOnly = try LocalFileHandle(url: url)
        let source: any AbstractFileHandle = readOnly
        #expect(!(source is any WritableFileHandle))
        await #expect(throws: EXIFError.self) { try await EXIFKit.strip(from: readOnly, to: local) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 100 {
                group.addTask { () async throws in
                    #expect(
                        try await local.read(at: UInt64(index % 5), count: 1)
                            == data.subdata(in: index % 5 ..< index % 5 + 1)
                    )
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func allFormatsReadWriteAndStripThroughHandles() async throws {
        let metadata = Self.metadata()
        let tiff = TIFFSerializer.encode(metadata)
        var orf = tiff
        orf.replaceSubrange(2 ..< 4, with: [0x52, 0x4F])
        var rw2 = tiff
        rw2.replaceSubrange(2 ..< 4, with: [0x55, 0])
        let fixtures: [(ImageFormat, Data)] = [
            (.jpeg, Self.jpeg(tiff)), (.png, Self.png(tiff)),
            (.tiff, tiff + Data(count: 10000)), (.dng, tiff), (.cr2, tiff), (.nef, tiff), (.arw, tiff), (.pef, tiff),
            (.orf, orf), (.rw2, rw2), (.raf, Self.raf(Self.jpeg(tiff))), (.heif, Self.heif(tiff)),
            (.cr3, Self.cr3(tiff)),
        ]
        for (format, bytes) in fixtures {
            let source = InMemoryFileHandle(data: bytes)
            var parsed = try await EXIFKit.read(from: source, format: format)
            #expect(parsed.make == "Range Camera", "\(format)")
            #expect(parsed.iso == 640, "\(format)")
            #expect(abs((parsed.latitude ?? 0) - 38.7223) < 0.0001)
            parsed.ifd0.set(tagID: Tag.make, value: .ascii("Changed"))
            let output = WritableInMemoryFileHandle(data: Data(count: bytes.count * 2))
            try await EXIFKit.write(parsed, from: source, to: output, format: format)
            let rewritten = try await EXIFKit.read(from: output, format: format)
            #expect(rewritten.make == "Changed", "\(format)")
            #expect(rewritten.iso == 640, "\(format)")
            let stripped = WritableInMemoryFileHandle()
            try await EXIFKit.strip(from: output, to: stripped, format: format)
            switch format {
            case .jpeg, .png, .heif, .raf:
                await #expect(throws: (any Error).self) { try await EXIFKit.read(from: stripped, format: format) }
            default:
                let clean = try await EXIFKit.read(from: stripped, format: format)
                #expect(clean.exifIFD?.entries.isEmpty ?? true)
                #expect(clean.gpsIFD?.entries.isEmpty ?? true)
            }
        }
    }

    @Test func sparseMultiGigabyteTIFFReadsOnlyMetadata() async throws {
        let tiff = TIFFSerializer.encode(Self.metadata(.bigEndian))
        let source = SparseFile(size: 8 * 1024 * 1024 * 1024, regions: [(0, tiff)], allowed: [0 ..< UInt64(tiff.count)])
        let parsed = try await EXIFKit.read(from: source)
        #expect(parsed.iso == 640)
        #expect(await source.transferred < 4096)
    }

    @Test func sparsePNGSkipsGigabyteIDAT() async throws {
        let tiff = TIFFSerializer.encode(Self.metadata())
        let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
        var idat = ByteWriter()
        idat.writeUInt32(1_000_000_000)
        idat.writeBytes(Data("IDAT".utf8))
        let start = signature + idat.data
        let offset: UInt64 = 8 + 12 + 1_000_000_000
        let end = Self.chunk("eXIf", tiff) + Self.chunk("IEND", Data())
        let source = SparseFile(
            size: offset + UInt64(end.count), regions: [(0, start), (offset, end)],
            allowed: [0 ..< UInt64(start.count), offset ..< offset + UInt64(end.count)]
        )
        #expect(try await EXIFKit.read(from: source).make == "Range Camera")
        #expect(await source.transferred < 4096)
    }

    @Test func fragmentedAndIdatHEIF() async throws {
        let tiff = TIFFSerializer.encode(Self.metadata())
        for data in [Self.heif(tiff, fragmented: true), Self.heif(tiff, idat: true), Self.heif(tiff, extended: true)] {
            let source = InMemoryFileHandle(data: data)
            var metadata = try await EXIFKit.read(from: source)
            #expect(metadata.iso == 640)
            metadata.ifd0.set(tagID: Tag.make, value: .ascii("X"))
            let output = WritableInMemoryFileHandle()
            try await EXIFKit.write(metadata, from: source, to: output)
            #expect(try await EXIFKit.read(from: output).make == "X")
        }
    }

    @Test func rejectsCorruptOffsetsAndEnforcesBudget() async throws {
        let tiff = TIFFSerializer.encode(Self.metadata())
        await #expect(throws: EXIFError.self) {
            try await EXIFKit.read(from: tiff, options: ReadOptions(maximumMetadataBytes: 8))
        }
        var corrupt = tiff
        corrupt.replaceSubrange(4 ..< 8, with: [255, 255, 255, 255])
        await #expect(throws: (any Error).self) { try await EXIFKit.read(from: corrupt) }
        let same = WritableInMemoryFileHandle(data: tiff)
        await #expect(throws: EXIFError.self) { try await EXIFKit.strip(from: same, to: same) }
        let destination = WritableInMemoryFileHandle(data: Data("keep".utf8))
        await #expect(throws: (any Error).self) {
            try await EXIFKit.write(Self.metadata(), from: InMemoryFileHandle(data: corrupt), to: destination)
        }
        #expect(await destination.data == Data("keep".utf8))
    }

    @Test func insertionAndBoundedStreamingCopy() async throws {
        for (format, bytes) in [(ImageFormat.jpeg, Self.jpeg()), (.png, Self.png())] {
            let source = SparseFile(size: UInt64(bytes.count), regions: [(0, bytes)])
            let destination = WritableInMemoryFileHandle()
            try await EXIFKit.write(Self.metadata(), from: source, to: destination, format: format)
            #expect(try await EXIFKit.read(from: destination).iso == 640)
            #expect(await source.reads.allSatisfy { $0.count <= 65536 })
        }
    }
}

extension HandleTests {
    @Test func thumbnailIsLazyAndSerializerPreservesIt() async throws {
        let thumbnail = Data([0xFF, 0xD8]) + Data(repeating: 0x5A, count: 1024) + Data([0xFF, 0xD9])
        let thumbnailOffset: UInt64 = 2 * 1024 * 1024
        var ifd0 = IFD()
        ifd0.set(tagID: Tag.orientation, value: .short(1))
        ifd0.nextIFDOffset = 26
        var ifd1 = IFD()
        ifd1.set(tagID: Tag.jpegInterchangeFormat, value: .long(UInt32(thumbnailOffset)))
        ifd1.set(tagID: Tag.jpegInterchangeFormatLength, value: .long(UInt32(thumbnail.count)))
        var writer = ByteWriter(byteOrder: .littleEndian)
        writer.writeBytes([0x49, 0x49])
        writer.writeUInt16(42)
        writer.writeUInt32(8)
        writer.writeBytes(IFDWriter.writeIFD(ifd0, baseOffset: 8, byteOrder: .littleEndian))
        writer.writeBytes(IFDWriter.writeIFD(ifd1, baseOffset: 26, byteOrder: .littleEndian))
        let source = SparseFile(
            size: 16 * 1024 * 1024, regions: [(0, writer.data), (thumbnailOffset, thumbnail)],
            allowed: [0 ..< UInt64(writer.count), thumbnailOffset ..< thumbnailOffset + UInt64(thumbnail.count)]
        )
        let parsed = try await EXIFKit.read(from: source)
        #expect(await source.reads.allSatisfy { $0.upperBound <= UInt64(writer.count) })
        #expect(try await parsed.thumbnailData == thumbnail)
        let serialized = try await TIFFSerializer.serialize(parsed)
        #expect(try await EXIFKit.read(from: serialized).thumbnailData == thumbnail)
    }

    @Test func largeISOBMFFMediaIsSkippedIncludingExtendedSizes() async throws {
        let tiff = TIFFSerializer.encode(Self.metadata())
        let original = Self.heif(tiff)
        let source = InMemoryFileHandle(data: original)
        let boxes = try await ISOBMFFParser.parse(source)
        let meta = try #require(boxes.first { $0.type == "meta" })
        let mdat = try #require(boxes.first { $0.type == "mdat" })
        // Insert a huge unrelated mdat before the ordinary file; iloc offsets remain valid in a subregion.
        let ftyp = Self.box("ftyp", Data("heic".utf8) + Data(count: 4))
        let mediaLength: UInt64 = 5 * 1024 * 1024 * 1024
        var large = ByteWriter()
        large.writeUInt32(1)
        large.writeBytes(Data("mdat".utf8))
        large.writeUInt32(UInt32(mediaLength >> 32))
        large.writeUInt32(UInt32(truncatingIfNeeded: mediaLength))
        let cmt = Self.box("CMT1", tiff)
        let moov = Self.box("moov", Self.box("uuid", CR3Container.canonUUID + cmt))
        let end = UInt64(ftyp.count) + mediaLength
        let sparse = SparseFile(
            size: end + UInt64(moov.count),
            regions: [(0, ftyp + large.data), (end, moov)],
            allowed: [0 ..< UInt64(ftyp.count + large.count), end ..< end + UInt64(moov.count)]
        )
        #expect(try await EXIFKit.read(from: sparse, format: .cr3).make == "Range Camera")
        #expect(await sparse.transferred < 4096)
        #expect(meta.fileOffset < mdat.fileOffset)
    }

    @Test func growingFragmentedAndIdatHEIFCanRelocate() async throws {
        let tiff = TIFFSerializer.encode(Self.metadata())
        for original in [Self.heif(tiff, fragmented: true), Self.heif(tiff, idat: true)] {
            let source = InMemoryFileHandle(data: original)
            var metadata = try await EXIFKit.read(from: source)
            metadata.ifd0.set(tagID: Tag.imageDescription, value: .ascii(String(repeating: "x", count: 5000)))
            let destination = WritableInMemoryFileHandle()
            try await EXIFKit.write(metadata, from: source, to: destination)
            let parsed = try await EXIFKit.read(from: destination)
            #expect(parsed.imageDescription?.count == 5000)
            #expect(parsed.iso == 640)
            let stripped = WritableInMemoryFileHandle()
            try await EXIFKit.strip(from: destination, to: stripped)
            let twice = WritableInMemoryFileHandle()
            try await EXIFKit.strip(from: stripped, to: twice)
            #expect(await twice.data == stripped.data)
        }
    }

    @Test func smallTIFFExtendedFtypAndLateCompatibleBrandDetection() async throws {
        #expect(ImageFormat.detect(from: Data([0x49, 0x49, 42, 0, 8, 0, 0, 0])) == .tiff)
        let tiff = TIFFSerializer.encode(Self.metadata())
        let heif = Self.heif(tiff)
        let oldType = Self.box("ftyp", Data("heic".utf8) + Data(count: 4) + Data("mif1heic".utf8))
        // Same-sized ftyp, unknown major brand with HEIF only in the compatible brands.
        let compatible =
            Self.box("ftyp", Data("isom".utf8) + Data(count: 4) + Data("abcdheic".utf8)) + heif.dropFirst(oldType.count)
        #expect(try await EXIFKit.read(from: compatible).iso == 640)
        // Exercise extended ftyp without moving media/item offsets: CR3 CMTs are independently addressed.
        let cr3 =
            Self.box("ftyp", Data("crx ".utf8) + Data(count: 4), extended: true)
                + Self.box("moov", Self.box("uuid", CR3Container.canonUUID + Self.box("CMT1", tiff)))
        #expect(try await EXIFKit.read(from: cr3).make == "Range Camera")
    }

    @Test func failedCustomHandleAndReadOperationBudgetPropagate() async throws {
        actor Failing: AbstractFileHandle {
            let data = TIFFSerializer.encode(HandleTests.metadata())
            var size: UInt64 {
                get async throws { UInt64(data.count) }
            }

            func read(at offset: UInt64, count: Int) async throws -> Data {
                if offset > 16 {
                    throw CocoaError(.fileReadUnknown)
                }
                return data.subdata(in: Int(offset) ..< Int(offset) + count)
            }
        }
        await #expect(throws: CocoaError.self) { try await EXIFKit.read(from: Failing()) }
        await #expect(throws: EXIFError.self) {
            try await EXIFKit.read(
                from: TIFFSerializer.encode(Self.metadata()), options: ReadOptions(maximumReadOperations: 1)
            )
        }
        var byteReader = ByteReader(data: Data([0]))
        byteReader.offset = Int.max
        #expect(throws: EXIFError.self) { try byteReader.readBytes(Int.max) }
    }
}

extension HandleTests {
    @Test func localSparseEightGigabyteFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let local = try WritableLocalFileHandle(url: url)
        try await local.write(TIFFSerializer.encode(Self.metadata()), at: 0)
        try await local.truncate(to: 8 * 1024 * 1024 * 1024)
        let metadata = try await EXIFKit.read(from: url)
        #expect(metadata.make == "Range Camera")
        #expect(metadata.iso == 640)
    }

    @Test func duplicateValueReferencesCannotBypassDecodedBudget() async throws {
        let note = Data(repeating: 0xAB, count: 1024)
        var writer = ByteWriter(byteOrder: .littleEndian)
        writer.writeBytes([0x49, 0x49])
        writer.writeUInt16(42)
        writer.writeUInt32(8)
        writer.writeUInt16(10)
        for tag: UInt16 in 1 ... 10 {
            writer.writeUInt16(tag)
            writer.writeUInt16(7)
            writer.writeUInt32(UInt32(note.count))
            writer.writeUInt32(134)
        }
        writer.writeUInt32(0)
        writer.writeBytes(note)
        await #expect(throws: EXIFError.self) {
            try await EXIFKit.read(from: writer.data, options: ReadOptions(maximumMetadataBytes: 2048))
        }
    }
}

extension HandleTests {
    @Test func outputSizeOverflowPreservesDestination() async throws {
        let source = SparseFile(size: UInt64.max, regions: [(0, Self.jpeg())])
        let destination = WritableInMemoryFileHandle(data: Data("keep".utf8))
        await #expect(throws: EXIFError.self) {
            try await EXIFKit.write(Self.metadata(), from: source, to: destination, format: .jpeg)
        }
        #expect(await destination.data == Data("keep".utf8))
    }
}

extension HandleTests {
    @Test func underlyingDiskAndBackendErrorsPassThroughUnchanged() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("missing")
        func nativeReadError() -> NSError {
            do {
                let file = try FileHandle(forReadingFrom: url)
                try file.close()
                Issue.record("Expected missing file")
            } catch { return error as NSError }
            return NSError(domain: "Unexpected success", code: 0)
        }
        let expected = nativeReadError()
        do {
            _ = try LocalFileHandle(url: url)
            Issue.record("Expected missing file")
        } catch {
            let actual = error as NSError
            #expect(actual.domain == expected.domain)
            #expect(actual.code == expected.code)
            #expect(actual.userInfo[NSFilePathErrorKey] as? String == expected.userInfo[NSFilePathErrorKey] as? String)
        }
        struct BackendError: Error, Equatable { let operation: String }
        actor Backend: WritableFileHandle {
            let failingOperation: String
            init(_ failingOperation: String = "read") {
                self.failingOperation = failingOperation
            }

            var size: UInt64 {
                get async throws { 16 }
            }

            func read(at _: UInt64, count _: Int) async throws -> Data {
                throw BackendError(operation: "read")
            }

            func write(_: Data, at _: UInt64) async throws {
                if failingOperation == "write" {
                    throw BackendError(operation: "write")
                }
            }

            func truncate(to _: UInt64) async throws {
                if failingOperation == "truncate" {
                    throw BackendError(operation: "truncate")
                }
            }

            func synchronize() async throws {
                if failingOperation == "synchronize" {
                    throw BackendError(operation: "synchronize")
                }
            }
        }
        await #expect(throws: BackendError(operation: "read")) { try await EXIFKit.read(from: Backend()) }
        let source = InMemoryFileHandle(data: Self.jpeg())
        for operation in ["truncate", "write", "synchronize"] {
            await #expect(throws: BackendError(operation: operation)) {
                try await EXIFKit.write(Self.metadata(), from: source, to: Backend(operation))
            }
        }
    }
}
