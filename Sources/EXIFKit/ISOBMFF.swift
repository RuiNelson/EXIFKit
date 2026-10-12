import Foundation

// MARK: - ISOBMFF Box

/// A parsed ISOBMFF (ISO 14496-12) box.
///
/// ISOBMFF is a hierarchical container format used by HEIF, HEIC, MP4, CR3, etc.
/// Each "box" has:
///   - 4 bytes: size (includes the 8-byte header)
///   - 4 bytes: type (4 ASCII characters, e.g., "ftyp", "moov", "meta")
///   - If size == 1: 8 bytes extended size follows
///   - If size == 0: box extends to end of file
///   - Remaining bytes: box payload (may contain child boxes)
///
/// Some boxes are "full boxes" that have an additional 4-byte version+flags field.
public struct ISOBMFFBox: Sendable {
    /// 4-character box type (e.g., "ftyp", "moov", "meta", "uuid")
    public let type: String

    /// Raw payload data (after the header, not including children)
    public let data: Data

    /// Child boxes (if this is a container box)
    public var children: [ISOBMFFBox]

    /// Offset of this box in the original file
    public let fileOffset: Int

    /// Total size including header
    public let totalSize: Int

    /// Is this a "full box" (has version + flags)?
    public var isFullBox: Bool {
        // These box types are defined as FullBox in the spec
        ["meta", "hdlr", "pitm", "iloc", "iinf", "infe", "ispe", "iref", "ipma"].contains(type)
    }

    /// For full boxes: version byte
    public var version: UInt8? {
        guard isFullBox, data.count >= 4 else { return nil }
        return data[data.startIndex]
    }

    /// For full boxes: flags (3 bytes)
    public var flags: UInt32? {
        guard isFullBox, data.count >= 4 else { return nil }
        return UInt32(data[data.startIndex + 1]) << 16 |
               UInt32(data[data.startIndex + 2]) << 8 |
               UInt32(data[data.startIndex + 3])
    }

    /// Payload data after version+flags for full boxes
    public var payloadData: Data {
        if isFullBox && data.count >= 4 {
            return Data(data.dropFirst(4))
        }
        return data
    }

    // MARK: - Child lookup

    /// Find first child box of a given type
    public func child(ofType type: String) -> ISOBMFFBox? {
        children.first(where: { $0.type == type })
    }

    /// Find all child boxes of a given type
    public func children(ofType type: String) -> [ISOBMFFBox] {
        children.filter({ $0.type == type })
    }

    /// Find a box by path (e.g., "moov/meta/iinf")
    public func find(path: String) -> ISOBMFFBox? {
        let components = path.split(separator: "/").map(String.init)
        var current: ISOBMFFBox? = self
        for component in components {
            current = current?.child(ofType: component)
        }
        return current
    }
}

// MARK: - ISOBMFF Parser

/// Parses ISO Base Media File Format (ISOBMFF) containers.
///
/// Used by:
/// - **HEIF/HEIC**: Apple's default photo format since iPhone 7
/// - **Canon CR3**: Canon's modern RAW format (EOS R series, newer DSLRs)
/// - **AVIF**: AV1 Image File Format
///
/// The parser recursively descends into known container boxes to build
/// a tree structure. Unknown boxes are preserved as opaque blobs.
public struct ISOBMFFParser {

    /// Known container box types that contain child boxes
    private static let containerTypes: Set<String> = [
        "moov", "trak", "mdia", "minf", "stbl", "dinf",
        "meta", "iprp", "ipco", "iref", "edts",
        "iinf",                            // Item info (FullBox + entry_count)
        "uuid",                            // 16-byte UUID prefix before children
    ]

    /// Parse an ISOBMFF file into a list of top-level boxes
    public static func parse(_ data: Data) throws -> [ISOBMFFBox] {
        return try parseBoxes(from: data, offset: 0, length: data.count, depth: 0)
    }

