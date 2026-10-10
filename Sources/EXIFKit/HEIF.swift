import Foundation

// MARK: - HEIF/HEIC Container

/// Reads and writes EXIF metadata from HEIF/HEIC image files.
///
/// HEIF (High Efficiency Image File Format) uses the ISOBMFF container.
/// Apple adopted it as the default photo format starting with iOS 11 / iPhone 7.
///
/// HEIF file structure:
/// ```
/// ftyp (file type: "heic", "heix", "hevc", "mif1")
/// meta (FullBox)
///   hdlr (handler: "pict")
///   pitm (primary item ID)
///   iloc (item locations — offsets to actual data)
///   iinf (item info — describes each item)
///     infe (item info entry: "Exif", "hvc1", "grid", etc.)
///   iprp (item properties)
///     ipco (property container)
///       ispe (image spatial extents — width/height)
///       colr (color info)
///       hvcC (HEVC config)
///     ipma (property-to-item associations)
///   iref (item references)
/// mdat (media data — actual image pixels + EXIF blob)
/// ```
///
/// EXIF is stored as a separate "item" in the file:
/// 1. An `infe` box in `meta/iinf` identifies an item of type "Exif"
/// 2. The `iloc` box gives the offset and length of that item in `mdat`
/// 3. The item data is: 4-byte TIFF offset prefix + "Exif\0\0" + TIFF data
///    OR just raw TIFF data (varies by encoder)
public struct HEIFContainer {

    // MARK: - Detection

    /// Known HEIF/HEIC file type brands
    private static let heifBrands: Set<String> = [
        "heic",  // HEVC-coded images (Apple's default)
        "heix",  // HEVC extended
        "hevc",  // HEVC
        "hevx",  // HEVC extended
        "heim",  // HEVC multi-image
        "heis",  // HEVC scalable
        "mif1",  // Generic HEIF
        "msf1",  // HEIF sequence
        "avif",  // AV1 Image (uses same ISOBMFF container)
        "avis",  // AV1 sequence
    ]

    /// Check if data is a HEIF/HEIC file
    public static func isHEIF(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let ftyp = String(data: data[data.startIndex+4..<data.startIndex+8], encoding: .ascii)
        guard ftyp == "ftyp" else { return false }

        // Check major brand
        let brand = String(data: data[data.startIndex+8..<data.startIndex+12], encoding: .ascii) ?? ""
        if heifBrands.contains(brand) { return true }

        // Also check compatible brands (starting at offset 16, each 4 bytes)
        // Read ftyp box size first
        let boxSize = Int(
            UInt32(data[data.startIndex]) << 24 |
            UInt32(data[data.startIndex + 1]) << 16 |
            UInt32(data[data.startIndex + 2]) << 8 |
            UInt32(data[data.startIndex + 3])
        )

        var offset = 16 // Skip size(4) + type(4) + major_brand(4) + minor_version(4)
        while offset + 4 <= min(boxSize, data.count) {
            let compat = String(data: data[(data.startIndex + offset)..<(data.startIndex + offset + 4)], encoding: .ascii) ?? ""
            if heifBrands.contains(compat) { return true }
            offset += 4
        }

        return false
    }

    // MARK: - Reading

    /// Read EXIF metadata from a HEIF/HEIC file.
    public static func readEXIF(from data: Data) throws -> TIFFStructure {
        let boxes = try ISOBMFFParser.parse(data)

        // Try to extract EXIF data from the ISOBMFF structure
        if let exifData = ISOBMFFParser.extractEXIFData(from: boxes, fileData: data) {
            return try TIFFParser.parse(exifData)
        }

        // Fallback: scan for TIFF header in mdat
        if let tiffData = scanForTIFFInMdat(boxes: boxes, fileData: data) {
            return try TIFFParser.parse(tiffData)
        }

        throw EXIFError.unsupportedFormat("HEIF: No EXIF data found")
    }

    // MARK: - Writing

