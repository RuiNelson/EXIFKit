import Foundation

/// Convenience entry points backed by the shared random-access parser and streaming writer.
public enum WebPContainer {
    /// Check for a RIFF container with a `WEBP` form type.
    public static func isWebP(_ data: Data) -> Bool {
        data.count >= 12 && data.prefix(4) == Data("RIFF".utf8) && data.subdata(in: 8 ..< 12) == Data("WEBP".utf8)
    }

    public static func readEXIF(from source: any AbstractFileHandle) async throws -> TIFFStructure {
        try await EXIFKit.read(from: source, format: .webp)
    }

    public static func readEXIF(from data: Data) async throws -> TIFFStructure {
        try await EXIFKit.read(from: data, format: .webp)
    }

    public static func writeEXIF(_ structure: TIFFStructure, to data: Data) async throws -> Data {
        try await EXIFKit.write(structure, to: data, format: .webp)
    }

    public static func stripEXIF(from data: Data) async throws -> Data {
        try await EXIFKit.strip(from: data, format: .webp)
    }
}

extension HandleParser {
    struct WebPChunk {
        let type: String
        let start: UInt64
        let payload: UInt64
        let length: UInt64
        /// End including the pad byte that keeps chunks even-sized.
        let end: UInt64
    }

    struct WebPInfo {
        let riffSize: UInt64
        let riffEnd: UInt64
        let chunks: [WebPChunk]
    }

    private static func littleEndian(_ data: Data) -> UInt64 {
        data.reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    static func webp(_ file: FileRegion) async throws -> WebPInfo {
        guard file.length >= 12 else { throw EXIFError.invalidWebP("Truncated header") }
        let header = try await file.read(at: 0, count: 12)
        guard WebPContainer.isWebP(header) else { throw EXIFError.invalidWebP("Invalid signature") }
        let riffSize = littleEndian(header.subdata(in: 4 ..< 8))
        guard riffSize >= 4 else { throw EXIFError.invalidWebP("Invalid RIFF size") }
        let riffEnd = min(8 + riffSize, file.length)
        var chunks: [WebPChunk] = []
        var position: UInt64 = 12
        while riffEnd - position >= 8 {
            let chunkHeader = try await file.read(at: position, count: 8)
            let type = String(decoding: chunkHeader.prefix(4), as: UTF8.self)
            let length = littleEndian(chunkHeader.subdata(in: 4 ..< 8))
            let payload = position + 8
            guard length <= riffEnd - payload else { throw EXIFError.invalidWebP("Invalid chunk size for \(type)") }
            let end = min(payload + length + (length & 1), riffEnd)
            chunks.append(WebPChunk(type: type, start: position, payload: payload, length: length, end: end))
            position = end
        }
        return WebPInfo(riffSize: riffSize, riffEnd: riffEnd, chunks: chunks)
    }

    static func webpTIFF(_ file: FileRegion) async throws -> FileRegion {
        let info = try await webp(file)
        guard let chunk = info.chunks.first(where: { $0.type == "EXIF" }) else {
            throw EXIFError.invalidWebP("No EXIF chunk found")
        }
        // Some writers keep the JPEG-style "Exif\0\0" prefix, which the specification excludes.
        let prefix = Data([0x45, 0x78, 0x69, 0x66, 0, 0])
        if chunk.length > 6, try await file.read(at: chunk.payload, count: 6) == prefix {
            return try file.slice(at: chunk.payload + 6, length: chunk.length - 6)
        }
        return try file.slice(at: chunk.payload, length: chunk.length)
    }
}

extension EditPlanner {
    private static let webpExifFlag: UInt8 = 0x08

