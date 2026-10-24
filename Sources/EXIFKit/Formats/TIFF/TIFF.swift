import Foundation

// MARK: - TIFF Structure

/// The complete parsed TIFF metadata structure.
///
/// This is the common representation for all formats — JPEG wraps it in APP1,
/// PNG wraps it in an eXIf chunk, and TIFF/DNG files start with it directly.
public struct TIFFStructure: Sendable {
    /// The byte order used throughout the structure
    public let byteOrder: ByteOrder

    /// IFD0 — primary image metadata (make, model, orientation, etc.)
    public var ifd0: IFD

    /// IFD1 — thumbnail metadata (optional, usually in JPEG)
    public var ifd1: IFD?

    /// EXIF sub-IFD — camera settings (exposure, ISO, focal length, etc.)
    public var exifIFD: IFD?

    /// GPS sub-IFD — geolocation data
    public var gpsIFD: IFD?

    var sourceRegion: FileRegion?
    var loadedThumbnail: Data?
    /// Set by `setThumbnail`; formats that cannot rewrite IFD1 reject the write instead of ignoring it.
    var thumbnailEdited = false
    /// Interoperability metadata, read without retaining the TIFF source buffer.
    public var interopIFD: IFD?

    public init(
        byteOrder: ByteOrder,
        ifd0: IFD = IFD(),
        ifd1: IFD? = nil,
        exifIFD: IFD? = nil,
        gpsIFD: IFD? = nil
    ) {
        self.byteOrder = byteOrder
        self.ifd0 = ifd0
        self.ifd1 = ifd1
        self.exifIFD = exifIFD
        self.gpsIFD = gpsIFD
    }
}

// MARK: - TIFF Parser

/// Parses raw TIFF data (the "II"/"MM" byte-order marker through all IFDs).
///
/// This parser is used by all container formats:
/// - JPEG: pass the APP1 payload (after "Exif\0\0")
/// - PNG: pass the eXIf chunk data
/// - TIFF/DNG: pass the entire file
public enum TIFFParser {
    public static func parse(_ data: Data) async throws -> TIFFStructure {
        try await EXIFKit.read(from: data, format: .tiff)
    }

    public static func parse(_ source: any AbstractFileHandle) async throws -> TIFFStructure {
        try await EXIFKit.read(from: source, format: .tiff)
    }
}

// MARK: - TIFF Serializer

/// Rebuilds a complete TIFF data block from a TIFFStructure.
///
/// This is a "rebuild from scratch" approach — simpler and more reliable
/// than trying to patch offsets in place.
public enum TIFFSerializer {
    /// Serialize a TIFFStructure to a complete TIFF data block.
    ///
    /// Layout: [header][IFD0][IFD1][EXIF][GPS][Interop][thumbnail].
    /// Resolved interoperability metadata is included, and the source thumbnail is read on demand.
    /// Source I/O and invalid thumbnail offsets propagate as errors.
    public static func serialize(_ structure: TIFFStructure) async throws -> Data {
        try await EditPlanner.serialized(structure)
    }

    static func encode(_ structure: TIFFStructure) -> Data {
        let byteOrder = structure.byteOrder
        var ifd0 = structure.ifd0
        var ifd1 = structure.ifd1
        var exifIFD = structure.exifIFD
        let gpsIFD = structure.gpsIFD

        var interopIFD = structure.interopIFD
        exifIFD?.remove(tagID: Tag.interopIFDPointer)
        let thumbnail = structure.loadedThumbnail
        ifd1?.remove(tagID: Tag.jpegInterchangeFormat)
        if thumbnail == nil {
            ifd1?.remove(tagID: Tag.jpegInterchangeFormatLength)
        }

        // Placeholder pointers so every IFD has its final entry count before sizes are measured.
        // An IFD's serialized size doesn't depend on its position, so offsets can be laid out up front.
        ifd0.remove(tagID: Tag.exifIFDPointer)
        ifd0.remove(tagID: Tag.gpsIFDPointer)
        if exifIFD != nil {
            ifd0.set(tagID: Tag.exifIFDPointer, value: .long(0))
        }
        if gpsIFD != nil {
            ifd0.set(tagID: Tag.gpsIFDPointer, value: .long(0))
        }
        if interopIFD != nil {
            exifIFD?.set(tagID: Tag.interopIFDPointer, value: .long(0))
        }
        if let thumbnail {
            ifd1?.set(tagID: Tag.jpegInterchangeFormat, value: .long(0))
            ifd1?.set(tagID: Tag.jpegInterchangeFormatLength, value: .long(UInt32(thumbnail.count)))
        }

        func size(_ ifd: IFD?) -> UInt32 {
            ifd.map { UInt32(IFDWriter.writeIFD($0, baseOffset: 0, byteOrder: byteOrder).count) } ?? 0
        }
        let ifd0Offset: UInt32 = 8
        let ifd1Offset = ifd0Offset + size(ifd0)
        let exifOffset = ifd1Offset + size(ifd1)
        let gpsOffset = exifOffset + size(exifIFD)
        let interopOffset = gpsOffset + size(gpsIFD)
        let thumbnailOffset = interopOffset + size(interopIFD)

        if exifIFD != nil {
            ifd0.set(tagID: Tag.exifIFDPointer, value: .long(exifOffset))
        }
        if gpsIFD != nil {
            ifd0.set(tagID: Tag.gpsIFDPointer, value: .long(gpsOffset))
        }
        if interopIFD != nil {
            exifIFD?.set(tagID: Tag.interopIFDPointer, value: .long(interopOffset))
        }
        if thumbnail != nil {
            ifd1?.set(tagID: Tag.jpegInterchangeFormat, value: .long(thumbnailOffset))
        }
        ifd0.nextIFDOffset = ifd1 != nil ? ifd1Offset : 0
        ifd1?.nextIFDOffset = 0
        interopIFD?.nextIFDOffset = 0

        var writer = ByteWriter(byteOrder: byteOrder)
        writer.writeBytes(byteOrder == .littleEndian ? [0x49, 0x49] : [0x4D, 0x4D]) // "II" / "MM"
        writer.writeUInt16(42) // Magic
        writer.writeUInt32(ifd0Offset)
        for (ifd, offset) in [
            (ifd0, ifd0Offset), (ifd1, ifd1Offset), (exifIFD, exifOffset),
            (gpsIFD, gpsOffset), (interopIFD, interopOffset),
        ] {
            if let ifd {
                writer.writeBytes(IFDWriter.writeIFD(ifd, baseOffset: offset, byteOrder: byteOrder))
            }
        }
        if let thumbnail {
            writer.writeBytes(thumbnail)
        }

        return writer.data
    }
}
