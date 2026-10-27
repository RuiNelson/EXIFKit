# EXIFKit

A pure Swift library for reading, writing, and stripping EXIF metadata from images. Zero external dependencies — Foundation only.

Metadata is read through random-access file handles, so it can come from memory, local files, HTTP servers or your own storage backend without loading the image into memory.

## Features

- **Read** EXIF metadata from 15 image formats
- **Write** modified metadata back (GPS geotagging, camera info, timestamps, thumbnails, etc.)
- **Strip** all EXIF metadata for privacy
- **Auto-detect** image format from file contents
- **Random-access sources**: memory, local files, HTTP (`Range` reads, `PATCH`/`PUT` writes) or a custom `AbstractFileHandle`
- **SMB and SFTP** through the adapters in [SwiftSMB](https://github.com/RuiNelson/SwiftSMB) and [SwiftSFTP](https://github.com/RuiNelson/SwiftSFTP)
- **Few reads**: only metadata ranges are fetched, in aligned blocks; a typical extraction takes one to four handle reads
- **Streaming writes**: image data is copied in bounded blocks, so memory use stays small for large files
- **Lazy thumbnails**: the EXIF thumbnail is fetched only when requested
- Typed conveniences for common tags (`CameraMake`, `LensMake`, `ImageOrientation`, `ImageColorSpace`, `Date`, `CLLocation`)
- Configurable resource limits for untrusted files
- All 12 EXIF data types fully supported
- MakerNote blobs preserved as raw bytes (pass-through, no decoding)
- Swift 6 strict concurrency compliant

## Supported Formats

| Format | Type | Read | Write | Strip |
|--------|------|------|-------|-------|
| JPEG | Standard | Yes | Yes | Yes |
| PNG | Standard | Yes | Yes | Yes |
| WebP | RIFF | Yes | Yes | Yes |
| TIFF | Standard | Yes | Yes | Yes |
| DNG | Standard | Yes | Yes | Yes |
| CR2 (Canon) | TIFF-based | Yes | Yes | Yes |
| CR3 (Canon) | ISOBMFF | Yes | Yes | Yes |
| NEF (Nikon) | TIFF-based | Yes | Yes | Yes |
| ARW (Sony) | TIFF-based | Yes | Yes | Yes |
| RAF (Fujifilm) | Custom | Yes | Yes | Yes |
| ORF (Olympus/OM) | TIFF variant | Yes | Yes | Yes |
| RW2 (Panasonic) | TIFF variant | Yes | Yes | Yes |
| PEF (Pentax) | TIFF-based | Yes | Yes | Yes |
| HEIF/HEIC/AVIF | ISOBMFF | Yes | Yes | Yes |
| JPEG XL | ISOBMFF-style boxes | Yes | Yes | Yes |

Some formats limit what a write can do; see [Write Strategies](#write-strategies).

## Requirements

- Swift 6.3+
- macOS 11+ / iOS 14+ / tvOS 14+ / Mac Catalyst 14+ / watchOS 7+ / visionOS 1+
- Linux
- Android (API 28+)

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/RuiNelson/EXIFKit.git", from: "0.4.0")
]
```

Then link the `EXIFKit` product. Or in Xcode: File > Add Package Dependencies, then paste the repository URL.

## Usage

### Reading EXIF

```swift
import EXIFKit

// Auto-detect format from data
let metadata = try await EXIFKit.read(from: imageData)

// Or from a URL: file URLs open a LocalFileHandle, others an HTTPFileHandle
let metadata = try await EXIFKit.read(from: url)

// Or with explicit format
let metadata = try await EXIFKit.read(from: data, format: .cr3)

// Access common fields
print(metadata.make)              // "NIKON CORPORATION"
print(metadata.model)             // "NIKON Z 8"
print(metadata.dateTimeOriginal)  // "2024:01:15 14:30:00"
print(metadata.taken)             // 2024-01-15 14:30:00 +0000
print(metadata.iso)               // 100
print(metadata.fNumber)           // 2.8
print(metadata.focalLength)       // 50.0
print(metadata.lensModel)         // "NIKKOR Z 50mm f/1.8 S"
print(metadata.latitude)          // 51.5074
print(metadata.longitude)         // -0.1278
```

### Reading from File Handles

All sources use the same parser. Format detection inspects contents; pass `format:` to specify one explicitly.

```swift
let local = try LocalFileHandle(url: imageURL)
let fromFile = try await EXIFKit.read(from: local)

let memory = InMemoryFileHandle(data: imageData)
let fromMemory = try await EXIFKit.read(from: memory)

let remote = try await HTTPFileHandle(url: remoteURL)
let fromHTTP = try await EXIFKit.read(from: remote)
```

The parser follows metadata offsets and skips image payloads. To keep remote round trips few, it reads aligned 64 KiB blocks, fetches each contiguous run of missing blocks in one handle read, and reads independent directories and values concurrently. A typical JPEG, HEIF, JXL or RAW extraction takes one to four handle reads. Set `readAheadBytes` to 0 to read exact ranges instead, which transfers the least data but needs more reads. The block cache is dropped once the extraction returns. Results retain the source handle for deferred thumbnail reads; keep that source unchanged while using them.

Metadata reads (read-ahead included) and decoded values are each limited to 32 MiB per extraction, individual values to 10 MiB, and underlying read operations to 4096. Read-ahead falls back to exact reads rather than exceed these limits. The limits and the block size are configurable:

```swift
let options = ReadOptions(
    maximumMetadataBytes: 64 * 1024 * 1024,
    maximumReadOperations: 8192,
    readAheadBytes: 256 * 1024
)
let metadata = try await EXIFKit.read(from: source, options: options)
```

### Writing EXIF

```swift
var metadata = try await EXIFKit.read(from: imageData)

// Modify any tag
metadata.ifd0.set(tagID: Tag.software, value: .ascii("MyApp"))
metadata.ifd0.set(tagID: Tag.artist, value: .ascii("Photographer"))

// Write back
let newData = try await EXIFKit.write(metadata, to: imageData)
```

The `Data` overloads run the same writer with in-memory handles. To write between file handles:

```swift
// LocalFileHandle only opens existing files, so create the destination first.
FileManager.default.createFile(atPath: outputURL.path, contents: nil)
let destination = try LocalFileHandle(url: outputURL)
try await EXIFKit.write(metadata, from: source, to: destination)
```

`write` and `strip` never modify the source. Each one produces a complete new file in a separate destination: a copy of the source with the metadata replaced (`write`) or removed (`strip`).

Only the new metadata is built in memory. Everything else, including the image data, is copied from the source to the destination in blocks of at most 1 MiB, and the next block is read while the current one is written. Every byte of the source is read: writing from an HTTP source downloads the whole image.

The whole edit is planned and validated before the destination is touched. An impossible edit, such as EXIF too large for a JPEG, throws and leaves the destination unchanged. Otherwise the destination is truncated and written from the beginning.

#### Replacing the Original File

The destination must be a different file from the source, because the source is still being read while the destination is written. EXIFKit rejects the same handle passed twice, and two local handles that refer to the same file (same inode). It can't check custom handle types, so they must guarantee this themselves.

An I/O failure or cancellation stops the write and can leave a partial destination. To update a file in place, write to a temporary file, then rename it over the original once the call succeeds.

### GPS Geotagging

```swift
var metadata = try await EXIFKit.read(from: imageData)
metadata.setGPSCoordinates(
    latitude: 48.8566,    // positive = North
    longitude: 2.3522,    // positive = East
    altitude: 35.0        // optional, meters
)
let geotagged = try await EXIFKit.write(metadata, to: imageData)
```

This works even on files with no existing GPS data — the GPS sub-IFD and IFD0 pointer are created automatically.

Where CoreLocation is available, `metadata.location` returns a `CLLocation` and `metadata.setLocation(_:)` writes one, including altitude, accuracy, speed, course and timestamp.

### Stripping EXIF

```swift
let cleanData = try await EXIFKit.strip(from: imageData)

// Or between file handles
FileManager.default.createFile(atPath: cleanURL.path, contents: nil)
let clean = try LocalFileHandle(url: cleanURL)
try await EXIFKit.strip(from: source, to: clean)
```

### Reading Any Tag

```swift
let m = try await EXIFKit.read(from: data)
m.ifd0.value(for: Tag.imageDescription)?.stringValue
m.exifIFD?.value(for: Tag.exposureProgram)?.uint32Value
m.gpsIFD?.value(for: Tag.gpsTimeStamp)
m.exifIFD?.value(for: 0xA434) // raw tag ID
```

### Debug Dump

```swift
print(EXIFKit.dump(metadata))
```

## Convenience Accessors

`TIFFStructure` provides typed accessors for common fields:

| Category | Properties |
|----------|-----------|
| Camera | `make`, `makeTyped`, `model`, `software`, `artist`, `copyright`, `imageDescription` |
| Exposure | `iso`, `fNumber`, `exposureTime`, `exposureTimeFraction`, `exposureBias`, `flashFired` |
| Lens | `focalLength`, `focalLength35mm`, `lensModel`, `lensMake`, `lensMakeTyped` |
| Image | `orientation`, `orientationTyped`, `colorSpace`, `colorSpaceTyped`, `pixelWidth`, `pixelHeight` |
| Date/Time | `dateTimeOriginal`, `dateTimeDigitized`, `offsetTimeOriginal`, `offsetTimeDigitized`, `taken`, `digitized` |
| GPS | `latitude`, `longitude`, `altitude` (signed decimal degrees), `location` (`CLLocation`) |
| Thumbnail | `readThumbnail()`, `thumbnailData`, `loadingThumbnail()`, `setThumbnail(_:)` |

`taken` and `digitized` are `Date` values that use the matching offset tag when present, and UTC otherwise.

## Thumbnails

Many images embed a small JPEG preview, the EXIF thumbnail, in IFD1. EXIFKit gives it to you as JPEG `Data`. `read` doesn't fetch it: `readThumbnail()` reads it from the source when you ask, so keep the source available and unchanged until then. It returns `nil` if the file has no thumbnail. `metadata.thumbnailData` is the same call as an async property.

```swift
let metadata = try await EXIFKit.read(from: source)
let jpeg = try await metadata.readThumbnail()
```

To keep the metadata complete after the source is gone, call `loadingThumbnail()` while the source is still available. It returns a copy that holds the thumbnail in memory and no longer refers to the source, so `readThumbnail()` and `write` work after the source is closed or released:

```swift
// Nothing keeps the local handle once the copy is made, so its file descriptor is closed.
let metadata = try await EXIFKit.read(from: LocalFileHandle(url: imageURL)).loadingThumbnail()
let jpeg = try await metadata.readThumbnail()
```

### Showing a Thumbnail

The data is a regular JPEG, so `UIImage` can decode it directly:

```swift
import UIKit

if let jpeg = try await metadata.readThumbnail(),
   let image = UIImage(data: jpeg) {
    imageView.image = image
}
```

On macOS, use `NSImage(data: jpeg)` instead. In SwiftUI, wrap either one in `Image(uiImage:)` or `Image(nsImage:)`.

### Replacing or Removing a Thumbnail

`setThumbnail(_:)` takes JPEG data of up to 10 MiB and stores it in IFD1, creating IFD1 if needed. Pass `nil` to remove the thumbnail. Like other edits, the change reaches a file only when you call `write`.

To make a thumbnail from a `UIImage`, scale it down and encode it as JPEG. EXIF thumbnails are conventionally about 160 × 120 pixels:

```swift
import UIKit

func exifThumbnail(from image: UIImage, maxSide: CGFloat = 160) -> Data? {
    let scale = min(1, maxSide / max(image.size.width, image.size.height))
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1 // measure the thumbnail in pixels, not points
    let thumbnail = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
    }
    return thumbnail.jpegData(compressionQuality: 0.8)
}

