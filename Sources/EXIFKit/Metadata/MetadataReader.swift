import Foundation

/// Limits apply to actual metadata reads, not to the size of the image file.
public struct ReadOptions: Sendable {
    public var maximumMetadataBytes: Int
    public var maximumReadOperations: Int
    /// Metadata is fetched in aligned blocks of this size, so nearby structures arrive in one handle read.
    /// This trades a little transfer for far fewer round trips on remote handles. 0 fetches exact ranges.
    public var readAheadBytes: Int
    public init(
        maximumMetadataBytes: Int = 32 * 1024 * 1024, maximumReadOperations: Int = 4096,
        readAheadBytes: Int = 64 * 1024
    ) {
        self.maximumMetadataBytes = maximumMetadataBytes
        self.maximumReadOperations = maximumReadOperations
        self.readAheadBytes = readAheadBytes
    }
}

/// A logical byte stream backed by one or more physical extents (e.g. a fragmented HEIF item).
final class FileRegion: AbstractFileHandle, Sendable {
    let source: any AbstractFileHandle
    let ranges: [Range<UInt64>]
    let length: UInt64
    var size: UInt64 {
        get async throws { length }
    }

    init(_ source: any AbstractFileHandle, ranges: [Range<UInt64>]) throws {
        self.source = source
        self.ranges = ranges
        var total: UInt64 = 0
        for range in ranges {
            let (sum, overflow) = total.addingReportingOverflow(range.upperBound - range.lowerBound)
            guard !overflow else { throw EXIFError.invalidHEIF("Extent sizes overflow") }
            total = sum
        }
        length = total
    }

    init(_ source: any AbstractFileHandle, offset: UInt64, length: UInt64) throws {
        let (end, overflow) = offset.addingReportingOverflow(length)
        guard !overflow else { throw EXIFError.invalidHEIF("Offset overflows") }
        self.source = source
        ranges = [offset ..< end]
        self.length = length
    }

    func read(at offset: UInt64, count: Int) async throws -> Data {
        try validateRange(offset, count, size: length)
        var remaining = count
        var skip = offset
        var result = Data()
        for range in ranges where remaining > 0 {
            let size = range.upperBound - range.lowerBound
            if skip >= size {
                skip -= size
                continue
            }
            let amount = Int(min(UInt64(remaining), size - skip))
            let data = try await source.read(at: range.lowerBound + skip, count: amount)
            guard data.count == amount else { throw FileAccessError.shortRead(expected: amount, actual: data.count) }
            result.append(data)
            remaining -= amount
            skip = 0
        }
        return result
    }

    func write(_: Data, at _: UInt64) async throws {
        throw EXIFError.writeFailed("Cannot write through a logical file region")
    }

    func truncate(to _: UInt64) async throws {
        throw EXIFError.writeFailed("Cannot truncate a logical file region")
    }

    func reserveMetadata(_ count: Int) async throws {
        if let reader = source as? MetadataReader {
            try await reader.reserveMetadata(count)
        } else if let region = source as? FileRegion {
            try await region.reserveMetadata(count)
        }
    }

    func slice(at offset: UInt64, length: UInt64) throws -> FileRegion {
        guard offset <= self.length, length <= self.length - offset else {
            throw EXIFError.invalidHEIF("Slice outside file region")
        }
        return try FileRegion(self, offset: offset, length: length)
    }
}

