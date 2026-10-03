import XCTest
@testable import Karman

final class WeatherTests: XCTestCase {
    /// A frame with a uniform 10 m/s eastward, 5 m/s southward wind, a warm equator and one downpour.
    private func makeGrid() -> WeatherGrid {
        var bytes = [UInt8](repeating: 0, count: WeatherGrid.byteCount)
        for j in 0..<WeatherGrid.height {
            for i in 0..<WeatherGrid.width {
                let o = (j * WeatherGrid.width + i) * 4
                let lat = 90.0 - Double(j)
                bytes[o] = 148
                bytes[o + 1] = 118
                bytes[o + 2] = UInt8(max(0, min(255, (25 - abs(lat) * 0.6 + 80) * 2)))
            }
        }
        bytes[(80 * WeatherGrid.width + 20) * 4 + 3] = 180 // 10° N 20° E
        return WeatherGrid(id: "test", valid: Date(timeIntervalSince1970: 0), bytes: Data(bytes))
    }

    func testDecodesWindTemperatureAndRain() {
        let g = makeGrid()
        let s = g.sample(at: GeoPoint(lat: 0, lon: 0))
        XCTAssertEqual(s.u, 10, accuracy: 1e-9)
        XCTAssertEqual(s.v, -5, accuracy: 1e-9)
        XCTAssertEqual(s.tempC, 25, accuracy: 0.6)
        // Blowing toward the south-east, so it comes from the west-north-west.
        XCTAssertEqual(s.windFrom, 296.57, accuracy: 0.01)
        XCTAssertEqual(g.sample(at: GeoPoint(lat: 10, lon: 20)).rainMMH, 50 * pow(180.0 / 255, 2), accuracy: 1e-6)
    }

    func testBilinearAndWrapsTheAntimeridian() {
        let g = makeGrid()
        let full = g.sample(at: GeoPoint(lat: 10, lon: 20)).rainMMH
        XCTAssertEqual(g.sample(at: GeoPoint(lat: 10, lon: 20.5)).rainMMH, full / 2, accuracy: 1e-6)
        XCTAssertEqual(g.sample(at: GeoPoint(lat: 10, lon: -0.5)).tempC, g.sample(at: GeoPoint(lat: 10, lon: 359.5)).tempC, accuracy: 1e-9)
    }

    func testExtremesFindTheDownpour() {
        let wettest = makeGrid().extremes().first { $0.kind == .wettest }
        XCTAssertEqual(wettest?.point, GeoPoint(lat: 10, lon: 20))
    }

    func testTimelinePosition() {
        let t0 = Date(timeIntervalSince1970: 0)
        let times = (0..<5).map { t0.addingTimeInterval(Double($0) * 6 * 3600) }
        XCTAssertEqual(WeatherTimeline.position(of: t0.addingTimeInterval(-60), in: times)?.index, 0)
        let mid = WeatherTimeline.position(of: t0.addingTimeInterval(9 * 3600), in: times)
        XCTAssertEqual(mid?.index, 1)
        XCTAssertEqual(mid?.fraction ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(WeatherTimeline.position(of: t0.addingTimeInterval(40 * 3600), in: times)?.index, 4)
        XCTAssertNil(WeatherTimeline.position(of: t0, in: []))
    }

    func testOldLayerSettingsStillDecode() throws {
        let old = #"{"quakes":false,"storms":true,"fires":true,"otherEvents":true,"aurora":true,"satellites":true,"starlink":false,"launches":true,"clouds":true,"cityLights":true,"liveImagery":false}"#
        let layers = try JSONDecoder().decode(GlobeLayers.self, from: Data(old.utf8))
        XCTAssertFalse(layers.quakes)
        XCTAssertTrue(layers.wind)
        XCTAssertFalse(layers.temperature)
    }
}
