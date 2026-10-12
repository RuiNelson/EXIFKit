import Foundation

// MARK: - JPEG Marker Constants

/// JPEG files are a sequence of marker segments.
/// Each marker is 0xFF followed by a type byte.
private enum JPEGMarker {
    static let prefix:  UInt8 = 0xFF
    static let soi:     UInt8 = 0xD8  // Start of Image
    static let eoi:     UInt8 = 0xD9  // End of Image
    static let app0:    UInt8 = 0xE0  // JFIF
    static let app1:    UInt8 = 0xE1  // EXIF / XMP
    static let sos:     UInt8 = 0xDA  // Start of Scan (image data follows)
}

/// The 6-byte header that identifies an EXIF APP1 segment: "Exif\0\0"
private let exifHeader = Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])

// MARK: - JPEG Container

/// Reads and writes EXIF metadata embedded in JPEG files.
///
/// JPEG structure (simplified):
/// ```
/// FF D8              <- SOI (Start of Image)
/// FF E1 [len] [data] <- APP1 (EXIF) — this is what we care about
/// FF E0 [len] [data] <- APP0 (JFIF) — we preserve this
/// ...other markers...
/// FF DA [len] [data] <- SOS + compressed image data
/// FF D9              <- EOI (End of Image)
/// ```
///
/// Our strategy for writing:
/// 1. Parse all marker segments into an ordered list
/// 2. Find or create the EXIF APP1 segment
/// 3. Rebuild the JPEG with the modified APP1
///
/// This preserves all non-EXIF data (image pixels, JFIF, ICC profiles, etc.).
public struct JPEGContainer {

    /// A parsed JPEG marker segment
    struct MarkerSegment {
        let marker: UInt8
        var data: Data  // everything after the 2-byte length field

        /// Is this an EXIF APP1 segment?
        var isEXIF: Bool {
            marker == JPEGMarker.app1 && data.count >= 6 && data.prefix(6) == exifHeader
        }
    }

    // MARK: - Reading

    /// Extract EXIF metadata from JPEG file data.
    ///
    /// - Parameter jpegData: The raw JPEG file bytes
    /// - Returns: Parsed TIFF structure containing all EXIF data
    public static func readEXIF(from jpegData: Data) throws -> TIFFStructure {
        let segments = try parseSegments(jpegData).segments

        guard let exifSegment = segments.first(where: { $0.isEXIF }) else {
            throw EXIFError.invalidJPEG("No EXIF APP1 segment found")
        }

        // The TIFF data starts after the 6-byte "Exif\0\0" header
        let tiffData = exifSegment.data.dropFirst(6)
        return try TIFFParser.parse(Data(tiffData))
    }

    // MARK: - Writing

    /// Write modified EXIF metadata back into a JPEG file.
    ///
    /// - Parameters:
    ///   - structure: The (possibly modified) TIFF structure
    ///   - jpegData: The original JPEG file data
    /// - Returns: New JPEG file data with updated EXIF
    public static func writeEXIF(_ structure: TIFFStructure, to jpegData: Data) throws -> Data {
        var (segments, sosOffset) = try parseSegments(jpegData)

        // Build the new APP1 payload: "Exif\0\0" + TIFF data
        let tiffData = TIFFSerializer.serialize(structure)
        var app1Payload = exifHeader
        app1Payload.append(tiffData)
        // The segment length field is a UInt16 that counts itself.
        guard app1Payload.count + 2 <= Int(UInt16.max) else {
            throw EXIFError.writeFailed("EXIF data is \(app1Payload.count) bytes; a JPEG APP1 segment holds at most 65533")
        }

        // Find existing EXIF segment and replace it, or insert after SOI
        if let exifIndex = segments.firstIndex(where: { $0.isEXIF }) {
            segments[exifIndex].data = app1Payload
        } else {
            // Insert after SOI, but keep a leading JFIF APP0 first as JFIF requires
            let newSegment = MarkerSegment(marker: JPEGMarker.app1, data: app1Payload)
            segments.insert(newSegment, at: segments.first?.marker == JPEGMarker.app0 ? 1 : 0)
        }

        return try assembleJPEG(segments: segments, sosOffset: sosOffset, originalData: jpegData)
    }

