#if canImport(Hummingbird)
    @testable import EXIFKit
    import Foundation
    import Hummingbird
    import HummingbirdTesting
    import Testing

    private actor RequestLog {
        var ranges: [Range<Int>] = []
        func record(_ range: Range<Int>) {
            ranges.append(range)
        }

        var bytes: Int {
            ranges.reduce(0) { $0 + $1.count }
        }
    }

    struct HTTPHandleTests {
        enum Behavior: Sendable { case normal, ignoreRange, malformedRange, shortBody, changed, error, empty }

        @available(macOS 14, iOS 17, tvOS 17, *)
        private func server(
            _ data: Data, behavior: Behavior = .normal, log: RequestLog = RequestLog(),
            body: @escaping @Sendable (URL) async throws -> Void
        ) async throws {
            let router = Router()
            router.get("/image") { request, _ -> Response in
                if behavior == .ignoreRange {
                    return Response(status: .ok, body: .init(byteBuffer: .init(bytes: data)))
                }
                if behavior == .error {
                    return Response(status: .internalServerError)
                }
                if behavior == .empty {
                    return Response(status: .rangeNotSatisfiable, headers: [.contentRange: "bytes */0"])
                }
                let field = request.headers[.range] ?? ""
                guard field.hasPrefix("bytes=") else { return Response(status: .badRequest) }
                let range = field.dropFirst(6).split(separator: "-")
                guard range.count == 2, let start = Int(range[0]), let last = Int(range[1]),
                      start <= last, start >= 0, last < data.count
                else { return Response(status: .rangeNotSatisfiable) }
                if behavior == .changed, request.headers[.ifMatch] != nil {
                    return Response(status: .preconditionFailed)
                }
                await log.record(start ..< last + 1)
                var slice = data.subdata(in: start ..< last + 1)
                if behavior == .shortBody, start != 0 || last != 0 {
                    slice = slice.dropLast()
                }
                return Response(
                    status: .partialContent,
                    headers: [
                        .contentRange: behavior == .malformedRange
                            ? "bytes 1-9/10" : "bytes \(start)-\(last)/\(data.count)",
                        .eTag: "\"test-version\"",
                        .contentLength: "\(slice.count)",
                    ], body: .init(byteBuffer: .init(bytes: slice))
                )
            }
            let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
            try await app.test(.live) { client in
                let port = try #require(client.port)
                try await body(URL(string: "http://localhost:\(port)/image")!)
            }
        }

        @Test func actualHTTPRangeExtractionAndStreamingWrite() async throws {
            guard #available(macOS 14, iOS 17, tvOS 17, *) else { return }
            let tiff = TIFFSerializer.encode(HandleTests.metadata())
            let data = HandleTests.jpeg(tiff) + Data(count: 2 * 1024 * 1024)
            let log = RequestLog()
            try await server(data, log: log) { url in
                let handle = try await HTTPFileHandle(url: url)
                #expect(try await handle.size == UInt64(data.count))
                var metadata = try await EXIFKit.read(from: handle)
                #expect(metadata.iso == 640)
                #expect(await log.bytes < 4096)
                #expect(await log.ranges.count < 30)
                metadata.ifd0.set(tagID: Tag.make, value: .ascii("HTTP edited"))
                let destination = InMemoryFileHandle()
                try await EXIFKit.write(metadata, from: handle, to: destination)
                #expect(try await EXIFKit.read(from: destination).make == "HTTP edited")
                #expect(await destination.data.suffix(100_000) == data.suffix(100_000))
                #expect(await log.ranges.allSatisfy { $0.count <= 65536 })
            }
        }

        @Test func URLConvenienceAndConcurrentReads() async throws {
            guard #available(macOS 14, iOS 17, tvOS 17, *) else { return }
            let data = TIFFSerializer.encode(HandleTests.metadata(.bigEndian))
            try await server(data) { url in
                #expect(try await EXIFKit.read(from: url).iso == 640)
                let handle = try await HTTPFileHandle(url: url)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for offset in [0, 8, 12, 20, 32] {
                        group.addTask { () async throws in
                            #expect(
                                try await handle.read(at: UInt64(offset), count: 4)
                                    == data.subdata(in: offset ..< offset + 4)
                            )
                        }
                    }
                    try await group.waitForAll()
                }
            }
        }

        @Test func rejectsIgnoredRangesAndMalformedResponses() async throws {
            guard #available(macOS 14, iOS 17, tvOS 17, *) else { return }
            let data = TIFFSerializer.encode(HandleTests.metadata())
            for behavior in [Behavior.ignoreRange, .malformedRange, .error] {
                try await server(data, behavior: behavior) { url in
                    await #expect(throws: URLError.self) { try await HTTPFileHandle(url: url) }
                }
            }
            for behavior in [Behavior.shortBody, .changed] {
                try await server(data, behavior: behavior) { url in
                    let handle = try await HTTPFileHandle(url: url)
                    if behavior == .shortBody {
                        await #expect(throws: FileAccessError.self) { try await EXIFKit.read(from: handle) }
                    } else {
                        await #expect(throws: URLError.self) { try await EXIFKit.read(from: handle) }
                    }
                }
            }
        }

        @Test func nikonFixtureMatchesExiv2InMemoryAndOverHTTP() async throws {
            guard #available(macOS 14, iOS 17, tvOS 17, *) else { return }
            let data = try Data(contentsOf: NikonFixture.url())
            let oracle = try NikonFixture.tags()
            let memory = try await EXIFKit.read(from: InMemoryFileHandle(data: data))
            try EXIFOracleTag.assertMatches(memory, tags: oracle)
            let log = RequestLog()
            try await server(data, log: log) { url in
                let handle = try await HTTPFileHandle(url: url)
                let metadata = try await EXIFKit.read(from: handle)
                try EXIFOracleTag.assertMatches(metadata, tags: oracle)
                let beforeThumbnail = await log.bytes
                #expect(beforeThumbnail < 4096)
                let expected = try NikonFixture.thumbnail()
                #expect(try await metadata.readThumbnail() == expected)
                #expect(await log.bytes - beforeThumbnail == expected.count)
            }
        }

        @Test func emptyFileAndCancellation() async throws {
            guard #available(macOS 14, iOS 17, tvOS 17, *) else { return }
            try await server(Data(), behavior: .empty) { url in
                let handle = try await HTTPFileHandle(url: url)
                #expect(try await handle.size == 0)
                #expect(try await handle.read(at: 0, count: 0).isEmpty)
                await #expect(throws: FileAccessError.self) { try await handle.read(at: 0, count: 1) }
            }
            let memory = InMemoryFileHandle(data: TIFFSerializer.encode(HandleTests.metadata()))
            let task = Task { () throws -> TIFFStructure in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await EXIFKit.read(from: memory)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }

#endif
