import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
    import Synchronization
#endif

/// One URLSession per handle, so its requests reuse open connections instead of repeating TCP and TLS setup.
final class HTTPSession: Sendable {
    let session: URLSession
    #if canImport(FoundationNetworking)
        /// FoundationNetworking has no per-task delegates; session callbacks are routed by task.
        let router = HTTPTaskRouter()
    #endif

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        #if canImport(FoundationNetworking)
            session = URLSession(configuration: config, delegate: router, delegateQueue: nil)
        #else
            session = URLSession(configuration: config)
        #endif
    }

    deinit { session.invalidateAndCancel() }
}

#if canImport(FoundationNetworking)
    final class HTTPTaskRouter: NSObject, URLSessionDataDelegate, Sendable {
        private let handlers = Mutex<[Int: any URLSessionDataDelegate & Sendable]>([:])

        /// Register before resuming the task so no callback is missed.
        func register(_ handler: any URLSessionDataDelegate & Sendable, for task: URLSessionTask) {
            handlers.withLock { $0[task.taskIdentifier] = handler }
        }

        private func handler(_ task: URLSessionTask) -> (any URLSessionDataDelegate & Sendable)? {
            handlers.withLock { $0[task.taskIdentifier] }
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            guard let handler = handler(dataTask) else { return completionHandler(.cancel) }
            handler.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            handler(dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let handler = handlers.withLock { $0.removeValue(forKey: task.taskIdentifier) }
            handler?.urlSession(session, task: task, didCompleteWithError: error)
        }
    }
#endif
