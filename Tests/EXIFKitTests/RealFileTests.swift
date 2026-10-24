import Foundation
import Testing

@testable import EXIFKit

private actor MeasuredLocalFile: AbstractFileHandle {
    private let source: LocalFileHandle
    private(set) var transferred = 0

    init(url: URL) throws {
        source = try LocalFileHandle(url: url)
    }

    var size: UInt64 {
        get async throws { try await source.size }
    }

    func read(at offset: UInt64, count: Int) async throws -> Data {
        let bytes = try await source.read(at: offset, count: count)
        transferred += bytes.count
        return bytes
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
        #expect(await source.transferred < 4096)
        let fromURL = try await EXIFKit.read(from: url)
        try EXIFOracleTag.assertMatches(fromURL, tags: oracle)
    }

    @Test func nikonThumbnailMatchesExiv2AndIsFetchedOnlyOnDemand() async throws {
        let source = try MeasuredLocalFile(url: NikonFixture.url())
        let metadata = try await EXIFKit.read(from: source)
        let beforeThumbnail = await source.transferred
        #expect(beforeThumbnail < 4096)
        let expected = try NikonFixture.thumbnail()
        #expect(expected.count == 6924)
        #expect(try await metadata.readThumbnail() == expected)
        #expect(await source.transferred - beforeThumbnail == expected.count)
        let serialized = try await TIFFSerializer.serialize(metadata)
        let reparsed = try await TIFFParser.parse(serialized)
        #expect(try await reparsed.readThumbnail() == expected)
    }
}
