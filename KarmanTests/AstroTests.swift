import XCTest
@testable import Karman

final class AstroTests: XCTestCase {
    func testSubsolarPointAtEquinox() {
        // 2024 March equinox: 2024-03-20 03:06 UTC, the Sun is overhead at the equator.
        let date = ISO8601DateFormatter().date(from: "2024-03-20T03:06:00Z")!
        XCTAssertEqual(Astro.subsolarPoint(date).lat, 0, accuracy: 0.1)
    }

    func testSubsolarPointAtJuneSolstice() {
        let date = ISO8601DateFormatter().date(from: "2024-06-20T20:51:00Z")!
        XCTAssertEqual(Astro.subsolarPoint(date).lat, 23.44, accuracy: 0.1)
    }

    func testMoonPhaseNearKnownFullMoon() {
        // Full Moon: 2024-04-23 23:49 UTC
        let date = ISO8601DateFormatter().date(from: "2024-04-23T23:49:00Z")!
        let phase = Astro.moonPhase(date)
        XCTAssertGreaterThan(phase.illumination, 0.98)
        XCTAssertEqual(phase.phase, 0.5, accuracy: 0.03)
    }

    func testSunsetIstanbulIsPlausible() {
        // Istanbul, 2026-10-03: sunset around 15:45 UTC (18:45 local).
        let start = ISO8601DateFormatter().date(from: "2026-10-03T06:00:00Z")!
        let times = Astro.sunTimes(from: start, observer: GeoPoint(lat: 41.01, lon: 28.98))
        let sunset = try! XCTUnwrap(times.sunset)
        let expected = ISO8601DateFormatter().date(from: "2026-10-03T15:45:00Z")!
        XCTAssertLessThan(abs(sunset.timeIntervalSince(expected)), 10 * 60)
    }

    func testGreatCircleDistance() {
        let istanbul = GeoPoint(lat: 41.01, lon: 28.98), london = GeoPoint(lat: 51.5, lon: -0.12)
        XCTAssertEqual(istanbul.distanceKm(to: london), 2500, accuracy: 30)
    }
}

final class SGP4Tests: XCTestCase {
    /// Reference values from python-sgp4 (Vallado) for the same element set.
    func testISSMatchesReferenceImplementation() throws {
        let json = #"{"name": "ISS (ZARYA)", "id": 25544, "epoch": "2026-10-02T11:10:18.655680", "mm": 15.48710782, "ecc": 0.00069284, "inc": 51.6313, "raan": 129.1782, "argp": 213.7086, "ma": 146.3462, "bstar": 7.4913218e-05, "ndot": 3.639e-05, "nddot": 0}"#
        let elements = try JSONDecoder().decode(OrbitalElements.self, from: Data(json.utf8))
        let sat = try SGP4(elements: elements)
        let r0 = try sat.propagate(minutes: 0).position
        XCTAssertEqual(r0.x, -4297.873529, accuracy: 1e-3)
        XCTAssertEqual(r0.y, 5273.813604, accuracy: 1e-3)
        XCTAssertEqual(r0.z, -0.003534, accuracy: 1e-3)
        let r1 = try sat.propagate(minutes: 1440).position
        XCTAssertEqual(r1.x, 3771.229786, accuracy: 1e-3)
        XCTAssertEqual(r1.y, -5652.566131, accuracy: 1e-3)
        XCTAssertEqual(r1.z, 77.906939, accuracy: 1e-3)
        XCTAssertEqual(sat.periodMinutes, 92.98, accuracy: 0.1)
    }

    func testDeepSpaceOrbitsAreRejected() {
        var e = OrbitalElements(name: "GPS", id: 1, epoch: "2026-10-01T00:00:00", mm: 2.0056, ecc: 0.01, inc: 55, raan: 10, argp: 20, ma: 30, bstar: 0, ndot: 0, nddot: 0)
        XCTAssertThrowsError(try SGP4(elements: e))
        e.mm = 15.5
        XCTAssertNoThrow(try SGP4(elements: e))
    }
}

final class AuroraTests: XCTestCase {
    func testVisibleChanceFallsOffWithDistance() {
        var grid = [UInt8](repeating: 0, count: 360 * 181)
        // A strong oval band at 66°N around 20°E.
        for lon in 0..<40 { grid[(66 + 90) * 360 + lon] = 80 }
        let under = AuroraMath.visibleChance(grid: grid, width: 360, at: GeoPoint(lat: 66, lon: 20))
        let near = AuroraMath.visibleChance(grid: grid, width: 360, at: GeoPoint(lat: 60, lon: 20))
        let far = AuroraMath.visibleChance(grid: grid, width: 360, at: GeoPoint(lat: 45, lon: 20))
        XCTAssertGreaterThan(under, near)
        XCTAssertGreaterThan(near, 0)
        XCTAssertEqual(far, 0)
    }
}
