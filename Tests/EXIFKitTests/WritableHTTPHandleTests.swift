#if canImport(Hummingbird)
    @testable import EXIFKit
    import Foundation
    #if canImport(FoundationNetworking)
        import FoundationNetworking
    #endif
    import Hummingbird
    import HummingbirdTesting
    import Testing

    private actor HTTPTestFile {
        private var contents: Data?
        private var version = 1
        private let patchStatus: Int?
        private(set) var writes: [(method: String, range: String?, bytes: Int)] = []
        private(set) var downloaded = 0
        var data: Data? {
            contents
        }

        init(_ contents: Data?, patchStatus: Int?) {
            self.contents = contents
            self.patchStatus = patchStatus
        }

        private var etag: String {
            "\"version-\(version)\""
        }

        func read(_ request: Request) -> Response {
            guard let contents else { return Response(status: .notFound) }
            if let expected = request.headers[.ifMatch], expected != etag {
                return Response(status: .preconditionFailed)
            }
            if contents.isEmpty {
                return Response(status: .rangeNotSatisfiable, headers: [.contentRange: "bytes */0", .eTag: etag])
            }
            let range = (request.headers[.range] ?? "").dropFirst(6).split(separator: "-")
            guard range.count == 2, let start = Int(range[0]), let end = Int(range[1]), start >= 0, start <= end,
                  end < contents.count
            else {
                return Response(status: .rangeNotSatisfiable)
            }
            downloaded += end - start + 1
            return Response(
                status: .partialContent,
                headers: [.contentRange: "bytes \(start)-\(end)/\(contents.count)", .eTag: etag],
                body: .init(byteBuffer: .init(bytes: contents.subdata(in: start ..< end + 1)))
            )
        }

        func write(_ request: Request, data: Data) -> Response {
            let method = request.method.rawValue
            writes.append((method, request.headers[.contentRange], data.count))
            if method == "PATCH", let patchStatus {
                return Response(status: .init(code: patchStatus))
            }
            if let expected = request.headers[.ifMatch], expected != etag {
                return Response(status: .preconditionFailed)
            }
            if request.headers[.ifNoneMatch] == "*", contents != nil {
                return Response(status: .preconditionFailed)
            }
            if method == "PUT" {
                contents = data
            } else {
                let field = (request.headers[.contentRange] ?? "").split(separator: " ")
                guard field.count == 2, field[0] == "bytes" else { return Response(status: .badRequest) }
                let location = field[1].split(separator: "/")
                guard location.count == 2, let length = Int(location[1]), length >= 0, length <= 4 * 1024 * 1024 else {
                    return Response(status: .badRequest)
                }
                var output = contents ?? Data()
                if length < output.count {
                    output.removeSubrange(length ..< output.count)
                } else if length > output.count {
                    output.append(Data(count: length - output.count))
                }
                if location[0] != "*" {
                    let range = location[0].split(separator: "-")
                    guard range.count == 2, let start = Int(range[0]), let end = Int(range[1]),
                          start >= 0, end >= start, end < length, end - start + 1 == data.count
                    else { return Response(status: .badRequest) }
                    output.replaceSubrange(start ..< end + 1, with: data)
                } else if !data.isEmpty {
                    return Response(status: .badRequest)
                }
                contents = output
            }
            version += 1
            return Response(status: .noContent, headers: [.eTag: etag])
        }
    }

    struct WritableHTTPHandleTests {
        @available(macOS 14, iOS 17, tvOS 17, *)
        private func server(
            initial: Data?, patchStatus: Int? = nil,
            body: @escaping @Sendable (URL, HTTPTestFile) async throws -> Void
        ) async throws {
            let state = HTTPTestFile(initial, patchStatus: patchStatus)
            let router = Router()
            router.get("/image") { request, _ in await state.read(request) }
            router.patch("/image") { request, _ in
                let bytes = try await request.body.collect(upTo: 4 * 1024 * 1024)
                return await state.write(request, data: Data(bytes.readableBytesView))
            }
            router.put("/image") { request, _ in
                let bytes = try await request.body.collect(upTo: 4 * 1024 * 1024)
                return await state.write(request, data: Data(bytes.readableBytesView))
            }
            let app = Application(router: router)
            try await app.test(.live) { client in
                let port = try #require(client.port)
                try await body(URL(string: "http://localhost:\(port)/image")!, state)
            }
        }

        @Test func allStandardHandlesShareMutationCapability() async throws {
            guard #available(macOS 14, iOS 17, tvOS 17, *) else { return }
            let memory: any AbstractFileHandle = InMemoryFileHandle(data: Data())
            try await memory.truncate(to: 1)
            try await server(initial: Data([1, 2, 3])) { url, _ in
                let http: any AbstractFileHandle = try await HTTPFileHandle(url: url)
                try await http.write(Data([4]), at: 3)
            }
        }

        @Test func patchChangesOnlyRequestedOffsets() async throws {
            guard #available(macOS 14, iOS 17, tvOS 17, *) else { return }
            let original = Data(repeating: 0xA5, count: 100_000)
            try await server(initial: original) { url, state in
                let handle = try await HTTPFileHandle(url: url)
                try await handle.write(Data([1, 2, 3]), at: 123)
                #expect(await state.writes.isEmpty)
                #expect(try await handle.read(at: 123, count: 3) == Data([1, 2, 3]))
                try await handle.synchronize()
                let writes = await state.writes
                #expect(writes.count == 1)
                #expect(writes.first?.method == "PATCH")
                #expect(writes.first?.range == "bytes 123-125/100000")
                #expect(writes.first?.bytes == 3)
                var expected = original
                expected.replaceSubrange(123 ..< 126, with: [1, 2, 3])
                #expect(await state.data == expected)
                #expect(try await handle.read(at: 0, count: 3) == original.prefix(3))
                #expect(await state.downloaded == 4) // probe + requested uncached bytes
            }
        }

        @Test func unsupportedPatchFallsBackToPUTWithoutLosingUntouchedBytes() async throws {
            guard #available(macOS 14, iOS 17, tvOS 17, *) else { return }
            let original = Data(repeating: 0xA5, count: 100_000)
            for status in [405, 415, 501] {
                try await server(initial: original, patchStatus: status) { url, state in
                    let handle = try await HTTPFileHandle(url: url)
                    try await handle.write(Data([1, 2, 3]), at: 123)
                    try await handle.synchronize()
                    var expected = original
                    expected.replaceSubrange(123 ..< 126, with: [1, 2, 3])
                    #expect(await state.data == expected)
                    let writes = await state.writes
                    #expect(writes.map(\.method) == ["PATCH", "PUT"])
                    #expect(writes.last?.bytes == original.count)
                    try await handle.write(Data([9]), at: 0)
                    try await handle.synchronize()
                    #expect(await state.writes.map(\.method) == ["PATCH", "PUT", "PUT"])
                }
            }
        }

        @Test func exifWriterAndStripSynchronizeNewHTTPDestination() async throws {
            guard #available(macOS 14, iOS 17, tvOS 17, *) else { return }
            let original = HandleTests.jpeg(TIFFSerializer.encode(HandleTests.metadata()))
            for status: Int? in [nil, 405] {
                try await server(initial: nil, patchStatus: status) { url, state in
                    let destination = try await HTTPFileHandle(url: url)
                    let source = InMemoryFileHandle(data: original)
                    var metadata = try await EXIFKit.read(from: source)
                    metadata.ifd0.set(tagID: Tag.artist, value: .ascii("Remote writer"))
                    try await EXIFKit.write(metadata, from: source, to: destination)
                    let bytes = try #require(await state.data)
                    #expect(try await EXIFKit.read(from: bytes).artist == "Remote writer")
                    try await EXIFKit.strip(from: source, to: destination)
                    let stripped = try #require(await state.data)
                    await #expect(throws: EXIFError.self) { try await EXIFKit.read(from: stripped) }
                }
            }
        }

        @Test func resizingAndConcurrentWritesAreSerialized() async throws {
            guard #available(macOS 14, iOS 17, tvOS 17, *) else { return }
            try await server(initial: Data([0, 1, 2, 3, 4, 5])) { url, state in
                let handle = try await HTTPFileHandle(url: url)
                try await handle.truncate(to: 3)
                try await handle.synchronize()
                #expect(await state.data == Data([0, 1, 2]))
                try await handle.truncate(to: 0)
                try await handle.synchronize()
                #expect(await state.data == Data())
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for offset in 0 ..< 100 {
                        group.addTask { try await handle.write(Data([UInt8(offset)]), at: UInt64(offset)) }
                    }
                    try await group.waitForAll()
                }
                try await handle.synchronize()
                #expect(await state.data == Data((0 ..< 100).map(UInt8.init)))
            }
        }

        @Test func HTTPFailureIsPreservedAndDoesNotTriggerPUT() async throws {
            guard #available(macOS 14, iOS 17, tvOS 17, *) else { return }
            try await server(initial: Data([0, 1, 2]), patchStatus: 403) { url, state in
                let handle = try await HTTPFileHandle(url: url)
                try await handle.write(Data([9]), at: 0)
                do {
                    try await handle.synchronize()
                    Issue.record("Expected a rejected write")
                } catch let error as URLError {
                    #expect(error.code == .badServerResponse)
                    #expect((error.userInfo["HTTPURLResponse"] as? HTTPURLResponse)?.statusCode == 403)
                }
                #expect(await state.writes.map(\.method) == ["PATCH"])
                #expect(await state.data == Data([0, 1, 2]))
            }
        }
    }