    static func webp(_ file: FileRegion, structure: TIFFStructure?) async throws -> [FileEdit] {
        let info = try await HandleParser.webp(file)
        var payload = Data()
        if let structure {
            let data = try await serialized(structure)
            guard data.count < Int(UInt32.max) - 16 else { throw EXIFError.writeFailed("EXIF exceeds WebP chunk capacity") }
            var writer = ByteWriter(byteOrder: .littleEndian)
            writer.writeBytes(Data("EXIF".utf8))
            writer.writeUInt32(UInt32(data.count))
            writer.writeBytes(data)
            if data.count & 1 == 1 { writer.writeByte(0) }
            payload = writer.data
        }
        var edits: [FileEdit] = []
        var delta = Int64(0)
        func replace(_ range: Range<UInt64>, with bytes: Data) {
            edits.append(FileEdit(range, bytes))
            delta += Int64(bytes.count) - Int64(range.count)
        }

        var found = false
        for chunk in info.chunks where chunk.type == "EXIF" {
            replace(chunk.start ..< chunk.end, with: found ? Data() : payload)
            found = true
        }
        if !found, structure != nil {
            // EXIF follows the image data and precedes XMP.
            let position = info.chunks.first(where: { $0.type == "XMP " })?.start ?? info.riffEnd
            replace(position ..< position, with: payload)
        }

        if let vp8x = info.chunks.first(where: { $0.type == "VP8X" }) {
            guard vp8x.length >= 10 else { throw EXIFError.invalidWebP("Truncated VP8X chunk") }
            let flags = try await file.read(at: vp8x.payload, count: 1)[0]
            let updated = structure != nil ? flags | webpExifFlag : flags & ~webpExifFlag
            if updated != flags {
                edits.append(FileEdit(vp8x.payload ..< vp8x.payload + 1, Data([updated])))
            }
        } else if structure != nil {
            // Simple lossy and lossless files need an extended header before they can carry metadata.
            replace(12 ..< 12, with: try await vp8x(for: info, in: file))
        }

        if delta != 0 {
            let size = Int64(info.riffSize) + delta
            guard size >= 4, size <= Int64(UInt32.max) else {
                throw EXIFError.writeFailed("WebP exceeds 32-bit RIFF size")
            }
            var writer = ByteWriter(byteOrder: .littleEndian)
            writer.writeUInt32(UInt32(size))
            edits.append(FileEdit(4 ..< 8, writer.data))
        }
        return edits
    }

    private static func vp8x(for info: HandleParser.WebPInfo, in file: FileRegion) async throws -> Data {
        guard let image = info.chunks.first(where: { $0.type == "VP8 " || $0.type == "VP8L" }) else {
            throw EXIFError.invalidWebP("No image chunk found")
        }
        let bytes = try await file.read(at: image.payload, count: Int(min(image.length, 10)))
        var width: UInt32
        var height: UInt32
        var flags = webpExifFlag
        if image.type == "VP8L" {
            guard bytes.count >= 5, bytes[0] == 0x2F else { throw EXIFError.invalidWebP("Invalid VP8L header") }
            let bits = UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 24
            width = (bits & 0x3FFF) + 1
            height = (bits >> 14 & 0x3FFF) + 1
            if bits >> 28 & 1 == 1 { flags |= 0x10 }
        } else {
            guard bytes.count >= 10, bytes[3] == 0x9D, bytes[4] == 0x01, bytes[5] == 0x2A else {
                throw EXIFError.invalidWebP("Invalid VP8 header")
            }
            width = (UInt32(bytes[6]) | UInt32(bytes[7]) << 8) & 0x3FFF
            height = (UInt32(bytes[8]) | UInt32(bytes[9]) << 8) & 0x3FFF
        }
        var writer = ByteWriter(byteOrder: .littleEndian)
        writer.writeBytes(Data("VP8X".utf8))
        writer.writeUInt32(10)
        writer.writeByte(flags)
        writer.writeBytes([0, 0, 0])
        for dimension in [width - 1, height - 1] {
            writer.writeBytes([UInt8(dimension & 0xFF), UInt8(dimension >> 8 & 0xFF), UInt8(dimension >> 16 & 0xFF)])
        }
        return writer.data
    }
}
