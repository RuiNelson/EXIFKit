import Foundation

extension EditPlanner {
    struct Layout {
        let table: Range<UInt64>
        let values: [UInt16: Range<UInt64>]
    }

    static func layout(_ file: FileRegion, at offset: UInt64, order: ByteOrder) async throws -> Layout {
        var count = try ByteReader(data: await file.read(at: offset, count: 2), byteOrder: order)
        let entries = try Int(count.readUInt16())
        guard entries < 1000 else { throw EXIFError.corruptedIFD("Too many directory entries") }
        let length = 2 + entries * 12 + 4
        var table = try ByteReader(data: await file.read(at: offset, count: length), byteOrder: order)
        table.offset = 2
        var values: [UInt16: Range<UInt64>] = [:]
        for _ in 0 ..< entries {
            let tag = try table.readUInt16()
            let type = try EXIFDataType(rawValue: table.readUInt16())
            let count = try UInt64(table.readUInt32())
            let start = try UInt64(table.readUInt32())
            let size = count * UInt64(type?.unitSize ?? 0)
            if size > 4 {
                guard start <= file.length, size <= file.length - start else {
                    throw EXIFError.corruptedIFD("Invalid value range")
                }
                values[tag] = start ..< start + size
            }
        }
        return Layout(table: offset ..< offset + UInt64(length), values: values)
    }

