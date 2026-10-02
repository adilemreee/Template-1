import XCTest
@testable import Karman

final class AstroTests: XCTestCase {
    func testSubsolarPointAtEquinox() {
        // 2024 March equinox: 2024-03-20 03:06 UTC, the Sun is overhead at the equator.
        let date = ISO8601DateFormatter().date(from: "2024-03-20T03:06:00Z")!
        let p = Astro.subsolarPoint(date)
        XCTAssertEqual(p.lat, 0, accuracy: 0.1)
    }
}
