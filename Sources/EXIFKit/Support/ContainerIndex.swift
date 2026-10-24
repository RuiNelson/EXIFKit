import Foundation

/// Box locations only: media payloads are never retained in the index.
struct BoxReference: Sendable {
    let type: String
    let start: UInt64
    let end: UInt64
    let payload: UInt64
    var children: [BoxReference]
    var length: UInt64 {
        end - payload
    }

    func first(_ type: String) -> BoxReference? {
        if self.type == type {
            return self
        }
        for child in children {
            if let box = child.first(type) {
                return box
            }
        }
        return nil
    }
}

extension HandleParser {
    static func boxes(
        _ file: FileRegion, start: UInt64 = 0, end: UInt64? = nil,
        depth: Int = 0
    ) async throws -> [BoxReference] {
        guard depth < 16 else { throw EXIFError.invalidHEIF("Box nesting too deep") }
        let end = end ?? file.length
        var position = start
        var result: [BoxReference] = []
        while position < end {
            guard end - position >= 8 else { throw EXIFError.invalidHEIF("Truncated box header") }
            var header = try ByteReader(data: await file.read(at: position, count: 8))
            let size = try header.readUInt32()
            let type = try header.readASCII(4)
            var headerSize: UInt64 = 8
            var length = UInt64(size)
            if size == 1 {
                guard end - position >= 16 else { throw EXIFError.invalidHEIF("Truncated extended box header") }
                var extended = try ByteReader(data: await file.read(at: position + 8, count: 8))
                length = try UInt64(extended.readUInt32()) << 32 | UInt64(extended.readUInt32())
                headerSize = 16
            } else if size == 0 {
                length = end - position
            }
            guard length >= headerSize, length <= end - position else {
                throw EXIFError.invalidHEIF("Invalid box size for \(type)")
            }
            let payload = position + headerSize
            var childStart: UInt64?
            switch type {
            case "moov": childStart = payload
            case "meta":
                guard length - headerSize >= 4 else { throw EXIFError.invalidHEIF("Truncated meta box") }
                childStart = payload + 4
            case "iinf":
                guard length - headerSize >= 6 else { throw EXIFError.invalidHEIF("Truncated iinf") }
                let version = try await file.read(at: payload, count: 1)[0]
                childStart = payload + (version == 0 ? 6 : 8)
            case "uuid":
                if length - headerSize >= 16,
                   try await file.read(at: payload, count: 16) == CR3Container.canonUUID
                {
                    childStart = payload + 16
                }
            default: break
            }
            var children: [BoxReference] = []
            if let childStart {
                guard childStart <= position + length else { throw EXIFError.invalidHEIF("Truncated container") }
                children = try await boxes(file, start: childStart, end: position + length, depth: depth + 1)
            }
            result.append(
                BoxReference(type: type, start: position, end: position + length, payload: payload, children: children)
            )
            position += length
        }
        return result
    }

    struct HEIFInfo {
        let tiff: FileRegion
        let itemRegion: FileRegion
        let ranges: [Range<UInt64>]
        let item: ItemLocations.Item
        let locations: ItemLocations
        let iloc: BoxReference
        let boxes: [BoxReference]
    }

    static func heif(_ file: FileRegion, parseTIFF: Bool = true) async throws -> HEIFInfo {
        let index = try await boxes(file)
        guard let meta = index.first(where: { $0.type == "meta" }),
              let iloc = meta.children.first(where: { $0.type == "iloc" }),
              let iinf = meta.children.first(where: { $0.type == "iinf" })
        else {
            throw EXIFError.invalidHEIF("No meta/iinf/iloc metadata index")
        }
        var exifID: UInt32?
        for infe in iinf.children where infe.type == "infe" {
            // Only the fixed header is needed; item names can be arbitrarily long.
            guard infe.length >= 12 else { continue }
            var reader = try ByteReader(data: await file.read(at: infe.payload, count: Int(min(infe.length, 16))))
            let version = try reader.readByte()
            guard version == 2 || version == 3 else { continue }
            reader.offset = 4
            let id = try version == 3 ? reader.readUInt32() : UInt32(reader.readUInt16())
            _ = try reader.readUInt16()
            if try reader.readASCII(4) == "Exif" {
                exifID = id
                break
            }
        }
        guard let exifID else { throw EXIFError.invalidHEIF("No Exif item declared") }
        guard iloc.length <= 10 * 1024 * 1024 else { throw EXIFError.resourceLimitExceeded }
        let bytes = try await file.read(at: iloc.payload, count: Int(iloc.length))
        let locations = try ItemLocations(data: bytes)
        guard let item = locations.items.first(where: { $0.itemID == exifID }),
              item.dataReferenceIndex == 0, !item.extents.isEmpty
        else {
            throw EXIFError.invalidHEIF("Missing or external Exif item")
        }
        let base: UInt64
        let bound: UInt64
        switch item.constructionMethod {
        case 0:
            base = 0
            bound = file.length
        case 1:
            guard let idat = meta.children.first(where: { $0.type == "idat" }) else {
                throw EXIFError.invalidHEIF("Missing idat")
            }
            base = idat.payload
            bound = idat.end
        default: throw EXIFError.invalidHEIF("Unsupported Exif item construction method")
        }
        var ranges: [Range<UInt64>] = []
        for extent in item.extents {
            let (relative, overflow) = item.baseOffset.addingReportingOverflow(extent.offset)
            guard !overflow, relative <= bound - base else { throw EXIFError.invalidHEIF("Invalid item offset") }
            let start = base + relative
            guard extent.length > 0, extent.length <= bound - start else {
                throw EXIFError.invalidHEIF("Invalid item extent")
            }
            ranges.append(start ..< start + extent.length)
        }
        let region = try FileRegion(file, ranges: ranges)
        let tiff = try await parseTIFF ? exifTIFF(region) : region
        return HEIFInfo(
            tiff: tiff, itemRegion: region, ranges: ranges, item: item, locations: locations, iloc: iloc, boxes: index
        )
    }

    static func exifTIFF(_ region: FileRegion) async throws -> FileRegion {
        guard region.length >= 8 else { throw EXIFError.invalidHEIF("Truncated Exif item") }
        var prefix = try ByteReader(data: await region.read(at: 0, count: 4))
        let offset = try UInt64(prefix.readUInt32())
        var tried: Set<UInt64> = []
        for start in [4 + offset, 10, 6, 0] where tried.insert(start).inserted {
            guard start <= region.length, region.length - start >= 8 else { continue }
            let header = try await region.read(at: start, count: 4)
            if header == Data([0x49, 0x49, 42, 0]) || header == Data([0x4D, 0x4D, 0, 42]) {
                return try region.slice(at: start, length: region.length - start)
            }
        }
        throw EXIFError.invalidHEIF("No TIFF header in Exif item")
    }

    static func cr3(_ file: FileRegion) async throws -> TIFFStructure {
        let index = try await boxes(file)
        guard let moov = index.first(where: { $0.type == "moov" }), let cmt1 = moov.first("CMT1") else {
            throw EXIFError.invalidCR3("No CMT1 metadata box")
        }
        var result = try await tiff(file.slice(at: cmt1.payload, length: cmt1.length))
        if let cmt2 = moov.first("CMT2") {
            let exif = try await tiff(file.slice(at: cmt2.payload, length: cmt2.length))
            result.exifIFD = exif.ifd0
            result.interopIFD = exif.interopIFD
        }
        if let cmt4 = moov.first("CMT4") {
            result.gpsIFD = try await tiff(file.slice(at: cmt4.payload, length: cmt4.length)).ifd0
        }
        return result
    }
}
