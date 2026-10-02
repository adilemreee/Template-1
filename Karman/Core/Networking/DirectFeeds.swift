import Foundation

/// Fallback used when the Kármán API cannot be reached: earthquakes from USGS and the
/// aurora / Kp picture from NOAA SWPC, fetched directly from the public feeds.
enum DirectFeeds {
    private struct USGS: Decodable {
        struct Feature: Decodable {
            struct Props: Decodable {
                var mag: Double?
                var place: String?
                var time: Double
                var url: String?
                var felt: Int?
                var alert: String?
                var tsunami: Int?
                var sig: Int?
                var type: String?
            }
            struct Geometry: Decodable { var coordinates: [Double] }
            var id: String
            var properties: Props
            var geometry: Geometry
        }
        var features: [Feature]
    }

    private struct Ovation: Decodable {
        var coordinates: [[Double]]
        enum CodingKeys: String, CodingKey { case coordinates }
    }

    private struct KpRow: Decodable {
        var time_tag: String
        var Kp: Double
    }

    static func snapshot() async throws -> PlanetSnapshot {
        let session = URLSession.shared
        async let quakeData = session.data(from: URL(string: "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_week.geojson")!)
        async let ovationData = session.data(from: URL(string: "https://services.swpc.noaa.gov/json/ovation_aurora_latest.json")!)
        async let kpData = session.data(from: URL(string: "https://services.swpc.noaa.gov/products/noaa-planetary-k-index.json")!)

        let usgs = try JSONDecoder().decode(USGS.self, from: try await quakeData.0)
        let quakes: [Quake] = usgs.features.compactMap { f in
            guard let mag = f.properties.mag, f.geometry.coordinates.count >= 2, f.properties.type == "earthquake" else { return nil }
            let c = f.geometry.coordinates
            return Quake(id: f.id, mag: (mag * 10).rounded() / 10, place: f.properties.place ?? "", time: Date(timeIntervalSince1970: f.properties.time / 1000),
                         lat: c[1], lon: c[0], depthKm: c.count > 2 ? c[2] : 0, tsunami: f.properties.tsunami == 1, felt: f.properties.felt,
                         alert: f.properties.alert, sig: f.properties.sig ?? 0, url: f.properties.url)
        }.sorted { $0.time > $1.time }

        var aurora: AuroraGrid?
        if let ov = try? JSONDecoder().decode(Ovation.self, from: try await ovationData.0) {
            var grid = [UInt8](repeating: 0, count: 360 * 181)
            var maxN = 0, maxS = 0
            for c in ov.coordinates where c.count >= 3 {
                let lon = Int(c[0]), lat = Int(c[1]), v = max(0, min(100, Int(c[2])))
                guard lon >= 0, lon < 360, lat >= -90, lat <= 90 else { continue }
                grid[(lat + 90) * 360 + lon] = UInt8(v)
                if lat > 0 { maxN = max(maxN, v) } else { maxS = max(maxS, v) }
            }
            aurora = AuroraGrid(observed: Date(), forecast: Date(), maxNorth: maxN, maxSouth: maxS,
                                grid: Data(grid).base64EncodedString(), gridWidth: 360, gridHeight: 181)
        }

        var space: SpaceWeather?
        if let rows = try? JSONDecoder().decode([KpRow].self, from: try await kpData.0), let last = rows.last {
            let history = rows.compactMap { r -> Sample? in
                guard let t = KarmanJSON.parseISO8601(r.time_tag + "Z") else { return nil }
                return Sample(t: t, v: r.Kp)
            }
            space = SpaceWeather(kp: last.Kp, kpEstimated: last.Kp, kpTime: history.last?.t, gScale: last.Kp >= 5 ? Int(min(5, last.Kp - 4)) : 0,
                                 kpHistory: history, kpForecast: nil, windSpeed: 0, windDensity: 0, bz: 0, bt: 0, windTime: nil,
                                 windHistory: nil, bzHistory: nil, xrayFlux: 0, xrayClass: "—", xrayTime: nil, xrayHistory: nil, flares: nil, alerts: nil)
        }
        return PlanetSnapshot(generatedAt: Date(), quakes: quakes, events: [], aurora: aurora, space: space, launches: [], neos: [], sources: nil)
    }
}
