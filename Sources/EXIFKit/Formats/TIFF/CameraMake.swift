import Foundation

/// Well-known camera manufacturers, recognized from the EXIF `Make` string.
public enum CameraMake: String, CaseIterable, Sendable, Codable {
    case canon, nikon, sony, pentax, panasonicLumix, leica, leaf, mamiya, hasselblad, fujifilm, olympus, phaseOne, sigma, konicaMinolta
    case apple, samsung, xiaomi, vivo, oppo, honor, motorola, lenovo, huawei, google, onePlus

    /// Lowercased substrings that identify this make in an EXIF `Make` string.
    var matchStrings: [String] {
        switch self {
        case .phaseOne: ["phase one"]
        case .pentax: ["pentax", "ricoh"]
        case .panasonicLumix: ["panasonic", "lumix"]
        case .olympus: ["olympus", "om digital"]
        case .konicaMinolta: ["konica minolta"]
        case .onePlus: ["oneplus"]
        default: [rawValue]
        }
    }

    /// Creates a make by matching the EXIF `Make` string case-insensitively; nil if unrecognized.
    init?(fromExifString string: String) {
        let lowercased = string.lowercased()
        guard let make = Self.allCases.first(where: { make in
            make.matchStrings.contains { lowercased.contains($0) }
        }) else { return nil }
        self = make
    }
}
