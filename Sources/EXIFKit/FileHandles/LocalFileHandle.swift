import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

struct LocalFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

protocol LocalFileIdentifying: Sendable {
    var identity: LocalFileIdentity { get }
}

/// A local read-only source. Its type exposes no mutation operations.
public final class LocalFileHandle: AbstractFileHandle, LocalFileIdentifying, Sendable {
    private let storage: LocalFileStorage
    let identity: LocalFileIdentity

    public init(url: URL) throws {
        storage = try LocalFileStorage(url: url, writable: false, createIfNeeded: false)
        identity = storage.identity
    }

    public var size: UInt64 {
        get async throws { try await storage.size }
    }

    public func read(at offset: UInt64, count: Int) async throws -> Data {
        try await storage.read(at: offset, count: count)
    }

    public func close() async throws {
        try await storage.close()
    }
}

/// A local read/write destination. Creation does not truncate an existing file.
public final class WritableLocalFileHandle: WritableFileHandle, LocalFileIdentifying, Sendable {
    private let storage: LocalFileStorage
    let identity: LocalFileIdentity

    public init(url: URL, createIfNeeded: Bool = true) throws {
        storage = try LocalFileStorage(url: url, writable: true, createIfNeeded: createIfNeeded)
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

    public func close() async throws {
        try await storage.close()
    }
}

/// Keeps each seek and I/O operation in the same actor turn, so concurrent reads cannot move its cursor.
private actor LocalFileStorage {
    private let file: FileHandle
    nonisolated let identity: LocalFileIdentity

    init(url: URL, writable: Bool, createIfNeeded: Bool) throws {
        guard url.isFileURL else { throw URLError(.unsupportedURL) }
        if writable, createIfNeeded {
            let descriptor = try url.withUnsafeFileSystemRepresentation { path in
                guard let path else { throw CocoaError(.fileWriteInvalidFileName) }
                let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o666))
                guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                return descriptor
            }
            file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } else {
            file = try writable ? FileHandle(forUpdating: url) : FileHandle(forReadingFrom: url)
        }
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        identity = LocalFileIdentity(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino))
    }

    var size: UInt64 {
        get throws {
            try Task.checkCancellation()
            return try file.seekToEnd()
        }
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        try Task.checkCancellation()
        try validateRange(offset, count, size: file.seekToEnd())
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
        if data.isEmpty {
            return
        }
        try file.seek(toOffset: offset)
        try file.write(contentsOf: data)
    }

    func truncate(to size: UInt64) throws {
        try Task.checkCancellation()
        try file.truncate(atOffset: size)
    }

    func synchronize() throws {
        try file.synchronize()
    }

    func close() throws {
        try file.close()
    }
}
