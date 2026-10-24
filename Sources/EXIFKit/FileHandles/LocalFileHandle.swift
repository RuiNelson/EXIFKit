import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Android)
    import Android
#endif

struct LocalFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

protocol LocalFileIdentifying: Sendable {
    var identity: LocalFileIdentity? { get }
}

/// A local random-access handle. It opens an existing file read-only, then closes and reopens it
/// for update only when `write` or `truncate` is first called.
public final class LocalFileHandle: AbstractFileHandle, LocalFileIdentifying, Sendable {
    private let storage: LocalFileStorage
    let identity: LocalFileIdentity?

    public init(url: URL) throws {
        storage = try LocalFileStorage(url: url)
        identity = storage.identity
    }

    public var size: UInt64 {
        get async throws { try await storage.size }
    }

    public func read(at offset: UInt64, count: Int) async throws -> Data {
        try await storage.read(at: offset, count: count)
    }

    public func write(_ data: Data, at offset: UInt64) async throws {
        try await storage.write(data, at: offset)
    }

    public func truncate(to size: UInt64) async throws {
        try await storage.truncate(to: size)
    }

    public func synchronize() async throws {
        try await storage.synchronize()
    }

    func close() async throws {
        try await storage.close()
    }
}

/// Keeps each seek and I/O operation in the same actor turn. The descriptor is upgraded lazily.
private actor LocalFileStorage {
    private let url: URL
    private var file: FileHandle?
    private var writable = false
    nonisolated let identity: LocalFileIdentity?

    init(url: URL) throws {
        guard url.isFileURL else { throw URLError(.unsupportedURL) }
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        file = handle
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        identity = LocalFileIdentity(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino))
    }

    var size: UInt64 {
        get throws {
            try Task.checkCancellation()
            guard let file else { return 0 }
            return try file.seekToEnd()
        }
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        try Task.checkCancellation()
        let size = try self.size
        try validateRange(offset, count, size: size)
        guard count > 0 else { return Data() }
        guard let file else { throw FileAccessError.shortRead(expected: count, actual: 0) }
        try file.seek(toOffset: offset)
        var bytes = Data()
        while bytes.count < count {
            try Task.checkCancellation()
            let part = try file.read(upToCount: count - bytes.count) ?? Data()
            guard !part.isEmpty else { throw FileAccessError.shortRead(expected: count, actual: bytes.count) }
            bytes.append(part)
        }
        return bytes
    }

    func write(_ data: Data, at offset: UInt64) throws {
        try Task.checkCancellation()
        guard !data.isEmpty else { return }
        let file = try openForWriting()
        try file.seek(toOffset: offset)
        try file.write(contentsOf: data)
    }

    func truncate(to size: UInt64) throws {
        try Task.checkCancellation()
        try openForWriting().truncate(atOffset: size)
    }

    func synchronize() throws {
        try file?.synchronize()
    }

    func close() throws {
        try file?.close()
        file = nil
    }

    private func openForWriting() throws -> FileHandle {
        if writable, let file {
            return file
        }
        try file?.close()
        let handle = try FileHandle(forUpdating: url)
        file = handle
        writable = true
        return handle
    }
}
