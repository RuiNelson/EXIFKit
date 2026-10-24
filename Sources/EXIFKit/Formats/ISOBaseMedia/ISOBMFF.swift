import Foundation

/// A box index with offsets and children; payload bytes are not loaded.
public struct ISOBMFFBox: Sendable {
    public let type: String
    public let fileOffset: UInt64
    public let totalSize: UInt64
    public let payloadOffset: UInt64
    public let children: [ISOBMFFBox]
    init(_ box: BoxReference) {
        type = box.type
        fileOffset = box.start
        totalSize = box.end - box.start
        payloadOffset = box.payload
        children = box.children.map(ISOBMFFBox.init)
    }

    public func child(ofType type: String) -> ISOBMFFBox? {
        children.first { $0.type == type }
    }
}

public enum ISOBMFFParser {
    public static func parse(_ source: any AbstractFileHandle) async throws -> [ISOBMFFBox] {
        let size = try await source.size
        let reader = MetadataReader(source, size: size, options: ReadOptions())
        let file = try FileRegion(reader, offset: 0, length: size)
        return try await HandleParser.boxes(file).map(ISOBMFFBox.init)
    }

    public static func parse(_ data: Data) async throws -> [ISOBMFFBox] {
        try await parse(InMemoryFileHandle(data: data))
    }
}

struct ItemLocations {
    struct Extent {
        let offset: UInt64
        let length: UInt64
        /// Positions of the offset/length fields within the iloc box's complete payload, for in-place patching
        let offsetFieldPosition: Int
        let lengthFieldPosition: Int
    }

    struct Item {
        let itemID: UInt32
        /// 0 = file offsets, 1 = offsets into `idat`, 2 = item references
        let constructionMethod: UInt16
        let constructionMethodFieldPosition: Int?
        let dataReferenceIndex: UInt16
        let baseOffset: UInt64
        let extents: [Extent]
    }

    /// Byte widths of the extent offset/length fields (0, 4 or 8)
    let offsetSize: Int
    let lengthSize: Int
    let items: [Item]

    init(data: Data) throws {
        var reader = ByteReader(data: data, byteOrder: .bigEndian)
        let version = try reader.readByte()
        guard version <= 2 else { throw EXIFError.invalidHEIF("Unsupported iloc version") }
        reader.offset = 4
        let sizes = try reader.readByte()
        let moreSizes = try reader.readByte()
        let offsetSize = Int(sizes >> 4)
        let lengthSize = Int(sizes & 0x0F)
        let baseOffsetSize = Int(moreSizes >> 4)
        let indexSize = version >= 1 ? Int(moreSizes & 0x0F) : 0 // reserved in version 0

        func read(_ size: Int) throws -> UInt64 {
            switch size {
            case 0: return 0
            case 4: return try UInt64(reader.readUInt32())
            case 8: return try UInt64(reader.readUInt32()) << 32 | UInt64(reader.readUInt32())
            default: throw EXIFError.invalidHEIF("Invalid iloc field size \(size)")
            }
        }

        let itemCount = try version < 2 ? Int(reader.readUInt16()) : Int(reader.readUInt32())
        var items: [Item] = []
        for _ in 0 ..< itemCount {
            let itemID = try version < 2 ? UInt32(reader.readUInt16()) : reader.readUInt32()
            let constructionMethodFieldPosition = version >= 1 ? reader.offset : nil
            let constructionMethod = try version >= 1 ? reader.readUInt16() & 0x0F : 0
            let dataReferenceIndex = try reader.readUInt16()
            let baseOffset = try read(baseOffsetSize)
            let extentCount = try Int(reader.readUInt16())

            var extents: [Extent] = []
            for _ in 0 ..< extentCount {
                _ = try read(indexSize) // extent_index
                let offsetPosition = reader.offset
                let offset = try read(offsetSize)
                let lengthPosition = reader.offset
                let length = try read(lengthSize)
                extents.append(
                    Extent(
                        offset: offset, length: length,
                        offsetFieldPosition: offsetPosition, lengthFieldPosition: lengthPosition
                    )
                )
            }
            items.append(
                Item(
                    itemID: itemID, constructionMethod: constructionMethod,
                    constructionMethodFieldPosition: constructionMethodFieldPosition,
                    dataReferenceIndex: dataReferenceIndex,
                    baseOffset: baseOffset, extents: extents
                )
            )
        }

        self.offsetSize = offsetSize
        self.lengthSize = lengthSize
        self.items = items
    }
}
