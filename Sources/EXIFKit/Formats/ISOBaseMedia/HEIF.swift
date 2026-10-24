import Foundation

/// Convenience entry points backed by the shared random-access parser and streaming writer.
public enum HEIFContainer {
    private static let heifBrands: Set<String> = [
        "heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1", "avif", "avis",
    ]
    public static func isHEIF(_ data: Data) -> Bool {
        guard let brands = fileTypeBrands(data) else { return false }
        return brands.contains { heifBrands.contains($0) }
    }

    public static func readEXIF(from source: any AbstractFileHandle) async throws -> TIFFStructure {
        try await EXIFKit.read(from: source, format: .heif)
    }

    public static func readEXIF(from data: Data) async throws -> TIFFStructure {
        try await EXIFKit.read(from: data, format: .heif)
    }

    public static func writeEXIF(_ structure: TIFFStructure, to data: Data) async throws -> Data {
        try await EXIFKit.write(structure, to: data, format: .heif)
    }

    public static func stripEXIF(from data: Data) async throws -> Data {
        try await EXIFKit.strip(from: data, format: .heif)
    }
}

/// Inspect only bytes supplied by the caller; extended-size ftyp headers are supported.
func fileTypeBrands(_ data: Data) -> [String]? {
    guard data.count >= 16 else { return nil }
    var reader = ByteReader(data: data)
    guard let length32 = try? reader.readUInt32(), (try? reader.readASCII(4)) == "ftyp" else { return nil }
    var header = 8
    var length = UInt64(length32)
    if length32 == 1 {
        guard data.count >= 24, let high = try? reader.readUInt32(), let low = try? reader.readUInt32() else {
            return nil
        }
        header = 16
        length = UInt64(high) << 32 | UInt64(low)
    } else if length32 == 0 {
        length = UInt64(data.count)
    }
    guard length >= UInt64(header + 8) else { return nil }
    reader.offset = header
    guard let major = try? reader.readASCII(4) else { return nil }
    var brands = [major]
    reader.offset += 4 // minor version
    let end = Int(min(length, UInt64(data.count)))
    while reader.offset <= end - 4 {
        guard let brand = try? reader.readASCII(4) else { break }
        brands.append(brand)
    }
    return brands
}
