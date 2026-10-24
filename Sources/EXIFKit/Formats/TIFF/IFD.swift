import Foundation

// MARK: - IFD Entry

/// A single entry in an Image File Directory.
///
/// Each IFD entry is exactly 12 bytes on disk:
///   - 2 bytes: tag ID
///   - 2 bytes: data type
///   - 4 bytes: count (number of values, not bytes)
///   - 4 bytes: value or offset to value (if total size > 4 bytes)
public struct IFDEntry: Sendable {
    public let tagID: UInt16
    public let dataType: EXIFDataType
    public let count: UInt32
    public var value: TagValue

    /// Human-readable tag name
    public var tagName: String {
        Tag.name(for: tagID)
    }

    public init(tagID: UInt16, value: TagValue) {
        self.tagID = tagID
        dataType = value.dataType
        count = value.count
        self.value = value
    }

    init(tagID: UInt16, dataType: EXIFDataType, count: UInt32, value: TagValue) {
        self.tagID = tagID
        self.dataType = dataType
        self.count = count
        self.value = value
    }
}

// MARK: - IFD (Image File Directory)

/// A parsed IFD — an ordered collection of tag entries.
///
/// EXIF metadata is organized as a tree of IFDs:
///   IFD0 (main image)
///     → EXIF sub-IFD (camera settings)
///       → GPS sub-IFD (location)
///     → IFD1 (thumbnail)
public struct IFD: Sendable {
    /// The entries in tag-ID order
    public var entries: [IFDEntry]

    /// Offset to the next IFD (0 = no next IFD)
    public var nextIFDOffset: UInt32

    public init(entries: [IFDEntry] = [], nextIFDOffset: UInt32 = 0) {
        self.entries = entries
        self.nextIFDOffset = nextIFDOffset
    }

    // MARK: - Lookup

    /// Find an entry by tag ID
    public func entry(for tagID: UInt16) -> IFDEntry? {
        entries.first(where: { $0.tagID == tagID })
    }

    /// Get the value of a tag
    public func value(for tagID: UInt16) -> TagValue? {
        entry(for: tagID)?.value
    }

    // MARK: - Mutation

    /// Set or replace a tag value. Inserts in tag-ID order if new.
    public mutating func set(tagID: UInt16, value: TagValue) {
        if let index = entries.firstIndex(where: { $0.tagID == tagID }) {
            entries[index] = IFDEntry(tagID: tagID, value: value)
        } else {
            let entry = IFDEntry(tagID: tagID, value: value)
            // Insert in sorted order by tag ID (TIFF spec requires this)
            if let insertIndex = entries.firstIndex(where: { $0.tagID > tagID }) {
                entries.insert(entry, at: insertIndex)
            } else {
                entries.append(entry)
            }
        }
    }

    /// Remove a tag
    @discardableResult
    public mutating func remove(tagID: UInt16) -> IFDEntry? {
        if let index = entries.firstIndex(where: { $0.tagID == tagID }) {
            return entries.remove(at: index)
        }
        return nil
    }
}

// MARK: - IFD Reader

/// Reads IFD structures from raw TIFF data.
public enum IFDReader {
    public static func readIFD(
        from source: any AbstractFileHandle, at offset: UInt64,
        byteOrder: ByteOrder, options: ReadOptions = ReadOptions()
    ) async throws -> IFD {
        let size = try await source.size
        let reader = MetadataReader(source, size: size, options: options)
        return try await HandleParser.ifd(FileRegion(reader, offset: 0, length: size), at: offset, order: byteOrder)
    }

    public static func readIFD(from data: Data, at offset: Int, byteOrder: ByteOrder) async throws -> IFD {
        guard offset >= 0 else { throw EXIFError.invalidOffset(offset, dataSize: data.count) }
        return try await readIFD(from: InMemoryFileHandle(data: data), at: UInt64(offset), byteOrder: byteOrder)
    }

