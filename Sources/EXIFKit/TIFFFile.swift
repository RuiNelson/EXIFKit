import Foundation

// MARK: - TIFF File Container

/// Reads and writes EXIF metadata from standalone TIFF, DNG, and TIFF-based RAW files.
///
/// Write strategy (in place where possible, so saves don't grow the file):
/// 1. Each IFD's out-of-line values that are unchanged keep pointing at their original
///    bytes. Only new or changed values are appended. This also keeps MakerNotes at their
///    original offset, where any absolute offsets inside them stay valid.
/// 2. Each IFD's entry table is rewritten in its original slot when it fits, and appended
///    (with its pointer or the TIFF header updated) when it has grown.
/// 3. Image data offsets (StripOffsets, TileOffsets) are never touched.
public struct TIFFFileContainer {

    // Tags that reference image data — we must never modify these
    private static let imageDataTags: Set<UInt16> = [
        0x0111, // StripOffsets
        0x0117, // StripByteCounts
        0x0144, // TileOffsets
        0x0145, // TileByteCounts
        0x0201, // JPEGInterchangeFormat (thumbnail offset)
        0x0202, // JPEGInterchangeFormatLength
    ]

    // MARK: - Reading

    public static func readEXIF(from data: Data) throws -> TIFFStructure {
        return try TIFFParser.parse(data)
    }

    // MARK: - Writing

    public static func writeEXIF(_ structure: TIFFStructure, to originalData: Data) throws -> Data {
        let originalStructure = try TIFFParser.parse(originalData)
        return try writeEXIFInternal(structure, to: originalData, originalStructure: originalStructure)
    }

    /// Internal write that accepts a pre-parsed original structure.
    /// Used by RAWContainer for formats with non-standard TIFF magic (ORF, RW2).
    internal static func writeEXIFInternal(
        _ structure: TIFFStructure,
        to originalData: Data,
        originalStructure original: TIFFStructure
    ) throws -> Data {
        var data = originalData
        let byteOrder = structure.byteOrder

        var reader = ByteReader(data: data, byteOrder: byteOrder)
        try reader.seek(to: 4)
        let ifd0Offset = Int(try reader.readUInt32())

        var newIFD0 = structure.ifd0
        // Preserve all image-data tags from the original
        for tag in imageDataTags {
            if let entry = original.ifd0.entry(for: tag) {
                newIFD0.set(tagID: tag, value: entry.value)
            }
        }
        // Preserve next-IFD offset (IFD1 for thumbnail)
        newIFD0.nextIFDOffset = original.ifd0.nextIFDOffset

        // Sub-IFDs first: IFD0 holds their pointers
        for (pointerTag, ifd, originalIFD) in [
            (Tag.exifIFDPointer, structure.exifIFD, original.exifIFD),
            (Tag.gpsIFDPointer, structure.gpsIFD, original.gpsIFD),
        ] {
            guard let ifd else {
                newIFD0.remove(tagID: pointerTag)
                continue
            }
            let originalOffset = original.ifd0.value(for: pointerTag)?.uint32Value.map(Int.init)
            let previous = originalIFD.flatMap { o in originalOffset.map { (ifd: o, offset: $0) } }
            let offset = try place(ifd, replacing: previous, in: &data, byteOrder: byteOrder)
            newIFD0.set(tagID: pointerTag, value: .long(offset))
        }

        let newIFD0Offset = try place(newIFD0, replacing: (original.ifd0, ifd0Offset), in: &data, byteOrder: byteOrder)
        if Int(newIFD0Offset) != ifd0Offset {
            // Patch the TIFF header to point to the new IFD0 (bytes 4-7)
            var writer = ByteWriter(byteOrder: byteOrder)
            writer.writeUInt32(newIFD0Offset)
            data.replaceSubrange((data.startIndex + 4)..<(data.startIndex + 8), with: writer.data)
        }

        return data
    }

    /// Write `ifd` over the IFD it replaces: unchanged values keep their original bytes, and the
    /// entry table reuses the original slot if it fits. Returns where the table ended up.
    private static func place(
        _ ifd: IFD,
        replacing original: (ifd: IFD, offset: Int)?,
        in data: inout Data,
        byteOrder: ByteOrder
    ) throws -> UInt32 {
        var existing: [UInt16: (value: TagValue, range: Range<Int>)] = [:]
        var slot: Range<Int>? = nil
        if let original, let layout = try? IFDLayout(in: data, at: original.offset, byteOrder: byteOrder) {
            slot = layout.table
            for entry in original.ifd.entries {
                if let range = layout.values[entry.tagID] { existing[entry.tagID] = (entry.value, range) }
            }
        }

        // TIFF requires word-aligned IFDs and values; IFDWriter output is even-sized
        let appendOffset = data.count + data.count % 2
        let tableSize = 2 + 12 * ifd.entries.count + 4
        let inPlace = slot.map { tableSize <= $0.count } ?? false
        let tableOffset = inPlace ? slot!.lowerBound : appendOffset
        let (table, overflow) = IFDWriter.writeIFD(
            ifd,
            overflowOffset: UInt32(inPlace ? appendOffset : appendOffset + tableSize),
            byteOrder: byteOrder,
            existing: existing
        )

        var appended = overflow
        if let slot, inPlace {
            let start = data.startIndex + slot.lowerBound
            data.replaceSubrange(start..<start + slot.count, with: table + Data(count: slot.count - table.count))
        } else {
            appended = table + overflow
        }
        if !appended.isEmpty {
            if data.count < appendOffset { data.append(0) }
            data.append(appended)
        }
        return UInt32(tableOffset)
    }

    // MARK: - Scrubbing

    /// Zero an IFD's entry table and its out-of-line values.
    ///
    /// Rewrites only unlink old IFDs, so their bytes stay in the file; strip uses this
    /// so removed metadata (e.g. GPS) can't be recovered from dead space.
    static func zeroIFD(in data: inout Data, at ifdOffset: Int, byteOrder: ByteOrder) throws {
        let layout = try IFDLayout(in: data, at: ifdOffset, byteOrder: byteOrder)
        for range in [layout.table] + layout.values.values {
            data.resetBytes(in: (data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound))
        }
    }
}

// MARK: - IFD Layout

/// Where an IFD's entry table and out-of-line values sit in the data.
struct IFDLayout {
    let table: Range<Int>
    /// Out-of-line value bytes by tag (values of 4 bytes or less live inside the table)
    var values: [UInt16: Range<Int>] = [:]

    init(in data: Data, at offset: Int, byteOrder: ByteOrder) throws {
        var reader = ByteReader(data: data, byteOrder: byteOrder)
        try reader.seek(to: offset)
        let entryCount = Int(try reader.readUInt16())
        table = offset..<offset + 2 + entryCount * 12 + 4
        guard table.upperBound <= data.count else {
            throw EXIFError.corruptedIFD("IFD table at \(offset) extends past end of data")
        }
        for _ in 0..<entryCount {
            let tag = try reader.readUInt16()
            let type = EXIFDataType(rawValue: try reader.readUInt16())
            let size = Int(try reader.readUInt32()) * (type?.unitSize ?? 0)
            let valueOffset = Int(try reader.readUInt32())
            if size > 4, valueOffset + size <= data.count {
                values[tag] = valueOffset..<valueOffset + size
            }
        }
    }
}
