import Foundation

/// How seismic waves spread from an earthquake: when the P, S and surface waves arrive at a
/// distance, where their fronts are at a moment, and how strongly the ground shakes.
nonisolated enum Seismology {
    /// IASP91 surface-focus first-arrival times in seconds, every 10° of epicentral distance (0…100°).
    static let pTable: [Double] = [0, 146, 276, 373, 458, 538, 607, 670, 726, 777, 822]
    static let sTable: [Double] = [0, 262, 500, 675, 830, 974, 1105, 1222, 1326, 1418, 1500]
    /// Beyond 100° the core casts a shadow: only waves diffracted along it (P) arrive, slowly.
    static let pDiffractedSecondsPerDegree = 4.45
    static let sDiffractedSecondsPerDegree = 8.3
    /// The edge of the P- and S-wave shadow zone, in degrees.
    static let shadowZoneStart = 104.0
    /// Rayleigh waves near 20 s period travel at about 3.6 km/s.
    static let surfaceWaveKmPerSecond = 3.6
    static let kmPerDegree = 6371.0 * .pi / 180

    enum Wave: String, CaseIterable, Sendable { case p, s, surface }

    /// Travel time in seconds to an epicentral distance (degrees) from a source at a depth.
    static func travelTime(_ wave: Wave, degrees: Double, depthKm: Double = 10) -> Double {
        let d = max(0, min(180, degrees))
        let depth = max(0, depthKm)
        switch wave {
        case .surface:
            return d * kmPerDegree / surfaceWaveKmPerSecond
        case .p, .s:
            let table = wave == .p ? pTable : sTable
            let tail = wave == .p ? pDiffractedSecondsPerDegree : sDiffractedSecondsPerDegree
            // Far away, rays leave the source steeply: a deeper start saves about depth ÷ velocity.
            let teleseismic = max(0, interpolate(table, tail: tail, at: d) - (wave == .p ? 0.12 : 0.21) * depth)
            // Close in, the straight line from the hypocentre rules (faster rock for deeper sources).
            let km = (d * kmPerDegree * d * kmPerDegree + depth * depth).squareRoot()
            let local = km / (wave == .p ? 6.4 + 0.006 * depth : 3.7 + 0.0035 * depth)
            let blend = smoothstep(1 + depth / 60, 3 + depth / 30, d)
            return local * (1 - blend) + teleseismic * blend
        }
    }

    /// How far (degrees) a wave's front has travelled at a time after the origin (surface focus).
    static func front(_ wave: Wave, at seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        switch wave {
        case .surface:
            return min(180, seconds * surfaceWaveKmPerSecond / kmPerDegree)
        case .p, .s:
            let table = wave == .p ? pTable : sTable
            let tail = wave == .p ? pDiffractedSecondsPerDegree : sDiffractedSecondsPerDegree
            if let last = table.last, seconds >= last {
                return min(180, 100 + (seconds - last) / tail)
            }
            for i in 1..<table.count where seconds < table[i] {
                let f = (seconds - table[i - 1]) / (table[i] - table[i - 1])
                return (Double(i - 1) + f) * 10
            }
            return 100
        }
    }

    private static func interpolate(_ table: [Double], tail: Double, at degrees: Double) -> Double {
        let x = degrees / 10
        let i = Int(x)
        if i >= table.count - 1 { return table[table.count - 1] + (degrees - 100) * tail }
        let f = x - Double(i)
        return table[i] + (table[i + 1] - table[i]) * f
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// True when the direct P and S waves can't reach this distance (the core's shadow).
    static func inShadowZone(degrees: Double) -> Bool { degrees > shadowZoneStart }

    // MARK: Shaking

    /// Modified Mercalli intensity expected at a distance: Atkinson & Wald (2007) "Did You Feel It?"
    /// relation for active crust, with the hypocentral distance standing in for the rupture distance.
    static func intensity(magnitude m: Double, distanceKm: Double, depthKm: Double) -> Double {
        let hypo = (distanceKm * distanceKm + depthKm * depthKm).squareRoot()
        let r = (hypo * hypo + 14 * 14).squareRoot()
        let logR = log10(r)
        let b = r > 50 ? log10(r / 50) : 0
        let mmi = 12.27 + 2.270 * (m - 6) + 0.1304 * (m - 6) * (m - 6) - 1.30 * logR - 0.0007070 * r + 1.95 * b - 0.577 * m * logR
        return max(1, min(10, mmi))
    }

    static func intensityRoman(_ mmi: Double) -> String {
        let roman = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]
        return roman[max(0, min(9, Int(mmi.rounded()) - 1))]
    }

    /// The USGS words for shaking at an intensity.
    static func shakingWord(_ mmi: Double) -> String {
        switch Int(mmi.rounded()) {
        case ...1: String(localized: "Not felt")
        case 2...3: String(localized: "Weak")
        case 4: String(localized: "Light")
        case 5: String(localized: "Moderate")
        case 6: String(localized: "Strong")
        case 7: String(localized: "Very strong")
        case 8: String(localized: "Severe")
        case 9: String(localized: "Violent")
        default: String(localized: "Extreme")
        }
    }

    /// "+12:34" for a time after the origin.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "+%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "+%d:%02d", s / 60, s % 60)
    }
}
