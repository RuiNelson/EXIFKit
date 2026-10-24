import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// An HTTP(S) read-only source. Validates byte ranges before consuming response bodies.
public final class HTTPFileHandle: AbstractFileHandle, Sendable {
    let url: URL
    let length: UInt64
    let validator: HTTPValidator?
    public var size: UInt64 {
        get async throws { length }
    }

    public init(url: URL) async throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
        self.url = url
        let response = try await HTTPRangeRequest.fetch(url: url, offset: 0, count: 1, size: nil, validator: nil)
        length = response.size
        validator = response.validator
    }

    init(url: URL, length: UInt64, validator: HTTPValidator?) {
        self.url = url
        self.length = length
        self.validator = validator
    }

    public func read(at offset: UInt64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        try validateRange(offset, count, size: length)
        if count == 0 {
            return Data()
        }
        return try await HTTPRangeRequest.fetch(
            url: url, offset: offset, count: count, size: length, validator: validator
        ).data
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
}

func invalidHTTPResponse(_ response: URLResponse, _ detail: String) -> URLError {
    var info: [String: Any] = [NSLocalizedDescriptionKey: detail, "HTTPURLResponse": response]
    if let url = response.url {
        info[NSURLErrorFailingURLErrorKey] = url
    }
    return URLError(.badServerResponse, userInfo: info)
}

/// Transport errors are never caught or replaced. Only responses that violate the range contract
/// produce a new validation error; the complete response is kept in its userInfo.
func validateHTTPRange(
    _ response: URLResponse, offset: UInt64, count: Int,
    size: UInt64?, validator: HTTPValidator?
) throws -> UInt64 {
    guard let http = response as? HTTPURLResponse else { throw invalidHTTPResponse(response, "Expected HTTP response") }
    if http.statusCode == 416, size == nil, http.value(forHTTPHeaderField: "Content-Range") == "bytes */0" {
        return 0
    }
    guard http.statusCode == 206 else {
        throw invalidHTTPResponse(http, "Expected HTTP 206, received \(http.statusCode)")
    }
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
    else {
        throw invalidHTTPResponse(http, "Invalid Content-Range: \(field)")
    }
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
        request.setValue(
            validator.value, forHTTPHeaderField: validator.header == "ETag" ? "If-Match" : "If-Unmodified-Since"
        )
    }
    return request
}

#if !canImport(FoundationNetworking)
    enum HTTPRangeRequest {
        static func fetch(url: URL, offset: UInt64, count: Int, size: UInt64?, validator: HTTPValidator?) async throws
            -> HTTPRangeResponse
        {
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
                return HTTPRangeResponse(
                    data: Data(), size: 0, validator: (response as? HTTPURLResponse).flatMap(HTTPValidator.init)
                )
            }
            var bytes = Data()
            bytes.reserveCapacity(count)
            for try await byte in stream {
                guard bytes.count < count else {
                    throw invalidHTTPResponse(response, "Range body exceeds requested length")
                }
                bytes.append(byte)
            }
            guard bytes.count == count else { throw FileAccessError.shortRead(expected: count, actual: bytes.count) }
            return HTTPRangeResponse(
                data: bytes, size: length, validator: (response as? HTTPURLResponse).flatMap(HTTPValidator.init)
            )
        }
    }
#endif