var metadata = try await EXIFKit.read(from: source)
// Check for nil: setThumbnail(nil) would remove the existing thumbnail.
guard let jpeg = exifThumbnail(from: image) else { return }
try metadata.setThumbnail(jpeg)
try await EXIFKit.write(metadata, from: source, to: destination)
```

## File Handles

| Storage | Handle |
|---------|--------|
| Memory | `InMemoryFileHandle` |
| Local files | `LocalFileHandle` |
| HTTP | `HTTPFileHandle` |
| SMB | [SwiftSMB](#smb-and-sftp) adapter |
| SFTP | [SwiftSFTP](#smb-and-sftp) adapter |
| Custom | your `AbstractFileHandle` |

Mutable memory and local I/O are actor-isolated; HTTP serialises complete operations across suspension points.

### HTTP

`HTTPFileHandle` discovers the file size with a one-byte range request and uses HTTP `Range` for subsequent reads. All requests of a handle share one `URLSession`, so they reuse its connections instead of repeating TCP and TLS setup. It validates `206`, `Content-Range`, body length and resource size. Servers returning the whole file are rejected before their body is buffered. Strong ETags or Last-Modified headers, when provided, are checked on later requests; without validators, a same-sized remote replacement cannot be detected.

An `HTTPFileHandle` can also be a write destination:

```swift
let destination = try await HTTPFileHandle(url: outputURL)
try await EXIFKit.write(metadata, from: source, to: destination)
```

It doesn't upload each write as it happens. Writes go to a local temporary file, which is sparse, so only written regions use disk space. `synchronize()` then uploads the changed ranges. Ranges that weren't written are downloaded from the server only when something reads them.

`EXIFKit.write` and `strip` call `synchronize()` for you. If you call the handle's `write` or `truncate` yourself, call `synchronize()` when you're done: unsynchronized changes are discarded when the handle is released.

The server must accept `PATCH` requests with `Content-Type: application/octet-stream` and one of these headers:

- `Content-Range: bytes start-end/length` with a body: write the body at `start`, and set the resource's size to `length`.
- `Content-Range: bytes */length` with an empty body: resize the resource to `length`.

If the server answers `PATCH` with 405, 415 or 501, the handle falls back to a streamed `PUT` of the complete resource. Before the `PUT` it downloads any ranges it doesn't have locally, so bytes you didn't change are kept. Later synchronizations of that handle use `PUT` directly. Any other HTTP error is thrown to the caller. Uploads and response handling use bounded memory.

### Custom Storage

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

### Errors

Native filesystem, URLSession and consumer backend errors propagate unchanged. `FileAccessError` only describes invalid ranges and incomplete reads. EXIF parsing errors and metadata resource limits use `EXIFError`. HTTP response validation uses `URLError.badServerResponse`, preserving the `HTTPURLResponse` in the error's `userInfo["HTTPURLResponse"]`.

## SMB and SFTP

[SwiftSMB](https://github.com/RuiNelson/SwiftSMB) and [SwiftSFTP](https://github.com/RuiNelson/SwiftSFTP) include EXIFKit adapters, `SwiftSMBEXIFKit` and `SwiftSFTPEXIFKit`, which re-export EXIFKit. Only the ranges that hold metadata are read, not the whole image.

### SMB

```swift
import SwiftSMB
import SwiftSMBEXIFKit

