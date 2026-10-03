import XCTest
@testable import Karman

final class SkyTests: XCTestCase {
    private let iso = ISO8601DateFormatter()

    /// Positions at 2026-10-03 00:00 UTC against JPL Horizons (astrometric J2000).
    func testPlanetsMatchHorizons() {
        let date = iso.date(from: "2026-10-03T00:00:00Z")!
        let reference: [(Planets.Body, Double, Double, Double)] = [
            (.mercury, 210.00689, -14.34246, -0.075), (.venus, 213.25702, -21.03569, -4.740),
            (.mars, 125.00384, 20.62703, 1.095), (.jupiter, 142.18585, 15.51819, -1.878), (.saturn, 11.21133, 1.87040, 0.334),
        ]
        for (body, ra, dec, mag) in reference {
            let p = Planets.position(body, at: date)
            let mine = SkyLensMath.equatorial(p.eq)
            let truth = SkyLensMath.equatorial(raDegrees: ra, decDegrees: dec)
            XCTAssertLessThan(SkyLensMath.angle(mine, truth), 0.1, "\(body)")
            XCTAssertEqual(p.magnitude, mag, accuracy: 0.15, "\(body)")
        }
    }

    func testMeteorShowerPeaks() {
        let now = iso.date(from: "2026-10-03T12:00:00Z")!
        let orionids = MeteorShowers.upcoming(from: now).first { $0.shower.id == "ORI" }
        XCTAssertNotNil(orionids)
        XCTAssertEqual(orionids!.peak.timeIntervalSince(iso.date(from: "2026-10-21T12:00:00Z")!), 0, accuracy: 1.5 * 86400)
        XCTAssertTrue(orionids!.isActive)
        let perseids = MeteorShowers.nextDate(solarLongitude: 140, from: iso.date(from: "2026-06-01T00:00:00Z")!)
        XCTAssertEqual(perseids.timeIntervalSince(iso.date(from: "2026-08-12T22:00:00Z")!), 0, accuracy: 1.2 * 86400)
    }

    func testStargazingScore() {
        XCTAssertEqual(Stargazing.score(sunAltitude: -30, cloud: 0, humidity: 40, moonAltitude: -10, moonIllumination: 0.5), 100)
        XCTAssertEqual(Stargazing.score(sunAltitude: 10, cloud: 0, humidity: 40, moonAltitude: -10, moonIllumination: 0), 0)
        XCTAssertEqual(Stargazing.score(sunAltitude: -30, cloud: 100, humidity: 40, moonAltitude: -10, moonIllumination: 0), 0)
        let full = Stargazing.score(sunAltitude: -30, cloud: 0, humidity: 40, moonAltitude: 60, moonIllumination: 1)
        XCTAssertTrue((40...55).contains(full))
    }

    func testLensGeometry() {
        let ist = GeoPoint(lat: 41.01, lon: 28.98)
        let date = iso.date(from: "2026-10-03T20:00:00Z")!
        let polaris = SkyLensMath.altAz(SkyLensMath.equatorialToLocal(date: date, observer: ist).apply(SkyLensMath.equatorial(raDegrees: 37.95, decDegrees: 89.26)))
        XCTAssertEqual(polaris.altitude, 41, accuracy: 1)
        let ground = SkyLensMath.groundPolygon(up: SIMD3(0, 1, 0), size: CGSize(width: 400, height: 800), focal: 600)
        XCTAssertEqual(ground.count, 4)
        XCTAssertTrue(ground.allSatisfy { $0.y >= 399.9 })
    }

    func testCatalogLoads() throws {
        let sky = try XCTUnwrap(SkyCatalog.bundled)
        XCTAssertGreaterThanOrEqual(sky.constellations.count, 88)
        XCTAssertEqual(sky.stars.first?.name, "Sirius")
    }
}

final class SkyLensLookTests: XCTestCase {
    /// Drag-to-look: the chosen direction sits at the screen centre, higher is up, clockwise is right.
    func testLookRotation() {
        for (alt, az) in [(0.0, 0.0), (35, 180), (60, 75), (-20, 300)] {
            let m = SkyLensMath.lookRotation(altitude: alt, azimuth: az)
            let d = m.apply(SkyLensMath.local(altitude: alt, azimuth: az))
            XCTAssertEqual(d.z, -1, accuracy: 1e-9)
            XCTAssertGreaterThan(m.apply(SkyLensMath.local(altitude: alt + 5, azimuth: az)).y, 0)
            XCTAssertGreaterThan(m.apply(SkyLensMath.local(altitude: alt, azimuth: az + 5)).x, 0)
        }
    }
}
