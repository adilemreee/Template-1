import XCTest
import simd
@testable import Karman

final class SolarSystemTests: XCTestCase {
    private let iso = ISO8601DateFormatter()

    /// Earth's heliocentric longitude (J2000 ecliptic) is the Sun's geocentric longitude (equinox of
    /// date) plus 180°, once general precession is added.
    func testEarthOppositeTheSun() {
        for stamp in ["2026-03-20T15:00:00Z", "2026-06-21T08:00:00Z", "2026-10-03T12:00:00Z", "2030-01-01T00:00:00Z"] {
            let date = iso.date(from: stamp)!
            let e = SolarSystem.position(.earth, at: date)
            let lon = atan2(e.y, e.x) / Astro.deg + 180 + 1.397 * SolarSystem.centuries(date)
            var diff = abs((lon - Astro.sun(date).eclipticLon / Astro.deg).truncatingRemainder(dividingBy: 360))
            if diff > 180 { diff = 360 - diff }
            XCTAssertLessThan(diff, 0.03, stamp)
            XCTAssertEqual(simd_length(e), 1, accuracy: 0.02)
        }
    }

    /// Uranus in Taurus and Neptune at the start of Aries in 2026.
    func testOuterPlanets() {
        let date = iso.date(from: "2026-01-01T00:00:00Z")!
        let u = SolarSystem.position(.uranus, at: date), n = SolarSystem.position(.neptune, at: date)
        let uLon = (atan2(u.y, u.x) / Astro.deg + 360).truncatingRemainder(dividingBy: 360)
        let nLon = (atan2(n.y, n.x) / Astro.deg + 360).truncatingRemainder(dividingBy: 360)
        XCTAssertTrue((57...62).contains(uLon), "\(uLon)")
        XCTAssertTrue(nLon > 359 || nLon < 3, "\(nLon)")
        XCTAssertEqual(simd_length(u), 19.4, accuracy: 0.4)
        XCTAssertEqual(simd_length(n), 29.9, accuracy: 0.2)
    }

    func testOrbitsCloseAndHoldTheirPlanets() {
        let date = iso.date(from: "2026-10-03T00:00:00Z")!
        for p in SolarSystem.Planet.allCases {
            let loop = SolarSystem.orbit(p, at: date)
            XCTAssertLessThan(simd_length(loop.first! - loop.last!), 1e-9)
            let radii = loop.map { simd_length($0) }
            let el = SolarSystem.elements(p)
            XCTAssertEqual(radii.min()!, el.a * (1 - el.e), accuracy: el.a * 0.003, "\(p)")
            XCTAssertEqual(radii.max()!, el.a * (1 + el.e), accuracy: el.a * 0.003, "\(p)")
            let here = SolarSystem.position(p, at: date)
            XCTAssertLessThan(loop.map { simd_length($0 - here) }.min()!, el.a * 0.03, "\(p)")
            if let body = p.skyBody {
                XCTAssertEqual(simd_length(here), Planets.position(body, at: date).sunDistance, accuracy: 1e-9)
            }
        }
    }

    func testLightTime() {
        XCTAssertEqual(Fmt.lightTime(SolarSystem.lightSeconds(au: 1)), "8 min 19 s")
        XCTAssertEqual(Fmt.lightTime(SolarSystem.lightSeconds(au: 4.2)), "34 min")
        XCTAssertEqual(Fmt.lightTime(SolarSystem.lightSeconds(au: 30)), "4 h 9 min")
    }
}
