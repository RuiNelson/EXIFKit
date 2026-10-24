# EXIFKit

A Swift library for reading, writing and removing EXIF metadata through random-access file handles. Read metadata from memory, local files, HTTP servers or your own storage backend without loading the image into memory. The library has no external runtime dependencies.

Supports JPEG, PNG, TIFF, DNG, CR2, CR3, NEF, ARW, RAF, ORF, RW2, PEF and HEIF/HEIC/AVIF and JPEG XL. Requires Swift 6.3+, macOS 12+, iOS/tvOS 15+ or watchOS 8+.

## Installation

Add this repository as a Swift Package dependency and link the `EXIFKit` product:

```swift
.package(url: "https://github.com/RuiNelson/EXIFKit.git", branch: "abstract-file")
```

## Reading

```swift
import EXIFKit

let source = try LocalFileHandle(url: imageURL)
var metadata = try await EXIFKit.read(from: source)

print(metadata.make)
print(metadata.model)
print(metadata.iso)
print(metadata.dateTimeOriginal)
print(metadata.latitude, metadata.longitude)

// The thumbnail is fetched only when requested.
let thumbnail = try await metadata.readThumbnail()
```

All sources use the same parser. Format detection inspects contents; pass `format: .nef`, for example, to specify a format explicitly.

```swift
let memory = InMemoryFileHandle(data: imageData)
let fromMemory = try await EXIFKit.read(from: memory)

let remote = try await HTTPFileHandle(url: remoteURL)
let fromHTTP = try await EXIFKit.read(from: remote)

// Convenience overloads select a memory, local or HTTP handle.
let fromData = try await EXIFKit.read(from: imageData)
let fromURL = try await EXIFKit.read(from: imageURL)
```

The parser follows metadata offsets and skips image payloads. To keep remote round trips few, it reads aligned 64 KiB blocks, fetches each contiguous run of missing blocks in one handle read, and reads independent directories and values concurrently. A typical JPEG, HEIF, JXL or RAW extraction takes one to four handle reads. Set `readAheadBytes` to 0 to read exact ranges instead, which transfers the least data but needs more reads. The block cache is dropped once the extraction returns. Results retain the source handle for deferred thumbnail reads; keep that source unchanged while using them.

`HTTPFileHandle` discovers the file size with a one-byte range request and uses HTTP `Range` for subsequent reads. All requests of a handle share one `URLSession`, so they reuse its connections instead of repeating TCP and TLS setup. It validates `206`, `Content-Range`, body length and resource size. Servers returning the whole file are rejected before their body is buffered. Strong ETags or Last-Modified headers, when provided, are checked on later requests; without validators, a same-sized remote replacement cannot be detected. Writes are staged on disk and sent by `synchronize()`.

Metadata reads (read-ahead included) and decoded values are each limited to 32 MiB per extraction, individual values to 10 MiB, and underlying read operations to 4096. Read-ahead falls back to exact reads rather than exceed these limits. The limits and the block size are configurable:

```swift
let options = ReadOptions(
    maximumMetadataBytes: 64 * 1024 * 1024,
    maximumReadOperations: 8192,
    readAheadBytes: 256 * 1024
)
let metadata = try await EXIFKit.read(from: source, options: options)
```

## Writing and removing metadata

Write to a separate destination implementing `AbstractFileHandle`. Unchanged data is copied in blocks of at most 1 MiB, reading the next block while the current one is written; only metadata is assembled in memory. Writing from HTTP therefore transfers the image data needed to produce the output file.

```swift
var metadata = try await EXIFKit.read(from: source)
metadata.setGPSCoordinates(latitude: 38.7223, longitude: -9.1393)
metadata.ifd0.set(tagID: Tag.artist, value: .ascii("Photographer"))
try metadata.setThumbnail(thumbnailJPEG) // or nil to remove it

let destination = try LocalFileHandle(url: outputURL, createIfNeeded: true)
try await EXIFKit.write(metadata, from: source, to: destination)

let clean = try LocalFileHandle(url: cleanURL, createIfNeeded: true)
try await EXIFKit.strip(from: source, to: clean)
```

`LocalFileHandle(url:createIfNeeded: true)` creates a missing file without truncating an existing one; by default the file must exist. Each write/strip validates its edit plan before truncating the destination. Source and destination must refer to different underlying storage; identical handles and local files sharing an inode are rejected. Custom wrappers must also respect this requirement. An I/O failure or cancellation can leave a partial destination. To replace an existing file, write to a temporary file and rename it after success.

In-memory convenience overloads use the same streaming writer:

```swift
let editedData = try await EXIFKit.write(metadata, to: imageData)
let cleanData = try await EXIFKit.strip(from: imageData)
let report = EXIFKit.dump(metadata)
```

### HTTP destinations

```swift
let destination = try await HTTPFileHandle(url: outputURL)
try await EXIFKit.write(metadata, from: source, to: destination)
```

`HTTPFileHandle` stages changes in a sparse temporary file, and downloads untouched ranges only when needed. `synchronize()` sends dirty ranges with PATCH. `EXIFKit.write` and `strip` call it automatically; when using `write` or `truncate` directly, call it after completing your edits. Unsynchronised changes are discarded when the handle is released.

