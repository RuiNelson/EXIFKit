import Foundation

/// EXIF orientation: how the stored pixels must be transformed to display the image upright.
///
/// Raw values are the EXIF orientation codes. Rotations are clockwise and describe the
/// transform applied to the stored pixels. Case names match `UIImage.Orientation`.
public enum ImageOrientation: UInt16, CaseIterable, Sendable, Codable {
    /// 1 — Stored upright. No transform needed.
    case up = 1

    /// 2 — Mirror horizontally.
    case upMirrored = 2

    /// 3 — Rotate 180°.
    case down = 3

    /// 4 — Mirror vertically.
    case downMirrored = 4

    /// 5 — Mirror horizontally, then rotate 270°.
    case leftMirrored = 5

    /// 6 — Rotate 90°. Typical of a camera held in portrait with its top to the right.
    case right = 6

    /// 7 — Mirror horizontally, then rotate 90°.
    case rightMirrored = 7

    /// 8 — Rotate 270°. Typical of a camera held in portrait with its top to the left.
    case left = 8
}