    /// Recursively parse boxes from a data region
    private static func parseBoxes(
        from data: Data,
        offset: Int,
        length: Int,
        depth: Int
    ) throws -> [ISOBMFFBox] {
        // Prevent infinite recursion
        guard depth < 20 else { return [] }

        var boxes: [ISOBMFFBox] = []
        var pos = offset

        while pos < offset + length {
            guard pos + 8 <= data.count else { break }

            // Read box size (4 bytes big-endian)
            let size = Int(
                UInt32(data[data.startIndex + pos]) << 24 |
                UInt32(data[data.startIndex + pos + 1]) << 16 |
                UInt32(data[data.startIndex + pos + 2]) << 8 |
                UInt32(data[data.startIndex + pos + 3])
            )

            // Read box type (4 ASCII bytes)
            let typeData = data[(data.startIndex + pos + 4)..<(data.startIndex + pos + 8)]
            let type = String(data: Data(typeData), encoding: .ascii) ?? "????"

            // Determine actual box size
            var headerSize = 8
            var boxSize: Int

            if size == 1 {
                // Extended size (8 bytes)
                guard pos + 16 <= data.count else { break }
                headerSize = 16
                let extSize = UInt64(data[data.startIndex + pos + 8]) << 56 |
                              UInt64(data[data.startIndex + pos + 9]) << 48 |
                              UInt64(data[data.startIndex + pos + 10]) << 40 |
                              UInt64(data[data.startIndex + pos + 11]) << 32 |
                              UInt64(data[data.startIndex + pos + 12]) << 24 |
                              UInt64(data[data.startIndex + pos + 13]) << 16 |
                              UInt64(data[data.startIndex + pos + 14]) << 8 |
                              UInt64(data[data.startIndex + pos + 15])
                boxSize = Int(clamping: extSize)
            } else if size == 0 {
                // Box extends to end of data
                boxSize = (offset + length) - pos
            } else {
                boxSize = size
            }

            guard boxSize >= headerSize else { break }
            if boxSize > data.count - pos {
                // Truncated box — take what we can
                boxSize = data.count - pos
            }

            // Extract payload
            let payloadStart = pos + headerSize
            let payloadLength = boxSize - headerSize
            let payloadData: Data

            if payloadLength > 0 && payloadStart + payloadLength <= data.count {
                payloadData = Data(data[(data.startIndex + payloadStart)..<(data.startIndex + payloadStart + payloadLength)])
            } else {
                payloadData = Data()
            }

            // Recursively parse children for container boxes
            var children: [ISOBMFFBox] = []
            if containerTypes.contains(type) && payloadLength > 8 {
                // Different box types have different prefixes before child boxes
                let skipBytes: Int
                if type == "meta" || type == "iref" {
                    // FullBox: skip version(1) + flags(3)
                    skipBytes = 4
                } else if type == "iinf" {
                    // FullBox + entry_count: 2 bytes in version 0, 4 bytes after
                    skipBytes = data[data.startIndex + payloadStart] == 0 ? 6 : 8
                } else if type == "uuid" {
                    // UUID identifier prefix (16 bytes) before child boxes
                    skipBytes = 16
                } else {
                    skipBytes = 0
                }

                if payloadLength > skipBytes + 8 {
                    let childOffset = payloadStart + skipBytes
                    let childLength = payloadLength - skipBytes
                    children = (try? parseBoxes(from: data, offset: childOffset, length: childLength, depth: depth + 1)) ?? []
                }
            }

            let box = ISOBMFFBox(
                type: type,
                data: payloadData,
                children: children,
                fileOffset: pos,
                totalSize: boxSize
            )
            boxes.append(box)

            pos += boxSize
        }

        return boxes
    }

    // MARK: - EXIF Extraction from ISOBMFF

    /// Extract EXIF data from an ISOBMFF container.
    ///
    /// EXIF in ISOBMFF is typically stored in one of these locations:
    /// - `meta/iinf` + `meta/iloc` → locate the Exif item → read TIFF data
    /// - Canon CR3: `moov/uuid/CMT1` (IFD0), `CMT2` (EXIF), `CMT3` (MakerNote), `CMT4` (GPS)
    ///
    /// Returns the raw TIFF data block if found.
    public static func extractEXIFData(from boxes: [ISOBMFFBox], fileData: Data) -> Data? {
        // Strategy 1: Look for Exif item in meta box (HEIF style)
        if let exifData = extractFromMetaBox(boxes: boxes, fileData: fileData) {
            return exifData
        }

        // Strategy 2: Look for Canon CR3 metadata boxes
        if let exifData = extractFromCR3(boxes: boxes, fileData: fileData) {
            return exifData
        }

        return nil
    }

