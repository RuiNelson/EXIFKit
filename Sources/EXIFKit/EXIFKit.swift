import Foundation

// MARK: - Image Format Detection

/// Supported image formats for EXIF parsing
public enum ImageFormat: String, CaseIterable, Sendable {
    case jpeg
    case png
    case webp
    case tiff
    case dng
    case cr2 // Canon (TIFF-based)
    case cr3 // Canon (ISOBMFF-based)
    case nef // Nikon (TIFF-based)
    case arw // Sony (TIFF-based)
    case raf // Fujifilm (custom)
    case orf // Olympus / OM System (TIFF variant)
    case rw2 // Panasonic / Lumix (TIFF variant)
    case pef // Pentax (TIFF-based)
    case heif // HEIF / HEIC (ISOBMFF-based)
    case jxl // JPEG XL container (ISOBMFF-style boxes)

    /// Whether this format is TIFF-based (uses standard IFD structures)
    public var isTIFFBased: Bool {
        switch self {
        case .tiff, .dng, .cr2, .nef, .arw, .orf, .rw2, .pef:
            return true
        default:
            return false
        }
    }

    /// Whether this format uses ISOBMFF container
    public var isISOBMFF: Bool {
        switch self {
        case .cr3, .heif, .jxl:
            return true
        default:
            return false
        }
    }

    /// Detect format from file data by inspecting magic bytes
    public static func detect(from data: Data) -> ImageFormat? {
        let head = [UInt8](data.prefix(16))
        if head.count >= 2, head[0] == 0xFF, head[1] == 0xD8 {
            return .jpeg
        }
        if head.count >= 8, data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) {
            return .png
        }
        if WebPContainer.isWebP(data) {
            return .webp
        }
        if JXLContainer.isJXL(data) {
            return .jxl
        }
        if RAFContainer.isRAF(data) {
            return .raf
        }
        if CR3Container.isCR3(data) {
            return .cr3
        }
        if HEIFContainer.isHEIF(data) {
            return .heif
        }
        guard head.count >= 8 else { return nil }
        let little = head[0] == 0x49 && head[1] == 0x49
        let big = head[0] == 0x4D && head[1] == 0x4D
        guard little || big else { return nil }
        let magic = little ? UInt16(head[2]) | UInt16(head[3]) << 8 : UInt16(head[2]) << 8 | UInt16(head[3])
        if magic == 0x4F52 || magic == 0x5352 {
            return .orf
        }
        if magic == 0x0055 {
            return .rw2
        }
        if magic == 42 {
            if head.count >= 10, head[8] == 0x43, head[9] == 0x52 {
                return .cr2
            }
            return .tiff
        }
        return nil
    }

    /// Detect format from file extension
    public static func detect(fromExtension ext: String) -> ImageFormat? {
        switch ext.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "png": return .png
        case "webp": return .webp
        case "tif", "tiff": return .tiff
        case "dng": return .dng
        case "cr2": return .cr2
        case "cr3": return .cr3
        case "nef", "nrw": return .nef
        case "arw", "srf", "sr2": return .arw
        case "raf": return .raf
        case "orf": return .orf
        case "rw2": return .rw2
        case "pef": return .pef
        case "srw": return .tiff
        case "heif", "heic": return .heif
        case "avif": return .heif
        case "jxl": return .jxl
        default: return nil
        }
    }
}

// MARK: - EXIFKit

/// Main entry point for reading and writing EXIF metadata.
///
/// Supports all major image formats:
/// - **Standard**: JPEG, PNG, WebP, TIFF, DNG
/// - **Canon**: CR2 (TIFF-based), CR3 (ISOBMFF-based)
/// - **Nikon**: NEF (TIFF-based)
/// - **Sony**: ARW (TIFF-based)
/// - **Fujifilm**: RAF (custom container)
/// - **Olympus/OM System**: ORF (TIFF variant)
/// - **Panasonic/Lumix**: RW2 (TIFF variant)
/// - **Pentax**: PEF (TIFF-based)
/// - **Apple/Modern**: HEIF/HEIC (ISOBMFF-based)
/// - **JPEG XL**: container files with an `Exif` box
///
/// Usage:
/// ```swift
/// // Read — auto-detects format
/// let metadata = try await EXIFKit.read(from: imageData)
/// print(metadata.make)             // "NIKON CORPORATION"
/// print(metadata.model)            // "NIKON Z 8"
/// print(metadata.dateTimeOriginal) // "2024:01:15 14:30:00"
///
/// // Modify and write back
/// var metadata = try await EXIFKit.read(from: imageData)
/// metadata.setGPSCoordinates(latitude: 48.8566, longitude: 2.3522)
/// let newData = try await EXIFKit.write(metadata, to: imageData)
/// ```
public enum EXIFKit {
    // MARK: - Reading

