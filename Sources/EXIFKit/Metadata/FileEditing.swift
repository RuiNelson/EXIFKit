import Foundation

enum OutputPiece {
    case bytes(Data)
    case zeros(UInt64)
    var count: UInt64 {
        switch self {
        case let .bytes(bytes): UInt64(bytes.count)
        case let .zeros(count): count
        }
    }
}

struct FileEdit {
    let range: Range<UInt64>
    let pieces: [OutputPiece]
    init(_ range: Range<UInt64>, _ bytes: Data) {
        self.range = range
        pieces = [.bytes(bytes)]
    }

    init(_ range: Range<UInt64>, pieces: [OutputPiece]) {
        self.range = range
        self.pieces = pieces
    }
}

extension EXIFKit {
    /// Stream a modified file to a separate destination. Image bytes are copied in 64 KiB blocks.
    /// Validation happens before the destination is truncated. I/O failures can leave a partial destination;
    /// use a temporary file and rename it after success when replacing an existing file.
    public static func write(
        _ structure: TIFFStructure, from source: any AbstractFileHandle,
        to destination: any AbstractFileHandle, format: ImageFormat? = nil,
        options: ReadOptions = ReadOptions()
    ) async throws {
        try await edit(structure, stripping: false, from: source, to: destination, format: format, options: options)
    }

    /// Stream a file with EXIF removed to a separate destination.
    public static func strip(
        from source: any AbstractFileHandle, to destination: any AbstractFileHandle,
        format: ImageFormat? = nil, options: ReadOptions = ReadOptions()
    ) async throws {
        try await edit(nil, stripping: true, from: source, to: destination, format: format, options: options)
    }

    private static func edit(
        _ structure: TIFFStructure?, stripping: Bool, from source: any AbstractFileHandle,
        to destination: any AbstractFileHandle, format: ImageFormat?, options: ReadOptions
    ) async throws {
        guard source !== destination else {
            throw EXIFError.writeFailed("Source and destination refer to the same file")
        }
        if let localSource = source as? any LocalFileIdentifying,
           let localDestination = destination as? any LocalFileIdentifying,
           localSource.identity == localDestination.identity
        {
            throw EXIFError.writeFailed("Source and destination refer to the same file")
        }
        let size = try await source.size
        let reader = MetadataReader(source, size: size, options: options)
        let file = try FileRegion(reader, offset: 0, length: size)
        let detected: ImageFormat
        if let format {
            detected = format
        } else {
            detected = try await HandleParser.detect(file)
        }
        let edits = try await EditPlanner.plan(structure, stripping: stripping, file: file, format: detected)
        try await stream(source, size: size, edits: edits, to: destination)
    }

    private static func stream(
        _ source: any AbstractFileHandle, size: UInt64,
        edits: [FileEdit], to destination: any AbstractFileHandle
    ) async throws {
        let edits = edits.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var checked: UInt64 = 0
        var outputSize = size
        for edit in edits {
            guard edit.range.lowerBound >= checked, edit.range.upperBound <= size else {
                throw EXIFError.writeFailed("Overlapping or invalid edit ranges")
            }
            checked = edit.range.upperBound
            outputSize -= edit.range.upperBound - edit.range.lowerBound
            for piece in edit.pieces {
                let (sum, overflow) = outputSize.addingReportingOverflow(piece.count)
                guard !overflow else { throw EXIFError.writeFailed("Output size exceeds 64-bit offsets") }
                outputSize = sum
            }
        }
        try Task.checkCancellation()
        try await destination.truncate(to: 0)
        var input: UInt64 = 0
        var output: UInt64 = 0
        func copy(until end: UInt64) async throws {
            while input < end {
                try Task.checkCancellation()
                let amount = Int(min(65536, end - input))
                let data = try await source.read(at: input, count: amount)
                guard data.count == amount else {
                    throw FileAccessError.shortRead(expected: amount, actual: data.count)
                }
                try await destination.write(data, at: output)
                input += UInt64(amount)
                output += UInt64(amount)
            }
        }
        for edit in edits {
            try await copy(until: edit.range.lowerBound)
            for piece in edit.pieces {
                switch piece {
                case let .bytes(data):
                    // Metadata is already materialized; bound each destination write too.
                    var position = 0
                    while position < data.count {
                        try Task.checkCancellation()
                        let amount = min(65536, data.count - position)
                        try await destination.write(data.subdata(in: position ..< position + amount), at: output)
                        position += amount
                        output += UInt64(amount)
                    }
                case let .zeros(length):
                    var remaining = length
                    while remaining > 0 {
                        try Task.checkCancellation()
                        let amount = Int(min(65536, remaining))
                        try await destination.write(Data(count: amount), at: output)
                        output += UInt64(amount)
                        remaining -= UInt64(amount)
                    }
                }
            }
            input = edit.range.upperBound
        }
        try await copy(until: size)
        try Task.checkCancellation()
        try await destination.truncate(to: output)
        try await destination.synchronize()
    }
}

