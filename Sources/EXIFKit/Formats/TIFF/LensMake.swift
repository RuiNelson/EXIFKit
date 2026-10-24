import Foundation

/// Well-known lens manufacturers, recognized from the EXIF `LensMake` string.
public enum LensMake: String, CaseIterable, Sendable, Codable {
    case canon, nikon, sony, pentax, panasonicLumix, leica, olympus, fujifilm, hasselblad, mamiya, konicaMinolta, apple
    case sigma, tamron, tokina, carlZeiss, samyang, voigtlander, laowa, viltrox, ttArtisan, sevenArtisans
    case irix, meike, kowa, schneider, rodenstock, cosina

    /// Lowercased substrings that identify this make in an EXIF `LensMake` string.
    var matchStrings: [String] {
        switch self {
        case .nikon: ["nikon", "nikkor"]
        case .pentax: ["pentax", "ricoh"]
        case .panasonicLumix: ["panasonic", "lumix"]
        case .olympus: ["olympus", "om digital"]
        case .konicaMinolta: ["konica", "minolta"]
        case .carlZeiss: ["zeiss"]
        case .samyang: ["samyang", "rokinon"]
        case .voigtlander: ["voigtl"]
        case .laowa: ["laowa", "venus optics"]
        case .ttArtisan: ["ttartisan", "tt artisan"]
        case .sevenArtisans: ["7artisans", "7 artisans"]
        default: [rawValue]
        }
    }

    /// Creates a make by matching the EXIF `LensMake` string case-insensitively; nil if unrecognized.
    init?(fromExifString string: String) {
        let lowercased = string.lowercased()
        guard let make = Self.allCases.first(where: { make in
            make.matchStrings.contains { lowercased.contains($0) }
        }) else { return nil }
        self = make
    }
}
