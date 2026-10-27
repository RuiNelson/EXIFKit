import Foundation

// MARK: - EXIF Errors

public enum EXIFError: Error, LocalizedError, CustomStringConvertible {
    case unexpectedEndOfData(needed: Int, available: Int, at: Int)
    case invalidOffset(Int, dataSize: Int)
    case invalidTIFFHeader
    case invalidByteOrder
    case unsupportedFormat(String)
    case tagNotFound(UInt16)
    case typeMismatch(expected: String, got: String)
    case invalidJPEG(String)
    case invalidPNG(String)
    case invalidWebP(String)
    case invalidHEIF(String)
    case invalidCR3(String)
    case invalidJXL(String)
    case invalidRAF(String)
    case invalidRAW(String)
    case corruptedIFD(String)
    case resourceLimitExceeded
    case writeFailed(String)

    public var description: String {
        switch self {
        case let .unexpectedEndOfData(needed, available, at):
            return "Unexpected end of data at offset \(at): needed \(needed) bytes, \(available) available"
        case let .invalidOffset(offset, dataSize):
            return "Invalid offset \(offset) for data of size \(dataSize)"
        case .invalidTIFFHeader:
            return "Invalid TIFF header"
        case .invalidByteOrder:
            return "Invalid byte order marker (expected 'II' or 'MM')"
        case let .unsupportedFormat(fmt):
            return "Unsupported format: \(fmt)"
        case let .tagNotFound(tag):
            return "Tag 0x\(String(tag, radix: 16, uppercase: true)) not found"
        case let .typeMismatch(expected, got):
            return "Type mismatch: expected \(expected), got \(got)"
        case let .invalidJPEG(detail):
            return "Invalid JPEG: \(detail)"
        case let .invalidPNG(detail):
            return "Invalid PNG: \(detail)"
        case let .invalidWebP(detail):
            return "Invalid WebP: \(detail)"
        case let .invalidHEIF(detail):
            return "Invalid HEIF/HEIC: \(detail)"
        case let .invalidCR3(detail):
            return "Invalid CR3: \(detail)"
        case let .invalidJXL(detail):
            return "Invalid JPEG XL: \(detail)"
        case let .invalidRAF(detail):
            return "Invalid RAF: \(detail)"
        case let .invalidRAW(detail):
            return "Invalid RAW: \(detail)"
        case let .corruptedIFD(detail):
            return "Corrupted IFD: \(detail)"
        case .resourceLimitExceeded:
            return "Metadata exceeds the configured resource limits"
        case let .writeFailed(detail):
            return "Write failed: \(detail)"
        }
    }

    public var errorDescription: String? {
        description
    }
}

// MARK: - Rational Number Types

/// Unsigned rational (used for aperture, focal length, GPS coordinates, etc.)
public struct URational: Equatable, Hashable, CustomStringConvertible, Sendable {
    public let numerator: UInt32
    public let denominator: UInt32

    public var doubleValue: Double {
        guard denominator != 0 else { return 0 }
        return Double(numerator) / Double(denominator)
    }

    public var description: String {
        "\(numerator)/\(denominator)"
    }

    public init(numerator: UInt32, denominator: UInt32) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// Convenience: create from a double with a given denominator precision
    public init(_ value: Double, precision: UInt32 = 10000) {
        denominator = precision
        numerator = UInt32(clamping: Int64((value * Double(precision)).rounded()))
    }
}

public extension URational {
    /// The same value with numerator and denominator divided by their greatest common divisor
    var reduced: URational {
        var a = numerator, b = denominator
        while b != 0 {
            (a, b) = (b, a % b)
        }
        guard a > 1 else { return self }
        return URational(numerator: numerator / a, denominator: denominator / a)
    }

    /// The value read as an exposure time in seconds: "1/250 s", "30 s" or "0.4 s"
    var exposureTimeString: String {
        let fraction = reduced
        if fraction.numerator == 1 && fraction.denominator > 1 {
            return "1/\(fraction.denominator) s"
        }
        if fraction.denominator == 1 {
            return "\(fraction.numerator) s"
        }

        var decimal = String(format: "%.1f", fraction.doubleValue)
        while decimal.hasSuffix("0") || decimal.hasSuffix(".") {
            decimal.removeLast()
        }
        return decimal + " s"
    }
}

/// Signed rational (used for exposure bias, etc.)
public struct SRational: Equatable, Hashable, CustomStringConvertible, Sendable {
    public let numerator: Int32
    public let denominator: Int32

    public var doubleValue: Double {
        guard denominator != 0 else { return 0 }
        return Double(numerator) / Double(denominator)
    }

    public var description: String {
        "\(numerator)/\(denominator)"
    }

    public init(numerator: Int32, denominator: Int32) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// Convenience: create from a double
    public init(_ value: Double, precision: Int32 = 10000) {
        denominator = precision
        numerator = Int32(clamping: Int64((value * Double(precision)).rounded()))
    }
}

// MARK: - EXIF Data Type IDs

/// The 12 data types defined by the TIFF/EXIF spec.
/// Each IFD entry declares its type, which determines how to read the value bytes.
public enum EXIFDataType: UInt16, CaseIterable, Sendable {
    case byte = 1 // UInt8
    case ascii = 2 // 7-bit ASCII, null-terminated
    case short = 3 // UInt16
    case long = 4 // UInt32
    case rational = 5 // Two UInt32s (numerator/denominator)
    case sbyte = 6 // Int8
    case undefined = 7 // Arbitrary bytes
    case sshort = 8 // Int16
    case slong = 9 // Int32
    case srational = 10 // Two Int32s (numerator/denominator)
    case float = 11 // IEEE 754 float
    case double = 12 // IEEE 754 double