    /// Parse raw bytes into a TagValue based on the declared type and count
    static func parseValue(
        data: Data,
        type: EXIFDataType,
        count: UInt32,
        byteOrder: ByteOrder
    ) throws -> TagValue {
        var reader = ByteReader(data: data, byteOrder: byteOrder)

        switch type {
        case .byte:
            if count == 1 {
                return try .byte(reader.readByte())
            } else {
                var bytes: [UInt8] = []
                for _ in 0 ..< count {
                    try bytes.append(reader.readByte())
                }
                return .bytes(bytes)
            }

        case .ascii:
            return try .ascii(reader.readASCII(Int(count)))

        case .short:
            if count == 1 {
                return try .short(reader.readUInt16())
            } else {
                var values: [UInt16] = []
                for _ in 0 ..< count {
                    try values.append(reader.readUInt16())
                }
                return .shorts(values)
            }

        case .long:
            if count == 1 {
                return try .long(reader.readUInt32())
            } else {
                var values: [UInt32] = []
                for _ in 0 ..< count {
                    try values.append(reader.readUInt32())
                }
                return .longs(values)
            }

        case .rational:
            if count == 1 {
                return try .rational(reader.readURational())
            } else {
                var values: [URational] = []
                for _ in 0 ..< count {
                    try values.append(reader.readURational())
                }
                return .rationals(values)
            }

        case .srational:
            if count == 1 {
                return try .srational(reader.readSRational())
            } else {
                var values: [SRational] = []
                for _ in 0 ..< count {
                    try values.append(reader.readSRational())
                }
                return .srationals(values)
            }

        case .slong:
            if count == 1 {
                return try .signedLong(reader.readInt32())
            } else {
                var values: [Int32] = []
                for _ in 0 ..< count {
                    try values.append(reader.readInt32())
                }
                return .signedLongs(values)
            }

        case .sbyte:
            if count == 1 {
                return try .signedByte(Int8(bitPattern: reader.readByte()))
            } else {
                var values: [Int8] = []
                for _ in 0 ..< count {
                    try values.append(Int8(bitPattern: reader.readByte()))
                }
                return .signedBytes(values)
            }

        case .sshort:
            if count == 1 {
                return try .signedShort(Int16(bitPattern: reader.readUInt16()))
            } else {
                var values: [Int16] = []
                for _ in 0 ..< count {
                    try values.append(Int16(bitPattern: reader.readUInt16()))
                }
                return .signedShorts(values)
            }

        case .float:
            if count == 1 {
                let bits = try reader.readUInt32()
                return .float(Float(bitPattern: bits))
            } else {
                var values: [Float] = []
                for _ in 0 ..< count {
                    let bits = try reader.readUInt32()
                    values.append(Float(bitPattern: bits))
                }
                return .floats(values)
            }

        case .double:
            if count == 1 {
                let rawBytes = try reader.readBytes(8)
                let bits = rawBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                let ordered = reader.byteOrder == .littleEndian ? UInt64(littleEndian: bits) : UInt64(bigEndian: bits)
                return .double(Swift.Double(bitPattern: ordered))
            } else {
                var values: [Swift.Double] = []
                for _ in 0 ..< count {
                    let rawBytes = try reader.readBytes(8)
                    let bits = rawBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                    let ordered =
                        reader.byteOrder == .littleEndian ? UInt64(littleEndian: bits) : UInt64(bigEndian: bits)
                    values.append(Swift.Double(bitPattern: ordered))
                }
                return .doubles(values)
            }

        case .undefined:
            return .undefined(data.prefix(Int(count)))
        }
    }
}

// MARK: - IFD Writer

/// Serializes IFD structures back into TIFF-compatible bytes.
///
/// The writing strategy: all entries are written as 12-byte records.
/// Values that fit in 4 bytes go inline; larger values go into an overflow
/// area that follows the IFD entries.
public enum IFDWriter {
    /// Serialize an IFD to bytes.
    ///
    /// - Parameters:
    ///   - ifd: The IFD to write
    ///   - baseOffset: The absolute offset in the TIFF file where this IFD will be placed.
    ///     Needed to calculate correct value offsets.
    ///   - byteOrder: Endianness
    /// - Returns: The serialized bytes
    public static func writeIFD(
        _ ifd: IFD,
        baseOffset: UInt32,
        byteOrder: ByteOrder
    ) -> Data {
        // The overflow area starts after:
        //   2 bytes (entry count) + 12 bytes * entryCount + 4 bytes (next IFD offset)
        let overflowStart = baseOffset + 2 + UInt32(ifd.entries.count) * 12 + 4
        let (table, overflow) = writeIFD(ifd, overflowOffset: overflowStart, byteOrder: byteOrder)
        return table + overflow
    }

