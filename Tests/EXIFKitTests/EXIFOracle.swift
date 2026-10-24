@testable import EXIFKit
import Foundation
import Testing

/// Values are untranslated exiv2 output, so rationals and undefined bytes retain their exact representation.
struct EXIFOracleTag: Equatable, Sendable {
    let id: UInt16
    let key: String
    let type: String
    let count: UInt32
    let value: String

    var group: String {
        String(key.split(separator: ".")[1])
    }

    static func parse(_ data: Data) throws -> [EXIFOracleTag] {
        try String(decoding: data, as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("#") }.map { line in
            let fields = line.split(maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            let tag = try #require(fields.first.flatMap { UInt16($0.dropFirst(2), radix: 16) })
            try #require(fields.count >= 4, "Malformed exiv2 reference: \(line)")
            let count = try #require(UInt32(fields[3]))
            return EXIFOracleTag(id: tag, key: String(fields[1]), type: String(fields[2]), count: count,
                                 value: fields.count == 5 ? String(fields[4].drop(while: { $0.isWhitespace })) : "")
        }
    }

    static func assertMatches(_ metadata: TIFFStructure, tags: [EXIFOracleTag]) throws {
        let directories: [String: IFD?] = ["Image": metadata.ifd0, "Photo": metadata.exifIFD,
                                           "Thumbnail": metadata.ifd1, "GPSInfo": metadata.gpsIFD, "Iop": metadata.interopIFD]
        let types: [EXIFDataType: String] = [.ascii: "Ascii", .byte: "Byte", .short: "Short", .long: "Long",
                                             .rational: "Rational", .undefined: "Undefined", .sbyte: "SByte",
                                             .sshort: "SShort", .slong: "SLong", .srational: "SRational",
                                             .float: "Float", .double: "Double"]
        #expect(directories.values.compactMap { $0 }.reduce(0) { $0 + $1.entries.count } == tags.count)
        for tag in tags {
            let directory = try #require(directories[tag.group] ?? nil, "Missing directory for \(tag.key)")
            let entry = try #require(directory.entry(for: tag.id), "Missing \(tag.key)")
            #expect(types[entry.dataType] == tag.type, "Type of \(tag.key)")
            #expect(entry.count == tag.count, "Count of \(tag.key)")
            #expect(plainValue(entry.value) == tag.value, "Value of \(tag.key)")
        }
    }

    private static func plainValue(_ value: TagValue) -> String {
        switch value {
        case let .undefined(data): return data.map(String.init).joined(separator: " ")
        case let .bytes(values): return values.map(String.init).joined(separator: " ")
        case let .shorts(values): return values.map(String.init).joined(separator: " ")
        case let .longs(values): return values.map(String.init).joined(separator: " ")
        case let .signedBytes(values): return values.map(String.init).joined(separator: " ")
        case let .signedShorts(values): return values.map(String.init).joined(separator: " ")
        case let .signedLongs(values): return values.map(String.init).joined(separator: " ")
        case let .rationals(values): return values.map(\.description).joined(separator: " ")
        case let .srationals(values): return values.map(\.description).joined(separator: " ")
        default: return value.description
        }
    }
}

enum NikonFixture {
    static func url(_ name: String = "NikonD90", extension suffix: String = "jpg") throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: suffix, subdirectory: "Fixtures"))
    }

    static func tags() throws -> [EXIFOracleTag] {
        try EXIFOracleTag.parse(Data(contentsOf: url("NikonD90.exiv2", extension: "txt")))
    }

    static func thumbnail() throws -> Data {
        try Data(contentsOf: url("NikonD90.exiv2-thumbnail"))
    }
}
