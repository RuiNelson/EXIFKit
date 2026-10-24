import Foundation

/// Convenience entry points backed by the shared random-access parser and streaming writer.
public enum RAFContainer {
    public static func isRAF(_ data: Data) -> Bool {
        guard data.count >= 16 else { return false }
        let magic = String(data: data[data.startIndex ..< data.startIndex + 16], encoding: .ascii)
        return magic == "FUJIFILMCCD-RAW "
    }

    // MARK: - Reading

    public static func readEXIF(from source: any AbstractFileHandle) async throws -> TIFFStructure {
        try await EXIFKit.read(from: source, format: .raf)
    }

    public static func readEXIF(from data: Data) async throws -> TIFFStructure {
        try await EXIFKit.read(from: data, format: .raf)
    }

    public static func writeEXIF(_ structure: TIFFStructure, to data: Data) async throws -> Data {
        try await EXIFKit.write(structure, to: data, format: .raf)
    }

    public static func stripEXIF(from data: Data) async throws -> Data {
        try await EXIFKit.strip(from: data, format: .raf)
    }
}
