import Foundation

/// A mutable in-memory random-access handle.
public actor InMemoryFileHandle: AbstractFileHandle {
    private var storage: Data

    /// A snapshot of the current contents.
    public var data: Data {
        storage
    }

    public var size: UInt64 {
        get async throws { UInt64(storage.count) }
    }

    public init(data: Data = Data()) {
        storage = Data(data)
    }

    public func read(at offset: UInt64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        try validateRange(offset, count, size: UInt64(storage.count))
        return storage.subdata(in: Int(offset) ..< Int(offset) + count)
    }

    public func write(_ data: Data, at offset: UInt64) async throws {
        try Task.checkCancellation()
        guard !data.isEmpty else { return }
        guard offset <= UInt64(Int.max), UInt64(data.count) <= UInt64(Int.max) - offset else {
            throw FileAccessError.invalidRange(offset: offset, count: data.count, size: UInt64(storage.count))
        }
        let end = Int(offset) + data.count
        if end > storage.count {
            storage.append(Data(count: end - storage.count))
        }
        storage.replaceSubrange(Int(offset) ..< end, with: data)
    }

    public func truncate(to size: UInt64) async throws {
        try Task.checkCancellation()
        guard size <= UInt64(Int.max) else {
            throw FileAccessError.invalidRange(offset: size, count: 0, size: UInt64(storage.count))
        }
        if Int(size) < storage.count {
            storage.removeSubrange(Int(size) ..< storage.count)
        } else if Int(size) > storage.count {
            storage.append(Data(count: Int(size) - storage.count))
        }
    }
}