    /// Serialize the entry table and the overflow area separately, for callers that place them apart.
    ///
    /// - Parameter existing: Values already present in the target data, by tag. An entry whose value
    ///   is unchanged (and fits) points at those bytes instead of being copied into the overflow area.
    static func writeIFD(
        _ ifd: IFD,
        overflowOffset: UInt32,
        byteOrder: ByteOrder,
        existing: [UInt16: (value: TagValue, range: Range<Int>)] = [:]
    ) -> (table: Data, overflow: Data) {
        var writer = ByteWriter(byteOrder: byteOrder)
        var overflowWriter = ByteWriter(byteOrder: byteOrder)

        writer.writeUInt16(UInt16(ifd.entries.count))

        for entry in ifd.entries {
            writer.writeUInt16(entry.tagID)
            writer.writeUInt16(entry.value.dataType.rawValue)
            writer.writeUInt32(entry.value.count)

            let valueBytes = serializeValue(entry.value, byteOrder: byteOrder)

            if valueBytes.count <= 4 {
                // Inline: pad to 4 bytes
                writer.writeBytes(valueBytes)
                for _ in 0 ..< (4 - valueBytes.count) {
                    writer.writeByte(0)
                }
            } else if let old = existing[entry.tagID], old.value == entry.value, valueBytes.count <= old.range.count {
                // Unchanged value: keep pointing at the bytes already there
                writer.writeUInt32(UInt32(old.range.lowerBound))
            } else {
                // Write offset to overflow area
                writer.writeUInt32(overflowOffset + UInt32(overflowWriter.count))
                overflowWriter.writeBytes(valueBytes)
                overflowWriter.padToEven()
            }
        }

        writer.writeUInt32(ifd.nextIFDOffset)

        return (writer.data, overflowWriter.data)
    }

    /// Serialize a TagValue to raw bytes
    public static func serializeValue(_ value: TagValue, byteOrder: ByteOrder) -> Data {
        var w = ByteWriter(byteOrder: byteOrder)

        switch value {
        case let .byte(v):
            w.writeByte(v)
        case let .bytes(v):
            w.writeBytes(v)
        case let .ascii(v):
            // Must match TagValue.count (UTF-8 length + NUL), or the entry's count lies about its bytes.
            w.writeBytes(Data(v.utf8))
            w.writeByte(0)
        case let .short(v):
            w.writeUInt16(v)
        case let .shorts(v):
            for s in v {
                w.writeUInt16(s)
            }
        case let .long(v):
            w.writeUInt32(v)
        case let .longs(v):
            for l in v {
                w.writeUInt32(l)
            }
        case let .rational(v):
            w.writeURational(v)
        case let .rationals(v):
            for r in v {
                w.writeURational(r)
            }
        case let .srational(v):
            w.writeSRational(v)
        case let .srationals(v):
            for r in v {
                w.writeSRational(r)
            }
        case let .signedByte(v):
            w.writeByte(UInt8(bitPattern: v))
        case let .signedBytes(v):
            for b in v {
                w.writeByte(UInt8(bitPattern: b))
            }
        case let .signedShort(v):
            w.writeUInt16(UInt16(bitPattern: v))
        case let .signedShorts(v):
            for s in v {
                w.writeUInt16(UInt16(bitPattern: s))
            }
        case let .signedLong(v):
            w.writeInt32(v)
        case let .signedLongs(v):
            for l in v {
                w.writeInt32(l)
            }
        case let .float(v):
            w.writeUInt32(v.bitPattern)
        case let .floats(v):
            for f in v {
                w.writeUInt32(f.bitPattern)
            }
        case let .double(v):
            let bits = v.bitPattern
            let ordered = w.byteOrder == .littleEndian ? bits.littleEndian : bits.bigEndian
            withUnsafeBytes(of: ordered) { w.writeBytes(Data($0)) }
        case let .doubles(v):
            for d in v {
                let bits = d.bitPattern
                let ordered = w.byteOrder == .littleEndian ? bits.littleEndian : bits.bigEndian
                withUnsafeBytes(of: ordered) { w.writeBytes(Data($0)) }
            }
        case let .undefined(v):
            w.writeBytes(v)
        }

        return w.data
    }
}
