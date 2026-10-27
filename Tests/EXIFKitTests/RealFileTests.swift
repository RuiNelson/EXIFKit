@testable import EXIFKit
import Foundation
import Testing

private actor MeasuredLocalFile: AbstractFileHandle {
    private let source: LocalFileHandle
    private(set) var transferred = 0
    private(set) var reads = 0

    init(url: URL) throws {
        source = try LocalFileHandle(url: url)
    }

    var size: UInt64 {
        get async throws { try await source.size }
    }

    func read(at offset: UInt64, count: Int) async throws -> Data {
        let bytes = try await source.read(at: offset, count: count)
        transferred += bytes.count
        reads += 1
        return bytes
    }

    func write(_ data: Data, at offset: UInt64) async throws {
        try await source.write(data, at: offset)
    }

    func truncate(to size: UInt64) async throws {
        try await source.truncate(to: size)
    }
}

struct RealFileTests {
    @Test func nikonJPEGMatchesAllExiv2TagsAndReadsOnlyMetadata() async throws {
        let url = try NikonFixture.url()
        let source = try MeasuredLocalFile(url: url)
        #expect(try await ImageFormat.detect(from: source.read(at: 0, count: 16)) == .jpeg)
        let metadata = try await EXIFKit.read(from: source)
        let oracle = try NikonFixture.tags()
        #expect(oracle.count == 20)
        try EXIFOracleTag.assertMatches(metadata, tags: oracle)
        #expect(metadata.iso == 200)
        #expect(metadata.exposureTime == 0.004)
        #expect(metadata.fNumber == 8)
        #expect(metadata.focalLength == 45)
        #expect(metadata.pixelWidth == 4288)
        #expect(metadata.pixelHeight == 2848)
        // The caller's 16-byte detection read, then one block for all metadata.
        #expect(await source.reads == 2)
        #expect(await source.transferred == 16 + 65536)
        let exact = try MeasuredLocalFile(url: url)
        try await EXIFOracleTag.assertMatches(EXIFKit.read(from: exact, options: ReadOptions(readAheadBytes: 0)), tags: oracle)
        #expect(await exact.transferred < 4096)
        let fromURL = try await EXIFKit.read(from: url)
        try EXIFOracleTag.assertMatches(fromURL, tags: oracle)
    }

    @Test func nikonThumbnailMatchesExiv2AndIsFetchedOnlyOnDemand() async throws {
        let source = try MeasuredLocalFile(url: NikonFixture.url())
        let metadata = try await EXIFKit.read(from: source)
        let beforeThumbnail = await source.transferred
        #expect(await source.reads == 1)
        let expected = try NikonFixture.thumbnail()
        #expect(expected.count == 6924)
        #expect(try await metadata.readThumbnail() == expected)
        #expect(await source.transferred - beforeThumbnail == expected.count)
        let serialized = try await TIFFSerializer.serialize(metadata)
        let reparsed = try await TIFFParser.parse(serialized)
        #expect(try await reparsed.readThumbnail() == expected)
    }
}