#endif
#if canImport(Hummingbird)
    extension WritableHTTPHandleTests {
        @Test func newEmptyResourceAndEmptyWrites() async throws {
            guard #available(macOS 14, iOS 17, tvOS 17, *) else { return }
            try await server(initial: nil) { url, state in
                let handle = try await HTTPFileHandle(url: url)
                try await handle.write(Data(), at: 1000)
                #expect(try await handle.size == 0)
                try await handle.synchronize()
                #expect(await state.data == Data())
                #expect(await state.writes.first?.range == "bytes */0")
            }
            let memory = InMemoryFileHandle(data: Data([1, 2]))
            try await memory.write(Data(), at: UInt64.max)
            #expect(await memory.data == Data([1, 2]))
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let file = try LocalFileHandle(url: fileURL, createIfNeeded: true)
            try await file.write(Data(), at: UInt64.max)
            #expect(try await file.size == 0)
        }

        @Test func writableHTTPReadingFetchesOnlyMetadataAndCancelledWritesDoNothing() async throws {
            guard #available(macOS 14, iOS 17, tvOS 17, *) else { return }
            let bytes = HandleTests.jpeg(TIFFSerializer.encode(HandleTests.metadata())) + Data(count: 2 * 1024 * 1024)
            try await server(initial: bytes) { url, state in
                let handle = try await HTTPFileHandle(url: url)
                #expect(try await EXIFKit.read(from: handle).iso == 640)
                #expect(await state.downloaded <= 65537)
                let task = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    try await handle.write(Data([9]), at: 0)
                }
                await #expect(throws: CancellationError.self) { try await task.value }
                try await handle.synchronize()
                #expect(await state.writes.isEmpty)
                #expect(await state.data == bytes)
            }
        }
    }
#endif