The server's PATCH contract is `Content-Type: application/octet-stream` with `Content-Range: bytes start-end/length`. It must apply the body at that offset and set the resource to the declared length. An empty PATCH with `Content-Range: bytes */length` resizes it. HTTP 405, 415 or 501 selects a streamed PUT fallback of the complete resource; other HTTP failures are returned to the caller. A fallback preserves untouched bytes by fetching missing ranges first. Later synchronisations reuse PUT when PATCH was rejected. Uploads and response handling have bounded memory use.

Format constraints:

- JPEG EXIF must fit in a single APP1 segment. PNG stores it in an `eXIf` chunk.
- TIFF and TIFF-based RAW preserve image offsets and reuse unchanged out-of-line values, including MakerNotes. Their byte order cannot be changed during an edit, and writing requires 32-bit file offsets. `strip` removes and zeros the referenced EXIF/GPS/interoperability directories; IFD0, thumbnails and image layout tags are retained.
- HEIF uses declared Exif items and their `iloc` extents, including fragmented items and `idat` storage. Larger replacements are appended in a new `mdat`, updating the index and clearing the previous item. There is no brute-force scan through image data for unindexed EXIF, and creating a missing Exif item is unsupported.
- JPEG XL uses the container's top-level `Exif` box, which is replaced at any size (boxes hold no absolute offsets); a missing box is inserted after `ftyp`. Brotli-compressed (`brob`) Exif boxes cannot be read but are replaced or removed on write. Bare codestreams have no metadata container and are rejected. `strip` removes the box.
- CR3 metadata must fit in its existing CMT boxes. Image offsets are preserved; adding missing CMT boxes is unsupported. `strip` replaces CMT1–CMT4 with empty TIFF metadata.
- RAF edits preserve the embedded JPEG and update following CFA offsets when it grows.
- `setThumbnail` stores a JPEG thumbnail in IFD1, creating it if needed. In TIFF-based files the new thumbnail is appended and the previous one zeroed; an existing IFD1 must already be a JPEG thumbnail (as in CR2 and ARW), otherwise IFD1 is added after a lone IFD0 (as in NEF and DNG). Removal is limited to TIFF and DNG, since RAW readers may locate later IFDs by position. CR3 rejects the write.

Removal affects the metadata structures supported by this library; it does not remove unrelated XMP/IPTC or guarantee erasure of historical, unreferenced data left by earlier editors. MakerNotes are opaque bytes, with no vendor-specific decoding or relocation of their internal offsets.

## Custom storage

Implement the public protocol in [AbstractFileHandle.swift](Sources/EXIFKit/FileHandles/AbstractFileHandle.swift):

```swift
public protocol AbstractFileHandle: AnyObject, Sendable {
    var size: UInt64 { get async throws }
    func read(at offset: UInt64, count: Int) async throws -> Data
    func write(_ data: Data, at offset: UInt64) async throws
    func truncate(to size: UInt64) async throws
    func synchronize() async throws
}
```

Offsets are absolute and reads must return exactly the requested number of bytes, or throw. Zero-byte reads at EOF succeed. Implementations must handle concurrent calls without sharing an unsynchronised cursor and should propagate cancellation. Read-only backends throw from `write` and `truncate`. Writes may extend the file; truncation sets its exact length. `synchronize()` finishes pending writes and has a default no-op implementation for backends with immediately visible writes.

| Storage | Handle |
|---------|--------|
| Memory | `InMemoryFileHandle` |
| Local files | `LocalFileHandle` |
| HTTP | `HTTPFileHandle` |

Mutable memory and local I/O are actor-isolated; HTTP serialises complete operations across suspension points. `InMemoryFileHandle.data` is an asynchronous snapshot.

Native filesystem, URLSession and consumer backend errors propagate unchanged. `FileAccessError` only describes invalid ranges and incomplete reads. EXIF parsing errors and metadata resource limits use `EXIFError`. HTTP response validation uses `URLError.badServerResponse`, preserving the `HTTPURLResponse` in the error's `userInfo["HTTPURLResponse"]`.

## Migration and tests

Reading, writing, stripping and TIFF serialization are now `async throws`, including overloads taking `Data`. Replace eager `thumbnailData` access with `try await metadata.readThumbnail()` (or `try await metadata.thumbnailData`). Parsed metadata no longer retains a complete TIFF buffer. Low-level ISOBMFF parsing returns a box index rather than copied payloads.

Run `swift test`. Tests use [Hummingbird](https://github.com/hummingbird-project/hummingbird) to start real HTTP servers on temporary local ports (macOS 14+/iOS 17+). Hummingbird is a test-target dependency. Range requests, remote errors, streaming output and sparse multi-gigabyte files are tested without allocating those files in memory. The Nikon D90 JPEG is checked against saved `exiv2` results (the tests do not run exiv2); see [the test guide](Tests/README.md).

## License

MIT. See [LICENSE](LICENSE).
