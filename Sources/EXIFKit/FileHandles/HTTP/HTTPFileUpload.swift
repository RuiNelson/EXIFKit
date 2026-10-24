import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Streams from a file and stops at response headers without retaining the response body.
/// Errors produced by URLSession pass through unchanged.
enum HTTPFileUpload {
    static func send(_ request: URLRequest, fromFile url: URL, session: HTTPSession) async throws -> HTTPURLResponse {
        try await HTTPUploadRequest.send(request, fromFile: url, session: session)
    }
}

private final class HTTPUploadRequest: HTTPTaskHandler {
    private struct State {
        var continuation: CheckedContinuation<HTTPURLResponse, any Error>?
        var task: URLSessionUploadTask?
        var cancelled = false
    }

    private let state = HTTPLockedState(State())

    static func send(_ request: URLRequest, fromFile file: URL, session: HTTPSession) async throws -> HTTPURLResponse {
        let delegate = HTTPUploadRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.session.uploadTask(with: request, fromFile: file)
                session.router.register(delegate, for: task)
                delegate.state.withLock { state in
                    state.continuation = continuation
                    state.task = task
                    task.resume()
                    if state.cancelled {
                        task.cancel()
                    }
                }
            }
        } onCancel: {
            delegate.state.withLock { state in
                state.cancelled = true
                state.task?.cancel()
            }
        }
    }

    func urlSession(
        _: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        state.withLock { state in
            if let http = response as? HTTPURLResponse {
                state.continuation?.resume(returning: http)
            } else {
                state.continuation?.resume(throwing: invalidHTTPResponse(response, "Expected HTTP response"))
            }
            state.continuation = nil
        }
        completionHandler(.cancel)
    }

    /// The response is cancelled at headers; its body is never retained.
    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive _: Data) {}

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        state.withLock { state in
            defer {
                state.continuation = nil
                state.task = nil
            }
            if let error {
                state.continuation?.resume(throwing: error)
            } else {
                state.continuation?.resume(throwing: URLError(.badServerResponse))
            }
        }
    }
}
