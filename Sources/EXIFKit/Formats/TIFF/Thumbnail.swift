import Foundation

// MARK: - Thumbnail

extension TIFFStructure {
    /// Fetch only the embedded JPEG thumbnail. The source must remain unchanged.
    public func readThumbnail() async throws -> Data? {
        if let loadedThumbnail {
            return loadedThumbnail
        }
        guard let sourceRegion,
              let offset = ifd1?.value(for: Tag.jpegInterchangeFormat)?.uint32Value,
              let length = ifd1?.value(for: Tag.jpegInterchangeFormatLength)?.uint32Value,
              length > 0
        else { return nil }
        guard length <= 10 * 1024 * 1024 else { throw EXIFError.resourceLimitExceeded }
        return try await sourceRegion.read(at: UInt64(offset), count: Int(length))
    }

    func preparingForWrite() async throws -> TIFFStructure {
        var copy = self
        copy.loadedThumbnail = try await readThumbnail()
        return copy
    }

    /// Extract the embedded JPEG thumbnail from IFD1, if present.
    ///
    /// Most JPEG files contain a small JPEG thumbnail in IFD1.
    /// The thumbnail data is referenced by JPEGInterchangeFormat (offset)
    /// and JPEGInterchangeFormatLength (size) tags.
    public var thumbnailData: Data? {
        get async throws { try await readThumbnail() }
    }

    /// Replace the embedded JPEG thumbnail in IFD1, or remove it (and IFD1) with `nil`.
    ///
    /// A missing IFD1 is created with JPEG compression and 72 dpi resolution.
    /// In TIFF-based files the write replaces an IFD1 JPEG thumbnail, or adds IFD1 after a lone IFD0;
    /// any other IFD1 is rejected, and only TIFF and DNG thumbnails can be removed. CR3 rejects the write.
    public mutating func setThumbnail(_ jpeg: Data?) throws {
        if let jpeg {
            guard jpeg.count >= 4, jpeg.prefix(2) == Data([0xFF, 0xD8]) else {
                throw EXIFError.invalidJPEG("Thumbnail must be a JPEG image")
            }
            guard jpeg.count <= 10 * 1024 * 1024 else { throw EXIFError.resourceLimitExceeded }
            var directory = ifd1 ?? IFD()
            if ifd1 == nil {
                directory.set(tagID: Tag.xResolution, value: .rational(URational(numerator: 72, denominator: 1)))
                directory.set(tagID: Tag.yResolution, value: .rational(URational(numerator: 72, denominator: 1)))
                directory.set(tagID: Tag.resolutionUnit, value: .short(2))
            }
            // An uncompressed strip thumbnail would point at image data that is no longer written.
            for tag in [Tag.stripOffsets, Tag.rowsPerStrip, Tag.stripByteCounts] {
                directory.remove(tagID: tag)
            }
            directory.set(tagID: Tag.compression, value: .short(6))
            directory.set(tagID: Tag.jpegInterchangeFormatLength, value: .long(UInt32(jpeg.count)))
            ifd1 = directory
        } else {
            ifd1 = nil
        }
        loadedThumbnail = jpeg
        sourceRegion = nil
        thumbnailEdited = true
    }
}

extension EditPlanner {
    /// Writes the IFD1 thumbnail of a TIFF-based file through the planner's `append` and `place`.
    /// Returns IFD0's new next-IFD pointer and the edit that zeroes the superseded thumbnail.
    static func tiffThumbnail(
        _ updated: TIFFStructure, original: TIFFStructure, raw: Bool, fileLength: UInt64,
        append: (Data) -> UInt64,
        place: (IFD, IFD?, UInt32?) async throws -> UInt32
    ) async throws -> (nextIFDOffset: UInt32, edits: [FileEdit]) {
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
        var nextIFDOffset = original.ifd0.nextIFDOffset
        var edits: [FileEdit] = []
        if let jpeg = updated.loadedThumbnail, var directory = updated.ifd1 {
            let start = append(jpeg)
            guard start + UInt64(jpeg.count) <= UInt64(UInt32.max) else {
                throw EXIFError.writeFailed("Classic TIFF thumbnail offset exceeds 32 bits")
            }
            directory.set(tagID: Tag.jpegInterchangeFormat, value: .long(UInt32(start)))
            directory.set(tagID: Tag.jpegInterchangeFormatLength, value: .long(UInt32(jpeg.count)))
            directory.nextIFDOffset = previous?.nextIFDOffset ?? 0
            nextIFDOffset = try await place(directory, previous, previous == nil ? nil : original.ifd0.nextIFDOffset)
        } else if previous != nil {
            // RAW readers may locate later IFDs by their position in the chain.
            guard !raw else { throw EXIFError.writeFailed("Removing the thumbnail of a RAW file is unsupported") }
            nextIFDOffset = previous?.nextIFDOffset ?? 0
        }
        // Erase the superseded thumbnail, unless the main JPEG preview shares its bytes.
        let preview = original.ifd0.value(for: Tag.jpegInterchangeFormat)?.uint32Value.map { offset in
            UInt64(offset) ..< UInt64(offset)
                + UInt64(original.ifd0.value(for: Tag.jpegInterchangeFormatLength)?.uint32Value ?? 0)
        }
        if let range = previousRange, !range.isEmpty, range.upperBound <= fileLength,
           !(preview?.overlaps(range) ?? false)
        {
            edits.append(FileEdit(range, pieces: [.zeros(range.upperBound - range.lowerBound)]))
        }
        return (nextIFDOffset, edits)
    }
}
