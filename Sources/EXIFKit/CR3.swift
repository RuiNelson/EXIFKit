import Foundation

// MARK: - Canon CR3 Container

/// Reads and writes EXIF metadata from Canon CR3 RAW files.
///
/// CR3 is Canon's modern RAW format, introduced with the EOS M50 in 2018.
/// Unlike CR2 (which is TIFF-based), CR3 uses the ISO Base Media File Format
/// (ISOBMFF), the same container format as HEIF and MP4.
///
/// CR3 file structure:
/// ```
/// ftyp (file type: "crx ")
/// moov
///   uuid (Canon's UUID: 85c0b687-820f-11e0-8111-f4ce462b6a48)
///     CNCV (Canon Compressor Version)
///     CCTP (Canon CCTP)
///     CMT1 (IFD0 — TIFF-format metadata)
///     CMT2 (EXIF sub-IFD — TIFF-format)
///     CMT3 (Canon MakerNote — TIFF-format)
///     CMT4 (GPS sub-IFD — TIFF-format)
///     THMB (Thumbnail)
///   trak (preview image track)
///   trak (main image track)
///   trak (video track, if applicable)
/// mdat (raw image data)
/// ```
///
/// Each CMT box contains TIFF-format IFD data (with its own TIFF header).
/// We parse each CMT independently and combine them into a TIFFStructure.
public struct CR3Container {

    /// The Canon CR3 UUID that identifies Canon-specific metadata
    static let canonUUID = Data([
        0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0,
        0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48
    ])

    // MARK: - Detection

    /// Check if data is a CR3 file by looking for the "crx " file type
    public static func isCR3(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        // ftyp box starts at offset 0, type at offset 4
        let ftyp = String(data: data[data.startIndex+4..<data.startIndex+8], encoding: .ascii)
        guard ftyp == "ftyp" else { return false }
        // Major brand at offset 8
        let brand = String(data: data[data.startIndex+8..<data.startIndex+12], encoding: .ascii)
        return brand == "crx "
    }

    // MARK: - Reading

    /// Read EXIF metadata from a CR3 file.
    ///
    /// Parses the ISOBMFF structure, finds the CMT boxes, and combines
    /// their IFD data into a unified TIFFStructure.
    public static func readEXIF(from data: Data) throws -> TIFFStructure {
        let boxes = try ISOBMFFParser.parse(data)

        // Find Canon's UUID box inside moov
        guard let moov = boxes.first(where: { $0.type == "moov" }) else {
            throw EXIFError.unsupportedFormat("CR3: No moov box found")
        }

        // Find the Canon UUID box (contains CMT1-CMT4)
        let canonBox = findCanonUUIDBox(in: moov)

        // Parse each CMT box as a TIFF structure
        var byteOrder: ByteOrder = .littleEndian
        var ifd0 = IFD()
        var exifIFD: IFD? = nil
        var gpsIFD: IFD? = nil

        // CMT1: IFD0
        if let cmt1 = canonBox?.child(ofType: "CMT1") ?? findBoxRecursive("CMT1", in: [moov]) {
            if let tiff = try? TIFFParser.parse(cmt1.data) {
                ifd0 = tiff.ifd0
                byteOrder = tiff.byteOrder
            }
        }

        // CMT2: EXIF sub-IFD
        if let cmt2 = canonBox?.child(ofType: "CMT2") ?? findBoxRecursive("CMT2", in: [moov]) {
            if let tiff = try? TIFFParser.parse(cmt2.data) {
                exifIFD = tiff.ifd0 // CMT2's IFD0 IS the EXIF data
            }
        }

        // CMT4: GPS sub-IFD
        if let cmt4 = canonBox?.child(ofType: "CMT4") ?? findBoxRecursive("CMT4", in: [moov]) {
            if let tiff = try? TIFFParser.parse(cmt4.data) {
                gpsIFD = tiff.ifd0 // CMT4's IFD0 IS the GPS data
            }
        }

        // If we couldn't find any CMT boxes, try the generic ISOBMFF EXIF extraction
        if ifd0.entries.isEmpty {
            if let exifData = ISOBMFFParser.extractEXIFData(from: boxes, fileData: data) {
                return try TIFFParser.parse(exifData)
            }
            throw EXIFError.unsupportedFormat("CR3: No metadata boxes found")
        }

        return TIFFStructure(
            byteOrder: byteOrder,
            ifd0: ifd0,
            exifIFD: exifIFD,
            gpsIFD: gpsIFD
        )
    }

