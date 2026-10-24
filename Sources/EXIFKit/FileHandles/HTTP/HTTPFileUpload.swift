import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
    import Synchronization
#endif

/// Both implementations stream from a file and stop at response headers, without retaining
/// a potentially large response body. Errors produced by URLSession pass through unchanged.
enum HTTPFileUpload {
    static func send(_ request: URLRequest, fromFile url: URL, session: HTTPSession) async throws -> HTTPURLResponse {
        #if canImport(FoundationNetworking)
            return try await HTTPUploadRequest.send(request, fromFile: url, session: session)
        #else
            var request = request
            request.httpBodyStream = InputStream(url: url)
            let (stream, response) = try await session.session.bytes(for: request, delegate: HTTPUploadBody(file: url))
            defer { stream.task.cancel() }
            guard let response = response as? HTTPURLResponse else {
                throw invalidHTTPResponse(response, "Expected HTTP response")
            }
            return response
        #endif
    }
}

#if !canImport(FoundationNetworking)
    /// Re-open the file if URLSession needs to replay the request body.
    private final class HTTPUploadBody: NSObject, URLSessionTaskDelegate, Sendable {
        let file: URL
        init(file: URL) {
            self.file = file
        }

        func urlSession(
            _: URLSession, task _: URLSessionTask,
            needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void
        ) {
            completionHandler(InputStream(url: file))
        }
    }
#else
    private final class HTTPUploadRequest: NSObject, URLSessionDataDelegate, Sendable {
        private struct State {
            var continuation: CheckedContinuation<HTTPURLResponse, any Error>?
            var task: URLSessionUploadTask?
            var cancelled = false
        }

        private let state = Mutex(State())

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
#endif