    /// Remove all EXIF data from a JPEG file.
    public static func stripEXIF(from jpegData: Data) throws -> Data {
        var (segments, sosOffset) = try parseSegments(jpegData)
        segments.removeAll(where: { $0.isEXIF })
        return try assembleJPEG(segments: segments, sosOffset: sosOffset, originalData: jpegData)
    }

    // MARK: - Segment Parsing

    /// Parse a JPEG file into its component marker segments.
    ///
    /// This extracts all segments BEFORE the SOS marker.
    /// Everything from SOS onward (the actual image data) is treated as a
    /// single opaque blob that we pass through untouched. `sosOffset` is nil when
    /// the data ends before SOS (enough for reading, not for rewriting).
    private static func parseSegments(_ data: Data) throws -> (segments: [MarkerSegment], sosOffset: Int?) {
        guard data.count >= 4 else {
            throw EXIFError.invalidJPEG("File too small")
        }

        // Verify SOI
        guard data[data.startIndex] == JPEGMarker.prefix,
              data[data.startIndex + 1] == JPEGMarker.soi else {
            throw EXIFError.invalidJPEG("Missing SOI marker")
        }

        var segments: [MarkerSegment] = []
        var offset = 2 // Skip SOI

        while offset < data.count - 1 {
            // Find next marker
            guard data[data.startIndex + offset] == JPEGMarker.prefix else {
                throw EXIFError.invalidJPEG("Expected marker at offset \(offset)")
            }

            // Any marker may be preceded by 0xFF fill bytes
            if data[data.startIndex + offset + 1] == JPEGMarker.prefix {
                offset += 1
                continue
            }

            let markerType = data[data.startIndex + offset + 1]
            offset += 2

            // SOS marks the beginning of compressed image data — stop parsing
            if markerType == JPEGMarker.sos {
                return (segments, offset - 2)
            }

            // Skip standalone markers (no length field)
            if markerType == JPEGMarker.soi || markerType == JPEGMarker.eoi {
                continue
            }

            // Markers 0xFF00–0xFFFF with 0xD0-0xD7 (RST markers) are also standalone
            if markerType >= 0xD0 && markerType <= 0xD7 {
                continue
            }

            // Read segment length (2 bytes, big-endian, includes the 2 length bytes)
            guard offset + 2 <= data.count else {
                throw EXIFError.invalidJPEG("Truncated segment length at offset \(offset)")
            }

            let length = Int(data[data.startIndex + offset]) << 8 | Int(data[data.startIndex + offset + 1])
            offset += 2

            guard length >= 2 else {
                throw EXIFError.invalidJPEG("Invalid segment length \(length) at offset \(offset)")
            }

            let payloadLength = length - 2
            guard offset + payloadLength <= data.count else {
                throw EXIFError.invalidJPEG("Segment data exceeds file size")
            }

            let segmentData = data[(data.startIndex + offset)..<(data.startIndex + offset + payloadLength)]
            segments.append(MarkerSegment(marker: markerType, data: Data(segmentData)))
            offset += payloadLength
        }

        return (segments, nil)
    }

    /// Reassemble a JPEG file from segments + the original SOS/image data.
    ///
    /// We reconstruct the header segments and append the original image data
    /// (everything from SOS onward) unchanged.
    private static func assembleJPEG(segments: [MarkerSegment], sosOffset: Int?, originalData: Data) throws -> Data {
        // Without SOS there is no image data to carry over; writing would silently drop it.
        guard let sosOffset else {
            throw EXIFError.invalidJPEG("No SOS marker found")
        }

        var output = Data()

        // SOI
        output.append(JPEGMarker.prefix)
        output.append(JPEGMarker.soi)

        // All header segments
        for segment in segments {
            output.append(JPEGMarker.prefix)
            output.append(segment.marker)
            // Length = payload size + 2 (for the length field itself); parsed segments always fit
            let length = UInt16(segment.data.count + 2)
            output.append(UInt8(length >> 8))
            output.append(UInt8(length & 0xFF))
            output.append(segment.data)
        }

        output.append(originalData[(originalData.startIndex + sosOffset)...])

        return output
    }
}
