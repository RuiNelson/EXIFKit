@testable import EXIFKit
import Foundation
import Testing

#if canImport(CoreLocation)
import CoreLocation
#endif

private func read(_ raw: String) async throws -> TIFFStructure {
    try await EXIFKit.read(from: RAWFixture.url(raw))
}

private func readNikon() async throws -> TIFFStructure {
    try await EXIFKit.read(from: NikonFixture.url())
}

/// Nikon D90 JPEG is in git; the RAW samples are local-only and their tests are skipped without them.
struct ConvenienceTests {
    // MARK: - Nikon D90 JPEG

    @Test func nikonMakeAndExposure() async throws {
        let s = try await readNikon()
        #expect(s.makeTyped == .nikon)
        #expect(s.lensMakeTyped == nil)
        #expect(s.exposureTimeFraction == URational(numerator: 1, denominator: 250))
        #expect(s.exposureTimeFraction?.exposureTimeString == "1/250 s")
    }

    @Test func nikonDateReadsAsUTCWithoutOffset() async throws {
        let s = try await readNikon()
        #expect(s.taken == Date(timeIntervalSince1970: 1_282_319_827)) // 2010-08-20 15:57:07 UTC
        #expect(s.digitized == nil)
    }

    @Test func nikonHasNoOrientationColorSpaceOrLocation() async throws {
        let s = try await readNikon()
        #expect(s.orientationTyped == nil)
        #expect(s.colorSpaceTyped == nil)
        #if canImport(CoreLocation)
        #expect(s.location == nil)
        #endif
    }

    // MARK: - RAW samples

    @Test(.enabled(if: RAWFixture.available.contains("Canon5DMk2.cr2")))
    func canonCR2() async throws {
        let s = try await read("Canon5DMk2.cr2")
        #expect(s.makeTyped == .canon)
        #expect(s.orientationTyped == .up)
        #expect(s.colorSpaceTyped == .sRGB)
        #expect(s.exposureTimeFraction?.exposureTimeString == "1/50 s")
        #expect(s.taken == Date(timeIntervalSince1970: 1_500_561_086))
        #expect(s.digitized == s.taken)
    }

    @Test(.enabled(if: RAWFixture.available.contains("NikonD300.NEF")))
    func nikonNEF() async throws {
        let s = try await read("NikonD300.NEF")
        #expect(s.makeTyped == .nikon)
        #expect(s.orientationTyped == .up)
        #expect(s.colorSpaceTyped == nil)
        #expect(s.exposureTimeFraction?.exposureTimeString == "1/10 s")
    }

    @Test(.enabled(if: RAWFixture.available.contains("SonyAlpha7Mk3.ARW")))
    func sonyARWUsesOffsets() async throws {
        let s = try await read("SonyAlpha7Mk3.ARW")
        #expect(s.makeTyped == .sony)
        #expect(s.colorSpaceTyped == .uncalibrated)
        #expect(s.offsetTimeOriginal == "+01:00")
        #expect(s.offsetTimeDigitized == "+01:00")
        // 2018-03-13 16:38:58 at +01:00
        #expect(s.taken == Date(timeIntervalSince1970: 1_520_955_538))
        #expect(s.digitized == s.taken)
        #expect(s.exposureTimeFraction?.exposureTimeString == "1/50 s")
    }

    @Test(.enabled(if: RAWFixture.available.contains("Canon5DMk3-AdobeConverted.DNG")))
    func canonDNG() async throws {
        let s = try await read("Canon5DMk3-AdobeConverted.DNG")
        #expect(s.makeTyped == .canon)
        #expect(s.colorSpaceTyped == .sRGB)
        #expect(s.exposureTimeFraction?.exposureTimeString == "1/125 s")
    }

    @Test(.enabled(if: RAWFixture.available.contains("iPhone14Pro.DNG")))
    func iPhoneDNG() async throws {
        let s = try await read("iPhone14Pro.DNG")
        #expect(s.makeTyped == .apple)
        #expect(s.lensMakeTyped == .apple)
        #expect(s.orientation == 6)
        #expect(s.orientationTyped == .right)
        #expect(s.offsetTimeOriginal == "+01:00")
        #expect(s.exposureTimeFraction?.exposureTimeString == "1/34 s")
        // 2026-10-24 03:37:30 at +01:00
        #expect(s.taken == Date(timeIntervalSince1970: 1_792_809_450))
    }

