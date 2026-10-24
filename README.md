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

// Every tag, as readable text.
print(EXIFKit.dump(metadata))
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

`write` and `strip` never modify the source. Each one produces a complete new file in a separate destination: a copy of the source with the metadata replaced (`write`) or removed (`strip`).

```swift
var metadata = try await EXIFKit.read(from: source)
metadata.setGPSCoordinates(latitude: 38.7223, longitude: -9.1393)
metadata.ifd0.set(tagID: Tag.artist, value: .ascii("Photographer"))
try metadata.setThumbnail(thumbnailJPEG) // or nil to remove it

// LocalFileHandle only opens existing files, so create the destination first.
FileManager.default.createFile(atPath: outputURL.path, contents: nil)
let destination = try LocalFileHandle(url: outputURL)
try await EXIFKit.write(metadata, from: source, to: destination)

FileManager.default.createFile(atPath: cleanURL.path, contents: nil)
let clean = try LocalFileHandle(url: cleanURL)
try await EXIFKit.strip(from: source, to: clean)
```

### How the output is produced

Only the new metadata is built in memory. Everything else, including the image data, is copied from the source to the destination in blocks of at most 1 MiB, and the next block is read while the current one is written. Memory use stays small even for large files, but every byte of the source is read: writing from an HTTP source downloads the whole image.

The whole edit is planned and validated before the destination is touched. An impossible edit, such as EXIF too large for a JPEG, throws and leaves the destination unchanged. Otherwise the destination is truncated and written from the beginning.

### Replacing the original file

The destination must be a different file from the source, because the source is still being read while the destination is written. EXIFKit rejects the same handle passed twice, and two local handles that refer to the same file (same inode). It can't check custom handle types, so they must guarantee this themselves.

An I/O failure or cancellation stops the write and can leave a partial destination. To update a file in place, write to a temporary file, then rename it over the original once the call succeeds.

### In-memory data

For images already in memory, the `Data` overloads return the new file as `Data`. They run the same writer with in-memory handles:

```swift
let editedData = try await EXIFKit.write(metadata, to: imageData)
let cleanData = try await EXIFKit.strip(from: imageData)
```

### HTTP destinations

```swift
let destination = try await HTTPFileHandle(url: outputURL)
try await EXIFKit.write(metadata, from: source, to: destination)
```

An `HTTPFileHandle` doesn't upload each write as it happens. Writes go to a local temporary file, which is sparse, so only written regions use disk space. `synchronize()` then uploads the changed ranges. Ranges that weren't written are downloaded from the server only when something reads them.

`EXIFKit.write` and `strip` call `synchronize()` for you. If you call the handle's `write` or `truncate` yourself, call `synchronize()` when you're done: unsynchronized changes are discarded when the handle is released.

#### Server requirements

The server must accept `PATCH` requests with `Content-Type: application/octet-stream` and one of these headers:

- `Content-Range: bytes start-end/length` with a body: write the body at `start`, and set the resource's size to `length`.
- `Content-Range: bytes */length` with an empty body: resize the resource to `length`.

If the server answers `PATCH` with 405, 415 or 501, the handle falls back to a streamed `PUT` of the complete resource. Before the `PUT` it downloads any ranges it doesn't have locally, so bytes you didn't change are kept. Later synchronizations of that handle use `PUT` directly. Any other HTTP error is thrown to the caller. Uploads and response handling use bounded memory.

### Format constraints

- **JPEG:** the EXIF must fit in a single APP1 segment (about 64 KB).
- **PNG:** the EXIF is stored in an `eXIf` chunk.
- **TIFF and TIFF-based RAW:** image data stays at its original offsets. Unchanged values stored outside the directories, including MakerNotes, are reused rather than rewritten. The byte order can't be changed, and the file must stay within 32-bit offsets (4 GiB). `strip` removes the EXIF, GPS and interoperability directories and zeros their bytes. It keeps IFD0, thumbnails and image layout tags so the image stays readable.
- **HEIF, HEIC and AVIF:** only an Exif item that the file already declares can be edited. It is found through its `iloc` entry, including fragmented items and items stored in `idat`. A larger replacement is appended in a new `mdat` box, the index is updated, and the old item is cleared. EXIF that isn't in the index isn't searched for, and a file with no Exif item can't be given one.
- **JPEG XL:** the EXIF lives in the container's top-level `Exif` box. It can be replaced at any size, because boxes hold no absolute offsets, and it is inserted after `ftyp` if missing. Brotli-compressed (`brob`) Exif boxes can't be read, but they are replaced or removed on write. Bare codestreams have no container to hold metadata and are rejected. `strip` removes the box.
- **CR3:** the metadata must fit in the existing CMT boxes, and missing boxes can't be added. Image offsets are preserved. `strip` replaces CMT1–CMT4 with empty TIFF metadata.
- **RAF:** the embedded JPEG is preserved. If it grows, the offsets of the CFA data that follows are updated.
- **Thumbnails:** `setThumbnail` stores a JPEG thumbnail in IFD1. In TIFF-based files the new thumbnail is appended and the old one zeroed. If the file has an IFD1, it must already hold a JPEG thumbnail (as in CR2 and ARW); if it has only IFD0 (as in NEF and DNG), IFD1 is added after it. Removing a thumbnail works only for TIFF and DNG, because RAW readers may find later IFDs by position. CR3 rejects thumbnail changes.

### Limitations

`strip` removes only the metadata structures described above. It doesn't remove XMP or IPTC, and it doesn't guarantee that old bytes left behind by earlier editors, which the file no longer references, are erased.

MakerNotes are copied as opaque bytes. They aren't decoded, and their internal offsets aren't relocated.

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

Mutable memory and local I/O are actor-isolated; HTTP serialises complete operations across suspension points.

Native filesystem, URLSession and consumer backend errors propagate unchanged. `FileAccessError` only describes invalid ranges and incomplete reads. EXIF parsing errors and metadata resource limits use `EXIFError`. HTTP response validation uses `URLError.badServerResponse`, preserving the `HTTPURLResponse` in the error's `userInfo["HTTPURLResponse"]`.

## Migration and tests

Reading, writing, stripping and TIFF serialization are now `async throws`, including overloads taking `Data`. Replace eager `thumbnailData` access with `try await metadata.readThumbnail()` (or `try await metadata.thumbnailData`). Parsed metadata no longer retains a complete TIFF buffer. Low-level ISOBMFF parsing returns a box index rather than copied payloads.

Run `swift test`. Tests use [Hummingbird](https://github.com/hummingbird-project/hummingbird) to start real HTTP servers on temporary local ports (macOS 14+/iOS 17+). Hummingbird is a test-target dependency. Range requests, remote errors, streaming output and sparse multi-gigabyte files are tested without allocating those files in memory. The Nikon D90 JPEG is checked against saved `exiv2` results (the tests do not run exiv2); see [the test guide](Tests/README.md).

## License

MIT. See [LICENSE](LICENSE).
