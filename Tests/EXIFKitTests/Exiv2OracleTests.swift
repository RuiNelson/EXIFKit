#if os(macOS) || os(Linux)
import Foundation
import Testing

@testable import EXIFKit

private struct OracleCommandError: Error {
    let status: Int32
    let message: String
}

private enum Exiv2 {
    static let executable: URL? = {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["EXIV2"] { return URL(fileURLWithPath: explicit) }
        return (environment["PATH"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("exiv2")
        }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    /// Blocking subprocess I/O runs outside the Swift concurrency executor, with file-backed
    /// stdout/stderr so simultaneous output cannot fill a pipe and deadlock the child.
    static func run(_ arguments: [String]) async throws -> Data {
        let executable = try #require(executable)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let outputURL = directory.appendingPathComponent("stdout")
                    let errorURL = directory.appendingPathComponent("stderr")
                    try Data().write(to: outputURL, options: .withoutOverwriting)
                    try Data().write(to: errorURL, options: .withoutOverwriting)
                    let stdout = try FileHandle(forWritingTo: outputURL)
                    let stderr = try FileHandle(forWritingTo: errorURL)
                    defer { try? stdout.close(); try? stderr.close() }
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    var environment = ProcessInfo.processInfo.environment
                    environment["LC_ALL"] = "C"
                    process.environment = environment
                    process.standardOutput = stdout
                    process.standardError = stderr
                    try process.run()
                    process.waitUntilExit()
                    let diagnostics = try Data(contentsOf: errorURL)
                    guard process.terminationStatus == 0, diagnostics.isEmpty else {
                        throw OracleCommandError(status: process.terminationStatus,
                            message: String(decoding: diagnostics, as: UTF8.self))
                    }
                    return try Data(contentsOf: outputURL)
                })
            }
        }
    }

    static func tags(_ url: URL) async throws -> [EXIFOracleTag] {
        try await EXIFOracleTag.parse(run(["-PExkycv", url.path]))
    }
    static func thumbnail(_ url: URL) async throws -> Data {
        try await run(["-et-", "ex", url.path])
    }

    /// JPEG scan bytes and all non-EXIF segments must remain identical, including XMP/IPTC.
    static func preservedRanges(_ file: LocalFileHandle) async throws -> [Range<UInt64>] {
        let size = try await file.size
        #expect(try await file.read(at: 0, count: 2) == Data([0xFF, 0xD8]))
        var ranges: [Range<UInt64>] = [0..<2]
        var position: UInt64 = 2
        while position < size {
            let start = position
            let marker = try await file.read(at: position, count: 2)
            #expect(marker[0] == 0xFF)
            if marker[1] == 0xDA { ranges.append(start..<size); return ranges }
            let lengthBytes = try await file.read(at: position + 2, count: 2)
            let length = UInt64(lengthBytes[0]) << 8 | UInt64(lengthBytes[1])
            #expect(length >= 2)
            position += 2 + length
            if marker[1] == 0xE1, length >= 8,
               try await file.read(at: start + 4, count: 6) == Data("Exif\0\0".utf8) { continue }
            ranges.append(start..<position)
        }
        Issue.record("JPEG scan not found")
        return ranges
    }

    static func assertImageAndNonEXIFSegmentsPreserved(_ original: URL, _ output: URL) async throws {
        let lhs = try LocalFileHandle(url: original), rhs = try LocalFileHandle(url: output)
        let left = try await preservedRanges(lhs), right = try await preservedRanges(rhs)
        #expect(left.count == right.count)
        for (a, b) in zip(left, right) {
            let length = a.upperBound - a.lowerBound
            #expect(length == b.upperBound - b.lowerBound)
            var offset: UInt64 = 0
            while offset < length {
                let count = Int(min(65536, length - offset))
                let expected = try await lhs.read(at: a.lowerBound + offset, count: count)
                #expect(try await rhs.read(at: b.lowerBound + offset, count: count) == expected)
                offset += UInt64(count)
            }
        }
    }
}

