import Foundation

/// EXIF color space tag value.
///
/// The EXIF standard defines only `sRGB` and `uncalibrated`. The other cases are
/// non-standard values written by some cameras and documented by ExifTool.
public enum ImageColorSpace: UInt16, CaseIterable, Sendable, Codable {
    /// 1 — sRGB.
    case sRGB = 1

    /// 2 — Adobe RGB. Non-standard; most cameras write `uncalibrated` plus interoperability index "R03" instead.
    case adobeRGB = 2

    /// 65533 — Wide Gamut RGB. Non-standard.
    case wideGamutRGB = 0xFFFD

    /// 65534 — Color described by an ICC profile. Non-standard.
    case iccProfile = 0xFFFE

    /// 65535 — Uncalibrated. Check the interoperability index ("R03" is Adobe RGB) or the embedded ICC profile.
    case uncalibrated = 0xFFFF
}