    static func tiff(_ file: FileRegion, structure: TIFFStructure?, raw: Bool) async throws -> [FileEdit] {
        let original = try await HandleParser.tiff(file, raw: raw)
        var updated = structure ?? original
        guard updated.byteOrder == original.byteOrder else {
            throw EXIFError.writeFailed("Cannot change TIFF byte order in place")
        }
        if structure == nil {
            updated.exifIFD = nil
            updated.gpsIFD = nil
            updated.interopIFD = nil
            updated.ifd0.remove(tagID: Tag.exifIFDPointer)
            updated.ifd0.remove(tagID: Tag.gpsIFDPointer)
        }
        for directory in [updated.ifd0, updated.ifd1, updated.exifIFD, updated.gpsIFD, updated.interopIFD]
            .compactMap({ $0 })
        {
            guard directory.entries.count < 1000 else { throw EXIFError.writeFailed("Too many IFD entries") }
        }
        let order = original.byteOrder
        var header = try ByteReader(data: await file.read(at: 4, count: 4), byteOrder: order)
        let ifd0Offset = try UInt64(header.readUInt32())
        var edits: [FileEdit] = []
        var appended = Data()
        guard file.length <= UInt64(UInt32.max) else {
            throw EXIFError.writeFailed("Classic TIFF writing requires 32-bit file offsets")
        }
        let appendStart = file.length + file.length % 2
        func place(_ directory: IFD, previous: IFD?, at oldOffset: UInt32?) async throws -> UInt32 {
            var existing: [UInt16: (value: TagValue, range: Range<Int>)] = [:]
            var slot: Range<UInt64>?
            if let previous, let oldOffset {
                let layout = try await layout(file, at: UInt64(oldOffset), order: order)
                slot = layout.table
                for entry in previous.entries {
                    if let range = layout.values[entry.tagID] {
                        existing[entry.tagID] = (entry.value, Int(range.lowerBound) ..< Int(range.upperBound))
                    }
                }
            }
            let tableSize = 2 + directory.entries.count * 12 + 4
            let inPlace = slot.map { UInt64(tableSize) <= $0.upperBound - $0.lowerBound } ?? false
            let end = appendStart + UInt64(appended.count)
            let location = inPlace ? slot!.lowerBound : end
            let overflowStart = inPlace ? end : end + UInt64(tableSize)
            guard location <= UInt64(UInt32.max), overflowStart <= UInt64(UInt32.max) else {
                throw EXIFError.writeFailed("Classic TIFF metadata offsets exceed 32 bits")
            }
            let (table, overflow) = IFDWriter.writeIFD(
                directory, overflowOffset: UInt32(overflowStart), byteOrder: order, existing: existing
            )
            guard UInt64(overflow.count) <= UInt64(UInt32.max) - overflowStart else {
                throw EXIFError.writeFailed("TIFF exceeds 32-bit offsets")
            }
            if inPlace, let slot {
                edits.append(
                    FileEdit(
                        slot, pieces: [.bytes(table), .zeros(slot.upperBound - slot.lowerBound - UInt64(table.count))]
                    )
                )
                appended.append(overflow)
            } else {
                appended.append(table)
                appended.append(overflow)
            }
            return UInt32(location)
        }
        var exif = updated.exifIFD
        if let interop = updated.interopIFD {
            let pointer = try await place(
                interop, previous: original.interopIFD,
                at: original.exifIFD?.value(for: Tag.interopIFDPointer)?.uint32Value
            )
            exif?.set(tagID: Tag.interopIFDPointer, value: .long(pointer))
        } else {
            exif?.remove(tagID: Tag.interopIFDPointer)
        }
        var ifd0 = updated.ifd0
        for tag: UInt16 in [0x0111, 0x0117, 0x0144, 0x0145, 0x0201, 0x0202] {
            if let entry = original.ifd0.entry(for: tag) {
                ifd0.set(tagID: tag, value: entry.value)
            }
        }
        ifd0.nextIFDOffset = original.ifd0.nextIFDOffset
        if updated.thumbnailEdited {
            // Only an EXIF-style IFD1 (or none) can be replaced: other chained IFDs are pages or RAW data.
            let previous = original.ifd1
            let previousRange = previous.flatMap { ifd -> Range<UInt64>? in
                guard let offset = ifd.value(for: Tag.jpegInterchangeFormat)?.uint32Value,
                      let length = ifd.value(for: Tag.jpegInterchangeFormatLength)?.uint32Value else { return nil }
                return UInt64(offset) ..< UInt64(offset) + UInt64(length)
            }
            guard previous == nil || previousRange != nil else {
                throw EXIFError.writeFailed("IFD1 is not a JPEG thumbnail")
            }
            if let jpeg = updated.loadedThumbnail, var directory = updated.ifd1 {
                let start = appendStart + UInt64(appended.count)
                guard start + UInt64(jpeg.count) <= UInt64(UInt32.max) else {
                    throw EXIFError.writeFailed("Classic TIFF thumbnail offset exceeds 32 bits")
                }
                appended.append(jpeg)
                if jpeg.count % 2 == 1 {
                    appended.append(0)
                }
                directory.set(tagID: Tag.jpegInterchangeFormat, value: .long(UInt32(start)))
                directory.set(tagID: Tag.jpegInterchangeFormatLength, value: .long(UInt32(jpeg.count)))
                directory.nextIFDOffset = previous?.nextIFDOffset ?? 0
                ifd0.nextIFDOffset = try await place(
                    directory, previous: previous, at: previous == nil ? nil : original.ifd0.nextIFDOffset
                )
            } else if previous != nil {
                // RAW readers may locate later IFDs by their position in the chain.
                guard !raw else { throw EXIFError.writeFailed("Removing the thumbnail of a RAW file is unsupported") }
                ifd0.nextIFDOffset = previous?.nextIFDOffset ?? 0
            }
            // Erase the superseded thumbnail, unless the main JPEG preview shares its bytes.
            let preview = original.ifd0.value(for: Tag.jpegInterchangeFormat)?.uint32Value.map { offset in
                UInt64(offset) ..< UInt64(offset)
                    + UInt64(original.ifd0.value(for: Tag.jpegInterchangeFormatLength)?.uint32Value ?? 0)
            }
            if let range = previousRange, !range.isEmpty, range.upperBound <= file.length,
               !(preview?.overlaps(range) ?? false)
            {
                edits.append(FileEdit(range, pieces: [.zeros(range.upperBound - range.lowerBound)]))
            }
        }
        for (tag, directory, oldDirectory) in [
            (Tag.exifIFDPointer, exif, original.exifIFD), (Tag.gpsIFDPointer, updated.gpsIFD, original.gpsIFD),
        ] {
            guard let directory else {
                ifd0.remove(tagID: tag)
                continue
            }
            let pointer = try await place(
                directory, previous: oldDirectory, at: original.ifd0.value(for: tag)?.uint32Value
            )
            ifd0.set(tagID: tag, value: .long(pointer))
        }
        let pointer = try await place(ifd0, previous: original.ifd0, at: UInt32(ifd0Offset))
        if UInt64(pointer) != ifd0Offset {
            var writer = ByteWriter(byteOrder: order)
            writer.writeUInt32(pointer)
            edits.append(FileEdit(4 ..< 8, writer.data))
        }
        if !appended.isEmpty {
            let padding = appendStart - file.length
            edits.append(FileEdit(file.length ..< file.length, pieces: [.zeros(padding), .bytes(appended)]))
        }
        if structure == nil {
            for (directory, pointer) in [
                (original.exifIFD, original.ifd0.value(for: Tag.exifIFDPointer)?.uint32Value),
                (original.gpsIFD, original.ifd0.value(for: Tag.gpsIFDPointer)?.uint32Value),
                (original.interopIFD, original.exifIFD?.value(for: Tag.interopIFDPointer)?.uint32Value),
            ] {
                if directory != nil, let pointer {
                    let layout = try await layout(file, at: UInt64(pointer), order: order)
                    for range in [layout.table] + Array(layout.values.values) {
                        edits.append(FileEdit(range, pieces: [.zeros(range.upperBound - range.lowerBound)]))
                    }
                }
            }
            // Overlapping scrub regions are merged; overlap with retained IFD tables is rejected by stream validation.
            var zeros = edits.filter { edit in edit.pieces.allSatisfy {
                if case .zeros = $0 {
                    true
                } else {
                    false
                }
            } }
            .map(\.range).sorted { $0.lowerBound < $1.lowerBound }
            edits.removeAll { edit in edit.pieces.allSatisfy {
                if case .zeros = $0 {
                    true
                } else {
                    false
                }
            } }
            var merged: [Range<UInt64>] = []
            while !zeros.isEmpty {
                let range = zeros.removeFirst()
                if let last = merged.last, range.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
                } else {
                    merged.append(range)
                }
            }
            edits += merged.map { FileEdit($0, pieces: [.zeros($0.upperBound - $0.lowerBound)]) }
        }
        return edits
    }

    static func cr3(_ file: FileRegion, structure: TIFFStructure?) async throws -> [FileEdit] {
        let index = try await HandleParser.boxes(file)
        guard let moov = index.first(where: { $0.type == "moov" }) else { throw EXIFError.invalidCR3("Missing moov") }
        var edits: [FileEdit] = []
        let targets: [(String, IFD?)] =
            structure.map { [("CMT1", $0.ifd0), ("CMT2", $0.exifIFD), ("CMT4", $0.gpsIFD)] }
                ?? [("CMT1", nil), ("CMT2", nil), ("CMT3", nil), ("CMT4", nil)]
        for (type, directory) in targets {
            guard let box = moov.first(type) else {
                if directory != nil {
                    throw EXIFError.invalidCR3("No \(type) box for metadata")
                }
                continue
            }
            let order: ByteOrder
            if let structure {
                order = structure.byteOrder
            } else {
                order = try await file.read(at: box.payload, count: 1)[0] == 0x4D ? .bigEndian : .littleEndian
            }
            let tiff = TIFFSerializer.encode(TIFFStructure(byteOrder: order, ifd0: directory ?? IFD()))
            guard UInt64(tiff.count) <= box.length else {
                throw EXIFError.invalidCR3("\(type) metadata exceeds its original capacity")
            }
            edits.append(
                FileEdit(box.payload ..< box.end, pieces: [.bytes(tiff), .zeros(box.length - UInt64(tiff.count))])
            )
        }
        return edits
    }

    static func heif(_ file: FileRegion, structure: TIFFStructure?) async throws -> [FileEdit] {
        let info = try await HandleParser.heif(file, parseTIFF: false)
        guard let structure else {
            return info.ranges.map { FileEdit($0, pieces: [.zeros($0.upperBound - $0.lowerBound)]) }
        }
        let bytes = try await Data([0, 0, 0, 6, 0x45, 0x78, 0x69, 0x66, 0, 0]) + serialized(structure)
        if UInt64(bytes.count) <= info.itemRegion.length {
            var offset = 0
            return info.ranges.map { range in
                let length = range.upperBound - range.lowerBound
                let count = min(bytes.count - offset, Int(length))
                defer { offset += count }
                return FileEdit(
                    range, pieces: [.bytes(bytes.subdata(in: offset ..< offset + count)), .zeros(length - UInt64(count))]
                )
            }
        }
        // Relocate the logical item while preserving its extent count. The final extent grows.
        guard info.boxes.last?.end == file.length else { throw EXIFError.invalidHEIF("Invalid top-level boxes") }
        // A size-zero final box would absorb appended bytes. Give it an explicit size first.
        var edits: [FileEdit] = []
        if let last = info.boxes.last {
            var head = try ByteReader(data: await file.read(at: last.start, count: 4))
            if try head.readUInt32() == 0 {
                let length = last.end - last.start
                guard length <= UInt64(UInt32.max) else {
                    throw EXIFError.invalidHEIF("Cannot extend a >4 GiB size-zero box")
                }
                var writer = ByteWriter()
                writer.writeUInt32(UInt32(length))
                edits.append(FileEdit(last.start ..< last.start + 4, writer.data))
            }
        }
        guard file.length <= UInt64.max - UInt64(bytes.count) - 8 else {
            throw EXIFError.writeFailed("HEIF output size overflows")
        }
        let start = file.length + 8
        guard start >= info.item.baseOffset else { throw EXIFError.invalidHEIF("Invalid base offset") }
        func field(_ value: UInt64, size: Int, position: Int) throws -> FileEdit {
            guard size == 4 || size == 8, size == 8 || value <= UInt64(UInt32.max) else {
                throw EXIFError.invalidHEIF("iloc field cannot represent new location")
            }
            var writer = ByteWriter()
            if size == 8 {
                writer.writeUInt32(UInt32(value >> 32))
            }
            writer.writeUInt32(UInt32(truncatingIfNeeded: value))
            let offset = info.iloc.payload + UInt64(position)
            return FileEdit(offset ..< offset + UInt64(size), writer.data)
        }
        if info.item.constructionMethod == 1, let position = info.item.constructionMethodFieldPosition {
            let offset = info.iloc.payload + UInt64(position)
            edits.append(FileEdit(offset ..< offset + 2, Data([0, 0])))
        }
        var consumed: UInt64 = 0
        for (index, extent) in info.item.extents.enumerated() {
            let length = index == info.item.extents.count - 1 ? UInt64(bytes.count) - consumed : extent.length
            try edits.append(
                field(
                    start + consumed - info.item.baseOffset, size: info.locations.offsetSize,
                    position: extent.offsetFieldPosition
                )
            )
            try edits.append(field(length, size: info.locations.lengthSize, position: extent.lengthFieldPosition))
            consumed += length
        }
        var header = ByteWriter()
        header.writeUInt32(UInt32(bytes.count + 8))
        header.writeBytes(Data("mdat".utf8))
        edits.append(FileEdit(file.length ..< file.length, header.data + bytes))
        // Erase the superseded EXIF bytes instead of leaving recoverable GPS/MakerNotes behind.
        edits += info.ranges.map { FileEdit($0, pieces: [.zeros($0.upperBound - $0.lowerBound)]) }
        return edits
    }

    static func raf(_ file: FileRegion, structure: TIFFStructure?, stripping: Bool) async throws -> [FileEdit] {
        let embedded = try await HandleParser.raf(file)
        let start = embedded.ranges[0].lowerBound
        let edits = try await jpeg(embedded, tiff: structure, stripping: stripping)
        var length = embedded.length
        for edit in edits {
            let replacement = edit.pieces.reduce(UInt64(0)) { $0 + $1.count }
            length = length - (edit.range.upperBound - edit.range.lowerBound) + replacement
        }
        let growth = length > embedded.length ? length - embedded.length : 0
        let capacity = embedded.length + (growth + 511) / 512 * 512
        var output = edits.map {
            FileEdit($0.range.lowerBound + start ..< $0.range.upperBound + start, pieces: $0.pieces)
        }
        output.append(FileEdit(start + embedded.length ..< start + embedded.length, pieces: [.zeros(capacity - length)]))
        func patch(_ position: UInt64, _ value: UInt64) throws -> FileEdit {
            guard value <= UInt64(UInt32.max) else { throw EXIFError.writeFailed("RAF offset exceeds 32 bits") }
            var writer = ByteWriter()
            writer.writeUInt32(UInt32(value))
            return FileEdit(position ..< position + 4, writer.data)
        }
        try output.append(patch(88, capacity))
        if capacity != embedded.length {
            for position: UInt64 in [92, 100] {
                var reader = try ByteReader(data: await file.read(at: position, count: 4))
                let current = try UInt64(reader.readUInt32())
                if current > start {
                    try output.append(patch(position, current + capacity - embedded.length))
                }
            }
        }
        return output
    }
}
