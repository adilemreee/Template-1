import Foundation

/// The major annual meteor showers (International Meteor Organization working list). Peaks are
/// fixed by the Sun's ecliptic longitude, so each year's date is found from the Sun's position.
nonisolated enum MeteorShowers {
    struct Shower: Sendable, Identifiable, Hashable {
        var id: String
        var name: String
        /// Solar longitude of the peak (J2000, degrees).
        var peakLongitude: Double
        /// Zenithal hourly rate at the peak under a perfect sky.
        var zhr: Double
        var radiantRA: Double
        var radiantDec: Double
        /// Days of activity before and after the peak.
        var before: Double
        var after: Double
        var speedKmS: Double
        var parent: String
    }

    static let all: [Shower] = [
        Shower(id: "QUA", name: String(localized: "Quadrantids"), peakLongitude: 283.15, zhr: 110, radiantRA: 230, radiantDec: 49, before: 6, after: 8, speedKmS: 41, parent: "2003 EH1"),
        Shower(id: "LYR", name: String(localized: "Lyrids"), peakLongitude: 32.32, zhr: 18, radiantRA: 271, radiantDec: 34, before: 8, after: 8, speedKmS: 49, parent: "C/1861 G1 Thatcher"),
        Shower(id: "ETA", name: String(localized: "Eta Aquariids"), peakLongitude: 45.5, zhr: 50, radiantRA: 338, radiantDec: -1, before: 17, after: 23, speedKmS: 66, parent: "1P/Halley"),
        Shower(id: "SDA", name: String(localized: "Southern Delta Aquariids"), peakLongitude: 127, zhr: 25, radiantRA: 340, radiantDec: -16, before: 18, after: 23, speedKmS: 41, parent: "96P/Machholz"),
        Shower(id: "PER", name: String(localized: "Perseids"), peakLongitude: 140.0, zhr: 100, radiantRA: 48, radiantDec: 58, before: 26, after: 12, speedKmS: 59, parent: "109P/Swift–Tuttle"),
        Shower(id: "DRA", name: String(localized: "Draconids"), peakLongitude: 195.4, zhr: 10, radiantRA: 262, radiantDec: 54, before: 2, after: 2, speedKmS: 20, parent: "21P/Giacobini–Zinner"),
        Shower(id: "ORI", name: String(localized: "Orionids"), peakLongitude: 208, zhr: 20, radiantRA: 95, radiantDec: 16, before: 19, after: 16, speedKmS: 66, parent: "1P/Halley"),
        Shower(id: "LEO", name: String(localized: "Leonids"), peakLongitude: 235.27, zhr: 15, radiantRA: 152, radiantDec: 22, before: 11, after: 13, speedKmS: 71, parent: "55P/Tempel–Tuttle"),
        Shower(id: "GEM", name: String(localized: "Geminids"), peakLongitude: 262.2, zhr: 150, radiantRA: 112, radiantDec: 33, before: 10, after: 6, speedKmS: 35, parent: "3200 Phaethon"),
        Shower(id: "URS", name: String(localized: "Ursids"), peakLongitude: 270.7, zhr: 10, radiantRA: 217, radiantDec: 76, before: 5, after: 4, speedKmS: 33, parent: "8P/Tuttle"),
    ]

    /// The Sun's ecliptic longitude in degrees (0…360).
    static func solarLongitude(_ date: Date) -> Double {
        var l = Astro.sun(date).eclipticLon / Astro.deg
        l = l.truncatingRemainder(dividingBy: 360)
        return l < 0 ? l + 360 : l
    }

    /// The next time the Sun reaches a longitude, at or after `from` (within a year).
    static func nextDate(solarLongitude target: Double, from: Date) -> Date {
        // The Sun moves about 0.9856° a day; refine twice.
        var diff = (target - solarLongitude(from)).truncatingRemainder(dividingBy: 360)
        if diff < 0 { diff += 360 }
        var t = from.addingTimeInterval(diff / 0.98565 * 86400)
        for _ in 0..<3 {
            var d = (target - solarLongitude(t)).truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 } else if d < -180 { d += 360 }
            t = t.addingTimeInterval(d / 0.98565 * 86400)
        }
        return t
    }

    struct Outlook: Sendable, Identifiable {
        var shower: Shower
        var peak: Date
        /// Fraction of the Moon lit at the peak.
        var moonIllumination: Double
        var isActive: Bool
        var id: String { shower.id }
        var activeFrom: Date { peak.addingTimeInterval(-shower.before * 86400) }
        var activeUntil: Date { peak.addingTimeInterval(shower.after * 86400) }
    }

    /// Showers active now or peaking soon, nearest peak first.
    static func upcoming(from now: Date = Date(), within days: Double = 75) -> [Outlook] {
        all.compactMap { s -> Outlook? in
            // The current year's peak may have just passed while the shower is still active.
            var peak = nextDate(solarLongitude: s.peakLongitude, from: now.addingTimeInterval(-s.after * 86400))
            if peak.addingTimeInterval(s.after * 86400) < now { peak = nextDate(solarLongitude: s.peakLongitude, from: now) }
            guard peak.timeIntervalSince(now) < days * 86400 else { return nil }
            let active = now >= peak.addingTimeInterval(-s.before * 86400) && now <= peak.addingTimeInterval(s.after * 86400)
            return Outlook(shower: s, peak: peak, moonIllumination: Astro.moonPhase(peak).illumination, isActive: active)
        }
        .sorted { $0.peak < $1.peak }
    }

    /// Meteors an observer might actually see in an hour: the ZHR thinned by a low radiant, by
    /// moonlight, and by a sky that is not perfectly dark.
    static func expectedRate(_ s: Shower, at date: Date, observer: GeoPoint, limitingMagnitude: Double = 6.0) -> Double {
        let radiant = Astro.horizontal(Astro.Equatorial(ra: s.radiantRA * Astro.deg, dec: s.radiantDec * Astro.deg, distance: 1), at: date, observer: observer)
        guard radiant.altitude > 0 else { return 0 }
        let population = 2.4   // typical population index
        let peakFactor = exp(-abs(solarLongitude(date) - s.peakLongitude) / 1.5)
        return s.zhr * peakFactor * sin(radiant.altitude * Astro.deg) / pow(population, 6.5 - limitingMagnitude)
    }

    /// The best hour of a night to watch: when the radiant is highest in a dark sky.
    static func bestTime(_ s: Shower, observer: GeoPoint, night: ClosedRange<Date>) -> (date: Date, altitude: Double)? {
        var best: (Date, Double)?
        var t = night.lowerBound
        while t <= night.upperBound {
            if Astro.sunAltitude(at: t, observer: observer) < -12 {
                let h = Astro.horizontal(Astro.Equatorial(ra: s.radiantRA * Astro.deg, dec: s.radiantDec * Astro.deg, distance: 1), at: t, observer: observer)
                if h.altitude > (best?.1 ?? 10) { best = (t, h.altitude) }
            }
            t = t.addingTimeInterval(900)
        }
        return best
    }
}