let client = try await SMB.connect(server: server, credentials: credentials, share: "Photos")
let metadata = try await client.imageMetadata(at: "2026/IMG_0001.JPG")
```

### SFTP

```swift
import SwiftSFTP
import SwiftSFTPEXIFKit

let client = try SFTPClient(openSocketIn: myServer,
                            authentication: myCreds)
try await client.login()

let metadata = try await client.imageMetadata(path: "/Photos/DSC_0042.NEF").loadingThumbnail()
let thumbnail = try await metadata.readThumbnail()
```

## Architecture

```
EXIFKit.swift                 <- Public API: read/write/strip/dump + ImageFormat enum
  +-- FileHandles/
  |     +-- AbstractFileHandle.swift  <- Random-access storage protocol
  |     +-- InMemoryFileHandle.swift  <- Data-backed handle
  |     +-- LocalFileHandle.swift     <- File-descriptor handle
  |     +-- HTTP/                     <- Range reads, staged PATCH/PUT writes, shared URLSession
  +-- Metadata/
  |     +-- MetadataReader.swift      <- ReadOptions, block cache, resource limits
  |     +-- FileEditing.swift         <- Edit planning and streaming copy to the destination
  |     +-- MetadataEditing.swift     <- Per-format edit plans
  +-- Formats/
  |     +-- JPEG.swift                <- APP1 marker segment container
  |     +-- PNG.swift                 <- eXIf chunk container (with CRC32)
  |     +-- WebP.swift                <- RIFF EXIF chunk + VP8X flag
  |     +-- ISOBaseMedia/             <- ISOBMFF parser, HEIF/HEIC/AVIF (iloc), JPEG XL (Exif box)
  |     +-- RAW/                      <- CR2/NEF/ARW/ORF/RW2/PEF, CR3 (CMT boxes), RAF
  |     +-- TIFF/                     <- TIFFStructure, IFD engine, tags, thumbnails, typed conveniences
  +-- Support/
  |     +-- ByteReader.swift          <- Endian-aware binary I/O
  |     +-- ContainerIndex.swift      <- Box locations without payloads
  +-- Types.swift                     <- TagValue, EXIFError, URational, SRational
