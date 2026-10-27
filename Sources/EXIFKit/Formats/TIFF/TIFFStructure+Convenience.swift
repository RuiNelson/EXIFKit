import Foundation

public extension TIFFStructure {
    /// Camera manufacturer
    var make: String? {
        ifd0.value(for: Tag.make)?.stringValue
    }

    /// Camera model
    var model: String? {
        ifd0.value(for: Tag.model)?.stringValue
    }

    /// Image orientation (1-8)
    var orientation: UInt16? {
        if case let .short(v) = ifd0.value(for: Tag.orientation) {
            return v
        }
        return nil
    }

    /// Software used to create/edit the image
    var software: String? {
        ifd0.value(for: Tag.software)?.stringValue
    }

    /// Image description / title
    var imageDescription: String? {
        ifd0.value(for: Tag.imageDescription)?.stringValue
    }

    /// Copyright string
    var copyright: String? {
        ifd0.value(for: Tag.copyright)?.stringValue
    }

    /// Artist / photographer
    var artist: String? {
        ifd0.value(for: Tag.artist)?.stringValue
    }

    /// Date/time the image was taken
    var dateTimeOriginal: String? {
        exifIFD?.value(for: Tag.dateTimeOriginal)?.stringValue
    }

    /// Date/time the image was digitized
    var dateTimeDigitized: String? {
        exifIFD?.value(for: Tag.dateTimeDigitized)?.stringValue
    }

    /// Timezone offset for dateTimeOriginal (e.g., "+09:00")
    var offsetTimeOriginal: String? {
        exifIFD?.value(for: Tag.offsetTimeOriginal)?.stringValue
    }

    /// ISO speed
    var iso: UInt16? {
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
    var focalLength: Double? {
        exifIFD?.value(for: Tag.focalLength)?.doubleValue
    }

    /// Focal length in 35mm equivalent
    var focalLength35mm: UInt16? {
        if case let .short(v) = exifIFD?.value(for: Tag.focalLength35mm) {
            return v
        }
        return nil
    }

    /// F-number (aperture)
    var fNumber: Double? {
        exifIFD?.value(for: Tag.fNumber)?.doubleValue
    }

    /// Exposure time in seconds
    var exposureTime: Double? {
        exifIFD?.value(for: Tag.exposureTime)?.doubleValue
    }

    /// Exposure bias / compensation in EV
    var exposureBias: Double? {
        exifIFD?.value(for: Tag.exposureBias)?.doubleValue
    }

    /// Lens model name
    var lensModel: String? {
        exifIFD?.value(for: Tag.lensModel)?.stringValue
    }

    /// Lens manufacturer
    var lensMake: String? {
        exifIFD?.value(for: Tag.lensMake)?.stringValue
    }

    /// Flash fired (bit 0 of flash tag)
    var flashFired: Bool? {
        if case let .short(v) = exifIFD?.value(for: Tag.flash) {
            return (v & 1) == 1
        }
        return nil
    }

    /// Color space (1 = sRGB, 65535 = uncalibrated)
    var colorSpace: UInt16? {
        if case let .short(v) = exifIFD?.value(for: Tag.colorSpace) {
            return v
        }
        return nil
    }

    /// Pixel width from EXIF
    var pixelWidth: UInt32? {
        exifIFD?.value(for: Tag.pixelXDimension)?.uint32Value
    }

    /// Pixel height from EXIF
    var pixelHeight: UInt32? {
        exifIFD?.value(for: Tag.pixelYDimension)?.uint32Value
    }

    /// GPS latitude as a signed decimal degree (negative = South)
    var latitude: Double? {
        guard let coords = gpsIFD?.value(for: Tag.gpsLatitude),
              let ref = gpsIFD?.value(for: Tag.gpsLatitudeRef)?.stringValue, let degrees = degreesFromDMS(coords) else { return nil }
        return ref == "S" ? -degrees : degrees
    }

    /// GPS longitude as a signed decimal degree (negative = West)
    var longitude: Double? {
        guard let coords = gpsIFD?.value(for: Tag.gpsLongitude),
              let ref = gpsIFD?.value(for: Tag.gpsLongitudeRef)?.stringValue, let degrees = degreesFromDMS(coords) else { return nil }
        return ref == "W" ? -degrees : degrees
    }

    /// GPS altitude in meters
    var altitude: Double? {
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
    mutating func setGPSCoordinates(latitude: Double, longitude: Double, altitude: Double? = nil) {
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