    /// Write modified EXIF metadata back to a HEIF/HEIC file.
    ///
    /// HEIF writing is complex because:
    /// 1. EXIF data is stored as an item in mdat
    /// 2. Changing its size requires updating iloc offsets
    /// 3. It may also require updating iinf item sizes
    /// 4. Other items in mdat may shift if the EXIF item size changes
    ///
    /// Current strategy: in-place replacement when the new EXIF data
    /// fits in the same space, with zero-padding for smaller data.
    /// For larger data, we append it in a new mdat box and repoint iloc.
    public static func writeEXIF(_ structure: TIFFStructure, to data: Data) throws -> Data {
        let boxes = try ISOBMFFParser.parse(data)

        // Find the existing EXIF item location
        guard let meta = boxes.first(where: { $0.type == "meta" }),
              let iloc = meta.child(ofType: "iloc") else {
            throw EXIFError.unsupportedFormat("HEIF: Cannot write — no meta/iloc box found")
        }

        // Build new TIFF data
        let newTIFF = TIFFSerializer.serialize(structure)

        // Build the complete EXIF item: 4-byte prefix + "Exif\0\0" + TIFF
        var newExifItem = Data()
        // The 4-byte prefix is a big-endian offset from the end of this field to the TIFF header:
        // 6 skips "Exif\0\0"
        newExifItem.append(contentsOf: [0x00, 0x00, 0x00, 0x06])
        newExifItem.append(contentsOf: [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) // "Exif\0\0"
        newExifItem.append(newTIFF)

        // Find the EXIF item's location in the file
        guard let exifLocation = try findExifItemLocation(meta: meta, iloc: iloc, fileSize: data.count) else {
            throw EXIFError.unsupportedFormat("HEIF: Cannot locate EXIF item for writing")
        }

        var mutableData = data

        if newExifItem.count <= exifLocation.length {
            // In-place replacement (pad with zeros)
            let start = mutableData.startIndex + exifLocation.offset
            let end = start + exifLocation.length
            var padded = newExifItem
            padded.append(Data(count: exifLocation.length - newExifItem.count))
            mutableData.replaceSubrange(start..<end, with: padded)
        } else {
            // Append strategy: wrap the new item in its own top-level mdat (keeping the
            // file a valid box sequence) and repoint the item's iloc extent at it
            var mdatHeader = ByteWriter(byteOrder: .bigEndian)
            mdatHeader.writeUInt32(UInt32(newExifItem.count + 8))
            mdatHeader.writeBytes(Data("mdat".utf8))
            mutableData.append(mdatHeader.data)
            let appendOffset = mutableData.count
            mutableData.append(newExifItem)

            try patchIlocExtent(
                in: &mutableData,
                iloc: iloc,
                location: exifLocation,
                newOffset: UInt64(appendOffset),
                newLength: UInt64(newExifItem.count)
            )
        }

        return mutableData
    }

    /// Strip EXIF from a HEIF file by zeroing out the EXIF item data
    public static func stripEXIF(from data: Data) throws -> Data {
        let boxes = try ISOBMFFParser.parse(data)

        guard let meta = boxes.first(where: { $0.type == "meta" }),
              let iloc = meta.child(ofType: "iloc") else {
            throw EXIFError.unsupportedFormat("HEIF: Cannot strip — no meta/iloc box found")
        }

        guard let exifLocation = try findExifItemLocation(meta: meta, iloc: iloc, fileSize: data.count) else {
            // No EXIF to strip
            return data
        }

        var mutableData = data
        let start = mutableData.startIndex + exifLocation.offset
        let end = start + exifLocation.length
        let zeros = Data(count: exifLocation.length)
        mutableData.replaceSubrange(start..<end, with: zeros)

        return mutableData
    }

    // MARK: - Helpers

    private struct ExifItemLocation {
        let item: ItemLocations.Item
        let extent: ItemLocations.Extent
        let fieldSizes: (offset: Int, length: Int)
        let offset: Int
        let length: Int
    }

    /// Find the EXIF item's first extent: its byte range in the file and the iloc fields describing it
    private static func findExifItemLocation(
        meta: ISOBMFFBox,
        iloc: ISOBMFFBox,
        fileSize: Int
    ) throws -> ExifItemLocation? {
        let exifItemID = ISOBMFFParser.findExifItemID(in: meta)
        guard exifItemID != 0 else { return nil }

        let locations = try ItemLocations(iloc)
        guard let item = locations.items.first(where: { $0.itemID == exifItemID }),
              let extent = item.extents.first else { return nil }

        guard item.constructionMethod == 0 else {
            throw EXIFError.invalidHEIF("EXIF item stored with construction method \(item.constructionMethod) is not supported")
        }
        guard let range = item.fileRange(of: extent, fileSize: fileSize) else {
            throw EXIFError.invalidHEIF("EXIF item extends past end of file")
        }

        return ExifItemLocation(
            item: item,
            extent: extent,
            fieldSizes: (locations.offsetSize, locations.lengthSize),
            offset: range.lowerBound,
            length: range.count
        )
    }

    /// Scan mdat for a TIFF header (fallback when iloc parsing fails)
    private static func scanForTIFFInMdat(boxes: [ISOBMFFBox], fileData: Data) -> Data? {
        guard let mdat = boxes.first(where: { $0.type == "mdat" }) else { return nil }

        let mdatStart = mdat.fileOffset + 8
        let mdatEnd = mdat.fileOffset + mdat.totalSize

        guard mdatEnd <= fileData.count else { return nil }

        // Scan for TIFF header ("II\x2A\x00" or "MM\x00\x2A")
        var offset = mdatStart
        while offset < mdatEnd - 8 {
            let b0 = fileData[fileData.startIndex + offset]
            let b1 = fileData[fileData.startIndex + offset + 1]

            if (b0 == 0x49 && b1 == 0x49) || (b0 == 0x4D && b1 == 0x4D) {
                // Check magic number
                let magic: UInt16
                if b0 == 0x49 {
                    magic = UInt16(fileData[fileData.startIndex + offset + 2]) |
                            UInt16(fileData[fileData.startIndex + offset + 3]) << 8
                } else {
                    magic = UInt16(fileData[fileData.startIndex + offset + 2]) << 8 |
                            UInt16(fileData[fileData.startIndex + offset + 3])
                }

                if magic == 42 {
                    // Found TIFF header — extract up to end of mdat
                    let tiffLength = min(mdatEnd - offset, 65536) // Cap at 64KB for EXIF
                    let start = fileData.startIndex + offset
                    return Data(fileData[start..<start + tiffLength])
                }
            }

            // Also check for "Exif\0\0" prefix
            if b0 == 0x45 && b1 == 0x78 {
                let exifStr = String(data: Data(fileData[(fileData.startIndex + offset)..<(fileData.startIndex + offset + 4)]), encoding: .ascii)
                if exifStr == "Exif" {
                    let tiffStart = offset + 6
                    let tiffLength = min(mdatEnd - tiffStart, 65536)
                    if tiffStart + tiffLength <= fileData.count {
                        let start = fileData.startIndex + tiffStart
                        return Data(fileData[start..<start + tiffLength])
                    }
                }
            }

            offset += 1
        }

        return nil
    }

    /// Repoint the EXIF item's first iloc extent at new data by rewriting its fields in place.
    private static func patchIlocExtent(
        in data: inout Data,
        iloc: ISOBMFFBox,
        location: ExifItemLocation,
        newOffset: UInt64,
        newLength: UInt64
    ) throws {
        // Field positions are relative to payloadData: after the 8-byte box header and 4-byte version/flags
        let payloadStart = data.startIndex + iloc.fileOffset + 12

        func write(_ value: UInt64, size: Int, at position: Int) throws {
            var writer = ByteWriter(byteOrder: .bigEndian)
            switch size {
            case 4 where value <= UInt32.max:
                writer.writeUInt32(UInt32(value))
            case 8:
                writer.writeUInt32(UInt32(value >> 32))
                writer.writeUInt32(UInt32(truncatingIfNeeded: value))
            default:
                throw EXIFError.writeFailed("HEIF: iloc field too small for the new EXIF location")
            }
            let start = payloadStart + position
            data.replaceSubrange(start..<start + size, with: writer.data)
        }

        // Extent offsets are relative to the item's base_offset
        try write(newOffset - location.item.baseOffset, size: location.fieldSizes.offset,
                  at: location.extent.offsetFieldPosition)
        try write(newLength, size: location.fieldSizes.length, at: location.extent.lengthFieldPosition)
    }
}
