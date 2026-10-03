import Foundation

/// How good the sky is for stargazing, hour by hour: darkness, cloud cover (MET Norway), the
/// Moon's glare and haze combine into a 0–100 score.
nonisolated enum Stargazing {
    struct Hour: Sendable, Identifiable, Hashable {
        var date: Date
        var score: Int
        /// Total cloud cover in percent, when a forecast is available.
        var cloud: Double?
        var sunAltitude: Double
        var moonAltitude: Double
        var id: Date { date }
    }

    struct CloudSample: Sendable {
        var date: Date
        var cloud: Double     // %
        var humidity: Double  // %
    }

    static func score(sunAltitude: Double, cloud: Double?, humidity: Double?, moonAltitude: Double, moonIllumination: Double) -> Int {
        let darkness = pow(max(0, min(1, (-sunAltitude - 6) / 12)), 0.8)
        let clear = cloud.map { 1 - pow(max(0, min(100, $0)) / 100, 0.8) } ?? 0.8
        let moonUp = max(0, min(1, sin(moonAltitude * Astro.deg)))
        let moon = 1 - 0.55 * moonIllumination * pow(moonUp, 0.5)
        let haze = (humidity ?? 0) > 90 ? 0.85 : ((humidity ?? 0) > 80 ? 0.93 : 1)
        return Int((100 * darkness * clear * moon * haze).rounded())
    }

    /// The next `hours` hours from the top of the current hour.
    static func forecast(observer: GeoPoint, from now: Date = Date(), hours: Int = 14, clouds: [CloudSample]) -> [Hour] {
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        return (0..<hours).map { i in
            let t = start.addingTimeInterval(Double(i) * 3600)
            let sun = Astro.sunAltitude(at: t, observer: observer)
            let moon = Astro.moonHorizontal(at: t, observer: observer).altitude
            let illum = Astro.moonPhase(t).illumination
            let c = clouds.min { abs($0.date.timeIntervalSince(t)) < abs($1.date.timeIntervalSince(t)) }
                .flatMap { abs($0.date.timeIntervalSince(t)) <= 5400 ? $0 : nil }
            return Hour(date: t, score: score(sunAltitude: sun, cloud: c?.cloud, humidity: c?.humidity, moonAltitude: moon, moonIllumination: illum),
                        cloud: c?.cloud, sunAltitude: sun, moonAltitude: moon)
        }
    }

    /// The best stretch of the night: consecutive hours close to the peak score.
    static func bestWindow(_ hours: [Hour]) -> (start: Date, end: Date, score: Int)? {
        guard let peak = hours.max(by: { $0.score < $1.score }), peak.score >= 35,
              let i = hours.firstIndex(of: peak) else { return nil }
        let floor = max(30, peak.score - 15)
        var lo = i, hi = i
        while lo > 0 && hours[lo - 1].score >= floor { lo -= 1 }
        while hi < hours.count - 1 && hours[hi + 1].score >= floor { hi += 1 }
        return (hours[lo].date, hours[hi].date.addingTimeInterval(3600), peak.score)
    }

    static func verdict(_ score: Int) -> String {
        switch score {
        case 80...: String(localized: "Excellent")
        case 60..<80: String(localized: "Good")
        case 40..<60: String(localized: "Fair")
        case 20..<40: String(localized: "Poor")
        default: String(localized: "Not tonight")
        }
    }
}
