import Foundation

/// What the app hands to its widgets through the shared App Group container.
nonisolated struct WidgetState: Codable, Sendable {
    struct QuakeDot: Codable, Sendable, Hashable {
        var lat: Double
        var lon: Double
        var mag: Double
        var time: Date
    }

    struct TopQuake: Codable, Sendable, Hashable {
        var id: String
        var mag: Double
        var place: String
        var time: Date
        var distanceKm: Double?
    }

    struct Pass: Codable, Sendable, Hashable {
        var satellite: String
        var start: Date
        var peak: Date
        var end: Date
        var maxElevation: Double
        var startAzimuth: Double
        var endAzimuth: Double
        var magnitude: Double?

        /// Friendly station name for display ("ISS", "Tiangong").
        var stationName: String {
            let upper = satellite.uppercased()
            if upper.contains("CSS") || upper.contains("TIANHE") || upper.contains("TIANGONG") { return "Tiangong" }
            if upper.contains("ISS") || upper.contains("ZARYA") { return "ISS" }
            return satellite.capitalized
        }
    }

    struct NextLaunch: Codable, Sendable, Hashable {
        var name: String
        var rocket: String
        var provider: String
        var net: Date
        var location: String
    }

    var updatedAt: Date
    var kp: Double
    var gScale: Int
    var windSpeed: Double
    var bz: Double
    var auroraChance: Int?
    var location: GeoPoint?
    var locationName: String?
    var quakes24h: Int
    var topQuake: TopQuake?
    var recentQuakes: [QuakeDot]
    var passes: [Pass]
    var nextLaunch: NextLaunch?

    static let appGroup = "group.com.adilemre.karman"

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: "widget-state.json")
    }

    static func load() -> WidgetState? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? KarmanJSON.decoder().decode(WidgetState.self, from: data)
    }

    func save() {
        guard let url = Self.fileURL, let data = try? KarmanJSON.encoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    var nextPass: Pass? { passes.first { $0.end > Date() } }

    /// Starting point when the app has never shared anything: real data only, no samples.
    static let empty = WidgetState(updatedAt: .distantPast, kp: 0, gScale: 0, windSpeed: 0, bz: 0, auroraChance: nil, location: nil,
                                   locationName: nil, quakes24h: 0, topQuake: nil, recentQuakes: [], passes: [], nextLaunch: nil)

    static let placeholder = WidgetState(
        updatedAt: Date(), kp: 3.3, gScale: 0, windSpeed: 412, bz: -2.1, auroraChance: 12,
        location: GeoPoint(lat: 41.0, lon: 29.0), locationName: "Istanbul", quakes24h: 41,
        topQuake: TopQuake(id: "sample", mag: 6.1, place: "Kuril Islands", time: Date().addingTimeInterval(-7200), distanceKm: nil),
        recentQuakes: [QuakeDot(lat: 38.3, lon: 142.4, mag: 5.6, time: Date()), QuakeDot(lat: -6.2, lon: 130.1, mag: 4.9, time: Date()), QuakeDot(lat: 36.1, lon: 28.0, mag: 4.5, time: Date())],
        passes: [Pass(satellite: "ISS", start: Date().addingTimeInterval(5400), peak: Date().addingTimeInterval(5700), end: Date().addingTimeInterval(6000), maxElevation: 64, startAzimuth: 250, endAzimuth: 80, magnitude: -3.1)],
        nextLaunch: NextLaunch(name: "Starlink Group 12-7", rocket: "Falcon 9", provider: "SpaceX", net: Date().addingTimeInterval(20000), location: "Cape Canaveral")
    )
}

nonisolated enum AuroraMath {
    /// Chance (0–100) of seeing aurora from a location: the oval can be seen low on the
    /// poleward horizon from up to ~1000 km away (mirrors the server's alert logic).
    static func visibleChance(grid: [UInt8], width: Int, at p: GeoPoint) -> Int {
        guard grid.count == width * 181 else { return 0 }
        var best = 0.0
        let baseLat = Int(p.lat.rounded()), baseLon = Int(p.lon.rounded())
        for dLat in -10...10 {
            let la = baseLat + dLat
            guard la >= -90, la <= 90 else { continue }
            for dLon in -20...20 {
                let lo = ((baseLon + dLon) % 360 + 360) % 360
                let prob = Double(grid[(la + 90) * width + lo])
                guard prob > 0 else { continue }
                let d = p.distanceKm(to: GeoPoint(lat: Double(la), lon: Double(lo)))
                guard d <= 1000 else { continue }
                best = max(best, prob * (1 - d / 1150))
            }
        }
        return Int(best.rounded())
    }
}
