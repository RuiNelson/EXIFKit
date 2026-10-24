import Foundation

/// Random-access byte storage that EXIFKit reads images from and writes edited images to.
///
/// EXIFKit never loads a whole image. Its parsers follow the offsets stored inside the file and
/// ask a handle for just the byte ranges they need, typically a few kilobytes out of many
/// megabytes. Because every operation goes through this protocol, the same parser and writer
/// work with any storage that can serve byte ranges.
///
/// EXIFKit provides three handles:
///
/// | Storage     | Handle                 | Writes                                  |
/// |-------------|------------------------|-----------------------------------------|
/// | Memory      | ``InMemoryFileHandle`` | Immediate                               |
/// | Local files | ``LocalFileHandle``    | Immediate; flushed by `synchronize()`   |
/// | HTTP(S)     | ``HTTPFileHandle``     | Staged on disk; sent by `synchronize()` |
///
/// Conform your own type to read from or write to anything else, such as an object store, a
/// database blob or an encrypted container.
///
/// ## Reading
///
/// A handle has no cursor. Each ``read(at:count:)`` names an absolute offset and returns exactly
/// `count` bytes, or throws. It never returns fewer bytes, never pads, and never reads past
/// ``size``. A zero-byte read at any offset from 0 through ``size`` succeeds with empty `Data`.
///
/// EXIFKit only reads from a source. It never writes to, truncates or synchronizes one, so a
/// source can be read-only.
///
/// ## Writing
///
/// ``EXIFKit/write(_:from:to:format:options:)`` and ``EXIFKit/strip(from:to:format:options:)``
/// stream a new file into a separate destination handle. They plan and validate the whole edit
/// before calling the destination, then drive it strictly in sequence, one call at a time:
///
/// 1. `truncate(to: 0)`.
/// 2. `write(_:at:)` calls of at most 1 MiB each, at increasing offsets, with no gaps.
/// 3. `truncate(to:)` with the exact output length.
/// 4. `synchronize()`.
///
/// If any step throws or the task is cancelled, EXIFKit stops at once and does not call
/// `synchronize()`. The destination may then hold a partial file. To replace a file safely, write
/// to a temporary destination and move it into place after the call succeeds.
///
/// That sequence is how EXIFKit uses a destination, not the whole contract. Callers can use a
/// handle directly, so a writable handle must accept writes at any offset, including past the
/// end, and must let reads and ``size`` observe every completed write and truncation, even
/// before ``synchronize()``.
///
/// ## Concurrency and cancellation
///
/// EXIFKit reads independent parts of a file concurrently. For example, it fetches the EXIF and
/// GPS directories at the same time, and during an edit it reads the next block of the source
/// while writing the current one to the destination. A handle must therefore produce correct
/// results when called from several tasks at once:
///
/// - Don't share a seek position between calls. Use positional I/O such as `pread`, or seek and
///   read within one actor-isolated step that contains no suspension point.
/// - Prefer an `actor`, or a `final class` whose mutable state lives in an actor, as
///   ``LocalFileHandle`` does.
/// - When an operation spans several suspension points and must not interleave with others,
///   serialize the whole operation, as ``HTTPFileHandle`` does. Actor isolation alone doesn't
///   prevent interleaving at each `await`.
///
/// Check for cancellation before starting work and between chunks of a long transfer, and throw
/// `CancellationError` so that a cancelled extraction or edit ends promptly.
///
/// ## Performance on remote storage
///
/// When each read is a network round trip, the number of reads matters more than their size.
/// During extraction EXIFKit reads in aligned blocks of ``ReadOptions/readAheadBytes``
/// (64 KiB by default) and merges adjacent missing blocks into one read, so a typical JPEG, HEIF,
/// JPEG XL or RAW file needs one to four reads. Tune that option rather than adding read-ahead
/// inside the handle. ``ReadOptions/maximumReadOperations`` and
/// ``ReadOptions/maximumMetadataBytes`` cap the reads one extraction can make, which protects
/// against malformed files that point all over a large remote resource.
///
/// Expect requests from a few bytes to several megabytes. During an edit, which copies the whole
/// source, each read is at most 1 MiB.
///
/// ## Ownership and lifetime
///
/// The caller owns the handle and decides when to release or close it. EXIFKit never closes a
/// handle.
///
/// A `TIFFStructure` returned by a read keeps a strong reference to its source handle, so that
/// ``TIFFStructure/readThumbnail()`` can fetch the thumbnail later. Passing the structure to
/// ``EXIFKit/write(_:from:to:format:options:)`` can also read the thumbnail from that original
/// source, even when you write from a different one, so the handle stays in use after the read
/// returns. Holding the structure keeps the handle alive,
/// together with any resources it owns, such as an open file descriptor or a staging file.
///
/// - Important: Don't change a source's contents while an extraction runs or while you still use
///   structures read from it. EXIFKit doesn't re-parse the file, so a thumbnail read after a
///   change can fail or return unrelated bytes from the recorded range.
///
/// ## Identity
///
/// The protocol requires a class or actor so that EXIFKit can compare handles by identity. A
/// write or strip whose source and destination are the same object throws, because the output
/// would overwrite input that has not been read yet. ``LocalFileHandle`` also compares device and
/// inode numbers, which catches two handles opened on the same file.
///
/// - Important: EXIFKit can't detect two different handle objects that expose the same storage.
///   Never pass such a pair as the source and destination of an edit.
///
/// ## Errors
///
/// Throw your backend's own errors; EXIFKit propagates them unchanged. Use ``FileAccessError``
/// only for violations of the read contract that have no backend-specific error. EXIFKit also
/// checks the length of every read it receives and throws
/// ``FileAccessError/shortRead(expected:actual:)`` when a handle returns the wrong number of bytes.
///
/// ## Conforming to the protocol
///
/// Implement ``size``, ``read(at:count:)``, ``write(_:at:)`` and ``truncate(to:)``. Implement
/// ``synchronize()`` too if your handle buffers or stages changes; the default does nothing.
///
/// The following read-only handle serves a file whose length is already known and fetches each
/// range with a closure, such as a signed request to an object store. It validates the range
/// before contacting the backend and checks the length of the response, so a misbehaving backend
/// produces a clear error rather than corrupt metadata:
///
/// ```swift
/// final class RangeFetchingHandle: AbstractFileHandle {
///     typealias Fetch = @Sendable (Range<UInt64>) async throws -> Data
///
///     private let length: UInt64
///     private let fetch: Fetch
///
///     init(length: UInt64, fetch: @escaping Fetch) {
///         self.length = length
///         self.fetch = fetch
///     }
///
///     var size: UInt64 {
///         get async throws { length }
///     }
///
///     func read(at offset: UInt64, count: Int) async throws -> Data {
///         try Task.checkCancellation()
///         guard count >= 0, offset <= length, UInt64(count) <= length - offset else {
///             throw FileAccessError.invalidRange(offset: offset, count: count, size: length)
///         }
///         guard count > 0 else { return Data() }
///         let data = try await fetch(offset ..< offset + UInt64(count))
///         guard data.count == count else {
///             throw FileAccessError.shortRead(expected: count, actual: data.count)
///         }
///         return data
///     }
///
///     func write(_: Data, at _: UInt64) async throws {
///         throw CocoaError(.fileWriteNoPermission)
///     }
///
///     func truncate(to _: UInt64) async throws {
///         throw CocoaError(.fileWriteNoPermission)
///     }
/// }
///
/// let source = RangeFetchingHandle(length: objectLength) { range in
///     try await bucket.download(key, bytes: range)
/// }
/// let metadata = try await EXIFKit.read(from: source)
/// ```
///
/// A writable handle rarely needs its own random-access storage. Delegate to an existing handle
/// and add your backend in ``synchronize()``. This destination assembles the output in a local
/// file and uploads it once EXIFKit has finished writing:
///
/// ```swift
/// final class UploadingHandle: AbstractFileHandle {
///     private let stagingURL: URL
///     private let staging: LocalFileHandle
///     private let upload: @Sendable (URL) async throws -> Void
///
///     init(stagingURL: URL, upload: @escaping @Sendable (URL) async throws -> Void) throws {
///         self.stagingURL = stagingURL
///         try Data().write(to: stagingURL)
///         staging = try LocalFileHandle(url: stagingURL)
///         self.upload = upload
///     }
///
///     var size: UInt64 {
///         get async throws { try await staging.size }
///     }
///
///     func read(at offset: UInt64, count: Int) async throws -> Data {
///         try await staging.read(at: offset, count: count)
///     }
///
///     func write(_ data: Data, at offset: UInt64) async throws {
///         try await staging.write(data, at: offset)
///     }
///
///     func truncate(to size: UInt64) async throws {
///         try await staging.truncate(to: size)
///     }
///
///     func synchronize() async throws {
///         try await staging.synchronize()
///         try await upload(stagingURL)
///     }
/// }
/// ```
///
/// ## Topics
///
/// ### Reading
///
/// - ``size``
/// - ``read(at:count:)``
///
/// ### Writing
///
/// - ``write(_:at:)``
/// - ``truncate(to:)``
/// - ``synchronize()``
///
/// ### Errors
///
/// - ``FileAccessError``
public protocol AbstractFileHandle: AnyObject, Sendable {
    /// The current length of the file, in bytes.
    ///
    /// A writable handle reports the length after every completed ``write(_:at:)`` and
    /// ``truncate(to:)``, whether or not it has synchronized them. A destination that doesn't
    /// exist yet reports 0.
    ///
    /// EXIFKit reads this property once at the start of each read, write or strip, and treats
    /// the value as fixed until that call returns. Computing it may be expensive, such as a
    /// network request, but it shouldn't change during an operation.
    ///
    /// - Throws: An error from the backend, for example when the file can't be inspected.
    var size: UInt64 { get async throws }

