#if canImport(FoundationNetworking)
    import Foundation
    import FoundationNetworking
    import Synchronization

    /// FoundationNetworking has no AsyncBytes API. The delegate bridge keeps all mutable state in
    /// a checked Sendable Mutex; it validates headers before allowing a bounded response body.
    final class HTTPRangeRequest: NSObject, URLSessionDataDelegate, Sendable {
        private struct State {
            var continuation: CheckedContinuation<HTTPRangeResponse, any Error>?
            var bytes = Data()
            var response: URLResponse?
            var responseSize: UInt64 = 0
            var failure: (any Error)?
            var task: URLSessionDataTask?
            var cancelled = false
        }

        private let state = Mutex(State())
        private let offset: UInt64
        private let count: Int
        private let expectedSize: UInt64?
        private let validator: HTTPValidator?

        private init(offset: UInt64, count: Int, size: UInt64?, validator: HTTPValidator?) {
            self.offset = offset
            self.count = count
            expectedSize = size
            self.validator = validator
        }

        static func fetch(url: URL, offset: UInt64, count: Int, size: UInt64?, validator: HTTPValidator?) async throws
            -> HTTPRangeResponse
        {
            let delegate = HTTPRangeRequest(offset: offset, count: count, size: size, validator: validator)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let config = URLSessionConfiguration.ephemeral
                    config.urlCache = nil
                    config.requestCachePolicy = .reloadIgnoringLocalCacheData
                    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                    let request = httpRangeURLRequest(url: url, offset: offset, count: count, validator: validator)
                    let task = session.dataTask(with: request)
                    delegate.state.withLock { state in
                        state.continuation = continuation
                        state.task = task
                        task.resume()
                        if state.cancelled {
                            task.cancel()
                        }
                    }
                    session.finishTasksAndInvalidate()
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
            do {
                let length = try validateHTTPRange(
                    response, offset: offset, count: count, size: expectedSize, validator: validator
                )
                state.withLock { state in
                    state.response = response
                    state.responseSize = length
                }
                completionHandler(.allow)
            } catch {
                state.withLock { $0.failure = error }
                completionHandler(.cancel)
            }
        }

        func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let cancel = state.withLock { state in
                guard data.count <= count - state.bytes.count else {
                    if let response = state.response {
                        state.failure = invalidHTTPResponse(response, "Range body exceeds requested length")
                    }
                    return true
                }
                state.bytes.append(data)
                return false
            }
            if cancel {
                dataTask.cancel()
            }
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
            state.withLock { state in
                defer {
                    state.continuation = nil
                    state.task = nil
                }
                if let failure = state.failure {
                    state.continuation?.resume(throwing: failure)
                } else if let error {
                    state.continuation?.resume(throwing: error)
                } else if state.responseSize != 0, state.bytes.count != count {
                    state.continuation?.resume(
                        throwing: FileAccessError.shortRead(expected: count, actual: state.bytes.count)
                    )
                } else {
                    let validator = (state.response as? HTTPURLResponse).flatMap(HTTPValidator.init)
                    state.continuation?.resume(
                        returning: HTTPRangeResponse(data: state.bytes, size: state.responseSize, validator: validator)
                    )
                }
            }
        }
    }
#endif
