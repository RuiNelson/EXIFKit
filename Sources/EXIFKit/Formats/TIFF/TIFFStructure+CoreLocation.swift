#if canImport(CoreLocation)
import CoreLocation
import Foundation

public extension TIFFStructure {
    /// GPS metadata as a `CLLocation`, or nil if there is no valid latitude/longitude.
    ///
    /// Missing values use CoreLocation's "unknown" conventions: negative vertical accuracy
    /// (altitude invalid), negative speed and course. Horizontal accuracy comes from
    /// `GPSHPositioningError` and is 0 when absent, since negative would invalidate the coordinate.
    /// The timestamp is the GPS date/time, falling back to `taken`, then `.distantPast`.
    var location: CLLocation? {
        guard let latitude, let longitude else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

        return CLLocation(
            coordinate: coordinate,
            altitude: altitude ?? 0,
            horizontalAccuracy: gpsIFD?.value(for: Tag.gpsHPositioningError)?.doubleValue ?? 0,
            verticalAccuracy: altitude == nil ? -1 : 0,
            course: gpsCourse ?? -1,
            speed: gpsSpeedMetersPerSecond ?? -1,
            timestamp: gpsDate ?? taken ?? .distantPast
        )
    }

    /// Write a `CLLocation` into the GPS IFD, replacing any existing speed, course and accuracy.
    ///
    /// Negative (invalid) altitude accuracy, horizontal accuracy, speed or course are omitted.
    mutating func setLocation(_ location: CLLocation) {
        setGPSCoordinates(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil
        )

        if location.horizontalAccuracy >= 0 {
            gpsIFD?.set(tagID: Tag.gpsHPositioningError, value: .rational(URational(location.horizontalAccuracy, precision: 100)))
        } else {
            gpsIFD?.remove(tagID: Tag.gpsHPositioningError)
        }

        if location.speed >= 0 {
            gpsIFD?.set(tagID: Tag.gpsSpeedRef, value: .ascii("K"))
            gpsIFD?.set(tagID: Tag.gpsSpeed, value: .rational(URational(location.speed * 3.6, precision: 100)))
        } else {
            gpsIFD?.remove(tagID: Tag.gpsSpeedRef)
            gpsIFD?.remove(tagID: Tag.gpsSpeed)
        }

        if location.course >= 0 {
            gpsIFD?.set(tagID: Tag.gpsTrackRef, value: .ascii("T"))
            gpsIFD?.set(tagID: Tag.gpsTrack, value: .rational(URational(location.course, precision: 100)))
        } else {
            gpsIFD?.remove(tagID: Tag.gpsTrackRef)
            gpsIFD?.remove(tagID: Tag.gpsTrack)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: location.timestamp)
        let seconds = Double(c.second ?? 0) + Double(c.nanosecond ?? 0) / 1_000_000_000
        gpsIFD?.set(tagID: Tag.gpsDateStamp, value: .ascii(String(format: "%04d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)))
        gpsIFD?.set(tagID: Tag.gpsTimeStamp, value: .rationals([
            URational(numerator: UInt32(c.hour ?? 0), denominator: 1),
            URational(numerator: UInt32(c.minute ?? 0), denominator: 1),
            URational(seconds, precision: 1000),
        ]))
    }

    /// Direction of travel in degrees from true north; nil if absent or magnetic
    private var gpsCourse: Double? {
        guard let track = gpsIFD?.value(for: Tag.gpsTrack)?.doubleValue, (0 ..< 360).contains(track) else { return nil }
        return gpsIFD?.value(for: Tag.gpsTrackRef)?.stringValue == "M" ? nil : track
    }

    /// GPS speed converted to m/s (the reference defaults to km/h)
    private var gpsSpeedMetersPerSecond: Double? {
        guard let speed = gpsIFD?.value(for: Tag.gpsSpeed)?.doubleValue, speed >= 0 else { return nil }
        switch gpsIFD?.value(for: Tag.gpsSpeedRef)?.stringValue {
        case "M": return speed * 0.44704
        case "N": return speed * 0.514444
        default: return speed / 3.6
        }
    }

    /// GPS date and time (always UTC)
    private var gpsDate: Date? {
        guard let stamp = gpsIFD?.value(for: Tag.gpsDateStamp)?.stringValue,
              case let .rationals(time)? = gpsIFD?.value(for: Tag.gpsTimeStamp), time.count == 3 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd"
        guard let day = formatter.date(from: stamp.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return day.addingTimeInterval(time[0].doubleValue * 3600 + time[1].doubleValue * 60 + time[2].doubleValue)
    }
}
#endif
