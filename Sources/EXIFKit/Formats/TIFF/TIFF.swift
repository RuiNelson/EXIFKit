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
    /// Interoperability metadata, read without retaining the TIFF source buffer.
    public var interopIFD: IFD?

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

    // MARK: - Convenience Accessors

    /// Camera manufacturer
    public var make: String? {
        ifd0.value(for: Tag.make)?.stringValue
    }

    /// Camera model
    public var model: String? {
        ifd0.value(for: Tag.model)?.stringValue
    }

    /// Image orientation (1-8)
    public var orientation: UInt16? {
        if case let .short(v) = ifd0.value(for: Tag.orientation) {
            return v
        }
        return nil
    }

    /// Software used to create/edit the image
    public var software: String? {
        ifd0.value(for: Tag.software)?.stringValue
    }

    /// Image description / title
    public var imageDescription: String? {
        ifd0.value(for: Tag.imageDescription)?.stringValue
    }

    /// Copyright string
    public var copyright: String? {
        ifd0.value(for: Tag.copyright)?.stringValue
    }

    /// Artist / photographer
    public var artist: String? {
        ifd0.value(for: Tag.artist)?.stringValue
    }

    /// Date/time the image was taken
    public var dateTimeOriginal: String? {
        exifIFD?.value(for: Tag.dateTimeOriginal)?.stringValue
    }

    /// Date/time the image was digitized
    public var dateTimeDigitized: String? {
        exifIFD?.value(for: Tag.dateTimeDigitized)?.stringValue
    }

    /// Timezone offset for dateTimeOriginal (e.g., "+09:00")
    public var offsetTimeOriginal: String? {
        exifIFD?.value(for: Tag.offsetTimeOriginal)?.stringValue
    }

    /// ISO speed
    public var iso: UInt16? {
        if case let .short(v) = exifIFD?.value(for: Tag.isoSpeedRatings) {
            return v
        }
        // Some cameras use shorts array with count 1
        if case let .shorts(v) = exifIFD?.value(for: Tag.isoSpeedRatings), let first = v.first {
            return first
        }
        return nil
    }

    /// Focal length in mm
    public var focalLength: Double? {
        exifIFD?.value(for: Tag.focalLength)?.doubleValue
    }

    /// Focal length in 35mm equivalent
    public var focalLength35mm: UInt16? {
        if case let .short(v) = exifIFD?.value(for: Tag.focalLength35mm) {
            return v
        }
        return nil
    }

    /// F-number (aperture)
    public var fNumber: Double? {
        exifIFD?.value(for: Tag.fNumber)?.doubleValue
    }

    /// Exposure time in seconds
    public var exposureTime: Double? {
        exifIFD?.value(for: Tag.exposureTime)?.doubleValue
    }

    /// Exposure bias / compensation in EV
    public var exposureBias: Double? {
        exifIFD?.value(for: Tag.exposureBias)?.doubleValue
    }

    /// Lens model name
    public var lensModel: String? {
        exifIFD?.value(for: Tag.lensModel)?.stringValue
    }

    /// Lens manufacturer
    public var lensMake: String? {
        exifIFD?.value(for: Tag.lensMake)?.stringValue
    }

    /// Flash fired (bit 0 of flash tag)
    public var flashFired: Bool? {
        if case let .short(v) = exifIFD?.value(for: Tag.flash) {
            return (v & 1) == 1
        }
        return nil
    }

    /// Color space (1 = sRGB, 65535 = uncalibrated)
    public var colorSpace: UInt16? {
        if case let .short(v) = exifIFD?.value(for: Tag.colorSpace) {
            return v
        }
        return nil
    }

    /// Pixel width from EXIF
    public var pixelWidth: UInt32? {
        exifIFD?.value(for: Tag.pixelXDimension)?.uint32Value
    }

    /// Pixel height from EXIF
    public var pixelHeight: UInt32? {
        exifIFD?.value(for: Tag.pixelYDimension)?.uint32Value
    }

    // MARK: - Thumbnail Extraction

    /// Extract the embedded JPEG thumbnail from IFD1, if present.
    ///
    /// Most JPEG files contain a small JPEG thumbnail in IFD1.
    /// The thumbnail data is referenced by JPEGInterchangeFormat (offset)
    /// and JPEGInterchangeFormatLength (size) tags.
    public var thumbnailData: Data? {
        get async throws { try await readThumbnail() }
    }

    /// GPS latitude as a signed decimal degree (negative = South)
    public var latitude: Double? {
        guard let coords = gpsIFD?.value(for: Tag.gpsLatitude),
              let ref = gpsIFD?.value(for: Tag.gpsLatitudeRef)?.stringValue, let degrees = degreesFromDMS(coords) else { return nil }
        return ref == "S" ? -degrees : degrees
    }

    /// GPS longitude as a signed decimal degree (negative = West)
    public var longitude: Double? {
        guard let coords = gpsIFD?.value(for: Tag.gpsLongitude),
              let ref = gpsIFD?.value(for: Tag.gpsLongitudeRef)?.stringValue, let degrees = degreesFromDMS(coords) else { return nil }
        return ref == "W" ? -degrees : degrees
    }

    /// GPS altitude in meters
    public var altitude: Double? {
        guard let alt = gpsIFD?.value(for: Tag.gpsAltitude)?.doubleValue else { return nil }
        if case let .byte(ref) = gpsIFD?.value(for: Tag.gpsAltitudeRef), ref == 1 {
            return -alt // Below sea level
        }
        return alt
    }

    /// Convert DMS (degrees/minutes/seconds as 3 rationals) to decimal degrees
    private func degreesFromDMS(_ value: TagValue) -> Double? {
        guard case let .rationals(rats) = value, rats.count == 3 else { return nil }
        let d = rats[0].doubleValue
        let m = rats[1].doubleValue
        let s = rats[2].doubleValue
        return d + m / 60.0 + s / 3600.0
    }

    // MARK: - Mutation helpers

    /// Set GPS coordinates
    public mutating func setGPSCoordinates(latitude: Double, longitude: Double, altitude: Double? = nil) {
        if gpsIFD == nil {
            gpsIFD = IFD()
        }

        // Latitude
        let latRef: String = latitude >= 0 ? "N" : "S"
        let latDMS = decimalToDMS(abs(latitude))
        gpsIFD!.set(tagID: Tag.gpsLatitudeRef, value: .ascii(latRef))
        gpsIFD!.set(tagID: Tag.gpsLatitude, value: .rationals(latDMS))

        // Longitude
        let lonRef: String = longitude >= 0 ? "E" : "W"
        let lonDMS = decimalToDMS(abs(longitude))
        gpsIFD!.set(tagID: Tag.gpsLongitudeRef, value: .ascii(lonRef))
        gpsIFD!.set(tagID: Tag.gpsLongitude, value: .rationals(lonDMS))

        // Altitude
        if let alt = altitude {
            gpsIFD!.set(tagID: Tag.gpsAltitudeRef, value: .byte(alt < 0 ? 1 : 0))
            gpsIFD!.set(tagID: Tag.gpsAltitude, value: .rational(URational(abs(alt), precision: 1000)))
        }

        // GPS version
        gpsIFD!.set(tagID: Tag.gpsVersionID, value: .bytes([2, 3, 0, 0]))
    }

    /// Convert decimal degrees to DMS as 3 URationals
    private func decimalToDMS(_ decimal: Double) -> [URational] {
        let d = Int(decimal)
        let mFull = (decimal - Double(d)) * 60.0
        let m = Int(mFull)
        let s = (mFull - Double(m)) * 60.0
        return [
            URational(numerator: UInt32(d), denominator: 1),
            URational(numerator: UInt32(m), denominator: 1),
            URational(numerator: UInt32((s * 10000).rounded()), denominator: 10000),
        ]
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
