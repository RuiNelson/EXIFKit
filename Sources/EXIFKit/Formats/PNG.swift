import Foundation

/// Convenience entry points backed by the shared random-access parser and streaming writer.
public enum PNGContainer {
    public static func readEXIF(from source: any AbstractFileHandle) async throws -> TIFFStructure {
        try await EXIFKit.read(from: source, format: .png)
    }

    public static func readEXIF(from data: Data) async throws -> TIFFStructure {
        try await EXIFKit.read(from: data, format: .png)
    }

    public static func writeEXIF(_ structure: TIFFStructure, to data: Data) async throws -> Data {
        try await EXIFKit.write(structure, to: data, format: .png)
    }

    public static func stripEXIF(from data: Data) async throws -> Data {
        try await EXIFKit.strip(from: data, format: .png)
    }
}

enum CRC32 {
    static let table: [UInt32] = (0 ..< 256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0 ..< 8 {
            if c & 1 != 0 {
                c = 0xEDB8_8320 ^ (c >> 1)
            } else {
                c = c >> 1
            }
        }
        return c
    }

    static func calculate(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