/// Block cache scoped to one extraction. Misses fetch whole aligned blocks, one handle read per contiguous run,
/// and concurrent parsers share in-flight fetches. After `finish()` reads are exact and nothing is retained.
actor MetadataReader: AbstractFileHandle {
    let source: any AbstractFileHandle
    let length: UInt64
    let limit: Int
    private let blockSize: UInt64
    private var transferred = 0
    private var decoded = 0
    private var operations = 0
    private let maximumOperations: Int
    private var blocks: [UInt64: Task<Data, any Error>] = [:]
    private var recent: [UInt64] = []
    private var finished = false
    private static let cachedBlocks = 16
    var size: UInt64 {
        get async throws { length }
    }

    init(_ source: any AbstractFileHandle, size: UInt64, options: ReadOptions) {
        self.source = source
        length = size
        limit = max(0, options.maximumMetadataBytes)
        maximumOperations = max(0, options.maximumReadOperations)
        blockSize = UInt64(max(0, options.readAheadBytes))
    }

    func reserveMetadata(_ count: Int) throws {
        guard count >= 0, count <= limit - decoded else { throw EXIFError.resourceLimitExceeded }
        decoded += count
    }

    /// Drop cached blocks once parsing is done; a structure may keep this reader for its lazy thumbnail.
    func finish() {
        finished = true
        blocks = [:]
        recent = []
    }

    func read(at offset: UInt64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        try validateRange(offset, count, size: length)
        if count == 0 {
            return Data()
        }
        let first = blockSize == 0 ? 0 : offset / blockSize
        let last = blockSize == 0 ? 0 : (offset + UInt64(count) - 1) / blockSize
        guard blockSize > 0, !finished, last - first < UInt64(Self.cachedBlocks) else {
            return try await fetch(offset ..< offset + UInt64(count))
        }
        var runs: [ClosedRange<UInt64>] = []
        for index in first ... last where blocks[index] == nil {
            if let run = runs.last, run.upperBound + 1 == index {
                runs[runs.count - 1] = run.lowerBound ... index
            } else {
                runs.append(index ... index)
            }
        }
        let missing = runs.reduce(0) { $0 + Int(bytes($1).count) }
        guard missing <= limit - transferred, runs.count <= maximumOperations - operations else {
            // Read-ahead must not exhaust a budget the exact range would fit in.
            return try await fetch(offset ..< offset + UInt64(count))
        }
        transferred += missing
        operations += runs.count
        for run in runs {
            let range = bytes(run)
            let source = source
            let fetched = Task { try await Self.exact(source, range) }
            for index in run {
                let lower = Int((index * blockSize) - range.lowerBound)
                let upper = Int(min(length, (index + 1) * blockSize) - range.lowerBound)
                blocks[index] = Task { try await fetched.value.subdata(in: lower ..< upper) }
            }
        }
        let tasks = (first ... last).map { blocks[$0]! }
        recent.removeAll { (first ... last).contains($0) }
        recent.append(contentsOf: first ... last)
        while recent.count > Self.cachedBlocks {
            blocks[recent.removeFirst()] = nil
        }
        var result = Data(capacity: count)
        do {
            for (index, task) in zip(first ... last, tasks) {
                let block = try await task.value
                let start = index == first ? Int(offset - first * blockSize) : 0
                let end = index == last ? Int(offset + UInt64(count) - last * blockSize) : block.count
                result.append(block.subdata(in: start ..< end))
            }
        } catch {
            for (index, task) in zip(first ... last, tasks) where blocks[index] == task {
                blocks[index] = nil
            }
            throw error
        }
        return result
    }

    private func bytes(_ run: ClosedRange<UInt64>) -> Range<UInt64> {
        run.lowerBound * blockSize ..< min(length, (run.upperBound + 1) * blockSize)
    }

    private func fetch(_ range: Range<UInt64>) async throws -> Data {
        let count = Int(range.count)
        guard count <= limit - transferred, operations < maximumOperations else {
            throw EXIFError.resourceLimitExceeded
        }
        transferred += count
        operations += 1
        return try await Self.exact(source, range)
    }

    private static func exact(_ source: any AbstractFileHandle, _ range: Range<UInt64>) async throws -> Data {
        let count = Int(range.count)
        let data = try await source.read(at: range.lowerBound, count: count)
        guard data.count == count else { throw FileAccessError.shortRead(expected: count, actual: data.count) }
        // Normalize slices so block offsets are zero-based.
        return data.startIndex == 0 ? data : Data(data)
    }

    func write(_: Data, at _: UInt64) async throws {
        throw EXIFError.writeFailed("Cannot write through a metadata reader")
    }

    func truncate(to _: UInt64) async throws {
        throw EXIFError.writeFailed("Cannot truncate a metadata reader")
    }
}

enum HandleParser {
    static func detect(_ file: FileRegion) async throws -> ImageFormat {
        let head = try await file.read(at: 0, count: Int(min(16, file.length)))
        if let format = ImageFormat.detect(from: head) {
            return format
        }
        if head.count >= 8, head.subdata(in: 4 ..< 8) == Data("ftyp".utf8) {
            var reader = ByteReader(data: head)
            let size = try reader.readUInt32()
            var length = UInt64(size)
            if size == 1 {
                var extended = try ByteReader(data: await file.read(at: 8, count: 8))
                length = try UInt64(extended.readUInt32()) << 32 | UInt64(extended.readUInt32())
            } else if size == 0 {
                length = file.length
            }
            guard length <= file.length, length <= 10 * 1024 * 1024 else {
                throw EXIFError.invalidHEIF("Invalid ftyp size")
            }
            if let format = try ImageFormat.detect(from: await file.read(at: 0, count: Int(length))) {
                return format
            }
        }
        throw EXIFError.unsupportedFormat("Unable to detect image format")
    }

