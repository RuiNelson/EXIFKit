import Foundation

/// Convenience entry points backed by the shared random-access parser and streaming writer.
public enum JPEGContainer {
    public static func readEXIF(from source: any AbstractFileHandle) async throws -> TIFFStructure {
        try await EXIFKit.read(from: source, format: .jpeg)
    }

    public static func readEXIF(from data: Data) async throws -> TIFFStructure {
        try await EXIFKit.read(from: data, format: .jpeg)
    }

    public static func writeEXIF(_ structure: TIFFStructure, to data: Data) async throws -> Data {
        try await EXIFKit.write(structure, to: data, format: .jpeg)
    }

    public static func stripEXIF(from data: Data) async throws -> Data {
        try await EXIFKit.strip(from: data, format: .jpeg)
    }
}