```

The library is layered: container parsers find TIFF data within each format, the TIFF parser reads IFD chains, and the IFD engine reads individual tag entries. All reads go through a file handle and the shared block cache. All formats produce the same `TIFFStructure` output.

## Write Strategies

| Format | Strategy |
|--------|----------|
| JPEG | APP1 segment rebuild. The EXIF, thumbnail included, must fit in a single APP1 segment (about 64 KB). |
| PNG | `eXIf` chunk replace or insert. |
| WebP | `EXIF` chunk after the image data. Writing EXIF to a simple lossy or lossless file first adds a `VP8X` header, using the canvas size from the image bitstream. `strip` removes the chunk and clears the `VP8X` EXIF flag. |
| TIFF/DNG/RAW | Image data stays at its original offsets. Unchanged values stored outside the directories, including MakerNotes, are reused rather than rewritten. The byte order can't be changed, and the file must stay within 32-bit offsets (4 GiB). `strip` removes the EXIF, GPS and interoperability directories and zeros their bytes; it keeps IFD0, thumbnails and image layout tags so the image stays readable. |
| CR3 | The metadata must fit in the existing CMT boxes, and missing boxes can't be added. Image offsets are preserved. `strip` replaces CMT1–CMT4 with empty TIFF metadata. |
| HEIF/HEIC/AVIF | Only an Exif item that the file already declares can be edited. It is found through its `iloc` entry, including fragmented items and items stored in `idat`. A larger replacement is appended in a new `mdat` box, the index is updated, and the old item is cleared. |
| JPEG XL | Top-level `Exif` box, replaced at any size because boxes hold no absolute offsets, and inserted after `ftyp` if missing. Brotli-compressed (`brob`) Exif boxes can't be read, but they are replaced or removed on write. Bare codestreams have no container to hold metadata and are rejected. |
| RAF | Modify the embedded JPEG; if it grows, the offsets of the CFA data that follows are updated. |

Thumbnails:

- **JPEG and RAF:** the thumbnail is stored in the same APP1 segment as the rest of the EXIF, so together they must fit in about 64 KB. (RAF metadata lives in an embedded JPEG.)
- **TIFF and TIFF-based RAW:** the new thumbnail is appended to the file and the old one is zeroed. If the file has an IFD1, it must already hold a JPEG thumbnail (as in CR2 and ARW). If it has only IFD0 (as in NEF and DNG), IFD1 is added after it. Removing a thumbnail works only for TIFF and DNG, because RAW readers may find later IFDs by their position.
- **CR3:** thumbnail changes are rejected.

## Known Limitations

- **No XMP or IPTC** — Only TIFF/IFD-based EXIF is parsed, and `strip` doesn't remove XMP or IPTC
- **MakerNote is opaque** — Copied as raw bytes, not decoded; internal offsets aren't relocated
- **HEIF without an Exif item** — EXIF that isn't in the `iloc` index isn't searched for, and a file with no Exif item can't be given one
- **Brotli-compressed JPEG XL Exif** — Can't be read (it is replaced or removed on write)
- **Stale bytes** — `strip` doesn't guarantee that old bytes left behind by earlier editors, which the file no longer references, are erased

## Migrating from 0.1

Reading, writing, stripping and TIFF serialization are now `async throws`, including overloads taking `Data`. Replace eager `thumbnailData` access with `try await metadata.readThumbnail()` (or `try await metadata.thumbnailData`). Parsed metadata no longer retains a complete TIFF buffer. Low-level ISOBMFF parsing returns a box index rather than copied payloads.

## Testing

Run `swift test`. Tests use [Hummingbird](https://github.com/hummingbird-project/hummingbird) to start real HTTP servers on temporary local ports (macOS 14+/iOS 17+). Hummingbird is a test-target dependency. Range requests, remote errors, streaming output and sparse multi-gigabyte files are tested without allocating those files in memory. The Nikon D90 JPEG is checked against saved `exiv2` results (the tests do not run exiv2); see [the test guide](Tests/README.md).

## License

MIT. See [LICENSE](LICENSE).
