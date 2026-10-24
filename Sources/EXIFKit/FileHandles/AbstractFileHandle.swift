import Foundation

/// A random-access byte handle. Offsets are absolute and reads return exactly `count` bytes.
/// Implementations must support concurrent calls without sharing an unsynchronised cursor.
/// Keep the handle unchanged while an extraction or a lazy thumbnail read is in progress.
public protocol AbstractFileHandle: AnyObject, Sendable {
    var size: UInt64 { get async throws }
    func read(at offset: UInt64, count: Int) async throws -> Data
    func write(_ data: Data, at offset: UInt64) async throws
    func truncate(to size: UInt64) async throws
    /// Finish pending writes. EXIFKit calls this after producing the complete destination.
    func synchronize() async throws
}

public extension AbstractFileHandle {
    func synchronize() async throws {
        ()
    }
}

/// Violations of the handle read contract, independent of any backend API.
public enum FileAccessError: Error, Sendable {
    case invalidRange(offset: UInt64, count: Int, size: UInt64)
    case shortRead(expected: Int, actual: Int)
}

func validateRange(_ offset: UInt64, _ count: Int, size: UInt64) throws {
    guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
        throw FileAccessError.invalidRange(offset: offset, count: count, size: size)
    }
}