    static func read(_ file: FileRegion, format: ImageFormat) async throws -> TIFFStructure {
        switch format {
        case .jpeg: return try await tiff(jpeg(file).tiff)
        case .png: return try await tiff(png(file).tiff)
        case .raf: return try await read(raf(file), format: .jpeg)
        case .cr3: return try await cr3(file)
        case .heif: return try await tiff(heif(file).tiff)
        case .jxl: return try await tiff(jxlTIFF(file))
        default: return try await tiff(file, raw: format != .tiff && format != .dng)
        }
    }

    static func tiff(_ file: FileRegion, raw: Bool = false) async throws -> TIFFStructure {
        guard file.length >= 8 else { throw EXIFError.invalidTIFFHeader }
        let header = try await file.read(at: 0, count: 8)
        let order: ByteOrder
        if header.prefix(2) == Data([0x49, 0x49]) {
            order = .littleEndian
        } else if header.prefix(2) == Data([0x4D, 0x4D]) {
            order = .bigEndian
        } else {
            throw EXIFError.invalidByteOrder
        }
        var reader = ByteReader(data: header, byteOrder: order)
        reader.offset = 2
        let magic = try reader.readUInt16()
        guard magic == 42 || (raw && [0x4F52, 0x5352, 0x0055].contains(magic)) else {
            throw EXIFError.invalidTIFFHeader
        }
        let offset = try reader.readUInt32()
        guard offset >= 8 else { throw EXIFError.corruptedIFD("IFD0 overlaps TIFF header") }
        let ifd0 = try await ifd(file, at: UInt64(offset), order: order)
        var result = TIFFStructure(byteOrder: order, ifd0: ifd0)
        var visited: Set<UInt32> = [offset]
        func claim(_ pointer: UInt32?) throws -> UInt64? {
            guard let pointer, pointer != 0 else { return nil }
            guard pointer >= 8, visited.insert(pointer).inserted else {
                throw EXIFError.corruptedIFD("Cyclic or overlapping directory pointer")
            }
            return UInt64(pointer)
        }
        @Sendable func directory(_ offset: UInt64?) async throws -> IFD? {
            guard let offset else { return nil }
            return try await ifd(file, at: offset, order: order)
        }
        // Sibling directories are independent, so their reads can share a round trip.
        let ifd1Offset = try claim(ifd0.nextIFDOffset)
        let exifOffset = try claim(ifd0.value(for: Tag.exifIFDPointer)?.uint32Value)
        let gpsOffset = try claim(ifd0.value(for: Tag.gpsIFDPointer)?.uint32Value)
        async let ifd1 = directory(ifd1Offset)
        async let gps = directory(gpsOffset)
        result.exifIFD = try await directory(exifOffset)
        result.interopIFD = try await directory(claim(result.exifIFD?.value(for: Tag.interopIFDPointer)?.uint32Value))
        result.ifd1 = try await ifd1
        result.gpsIFD = try await gps
        result.sourceRegion = file
        return result
    }