    /// Read only the ranges needed for metadata. The handle remains owned by the caller.
    public static func read(
        from handle: any AbstractFileHandle,
        format: ImageFormat? = nil,
        options: ReadOptions = ReadOptions()
    ) async throws -> TIFFStructure {
        let size = try await handle.size
        let reader = MetadataReader(handle, size: size, options: options)
        let file = try FileRegion(reader, offset: 0, length: size)
        let detected: ImageFormat
        if let format {
            detected = format
        } else {
            detected = try await HandleParser.detect(file)
        }
        let structure = try await HandleParser.read(file, format: detected)
        await reader.finish()
        return structure
    }

    /// In-memory convenience using the same parser as local and remote sources.
    public static func read(
        from data: Data, format: ImageFormat? = nil,
        options: ReadOptions = ReadOptions()
    ) async throws -> TIFFStructure {
        try await read(from: InMemoryFileHandle(data: data), format: format, options: options)
    }

    /// Select a local or HTTP handle from the URL scheme; detect format from contents.
    public static func read(
        from url: URL, format: ImageFormat? = nil,
        options: ReadOptions = ReadOptions()
    ) async throws -> TIFFStructure {
        let handle: any AbstractFileHandle
        if url.isFileURL {
            handle = try LocalFileHandle(url: url)
        } else {
            handle = try await HTTPFileHandle(url: url)
        }
        return try await read(from: handle, format: format, options: options)
    }

    /// Convenience for callers that already have the complete source in memory.
    public static func write(
        _ structure: TIFFStructure, to data: Data,
        format: ImageFormat? = nil
    ) async throws -> Data {
        let destination = InMemoryFileHandle()
        try await write(structure, from: InMemoryFileHandle(data: data), to: destination, format: format)
        return await destination.data
    }

    public static func strip(from data: Data, format: ImageFormat? = nil) async throws -> Data {
        let destination = InMemoryFileHandle()
        try await strip(from: InMemoryFileHandle(data: data), to: destination, format: format)
        return await destination.data
    }

    // MARK: - Dump

    /// Returns a human-readable dump of all EXIF tags.
    public static func dump(from data: Data) async throws -> String {
        let structure = try await read(from: data)
        return dump(structure)
    }

    /// Returns a human-readable dump of a TIFFStructure.
    public static func dump(_ structure: TIFFStructure) -> String {
        var lines: [String] = []

        lines.append("=== Info ===")
        lines.append("  Byte Order: \(structure.byteOrder == .littleEndian ? "Little Endian (II)" : "Big Endian (MM)")")

        lines.append("\n=== IFD0 ===")
        for entry in structure.ifd0.entries {
            lines.append("  \(Tag.name(for: entry.tagID)) (0x\(hex(entry.tagID))): \(entry.value)")
        }

        if let exif = structure.exifIFD {
            lines.append("\n=== EXIF IFD ===")
            for entry in exif.entries {
                if entry.tagID == Tag.makerNote {
                    lines.append("  MakerNote (0x927C): [\(entry.value.count) bytes]")
                    continue
                }
                lines.append("  \(Tag.name(for: entry.tagID)) (0x\(hex(entry.tagID))): \(entry.value)")
            }
        }

        if let gps = structure.gpsIFD {
            lines.append("\n=== GPS IFD ===")
            for entry in gps.entries {
                lines.append("  \(Tag.gpsName(for: entry.tagID)) (0x\(hex(entry.tagID))): \(entry.value)")
            }
        }

        if let lat = structure.latitude, let lon = structure.longitude {
            lines.append("\n=== GPS Coordinates ===")
            lines.append("  Latitude:  \(lat)")
            lines.append("  Longitude: \(lon)")
            if let alt = structure.altitude {
                lines.append("  Altitude:  \(alt)m")
            }
        }

        lines.append("\n=== Summary ===")
        if let make = structure.make {
            lines.append("  Camera: \(make) \(structure.model ?? "")")
        }
        if let dt = structure.dateTimeOriginal {
            lines.append("  Date: \(dt)")
        }
        if let iso = structure.iso {
            lines.append("  ISO: \(iso)")
        }
        if let f = structure.fNumber {
            lines.append("  Aperture: f/\(String(format: "%.1f", f))")
        }
        if let exp = structure.exposureTime {
            if exp < 1 {
                lines.append("  Shutter: 1/\(Int(1.0 / exp))s")
            } else {
                lines.append("  Shutter: \(String(format: "%.1f", exp))s")
            }
        }
        if let fl = structure.focalLength {
            lines.append("  Focal Length: \(String(format: "%.0f", fl))mm")
        }
        if let lens = structure.lensModel {
            lines.append("  Lens: \(lens)")
        }

        return lines.joined(separator: "\n")
    }

    private static func hex(_ value: UInt16) -> String {
        String(value, radix: 16, uppercase: true)
    }
}