    /// HEIF-style: find the Exif item through meta/iloc
    private static func extractFromMetaBox(boxes: [ISOBMFFBox], fileData: Data) -> Data? {
        guard let meta = boxes.first(where: { $0.type == "meta" }),
              let iloc = meta.child(ofType: "iloc"),
              let locations = try? ItemLocations(iloc) else { return nil }

        // 0 = no Exif item declared: try every item and keep the first that holds TIFF data
        let exifItemID = findExifItemID(in: meta)

        for item in locations.items where item.constructionMethod == 0 && (exifItemID == 0 || item.itemID == exifItemID) {
            for extent in item.extents {
                guard let range = item.fileRange(of: extent, fileSize: fileData.count) else { continue }
                let itemData = fileData[(fileData.startIndex + range.lowerBound)..<(fileData.startIndex + range.upperBound)]
                if let tiff = tiffData(inExifItem: itemData) { return tiff }
            }
        }

        return nil
    }

    /// The TIFF block inside an Exif item.
    ///
    /// ISO 23008-12 puts a big-endian UInt32 offset to the TIFF header first (counted from the
    /// end of that field, usually 6 to skip "Exif\0\0"). Some writers, including EXIFKit before
    /// it wrote that field big-endian, need the fallbacks: "Exif\0\0" after the field, bare "Exif\0\0", bare TIFF.
    static func tiffData(inExifItem item: Data) -> Data? {
        let bytes = Data(item)
        func tiff(at i: Int) -> Data? {
            guard i >= 0, i + 8 <= bytes.count, bytes[i] == bytes[i + 1],
                  bytes[i] == 0x49 || bytes[i] == 0x4D else { return nil }
            return bytes.subdata(in: i..<bytes.count)
        }
        var reader = ByteReader(data: bytes, byteOrder: .bigEndian)
        let headerOffset = (try? reader.readUInt32()).map(Int.init) ?? 0
        return tiff(at: 4 + headerOffset) ?? tiff(at: 10) ?? tiff(at: 6) ?? tiff(at: 0)
    }

    /// Find the item ID of the "Exif" item from the iinf box (0 if none)
    static func findExifItemID(in meta: ISOBMFFBox) -> UInt32 {
        guard let iinf = meta.child(ofType: "iinf") else { return 0 }

        // Each infe box describes an item
        for infe in iinf.children(ofType: "infe") {
            // Version 2: item_id(2), version 3: item_id(4); then item_protection_index(2) + item_type(4)
            var reader = ByteReader(data: infe.payloadData, byteOrder: .bigEndian)
            guard let itemID = try? (infe.version ?? 0) >= 3 ? reader.readUInt32() : UInt32(reader.readUInt16()),
                  (try? reader.readUInt16()) != nil,
                  let itemType = try? reader.readBytes(4) else { continue }

            if itemType == Data("Exif".utf8) {
                return itemID
            }
        }

        return 0
    }

    /// Canon CR3: extract TIFF data from CMT boxes
    private static func extractFromCR3(boxes: [ISOBMFFBox], fileData: Data) -> Data? {
        // CR3 stores metadata in moov/uuid/ with Canon-specific boxes:
        // CMT1 = IFD0 (TIFF header + IFD)
        // CMT2 = EXIF IFD
        // CMT3 = Canon MakerNote
        // CMT4 = GPS IFD
        //
        // Each CMT box contains raw TIFF-format IFD data.
        // CMT1 is the primary one that acts as a standard TIFF structure.

        for box in boxes {
            if box.type == "moov" {
                // Search through moov's children for uuid boxes containing CMT data
                for child in box.children {
                    if child.type == "uuid" {
                        // Look for CMT1 in uuid children
                        if let cmt1 = child.child(ofType: "CMT1") {
                            return cmt1.data
                        }
                        // Also check nested structures
                        for grandchild in child.children {
                            if let cmt1 = grandchild.child(ofType: "CMT1") {
                                return cmt1.data
                            }
                        }
                    }
                }
            }
        }

        // Direct search at any level
        return findBoxRecursive(type: "CMT1", in: boxes)?.data
    }

