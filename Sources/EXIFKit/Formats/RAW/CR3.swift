import Foundation

/// Convenience entry points backed by the shared random-access parser and streaming writer.
public enum CR3Container {
    static let canonUUID = Data([
        0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0,
        0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48,
    ])

    // MARK: - Detection

    /// Check if data is a CR3 file by looking for the "crx " file type
    public static func isCR3(_ data: Data) -> Bool {
        fileTypeBrands(data)?.first == "crx "
    }

    public static func readEXIF(from source: any AbstractFileHandle) async throws -> TIFFStructure {
        try await EXIFKit.read(from: source, format: .cr3)
    }

    public static func readEXIF(from data: Data) async throws -> TIFFStructure {
        try await EXIFKit.read(from: data, format: .cr3)
    }

    public static func writeEXIF(_ structure: TIFFStructure, to data: Data) async throws -> Data {
        try await EXIFKit.write(structure, to: data, format: .cr3)
    }

    public static func stripEXIF(from data: Data) async throws -> Data {
        try await EXIFKit.strip(from: data, format: .cr3)
    }
}
