import Foundation

/// Convenience entry points backed by the shared random-access parser and streaming writer.
public enum JXLContainer {
    static let signature = Data([0, 0, 0, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A])

    /// Check for the JPEG XL container signature box. Bare codestreams carry no EXIF and are not matched.
    public static func isJXL(_ data: Data) -> Bool {
        data.count >= signature.count && data.prefix(signature.count) == signature
    }

    public static func readEXIF(from source: any AbstractFileHandle) async throws -> TIFFStructure {
        try await EXIFKit.read(from: source, format: .jxl)
    }

    public static func readEXIF(from data: Data) async throws -> TIFFStructure {
        try await EXIFKit.read(from: data, format: .jxl)
    }

    public static func writeEXIF(_ structure: TIFFStructure, to data: Data) async throws -> Data {
        try await EXIFKit.write(structure, to: data, format: .jxl)
    }

    public static func stripEXIF(from data: Data) async throws -> Data {
        try await EXIFKit.strip(from: data, format: .jxl)
    }
}

extension HandleParser {
    /// Top-level boxes holding EXIF: plain `Exif` boxes, and Brotli `brob` wrappers whose inner type is `Exif`.
    struct JXLInfo {
        let boxes: [BoxReference]
        let exif: [BoxReference]
        let compressed: Set<UInt64>
    }

    static func jxl(_ file: FileRegion) async throws -> JXLInfo {
        guard file.length >= 12, try await file.read(at: 0, count: 12) == JXLContainer.signature else {
            throw EXIFError.invalidJXL("Missing container signature")
        }
        let index = try await boxes(file)
        var exif: [BoxReference] = []
        var compressed: Set<UInt64> = []
        for box in index {
            if box.type == "Exif" {
                exif.append(box)
            } else if box.type == "brob", box.length >= 4, try await file.read(at: box.payload, count: 4) == Data("Exif".utf8) {
                exif.append(box)
                compressed.insert(box.start)
            }
        }
        return JXLInfo(boxes: index, exif: exif, compressed: compressed)
    }

    static func jxlTIFF(_ file: FileRegion) async throws -> FileRegion {
        let info = try await jxl(file)
        guard let box = info.exif.first else { throw EXIFError.invalidJXL("No Exif box") }
        guard !info.compressed.contains(box.start) else {
            throw EXIFError.unsupportedFormat("Brotli-compressed JPEG XL Exif box")
        }
        return try await exifTIFF(file.slice(at: box.payload, length: box.length))
    }
}

extension EditPlanner {
    static func jxl(_ file: FileRegion, structure: TIFFStructure?) async throws -> [FileEdit] {
        let info = try await HandleParser.jxl(file)
        var replacement = Data()
        if let structure {
            // Box payload: 4-byte offset to the TIFF header (0 = immediately following), then the TIFF data.
            let payload = try await Data([0, 0, 0, 0]) + serialized(structure)
            guard payload.count <= Int(UInt32.max) - 8 else { throw EXIFError.writeFailed("EXIF exceeds JXL box capacity") }
            var writer = ByteWriter()
            writer.writeUInt32(UInt32(payload.count + 8))
            writer.writeBytes(Data("Exif".utf8))
            writer.writeBytes(payload)
            replacement = writer.data
        }
        var edits = info.exif.enumerated().map { index, box in
            FileEdit(box.start ..< box.end, index == 0 ? replacement : Data())
        }
        if info.exif.isEmpty, structure != nil {
            // Metadata boxes may follow the file type box; boxes carry no absolute offsets, so nothing else moves.
            guard let ftyp = info.boxes.first(where: { $0.type == "ftyp" }) else {
                throw EXIFError.invalidJXL("Missing ftyp box")
            }
            edits.append(FileEdit(ftyp.end ..< ftyp.end, replacement))
        }
        return edits
    }
}