    #if canImport(CoreLocation)
    @Test(.enabled(if: RAWFixture.available.contains("iPhone14Pro.DNG")))
    func iPhoneLocation() async throws {
        let s = try await read("iPhone14Pro.DNG")
        let location = try #require(s.location)
        #expect(abs(location.coordinate.latitude - 41.17496111) < 1e-6)
        #expect(abs(location.coordinate.longitude + 8.59029167) < 1e-6)
        #expect(abs(location.altitude - 137.2329) < 1e-3)
        #expect(location.verticalAccuracy >= 0)
    }

    @Test(.enabled(if: RAWFixture.available.contains("iPhone14Pro.DNG")))
    func locationSurvivesRoundTrip() async throws {
        var s = try await read("iPhone14Pro.DNG")
        let original = try #require(s.location)
        s.setLocation(CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093),
            altitude: -12.5, horizontalAccuracy: 5, verticalAccuracy: 3,
            course: 270, speed: 10, timestamp: original.timestamp
        ))
        let result = try #require(s.location)
        #expect(abs(result.coordinate.latitude + 33.8688) < 1e-4)
        #expect(abs(result.coordinate.longitude - 151.2093) < 1e-4)
        #expect(abs(result.altitude + 12.5) < 1e-3)
        #expect(result.horizontalAccuracy == 5)
        #expect(result.course == 270)
        #expect(abs(result.speed - 10) < 0.01)
    }

    @Test func setLocationOnNikonAddsGPSAndRemovesInvalidValues() async throws {
        var s = try await readNikon()
        s.setLocation(CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 10, longitude: 20),
            altitude: 5, horizontalAccuracy: 5, verticalAccuracy: 3, course: 90, speed: 4, timestamp: Date()
        ))
        #expect(s.location != nil)
        s.setLocation(CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 10, longitude: 20),
            altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1, course: -1, speed: -1, timestamp: Date()
        ))
        let ifd = try #require(s.gpsIFD)
        #expect(ifd.value(for: Tag.gpsSpeed) == nil)
        #expect(ifd.value(for: Tag.gpsTrack) == nil)
        #expect(ifd.value(for: Tag.gpsHPositioningError) == nil)
        #expect(try #require(s.location).speed < 0)
    }
    #endif
}

/// Pure value logic with no file involved.
struct ValueTests {
    @Test func makeMatching() {
        #expect(CameraMake(fromExifString: "Phase One A/S") == .phaseOne)
        #expect(CameraMake(fromExifString: "Panasonic") == .panasonicLumix)
        #expect(CameraMake(fromExifString: "OnePlus") == .onePlus)
        #expect(CameraMake(fromExifString: "RICOH IMAGING COMPANY, LTD.") == .pentax)
        #expect(CameraMake(fromExifString: "PENTAX Corporation") == .pentax)
        #expect(CameraMake(fromExifString: "OM Digital Solutions") == .olympus)
        #expect(CameraMake(fromExifString: "Unknown Maker") == nil)
        #expect(LensMake(fromExifString: "Carl Zeiss") == .carlZeiss)
        #expect(LensMake(fromExifString: "Voigtländer") == .voigtlander)
        #expect(LensMake(fromExifString: "TTArtisan") == .ttArtisan)
        #expect(LensMake(fromExifString: "Nobody") == nil)
    }

    @Test func orientationAndColorSpaceRawValues() {
        for raw in UInt16(1) ... 8 { #expect(ImageOrientation(rawValue: raw) != nil) }
        #expect(ImageOrientation(rawValue: 0) == nil)
        #expect(ImageOrientation(rawValue: 9) == nil)
        #expect(ImageColorSpace(rawValue: 1) == .sRGB)
        #expect(ImageColorSpace(rawValue: 2) == .adobeRGB)
        #expect(ImageColorSpace(rawValue: 0xFFFF) == .uncalibrated)
        #expect(ImageColorSpace(rawValue: 7) == nil)
    }

    @Test func rationalReducedAndExposureString() {
        #expect(URational(numerator: 10, denominator: 2500).reduced == URational(numerator: 1, denominator: 250))
        #expect(URational(numerator: 0, denominator: 5).reduced == URational(numerator: 0, denominator: 1))
        #expect(URational(numerator: 10, denominator: 2500).exposureTimeString == "1/250 s")
        #expect(URational(numerator: 30, denominator: 1).exposureTimeString == "30 s")
        #expect(URational(numerator: 2, denominator: 5).exposureTimeString == "0.4 s")
        #expect(URational(numerator: 13, denominator: 10).exposureTimeString == "1.3 s")
    }
}
