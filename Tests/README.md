# Tests

Run `swift test`. The library is checked with synthetic containers, sparse multi-gigabyte sources, real Hummingbird HTTP servers and the Nikon D90 JPEG in `EXIFKitTests/Fixtures`.

## Nikon D90 reference

`NikonD90.jpg` has 20 EXIF tags, an embedded JPEG thumbnail of 6924 bytes, and separate XMP/IPTC segments. The reference files were generated with **exiv2 0.28.9**:

- `NikonD90.exiv2.txt`: tag IDs, keys, types, component counts and untranslated values. Its header records the fixture's SHA-256 and generation command.
- `NikonD90.exiv2-thumbnail.jpg`: the thumbnail extracted independently by exiv2.

The saved references run on every supported test platform, without requiring exiv2. They check all EXIF tags, deferred thumbnail extraction, TIFF serialization, and agreement between memory, local and HTTP sources. Reading metadata transfers less than 4 KiB; fetching the thumbnail transfers its 6924 bytes separately.

## Edits and preservation

The tests never run exiv2 or exiftool; the tools only extract reference data saved in `Fixtures`. `NikonD90.exiv2-edited.jpg` (headers only, no image scan) was edited by exiv2 (Artist, Orientation, ISO), with its tags saved in `NikonD90.exiv2-edited.txt`. `ReferenceEditTests` check that EXIFKit reads it identically, that library edits (including new GPS tags) persist, that unchanged tags keep their counts, and that EXIF removal leaves the compressed JPEG scan and every non-EXIF segment (XMP/IPTC) byte for byte intact. Only temporary copies are edited.

To inspect the reference independently:

```sh
LC_ALL=C exiv2 -PExkycv Tests/EXIFKitTests/Fixtures/NikonD90.jpg
```

To extract its thumbnail:

```sh
exiv2 -et- ex Tests/EXIFKitTests/Fixtures/NikonD90.jpg > /tmp/NikonD90-thumbnail.jpg
```

To regenerate the edited reference, repeat the `exiv2 -M set ...` command recorded in its header on a copy of the fixture and truncate before the SOS marker.

When changing the fixture, regenerate the references with exiv2, update the SHA-256/version header, and inspect the differences. EXIFKit output must not be used to generate its own expected values. EXIF pointers may move during edits, so those tags are excluded from the comparison.