    /// Reads exactly `count` bytes, starting at an absolute offset.
    ///
    /// The result doesn't depend on any other call: there is no shared position to move. EXIFKit
    /// can issue several reads at once, and each must return the bytes for its own range.
    ///
    /// - Parameters:
    ///   - offset: The position of the first byte to read, counted from the start of the file.
    ///   - count: The number of bytes to read. Zero is valid at any `offset` from 0 through
    ///     ``size``.
    /// - Returns: Exactly `count` bytes. Returning fewer or more bytes violates the contract, and
    ///   EXIFKit rejects the result.
    /// - Throws: ``FileAccessError/invalidRange(offset:count:size:)`` when `count` is negative or
    ///   the range extends past ``size``. ``FileAccessError/shortRead(expected:actual:)`` when the
    ///   backend delivers fewer bytes than requested. `CancellationError` when the task is
    ///   cancelled. Otherwise, any error from the backend.
    func read(at offset: UInt64, count: Int) async throws -> Data

    /// Writes bytes at an absolute offset, overwriting existing bytes and extending the file as
    /// needed.
    ///
    /// When the write ends past ``size``, the file grows to `offset + data.count`. When `offset`
    /// itself is past the end, the bytes between the old end and `offset` read back as zeros,
    /// as with POSIX `pwrite`. Writing empty data does nothing.
    ///
    /// The handle may buffer the write until ``synchronize()``, but its own ``read(at:count:)``
    /// and ``size`` must reflect the write as soon as this method returns.
    ///
    /// A read-only handle throws an error that explains why it can't be written to.
    ///
    /// - Parameters:
    ///   - data: The bytes to write.
    ///   - offset: The position at which to write the first byte, counted from the start of the
    ///     file.
    /// - Throws: ``FileAccessError/invalidRange(offset:count:size:)`` when the resulting length
    ///   can't be represented. `CancellationError` when the task is cancelled. Otherwise, any
    ///   error from the backend, including the error that marks a handle as read-only.
    func write(_ data: Data, at offset: UInt64) async throws

