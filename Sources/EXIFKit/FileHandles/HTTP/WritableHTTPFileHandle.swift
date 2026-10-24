import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Stages random-access changes on disk and sends them on synchronize(). PATCH uses
/// Content-Range: bytes start-end/length; an empty bytes */length PATCH resizes the resource.
/// Servers rejecting PATCH with 405, 415 or 501 are retried with a complete streamed PUT.
public actor WritableHTTPFileHandle: WritableFileHandle {
    private let url: URL
    private let stagingURL: URL
    private let staging: WritableLocalFileHandle
    private let operations = HTTPFileOperations()
    private var remote: HTTPFileHandle?
    private var length: UInt64
    private var loaded: [Range<UInt64>] = []
    private var dirty: [Range<UInt64>] = []
    private var resized = false
    private var usePUT = false

    public init(url: URL) async throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
        self.url = url
        let remote: HTTPFileHandle?
        do { remote = try await HTTPFileHandle(url: url) } catch let error as URLError
            where (error.userInfo["HTTPURLResponse"] as? HTTPURLResponse)?.statusCode == 404
        {
            remote = nil // A missing destination will be created by PATCH or PUT.
        }
        self.remote = remote
        resized = remote == nil
        length = remote?.length ?? 0
        stagingURL = FileManager.default.temporaryDirectory.appendingPathComponent("EXIFKit-\(UUID().uuidString)")
        staging = try WritableLocalFileHandle(url: stagingURL)
        try await staging.truncate(to: length)
    }

    deinit { try? FileManager.default.removeItem(at: stagingURL) }

    public var size: UInt64 {
        get async throws { try await operations.run { await self.currentSize() } }
    }

    private func currentSize() -> UInt64 {
        length
    }

    public func read(at offset: UInt64, count: Int) async throws -> Data {
        try await operations.run { try await self.readIsolated(at: offset, count: count) }
    }

    public func write(_ data: Data, at offset: UInt64) async throws {
        try await operations.run { try await self.writeIsolated(data, at: offset) }
    }

    public func truncate(to size: UInt64) async throws {
        try await operations.run { try await self.truncateIsolated(to: size) }
    }

    public func synchronize() async throws {
        try await operations.run { try await self.synchronizeIsolated() }
    }

    private func readIsolated(at offset: UInt64, count: Int) async throws -> Data {
        try validateRange(offset, count, size: length)
        try await load(offset ..< offset + UInt64(count))
        return try await staging.read(at: offset, count: count)
    }

    private func writeIsolated(_ data: Data, at offset: UInt64) async throws {
        if data.isEmpty {
            return
        }
        let (end, overflow) = offset.addingReportingOverflow(UInt64(data.count))
        guard !overflow else { throw FileAccessError.invalidRange(offset: offset, count: data.count, size: length) }
        let oldLength = length
        try await staging.write(data, at: offset)
        length = max(length, end)
        let changed = min(offset, oldLength) ..< end
        loaded = merging(loaded, changed)
        dirty = merging(dirty, changed)
        if length != oldLength {
            resized = true
        }
    }

    private func truncateIsolated(to size: UInt64) async throws {
        let oldLength = length
        try await staging.truncate(to: size)
        length = size
        loaded = clipped(loaded, to: size)
        dirty = clipped(dirty, to: size)
        if size > oldLength {
            loaded = merging(loaded, oldLength ..< size)
            dirty = merging(dirty, oldLength ..< size)
        }
        if size != oldLength {
            resized = true
        }
    }

    /// Download only uncached gaps. The sparse staging file never allocates the complete resource in RAM.
    private func load(_ range: Range<UInt64>) async throws {
        var position = range.lowerBound
        for cached in loaded where cached.upperBound > position && cached.lowerBound < range.upperBound {
            if position < cached.lowerBound {
                try await loadGap(position ..< min(cached.lowerBound, range.upperBound))
            }
            position = max(position, cached.upperBound)
        }
        if position < range.upperBound {
            try await loadGap(position ..< range.upperBound)
        }
        loaded = merging(loaded, range)
    }

    private func loadGap(_ range: Range<UInt64>) async throws {
        guard let remote else {
            throw FileAccessError.shortRead(expected: Int(clamping: range.upperBound - range.lowerBound), actual: 0)
        }
        var position = range.lowerBound
        while position < range.upperBound {
            try Task.checkCancellation()
            let count = Int(min(65536, range.upperBound - position))
            let bytes = try await remote.read(at: position, count: count)
            try await staging.write(bytes, at: position)
            position += UInt64(count)
        }
    }

    private func synchronizeIsolated() async throws {
        guard !dirty.isEmpty || resized else { return }
        if !usePUT {
            let ranges = dirty.isEmpty ? [0 ..< 0] : dirty
            for range in ranges {
                let response = try await upload(method: "PATCH", range: range)
                if [405, 415, 501].contains(response.statusCode) {
                    usePUT = true
                    break
                }
                try await accept(response)
            }
        }
        if usePUT {
            try await load(0 ..< length)
            let response = try await upload(method: "PUT", range: 0 ..< length)
            try await accept(response)
        }
        dirty = []
        resized = false
    }

    private func accept(_ response: HTTPURLResponse) async throws {
        guard (200 ..< 300).contains(response.statusCode) else {
            throw invalidHTTPResponse(response, "HTTP write returned \(response.statusCode)")
        }
        if let validator = HTTPValidator(response) {
            remote = HTTPFileHandle(url: url, length: length, validator: validator)
        } else {
            remote = try await HTTPFileHandle(url: url)
            guard remote?.length == length else {
                throw invalidHTTPResponse(response, "Server did not apply the requested length")
            }
        }
    }

    private func upload(method: String, range: Range<UInt64>) async throws -> HTTPURLResponse {
        try Task.checkCancellation()
        let bodyURL: URL
        let temporary: Bool
        if range.lowerBound == 0 && range.upperBound == length {
            bodyURL = stagingURL
            temporary = false
        } else {
            bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "EXIFKit-upload-\(UUID().uuidString)"
            )
            temporary = true
        }
        defer {
            if temporary {
                try? FileManager.default.removeItem(at: bodyURL)
            }
        }
        if temporary {
            let body = try WritableLocalFileHandle(url: bodyURL)
            var position = range.lowerBound
            while position < range.upperBound {
                try Task.checkCancellation()
                let count = Int(min(65536, range.upperBound - position))
                try await body.write(staging.read(at: position, count: count), at: position - range.lowerBound)
                position += UInt64(count)
            }
            try await body.close()
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if method == "PATCH" {
            let contentRange =
                range.isEmpty ? "bytes */\(length)" : "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(length)"
            request.setValue(contentRange, forHTTPHeaderField: "Content-Range")
        }
        if let validator = remote?.validator {
            request.setValue(
                validator.value, forHTTPHeaderField: validator.header == "ETag" ? "If-Match" : "If-Unmodified-Since"
            )
        } else if remote == nil {
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        }
        request.setValue(String(range.upperBound - range.lowerBound), forHTTPHeaderField: "Content-Length")
        return try await HTTPFileUpload.send(request, fromFile: bodyURL)
    }

    private func clipped(_ ranges: [Range<UInt64>], to size: UInt64) -> [Range<UInt64>] {
        ranges.compactMap { $0.lowerBound < size ? $0.lowerBound ..< min($0.upperBound, size) : nil }
    }

    private func merging(_ ranges: [Range<UInt64>], _ added: Range<UInt64>) -> [Range<UInt64>] {
        guard !added.isEmpty else { return ranges }
        var result: [Range<UInt64>] = []
        for range in (ranges + [added]).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

/// Serializes complete async operations, including suspension points. Cancellation of a queued
/// operation is propagated before it can access the staging file or start a network request.
private actor HTTPFileOperations {
    private var tail: Task<Void, Never>?
    func run<Result: Sendable>(_ operation: @escaping @Sendable () async throws -> Result) async throws -> Result {
        let previous = tail
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task { _ = await task.result }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
