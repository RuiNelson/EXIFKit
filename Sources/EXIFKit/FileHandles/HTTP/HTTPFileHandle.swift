import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// An HTTP(S) random-access handle. Reads use validated ranges. Changes are staged on disk and
/// sent by `synchronize()` with offset PATCH requests, falling back to a streamed PUT.
public actor HTTPFileHandle: AbstractFileHandle {
    private let url: URL
    private let stagingURL: URL
    private let staging: LocalFileHandle
    private let operations = HTTPFileOperations()
    private var length: UInt64
    private var validator: HTTPValidator?
    private var resourceExists: Bool
    private var loaded: [Range<UInt64>] = []
    private var dirty: [Range<UInt64>] = []
    private var resized = false
    private var usePUT = false

    public init(url: URL) async throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
        self.url = url
        do {
            let response = try await HTTPRangeRequest.fetch(url: url, offset: 0, count: 1, size: nil, validator: nil)
            length = response.size
            validator = response.validator
            resourceExists = true
        } catch let error as URLError
            where (error.userInfo["HTTPURLResponse"] as? HTTPURLResponse)?.statusCode == 404
        {
            length = 0
            validator = nil
            resourceExists = false
        }
        stagingURL = FileManager.default.temporaryDirectory.appendingPathComponent("EXIFKit-\(UUID().uuidString)")
        staging = try LocalFileHandle(url: stagingURL, createIfNeeded: true)
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
        guard resourceExists else {
            throw FileAccessError.shortRead(expected: Int(clamping: range.upperBound - range.lowerBound), actual: 0)
        }
        var position = range.lowerBound
        while position < range.upperBound {
            try Task.checkCancellation()
            let count = Int(min(65536, range.upperBound - position))
            let response = try await HTTPRangeRequest.fetch(
                url: url, offset: position, count: count, size: length, validator: validator
            )
            try await staging.write(response.data, at: position)
            position += UInt64(count)
        }
    }

    private func synchronizeIsolated() async throws {
        guard !dirty.isEmpty || resized || !resourceExists else { return }
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
            try await accept(await upload(method: "PUT", range: 0 ..< length))
        }
        dirty = []
        resized = false
    }

    private func accept(_ response: HTTPURLResponse) async throws {
        guard (200 ..< 300).contains(response.statusCode) else {
            throw invalidHTTPResponse(response, "HTTP write returned \(response.statusCode)")
        }
        resourceExists = true
        if let updatedValidator = HTTPValidator(response) {
            validator = updatedValidator
        } else {
            let response = try await HTTPRangeRequest.fetch(url: url, offset: 0, count: 1, size: nil, validator: nil)
            guard response.size == length else {
                throw invalidHTTPResponse(response.response, "Server did not apply the requested length")
            }
            validator = response.validator
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
            bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("EXIFKit-upload-\(UUID().uuidString)")
            temporary = true
        }
        defer {
            if temporary {
                try? FileManager.default.removeItem(at: bodyURL)
            }
        }
        if temporary {
            let body = try LocalFileHandle(url: bodyURL, createIfNeeded: true)
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
            let contentRange = range.isEmpty ? "bytes */\(length)" : "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(length)"
            request.setValue(contentRange, forHTTPHeaderField: "Content-Range")
        }
        if let validator {
            request.setValue(validator.value, forHTTPHeaderField: validator.header == "ETag" ? "If-Match" : "If-Unmodified-Since")
        } else if !resourceExists {
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

/// Serializes complete async operations, including suspension points.
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

struct HTTPValidator: Sendable, Equatable {
    let header: String
    let value: String
    init?(_ response: HTTPURLResponse) {
        if let etag = response.value(forHTTPHeaderField: "ETag"), !etag.hasPrefix("W/") {
            header = "ETag"
            value = etag
        } else if let date = response.value(forHTTPHeaderField: "Last-Modified") {
            header = "Last-Modified"
            value = date
        } else {
            return nil
        }
    }
}

struct HTTPRangeResponse: Sendable {
    let data: Data
    let size: UInt64
    let validator: HTTPValidator?
    let response: URLResponse
}

func invalidHTTPResponse(_ response: URLResponse, _ detail: String) -> URLError {
    var info: [String: Any] = [NSLocalizedDescriptionKey: detail, "HTTPURLResponse": response]
    if let url = response.url {
        info[NSURLErrorFailingURLErrorKey] = url
    }
    return URLError(.badServerResponse, userInfo: info)
}

func validateHTTPRange(_ response: URLResponse, offset: UInt64, count: Int, size: UInt64?, validator: HTTPValidator?) throws -> UInt64 {
    guard let http = response as? HTTPURLResponse else { throw invalidHTTPResponse(response, "Expected HTTP response") }
    if http.statusCode == 416, size == nil, http.value(forHTTPHeaderField: "Content-Range") == "bytes */0" {
        return 0
    }
    guard http.statusCode == 206 else { throw invalidHTTPResponse(http, "Expected HTTP 206, received \(http.statusCode)") }
    guard http.value(forHTTPHeaderField: "Content-Encoding").map({ $0 == "identity" }) ?? true else {
        throw invalidHTTPResponse(http, "Encoded byte range")
    }
    let field = http.value(forHTTPHeaderField: "Content-Range") ?? ""
    let fields = field.split(separator: " ")
    let bounds = fields.last?.split(separator: "/") ?? []
    let endpoints = bounds.first?.split(separator: "-") ?? []
    guard fields.count == 2, fields[0] == "bytes", bounds.count == 2, endpoints.count == 2,
          let start = UInt64(endpoints[0]), let end = UInt64(endpoints[1]), let total = UInt64(bounds[1]),
          start == offset, end == offset + UInt64(count) - 1, end < total
    else { throw invalidHTTPResponse(http, "Invalid Content-Range: \(field)") }
    if let size, total != size {
        throw invalidHTTPResponse(http, "Resource size changed")
    }
    if let validator, http.value(forHTTPHeaderField: validator.header) != validator.value {
        throw invalidHTTPResponse(http, "Resource validator changed")
    }
    return total
}

func httpRangeURLRequest(url: URL, offset: UInt64, count: Int, validator: HTTPValidator?) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue("bytes=\(offset)-\(offset + UInt64(count) - 1)", forHTTPHeaderField: "Range")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    if let validator {
        request.setValue(validator.value, forHTTPHeaderField: validator.header == "ETag" ? "If-Match" : "If-Unmodified-Since")
    }
    return request
}

#if !canImport(FoundationNetworking)
    enum HTTPRangeRequest {
        static func fetch(url: URL, offset: UInt64, count: Int, size: UInt64?, validator: HTTPValidator?) async throws -> HTTPRangeResponse {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let request = httpRangeURLRequest(url: url, offset: offset, count: count, validator: validator)
            let (stream, response) = try await session.bytes(for: request)
            defer { stream.task.cancel() }
            let length = try validateHTTPRange(response, offset: offset, count: count, size: size, validator: validator)
            if length == 0 {
                return HTTPRangeResponse(data: Data(), size: 0, validator: (response as? HTTPURLResponse).flatMap(HTTPValidator.init), response: response)
            }
            var bytes = Data()
            bytes.reserveCapacity(count)
            for try await byte in stream {
                guard bytes.count < count else { throw invalidHTTPResponse(response, "Range body exceeds requested length") }
                bytes.append(byte)
            }
            guard bytes.count == count else { throw FileAccessError.shortRead(expected: count, actual: bytes.count) }
            return HTTPRangeResponse(data: bytes, size: length, validator: (response as? HTTPURLResponse).flatMap(HTTPValidator.init), response: response)
        }
    }
#endif