    /// Size in bytes of a single element of this type
    public var unitSize: Int {
        switch self {
        case .byte, .sbyte, .ascii, .undefined: return 1
        case .short, .sshort: return 2
        case .long, .slong, .float: return 4
        case .rational, .srational, .double: return 8
        }
    }
}

// MARK: - Tag Value

/// A type-safe wrapper for EXIF tag values.
/// This is what you get when you read a tag and what you provide when you write one.
public enum TagValue: Equatable, CustomStringConvertible, Sendable {
    case byte(UInt8)
    case bytes([UInt8])
    case ascii(String)
    case short(UInt16)
    case shorts([UInt16])
    case long(UInt32)
    case longs([UInt32])
    case rational(URational)
    case rationals([URational])
    case srational(SRational)
    case srationals([SRational])
    case signedByte(Int8)
    case signedBytes([Int8])
    case signedShort(Int16)
    case signedShorts([Int16])
    case signedLong(Int32)
    case signedLongs([Int32])
    case float(Float)
    case floats([Float])
    case double(Double)
    case doubles([Double])
    case undefined(Data)

    public var description: String {
        switch self {
        case let .byte(v): return "\(v)"
        case let .bytes(v): return "\(v)"
        case let .ascii(v): return v
        case let .short(v): return "\(v)"
        case let .shorts(v): return "\(v)"
        case let .long(v): return "\(v)"
        case let .longs(v): return "\(v)"
        case let .rational(v): return v.description
        case let .rationals(v): return v.map(\.description).joined(separator: ", ")
        case let .srational(v): return v.description
        case let .srationals(v): return v.map(\.description).joined(separator: ", ")
        case let .signedByte(v): return "\(v)"
        case let .signedBytes(v): return "\(v)"
        case let .signedShort(v): return "\(v)"
        case let .signedShorts(v): return "\(v)"
        case let .signedLong(v): return "\(v)"
        case let .signedLongs(v): return "\(v)"
        case let .float(v): return "\(v)"
        case let .floats(v): return "\(v)"
        case let .double(v): return "\(v)"
        case let .doubles(v): return "\(v)"
        case let .undefined(v): return "\(v.count) bytes"
        }
    }

    // MARK: - Convenience accessors

    /// Get as string (works for .ascii, falls back to description)
    public var stringValue: String? {
        if case let .ascii(s) = self {
            return s
        }
        return nil
    }

    /// Get as UInt32 (works for .byte, .short, .long)
    public var uint32Value: UInt32? {
        switch self {
        case let .byte(v): return UInt32(v)
        case let .short(v): return UInt32(v)
        case let .long(v): return v
        default: return nil
        }
    }

    /// Get as Int (works for all integer types)
    public var intValue: Int? {
        switch self {
        case let .byte(v): return Int(v)
        case let .short(v): return Int(v)
        case let .long(v): return Int(v)
        case let .signedByte(v): return Int(v)
        case let .signedShort(v): return Int(v)
        case let .signedLong(v): return Int(v)
        default: return nil
        }
    }

    /// Get as Double (works for rational types, integers, and floats)
    public var doubleValue: Double? {
        switch self {
        case let .byte(v): return Double(v)
        case let .short(v): return Double(v)
        case let .long(v): return Double(v)
        case let .rational(v): return v.doubleValue
        case let .srational(v): return v.doubleValue
        case let .signedByte(v): return Double(v)
        case let .signedShort(v): return Double(v)
        case let .signedLong(v): return Double(v)
        case let .float(v): return Double(v)
        case let .double(v): return v
        default: return nil
        }
    }

    /// Get raw bytes (works for .undefined, .bytes)
    public var rawData: Data? {
        switch self {
        case let .undefined(d): return d
        case let .bytes(b): return Data(b)
        default: return nil
        }
    }

    /// The EXIF data type ID this value would serialize as
    public var dataType: EXIFDataType {
        switch self {
        case .byte, .bytes: return .byte
        case .ascii: return .ascii
        case .short, .shorts: return .short
        case .long, .longs: return .long
        case .rational, .rationals: return .rational
        case .srational, .srationals: return .srational
        case .signedByte, .signedBytes: return .sbyte
        case .signedShort, .signedShorts: return .sshort
        case .signedLong, .signedLongs: return .slong
        case .float, .floats: return .float
        case .double, .doubles: return .double
        case .undefined: return .undefined
        }
    }

    /// The number of elements (count field in IFD entry)
    public var count: UInt32 {
        switch self {
        case .byte, .signedByte, .short, .signedShort,
             .long, .signedLong, .rational, .srational,
             .float, .double:
            return 1
        case let .bytes(v): return UInt32(v.count)
        case let .ascii(v): return UInt32(v.utf8.count + 1) // +1 for null terminator
        case let .shorts(v): return UInt32(v.count)
        case let .signedBytes(v): return UInt32(v.count)
        case let .signedShorts(v): return UInt32(v.count)
        case let .longs(v): return UInt32(v.count)
        case let .signedLongs(v): return UInt32(v.count)
        case let .rationals(v): return UInt32(v.count)
        case let .srationals(v): return UInt32(v.count)
        case let .floats(v): return UInt32(v.count)
        case let .doubles(v): return UInt32(v.count)
        case let .undefined(v): return UInt32(v.count)
        }
    }

    /// Total size in bytes when serialized
    public var totalSize: Int {
        Int(count) * dataType.unitSize
    }
}