struct Exiv2OracleTests {
    @Test(.enabled(if: Exiv2.executable != nil))
    func liveExiv2MatchesSavedReferenceAndLibrary() async throws {
        let fixture = try NikonFixture.url()
        let live = try await Exiv2.tags(fixture)
        #expect(try live == NikonFixture.tags())
        try await EXIFOracleTag.assertMatches(EXIFKit.read(from: fixture), tags: live)
        #expect(try await Exiv2.thumbnail(fixture) == NikonFixture.thumbnail())
    }

    @Test(.enabled(if: Exiv2.executable != nil))
    func exiv2ValidatesLibraryEditsAndPreservedImageData() async throws {
        let fixture = try NikonFixture.url()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("edited.jpg")
        let source = try LocalFileHandle(url: fixture)
        var metadata = try await EXIFKit.read(from: source)
        metadata.ifd0.set(tagID: Tag.artist, value: .ascii("EXIFKit oracle test"))
        metadata.exifIFD?.set(tagID: Tag.isoSpeedRatings, value: .short(800))
        metadata.setGPSCoordinates(latitude: 38.7223, longitude: -9.1393, altitude: 12.5)
        try await EXIFKit.write(metadata, from: source, to: WritableLocalFileHandle(url: output))
        let live = try await Exiv2.tags(output)
        let reparsed = try await EXIFKit.read(from: output)
        try EXIFOracleTag.assertMatches(reparsed, tags: live)
        #expect(live.first { $0.key == "Exif.Image.Artist" }?.value == "EXIFKit oracle test")
        #expect(live.first { $0.key == "Exif.Photo.ISOSpeedRatings" }?.value == "800")
        let relocated: Set<String> = ["Exif.Image.ExifTag", "Exif.Thumbnail.JPEGInterchangeFormat", "Exif.Photo.ISOSpeedRatings"]
        for original in try NikonFixture.tags() where !relocated.contains(original.key) {
            #expect(live.first { $0.key == original.key } == original)
        }
        #expect(try await Exiv2.thumbnail(output) == NikonFixture.thumbnail())
        #expect(try await reparsed.readThumbnail() == NikonFixture.thumbnail())
        try await Exiv2.assertImageAndNonEXIFSegmentsPreserved(fixture, output)
    }

    @Test(.enabled(if: Exiv2.executable != nil))
    func exiv2ConfirmsStrippingRemovesEXIFAndPreservesOtherSegments() async throws {
        let fixture = try NikonFixture.url()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: output) }
        try await EXIFKit.strip(from: LocalFileHandle(url: fixture), to: WritableLocalFileHandle(url: output))
        #expect(try await Exiv2.tags(output).isEmpty)
        await #expect(throws: EXIFError.self) { try await EXIFKit.read(from: output) }
        try await Exiv2.assertImageAndNonEXIFSegmentsPreserved(fixture, output)
    }

    @Test(.enabled(if: Exiv2.executable != nil))
    func libraryReadsEditsMadeByExiv2() async throws {
        let fixture = try NikonFixture.url()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: output) }
        try FileManager.default.copyItem(at: fixture, to: output)
        _ = try await Exiv2.run(["-M", "set Exif.Image.Artist Ascii exiv2 oracle test",
                                "-M", "set Exif.Image.Orientation Short 6",
                                "-M", "set Exif.Photo.ISOSpeedRatings Short 1600", output.path])
        let metadata = try await EXIFKit.read(from: output)
        try await EXIFOracleTag.assertMatches(metadata, tags: Exiv2.tags(output))
        #expect(metadata.artist == "exiv2 oracle test")
        #expect(metadata.orientation == 6)
        #expect(metadata.iso == 1600)
        #expect(try await metadata.readThumbnail() == NikonFixture.thumbnail())
    }
}
#endif