enum EditPlanner {
    static func plan(
        _ structure: TIFFStructure?, stripping: Bool, file: FileRegion,
        format: ImageFormat
    ) async throws -> [FileEdit] {
        if structure?.thumbnailEdited == true, format == .cr3 {
            throw EXIFError.writeFailed("Replacing the thumbnail is unsupported for \(format.rawValue.uppercased())")
        }
        switch format {
        case .jpeg:
            return try await jpeg(file, tiff: structure, stripping: stripping)
        case .png:
            return try await png(file, structure: structure)
        case .raf:
            return try await raf(file, structure: structure, stripping: stripping)
        case .heif:
            return try await heif(file, structure: structure)
        case .jxl:
            return try await jxl(file, structure: structure)
        case .cr3:
            return try await cr3(file, structure: structure)
        default:
            return try await tiff(file, structure: structure, raw: format != .tiff && format != .dng)
        }
    }

    static func serialized(_ structure: TIFFStructure) async throws -> Data {
        let structure = try await structure.preparingForWrite()
        for ifd in [structure.ifd0, structure.ifd1, structure.exifIFD, structure.gpsIFD, structure.interopIFD]
            .compactMap({ $0 })
        {
            guard ifd.entries.count < 1000 else { throw EXIFError.writeFailed("Too many IFD entries") }
        }
        return TIFFSerializer.encode(structure)
    }

    static func jpeg(_ file: FileRegion, tiff structure: TIFFStructure?, stripping: Bool) async throws -> [FileEdit] {
        let payload: Data
        if let structure {
            let tiff = try await serialized(structure)
            guard tiff.count <= 65527 else { throw EXIFError.writeFailed("EXIF exceeds JPEG APP1 capacity") }
            var writer = ByteWriter()
            writer.writeBytes([0xFF, 0xE1])
            writer.writeUInt16(UInt16(tiff.count + 8))
            writer.writeBytes([0x45, 0x78, 0x69, 0x66, 0, 0])
            writer.writeBytes(tiff)
            payload = writer.data
        } else {
            payload = Data()
        }
        guard try await file.read(at: 0, count: 2) == Data([0xFF, 0xD8]) else {
            throw EXIFError.invalidJPEG("Missing SOI")
        }
        var position: UInt64 = 2
        var insertion: UInt64 = 2
        var edits: [FileEdit] = []
        var found = false
        var foundScan = false
        while position < file.length {
            let start = position
            var marker = try await file.read(at: position, count: 2)
            guard marker[0] == 0xFF else { throw EXIFError.invalidJPEG("Invalid marker") }
            while marker[1] == 0xFF {
                position += 1
                marker = try await file.read(at: position, count: 2)
            }
            position += 2
            if marker[1] == 0xDA {
                foundScan = true
                break
            }
            if marker[1] == 0xD9 {
                break
            }
            if marker[1] == 1 || (0xD0 ... 0xD7).contains(marker[1]) {
                continue
            }
            var reader = try ByteReader(data: await file.read(at: position, count: 2))
            let length = try UInt64(reader.readUInt16())
            guard length >= 2, length <= file.length - position else {
                throw EXIFError.invalidJPEG("Invalid segment length")
            }
            if start == 2, marker[1] == 0xE0 {
                insertion = position + length
            }
            if marker[1] == 0xE1, length >= 8,
               try await file.read(at: position + 2, count: 6) == Data([0x45, 0x78, 0x69, 0x66, 0, 0])
            {
                edits.append(FileEdit(start ..< position + length, found ? Data() : payload))
                found = true
            }
            position += length
        }
        guard foundScan else { throw EXIFError.invalidJPEG("Missing image scan") }
        if !found, !stripping {
            edits.append(FileEdit(insertion ..< insertion, payload))
        }
        return edits
    }

    static func png(_ file: FileRegion, structure: TIFFStructure?) async throws -> [FileEdit] {
        guard try await file.read(at: 0, count: 8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw EXIFError.invalidPNG("Invalid signature")
        }
        var payload = Data()
        if let structure {
            let data = try await serialized(structure)
            var writer = ByteWriter()
            writer.writeUInt32(UInt32(data.count))
            writer.writeBytes(Data("eXIf".utf8))
            writer.writeBytes(data)
            writer.writeUInt32(CRC32.calculate(Data("eXIf".utf8) + data))
            payload = writer.data
        }
        var position: UInt64 = 8
        var insertion: UInt64 = 8
        var edits: [FileEdit] = []
        var found = false
        var ended = false
        while file.length - position >= 12 {
            var header = try ByteReader(data: await file.read(at: position, count: 8))
            let length = try UInt64(header.readUInt32())
            let type = try header.readASCII(4)
            guard length <= file.length - position - 12 else { throw EXIFError.invalidPNG("Invalid chunk length") }
            let end = position + length + 12
            if position == 8 {
                guard type == "IHDR", length == 13 else { throw EXIFError.invalidPNG("Missing IHDR") }
                insertion = end
            }
            if type == "eXIf" {
                edits.append(FileEdit(position ..< end, found ? Data() : payload))
                found = true
            }
            position = end
            if type == "IEND" {
                ended = true
                break
            }
        }
        guard ended else { throw EXIFError.invalidPNG("Missing IEND") }
        if !found, structure != nil {
            edits.append(FileEdit(insertion ..< insertion, payload))
        }
        return edits
    }
}