    /// Recursively search for a box type
    private static func findBoxRecursive(type: String, in boxes: [ISOBMFFBox]) -> ISOBMFFBox? {
        for box in boxes {
            if box.type == type { return box }
            if let found = findBoxRecursive(type: type, in: box.children) {
                return found
            }
        }
        return nil
    }
}

// MARK: - Item Locations (iloc)

/// A parsed `iloc` box: where each item's bytes live.
struct ItemLocations {
    struct Extent {
        let offset: UInt64
        let length: UInt64
        /// Positions of the offset/length fields within the iloc box's `payloadData`, for in-place patching
        let offsetFieldPosition: Int
        let lengthFieldPosition: Int
    }

    struct Item {
        let itemID: UInt32
        /// 0 = file offsets, 1 = offsets into `idat`, 2 = item references
        let constructionMethod: UInt16
        let baseOffset: UInt64
        let extents: [Extent]

        /// The extent's byte range in the file, or nil if it doesn't fit within `fileSize`
        func fileRange(of extent: Extent, fileSize: Int) -> Range<Int>? {
            let (start, overflow) = baseOffset.addingReportingOverflow(extent.offset)
            guard !overflow, start <= UInt64(fileSize), extent.length <= UInt64(fileSize) - start else { return nil }
            return Int(start)..<Int(start + extent.length)
        }
    }

    /// Byte widths of the extent offset/length fields (0, 4 or 8)
    let offsetSize: Int
    let lengthSize: Int
    let items: [Item]

    init(_ iloc: ISOBMFFBox) throws {
        let version = iloc.version ?? 0
        var reader = ByteReader(data: iloc.payloadData, byteOrder: .bigEndian)
        let sizes = try reader.readByte()
        let moreSizes = try reader.readByte()
        let offsetSize = Int(sizes >> 4)
        let lengthSize = Int(sizes & 0x0F)
        let baseOffsetSize = Int(moreSizes >> 4)
        let indexSize = version >= 1 ? Int(moreSizes & 0x0F) : 0 // reserved in version 0

        func read(_ size: Int) throws -> UInt64 {
            switch size {
            case 0: return 0
            case 4: return UInt64(try reader.readUInt32())
            case 8: return try UInt64(reader.readUInt32()) << 32 | UInt64(reader.readUInt32())
            default: throw EXIFError.invalidHEIF("Invalid iloc field size \(size)")
            }
        }

        let itemCount = try version < 2 ? Int(reader.readUInt16()) : Int(reader.readUInt32())
        var items: [Item] = []
        for _ in 0..<itemCount {
            let itemID = try version < 2 ? UInt32(reader.readUInt16()) : reader.readUInt32()
            let constructionMethod = try version >= 1 ? reader.readUInt16() & 0x0F : 0
            _ = try reader.readUInt16() // data_reference_index
            let baseOffset = try read(baseOffsetSize)
            let extentCount = Int(try reader.readUInt16())

            var extents: [Extent] = []
            for _ in 0..<extentCount {
                _ = try read(indexSize) // extent_index
                let offsetPosition = reader.offset
                let offset = try read(offsetSize)
                let lengthPosition = reader.offset
                let length = try read(lengthSize)
                extents.append(Extent(offset: offset, length: length,
                                      offsetFieldPosition: offsetPosition, lengthFieldPosition: lengthPosition))
            }
            items.append(Item(itemID: itemID, constructionMethod: constructionMethod,
                              baseOffset: baseOffset, extents: extents))
        }

        self.offsetSize = offsetSize
        self.lengthSize = lengthSize
        self.items = items
    }
}
