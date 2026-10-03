import XCTest
@testable import Karman

final class SeismicTests: XCTestCase {
    func testTravelTimesMatchIASP91() {
        XCTAssertEqual(Seismology.travelTime(.p, degrees: 90, depthKm: 0), 777, accuracy: 1)
        XCTAssertEqual(Seismology.travelTime(.s, degrees: 30, depthKm: 0), 675, accuracy: 1)
        // A 600 km deep source reaches 30° in about five minutes.
        XCTAssertEqual(Seismology.travelTime(.p, degrees: 30, depthKm: 600), 301, accuracy: 10)
        XCTAssertLessThan(Seismology.travelTime(.p, degrees: 60, depthKm: 100), Seismology.travelTime(.p, degrees: 60, depthKm: 0))
    }

    func testFrontsInvertTravelTimes() {
        for degrees in [5.0, 25, 47, 88, 99, 120, 170] {
            for wave in Seismology.Wave.allCases {
                let t = Seismology.travelTime(wave, degrees: degrees, depthKm: 0)
                XCTAssertEqual(Seismology.front(wave, at: t), degrees, accuracy: 0.05)
            }
        }
    }

    func testTravelTimesNeverDecreaseWithDistance() {
        for depth in [0.0, 35, 150, 600] {
            var last = -1.0
            for d in stride(from: 0.0, through: 180, by: 0.25) {
                let t = Seismology.travelTime(.p, degrees: d, depthKm: depth)
                XCTAssertGreaterThanOrEqual(t, last)
                last = t
            }
        }
    }

    func testShakingIntensity() {
        XCTAssertEqual(Seismology.intensity(magnitude: 6, distanceKm: 0, depthKm: 10), 6.4, accuracy: 0.3)
        XCTAssertEqual(Seismology.intensity(magnitude: 7, distanceKm: 100, depthKm: 10), 4.5, accuracy: 0.3)
        XCTAssertLessThan(Seismology.intensity(magnitude: 5, distanceKm: 800, depthKm: 10), 2)
        XCTAssertEqual(Seismology.intensityRoman(4.4), "IV")
        XCTAssertEqual(Seismology.clock(754), "+12:34")
    }

    func testPlateBoundaries() throws {
        let plates = try XCTUnwrap(PlateBoundaries.bundled)
        XCTAssertEqual(plates.plates.count, 21)
        XCTAssertEqual(plates.nearest(to: GeoPoint(lat: 38.3, lon: 142.4))?.kind, .convergent)    // Tōhoku 2011
        XCTAssertEqual(plates.nearest(to: GeoPoint(lat: 35.8, lon: -120.4))?.kind, .transform)    // Parkfield
        XCTAssertEqual(plates.nearest(to: GeoPoint(lat: -54.5, lon: 0.7))?.kind, .divergent)      // SW Indian Ridge
        XCTAssertNil(plates.nearest(to: GeoPoint(lat: 20, lon: -160), maxKm: 300))                // Hawaii
    }
}
