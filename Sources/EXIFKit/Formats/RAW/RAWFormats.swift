import Foundation

/// Convenience entry points backed by the shared random-access parser and streaming writer.
public enum RAWContainer {
    /// Detected RAW sub-format
    public enum RAWFormat: String, Sendable {
        case cr2 // Canon
        case nef // Nikon
        case arw // Sony
        case orf // Olympus / OM System
        case rw2 // Panasonic / Lumix
        case pef // Pentax
        case srw // Samsung
        case genericTIFF
    }

    /// Detect the specific RAW format from file data
    public static func detectFormat(from data: Data) -> RAWFormat? {
        guard data.count >= 8 else { return nil }

        let head = [UInt8](data.prefix(12))

        // Check byte order marker
        let isLittleEndian = (head[0] == 0x49 && head[1] == 0x49)
        let isBigEndian = (head[0] == 0x4D && head[1] == 0x4D)

        guard isLittleEndian || isBigEndian else { return nil }

        // Read magic number
        let magic: UInt16
        if isLittleEndian {
            magic = UInt16(head[2]) | UInt16(head[3]) << 8
        } else {
            magic = UInt16(head[2]) << 8 | UInt16(head[3])
        }

        // RW2: magic = 0x0055
        if magic == 0x0055 {
            return .rw2
        }

        // ORF: magic = 0x4F52 ("OR") or 0x5352 ("SR") for some models
        if magic == 0x4F52 || magic == 0x5352 {
            return .orf
        }

        // Standard TIFF magic = 42
        guard magic == 42 else { return nil }

        // CR2: has "CR" at bytes 8-9 (Canon's identifier)
        if data.count >= 10, head[8] == 0x43, head[9] == 0x52 {
            return .cr2
        }

        // For other formats with magic 42, we need to check the Make tag
        // or use file extension. Return generic for now.
        return .genericTIFF
    }

    /// Refine the RAW format detection using the Make string from IFD0
    public static func refineFormat(
        _ initial: RAWFormat,
        make: String?,
        fileExtension: String? = nil
    ) -> RAWFormat {
        // If already a specific non-generic format, keep it
        if initial != .genericTIFF {
            return initial
        }

        // Try file extension first
        if let ext = fileExtension?.lowercased() {
            switch ext {
            case "cr2": return .cr2
            case "nef", "nrw": return .nef
            case "arw", "srf", "sr2": return .arw
            case "orf": return .orf
            case "rw2": return .rw2
            case "pef": return .pef
            case "srw": return .srw
            default: break
            }
        }

        // Try Make string
        guard let make = make?.lowercased() else { return initial }

        if make.contains("nikon") {
            return .nef
        }
        if make.contains("sony") {
            return .arw
        }
        if make.contains("olympus") || make.contains("om digi") {
            return .orf
        }
        if make.contains("pentax") || make.contains("ricoh") {
            return .pef
        }
        if make.contains("panasonic") || make.contains("lumix") {
            return .rw2
        }
        if make.contains("samsung") {
            return .srw
        }
        if make.contains("canon") {
            return .cr2
        }

        return initial
    }

    public static func readEXIF(from source: any AbstractFileHandle) async throws -> TIFFStructure {
        try await EXIFKit.read(from: source, format: .cr2)
    }

    public static func readEXIF(from data: Data) async throws -> TIFFStructure {
        try await EXIFKit.read(from: data, format: .cr2)
    }

    public static func writeEXIF(_ structure: TIFFStructure, to data: Data) async throws -> Data {
        try await EXIFKit.write(structure, to: data, format: .cr2)
    }

    public static func stripEXIF(from data: Data) async throws -> Data {
        try await EXIFKit.strip(from: data, format: .cr2)
    }
}