    static func ifd(_ file: FileRegion, at offset: UInt64, order: ByteOrder) async throws -> IFD {
        var countReader = try ByteReader(data: await file.read(at: offset, count: 2), byteOrder: order)
        let count = try Int(countReader.readUInt16())
        guard count < 1000 else { throw EXIFError.corruptedIFD("Too many IFD entries: \(count)") }
        var table = try ByteReader(data: await file.read(at: offset + 2, count: count * 12 + 4), byteOrder: order)
        struct Entry {
            let tag: UInt16
            let type: EXIFDataType
            let count: UInt32
            let bytes: Data
            let range: Range<UInt64>?
        }
        var entries: [Entry] = []
        var decodedBytes = 0
        for _ in 0 ..< count {
            let tag = try table.readUInt16()
            let rawType = try table.readUInt16()
            let amount = try table.readUInt32()
            let bytes = try table.readBytes(4)
            guard let type = EXIFDataType(rawValue: rawType == 13 ? 4 : rawType) else {
                entries.append(Entry(tag: tag, type: .undefined, count: 4, bytes: bytes, range: nil))
                continue
            }
            let length = UInt64(amount) * UInt64(type.unitSize)
            guard length <= 10 * 1024 * 1024 else { throw EXIFError.resourceLimitExceeded }
            decodedBytes += Int(length)
            var range: Range<UInt64>?
            if length > 4 {
                var pointer = ByteReader(data: bytes, byteOrder: order)
                let start = try UInt64(pointer.readUInt32())
                guard start <= file.length, length <= file.length - start else {
                    throw EXIFError.corruptedIFD("Value for tag \(tag) is outside TIFF region")
                }
                range = start ..< start + length
            }
            entries.append(Entry(tag: tag, type: type, count: amount, bytes: bytes, range: range))
        }
        try await file.reserveMetadata(decodedBytes)
        // Merge adjacent or overlapping values, without fetching gaps or image payloads.
        var ranges: [Range<UInt64>] = []
        for range in entries.compactMap(\.range).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = ranges.last, range.lowerBound <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        let values = try await withThrowingTaskGroup(of: (Range<UInt64>, Data).self) { group in
            for range in ranges {
                group.addTask { try await (range, file.read(at: range.lowerBound, count: Int(range.count))) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        var decoded: [IFDEntry] = []
        for entry in entries {
            var bytes = entry.bytes
            if let range = entry.range,
               let value = values.first(where: {
                   $0.0.lowerBound <= range.lowerBound && $0.0.upperBound >= range.upperBound
               })
            {
                let start = Int(range.lowerBound - value.0.lowerBound)
                bytes = value.1.subdata(in: start ..< start + Int(range.count))
            }
            let value = try IFDReader.parseValue(data: bytes, type: entry.type, count: entry.count, byteOrder: order)
            decoded.append(IFDEntry(tagID: entry.tag, dataType: entry.type, count: entry.count, value: value))
        }
        return try IFD(entries: decoded, nextIFDOffset: table.readUInt32())
    }

    struct JPEGInfo {
        let tiff: FileRegion
        let segment: Range<UInt64>
    }

    static func jpeg(_ file: FileRegion) async throws -> JPEGInfo {
        guard try await file.read(at: 0, count: 2) == Data([0xFF, 0xD8]) else {
            throw EXIFError.invalidJPEG("Missing SOI")
        }
        var position: UInt64 = 2
        while position < file.length {
            let start = position
            var marker = try await file.read(at: position, count: 2)
            guard marker[0] == 0xFF else { throw EXIFError.invalidJPEG("Invalid marker") }
            while marker[1] == 0xFF {
                position += 1
                marker = try await file.read(at: position, count: 2)
            }
            position += 2
            if marker[1] == 0xDA || marker[1] == 0xD9 {
                break
            }
            if marker[1] == 0x01 || (0xD0 ... 0xD7).contains(marker[1]) {
                continue
            }
            var reader = try ByteReader(data: await file.read(at: position, count: 2))
            let length = try UInt64(reader.readUInt16())
            guard length >= 2, length <= file.length - position else {
                throw EXIFError.invalidJPEG("Invalid segment size")
            }
            if marker[1] == 0xE1, length >= 8,
               try await file.read(at: position + 2, count: 6) == Data([0x45, 0x78, 0x69, 0x66, 0, 0])
            {
                return try JPEGInfo(
                    tiff: file.slice(at: position + 8, length: length - 8), segment: start ..< position + length
                )
            }
            position += length
        }
        throw EXIFError.invalidJPEG("No EXIF APP1 segment found")
    }

    struct PNGInfo {
        let tiff: FileRegion
        let chunk: Range<UInt64>
    }

    static func png(_ file: FileRegion) async throws -> PNGInfo {
        guard try await file.read(at: 0, count: 8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw EXIFError.invalidPNG("Invalid signature")
        }
        var position: UInt64 = 8
        while position <= file.length, file.length - position >= 12 {
            var reader = try ByteReader(data: await file.read(at: position, count: 8))
            let length = try UInt64(reader.readUInt32())
            let type = try reader.readASCII(4)
            guard length <= file.length - position - 12 else { throw EXIFError.invalidPNG("Invalid chunk size") }
            if type == "eXIf" {
                return try PNGInfo(
                    tiff: file.slice(at: position + 8, length: length), chunk: position ..< position + length + 12
                )
            }
            if type == "IEND" {
                break
            }
            position += length + 12
        }
        throw EXIFError.invalidPNG("No eXIf chunk found")
    }

    static func raf(_ file: FileRegion) async throws -> FileRegion {
        guard file.length >= 108 else { throw EXIFError.unsupportedFormat("RAF header too small") }
        guard try String(data: await file.read(at: 0, count: 16), encoding: .ascii) == "FUJIFILMCCD-RAW " else {
            throw EXIFError.unsupportedFormat("Invalid RAF signature")
        }
        var reader = try ByteReader(data: await file.read(at: 84, count: 8))
        let start = try UInt64(reader.readUInt32())
        let length = try UInt64(reader.readUInt32())
        guard start >= 108, length >= 2 else { throw EXIFError.unsupportedFormat("Invalid RAF JPEG location") }
        return try file.slice(at: start, length: length)
    }
}