    // MARK: - Writing

    /// Write modified EXIF metadata back to a CR3 file.
    ///
    /// Strategy: overwrite each CMT box's payload in place, zero-padded to its original size.
    /// moov precedes mdat, and the sample tables (co64) and Canon's CTBO hold absolute offsets
    /// past it, so moov must not change size. Metadata that no longer fits throws instead.
    public static func writeEXIF(_ structure: TIFFStructure, to data: Data) throws -> Data {
        let boxes = try ISOBMFFParser.parse(data)
        guard let moov = boxes.first(where: { $0.type == "moov" }) else {
            throw EXIFError.invalidCR3("No moov box found")
        }
        let canonBox = findCanonUUIDBox(in: moov)

        let payloads: [(type: String, ifd: IFD?)] = [
            ("CMT1", structure.ifd0),
            ("CMT2", structure.exifIFD),
            ("CMT4", structure.gpsIFD),
        ]

        var output = data
        for (type, ifd) in payloads {
            guard let box = canonBox?.child(ofType: type) ?? findBoxRecursive(type, in: [moov]) else {
                if ifd != nil {
                    throw EXIFError.invalidCR3("No \(type) box to hold the metadata; adding boxes is not supported")
                }
                continue
            }
            // A removed IFD becomes an empty TIFF: decoders (LibRaw) reject a CR3 with a zero-filled CMT box
            let tiff = TIFFSerializer.serialize(TIFFStructure(byteOrder: structure.byteOrder, ifd0: ifd ?? IFD()))
            let capacity = box.totalSize - 8
            guard tiff.count <= capacity else {
                throw EXIFError.invalidCR3("\(type) metadata grew to \(tiff.count) bytes; it must fit in the original \(capacity)")
            }
            let start = output.startIndex + box.fileOffset + 8
            output.replaceSubrange(start..<start + capacity, with: tiff + Data(count: capacity - tiff.count))
        }

        return output
    }

    // MARK: - Stripping

    /// Strip EXIF from a CR3 file by replacing each CMT box's contents with an empty TIFF.
    /// Zero-filling instead makes decoders (LibRaw) reject the whole file.
    public static func stripEXIF(from data: Data) throws -> Data {
        let boxes = try ISOBMFFParser.parse(data)

        var mutableData = data

        // Replace each CMT box's payload with an empty TIFF (keeping its byte order), zero-padded in place
        for cmtType in ["CMT1", "CMT2", "CMT3", "CMT4"] {
            if let cmtBox = findBoxRecursive(cmtType, in: boxes) {
                let payloadStart = cmtBox.fileOffset + 8
                let payloadLength = cmtBox.totalSize - 8
                let start = mutableData.startIndex + payloadStart
                let end = start + payloadLength
                if end <= mutableData.endIndex {
                    let byteOrder: ByteOrder = cmtBox.data.first == 0x4D ? .bigEndian : .littleEndian
                    var empty = TIFFSerializer.serialize(TIFFStructure(byteOrder: byteOrder))
                    if empty.count > payloadLength { empty = Data() } // too small to hold a TIFF: zero it
                    mutableData.replaceSubrange(start..<end, with: empty + Data(count: payloadLength - empty.count))
                }
            }
        }

        return mutableData
    }

    // MARK: - Helpers

    private static func findCanonUUIDBox(in moov: ISOBMFFBox) -> ISOBMFFBox? {
        for child in moov.children {
            if child.type == "uuid" {
                if child.child(ofType: "CMT1") != nil {
                    return child
                }
                if child.data.count >= 16 && child.data.prefix(16) == canonUUID {
                    return child
                }
            }
        }
        return nil
    }

    private static func findBoxRecursive(_ type: String, in boxes: [ISOBMFFBox]) -> ISOBMFFBox? {
        for box in boxes {
            if box.type == type { return box }
            if let found = findBoxRecursive(type, in: box.children) { return found }
        }
        return nil
    }
}
