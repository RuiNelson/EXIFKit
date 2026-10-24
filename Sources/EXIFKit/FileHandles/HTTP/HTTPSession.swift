import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// One URLSession per handle, so its requests reuse open connections instead of repeating TCP and TLS setup.
final class HTTPSession: Sendable {
    let session: URLSession
    /// Session callbacks are routed to the delegate registered for each task.
    let router = HTTPTaskRouter()

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: router, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }
}

protocol HTTPTaskHandler: Sendable {
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    )
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data)
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?)
}

final class HTTPTaskRouter: NSObject, URLSessionDataDelegate, Sendable {
    private let handlers = HTTPLockedState<[Int: any HTTPTaskHandler]>([:])

    /// Register before resuming the task so no callback is missed.
    func register(_ handler: any HTTPTaskHandler, for task: URLSessionTask) {
        handlers.withLock { $0[task.taskIdentifier] = handler }
    }

    private func handler(_ task: URLSessionTask) -> (any HTTPTaskHandler)? {
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

/// NSLock supports the package's minimum Apple versions. Access to state is serialized
/// between URLSession callbacks and task cancellation.
final class HTTPLockedState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
