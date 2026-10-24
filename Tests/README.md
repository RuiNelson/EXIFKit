# Tests

Run `swift test`. The library is checked with synthetic containers, sparse multi-gigabyte sources, real Hummingbird HTTP servers and the Nikon D90 JPEG in `EXIFKitTests/Fixtures`.

## Nikon D90 reference

`NikonD90.jpg` has 20 EXIF tags, an embedded JPEG thumbnail of 6924 bytes, and separate XMP/IPTC segments. The reference files were generated with **exiv2 0.28.9**:

- `NikonD90.exiv2.txt`: tag IDs, keys, types, component counts and untranslated values. Its header records the fixture's SHA-256 and generation command.
- `NikonD90.exiv2-thumbnail.jpg`: the thumbnail extracted independently by exiv2.

The saved references run on every supported test platform, without requiring exiv2. They check all EXIF tags, deferred thumbnail extraction, TIFF serialization, and agreement between memory, local and HTTP sources. Reading metadata transfers less than 4 KiB; fetching the thumbnail transfers its 6924 bytes separately.

## Live exiv2 checks

On macOS and Linux, `Exiv2OracleTests` runs when `exiv2` is on `PATH`. Select another executable with:

```sh
EXIV2=/path/to/exiv2 swift test --filter Exiv2OracleTests
```

These tests compare the saved reference against exiv2, validate EXIFKit edits (including new GPS tags), read files modified by exiv2, and confirm EXIF removal. They compare the compressed JPEG scan and every non-EXIF segment byte for byte, so XMP/IPTC and image data must remain intact. Only temporary copies are edited.

To inspect the reference independently:

```sh
LC_ALL=C exiv2 -PExkycv Tests/EXIFKitTests/Fixtures/NikonD90.jpg
```

To extract its thumbnail:

```sh
exiv2 -et- ex Tests/EXIFKitTests/Fixtures/NikonD90.jpg > /tmp/NikonD90-thumbnail.jpg
```

When changing the fixture, regenerate the reference with exiv2, update the SHA-256/version header, and inspect the differences. EXIFKit output must not be used to generate its own expected values. EXIF pointers may move during edits; the live tests compare their new locations against exiv2 and require unchanged semantic values for the remaining original tags.