    /// Sets the length of the file to exactly `size` bytes.
    ///
    /// Shrinking the file discards every byte from `size` onward. Growing it appends bytes that
    /// read back as zeros. As with ``write(_:at:)``, the handle may buffer the change until
    /// ``synchronize()``, but its own reads and ``size`` reflect it as soon as this method
    /// returns.
    ///
    /// A read-only handle throws an error that explains why it can't be written to.
    ///
    /// - Parameter size: The new length of the file, in bytes.
    /// - Throws: ``FileAccessError/invalidRange(offset:count:size:)`` when the backend can't
    ///   represent the length. `CancellationError` when the task is cancelled. Otherwise, any
    ///   error from the backend, including the error that marks a handle as read-only.
    func truncate(to size: UInt64) async throws

    /// Commits every completed write and truncation to the underlying storage.
    ///
    /// EXIFKit calls this method exactly once per successful write or strip, after the
    /// destination holds the complete output. It never calls it on a source, or after a failure.
    /// Call it yourself when you use ``write(_:at:)`` or ``truncate(to:)`` directly.
    ///
    /// What "commit" means depends on the backend. ``LocalFileHandle`` flushes the file to disk.
    /// ``HTTPFileHandle`` uploads its staged changes and discards any that are still staged when
    /// it's released. ``InMemoryFileHandle`` uses the default implementation, which does nothing.
    ///
    /// - Throws: An error from the backend. After an error, the underlying storage may hold some,
    ///   all or none of the changes, depending on the backend.
    func synchronize() async throws
}

public extension AbstractFileHandle {
    /// Does nothing, for handles whose writes reach the underlying storage as soon as they
    /// complete.
    func synchronize() async throws {
        ()
    }
}

/// A violation of the ``AbstractFileHandle`` read contract, independent of any backend.
///
/// Backend failures, such as a missing file or an unreachable server, surface as the backend's
/// own errors. This type only describes requests and results that break the contract itself, so
/// a custom handle can report them in the same way as the handles EXIFKit provides.
public enum FileAccessError: Error, Sendable {
    /// The requested range has a negative count, overflows, or extends past the end of the file.
    ///
    /// - Parameters:
    ///   - offset: The requested start offset.
    ///   - count: The requested number of bytes.
    ///   - size: The length of the file when the request was made.
    case invalidRange(offset: UInt64, count: Int, size: UInt64)

    /// A read delivered fewer bytes than it requested, for example because the file shrank or a
    /// transfer ended early.
    ///
    /// EXIFKit also throws this error when a handle's ``AbstractFileHandle/read(at:count:)``
    /// returns a different number of bytes than requested.
    ///
    /// - Parameters:
    ///   - expected: The number of bytes requested.
    ///   - actual: The number of bytes received.
    case shortRead(expected: Int, actual: Int)
}

func validateRange(_ offset: UInt64, _ count: Int, size: UInt64) throws {
    guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
        throw FileAccessError.invalidRange(offset: offset, count: count, size: size)
    }
}
