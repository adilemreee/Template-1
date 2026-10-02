import Foundation
import simd

/// Low-precision solar, lunar and sidereal-time astronomy (≈0.01° Sun, ≈0.3° Moon) —
/// plenty for rendering, twilight times, pass predictions and moon phases.
nonisolated enum Astro {
    static let deg = Double.pi / 180

    static func julianDate(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86400.0 + 2440587.5
    }

    /// Greenwich mean sidereal time in radians.
    static func gmst(_ date: Date) -> Double {
        let jd = julianDate(date)
        let t = (jd - 2451545.0) / 36525.0
        var g = 280.46061837 + 360.98564736629 * (jd - 2451545.0) + 0.000387933 * t * t - t * t * t / 38710000.0
        g = g.truncatingRemainder(dividingBy: 360)
        if g < 0 { g += 360 }
        return g * deg
    }

    struct Equatorial: Sendable {
        var ra: Double   // radians
        var dec: Double  // radians
        var distance: Double // AU for the Sun, Earth radii for the Moon
    }

    // MARK: Sun

    static func sun(_ date: Date) -> (eq: Equatorial, eclipticLon: Double) {
        let n = julianDate(date) - 2451545.0
        let L = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let g = ((357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360)) * deg
        let λ = (L + 1.915 * sin(g) + 0.020 * sin(2 * g)) * deg
        let ε = (23.439 - 0.0000004 * n) * deg
        let ra = atan2(cos(ε) * sin(λ), cos(λ))
        let dec = asin(sin(ε) * sin(λ))
        let r = 1.00014 - 0.01671 * cos(g) - 0.00014 * cos(2 * g)
        return (Equatorial(ra: ra, dec: dec, distance: r), λ)
    }

    /// Where the Sun is directly overhead.
    static func subsolarPoint(_ date: Date) -> GeoPoint {
        let s = sun(date).eq
        return GeoPoint(lat: s.dec / deg, lon: Geo.normalizeLon((s.ra - gmst(date)) / deg))
    }

    /// Unit vector toward the Sun in the render frame.
    static func sunDirection(_ date: Date) -> SIMD3<Float> {
        subsolarPoint(date).unitVectorF
    }

    // MARK: Moon (Schlyter's method with the main perturbations)

    static func moon(_ date: Date) -> (eq: Equatorial, eclipticLon: Double, eclipticLat: Double) {
        let d = julianDate(date) - 2451543.5
        func norm(_ x: Double) -> Double { var v = x.truncatingRemainder(dividingBy: 360); if v < 0 { v += 360 }; return v }
        let N = norm(125.1228 - 0.0529538083 * d) * deg
        let i = 5.1454 * deg
        let w = norm(318.0634 + 0.1643573223 * d) * deg
        let a = 60.2666
        let e = 0.054900
        let M = norm(115.3654 + 13.0649929509 * d) * deg
        var E = M + e * sin(M) * (1 + e * cos(M))
        for _ in 0..<5 { E = E - (E - e * sin(E) - M) / (1 - e * cos(E)) }
        let xv = a * (cos(E) - e)
        let yv = a * sqrt(1 - e * e) * sin(E)
        let v = atan2(yv, xv)
        var r = sqrt(xv * xv + yv * yv)
        let xh = r * (cos(N) * cos(v + w) - sin(N) * sin(v + w) * cos(i))
        let yh = r * (sin(N) * cos(v + w) + cos(N) * sin(v + w) * cos(i))
        let zh = r * sin(v + w) * sin(i)
        var lon = atan2(yh, xh)
        var lat = atan2(zh, sqrt(xh * xh + yh * yh))

        let Ms = norm(356.0470 + 0.9856002585 * d) * deg
        let ws = norm(282.9404 + 4.70935e-5 * d) * deg
        let Ls = Ms + ws
        let Lm = N + w + M
        let D = Lm - Ls
        let F = Lm - N
        lon += (-1.274 * sin(M - 2 * D) + 0.658 * sin(2 * D) - 0.186 * sin(Ms) - 0.059 * sin(2 * M - 2 * D)
            - 0.057 * sin(M - 2 * D + Ms) + 0.053 * sin(M + 2 * D) + 0.046 * sin(2 * D - Ms) + 0.041 * sin(M - Ms)
            - 0.035 * sin(D) - 0.031 * sin(M + Ms) - 0.015 * sin(2 * F - 2 * D) + 0.011 * sin(M - 4 * D)) * deg
        lat += (-0.173 * sin(F - 2 * D) - 0.055 * sin(M - F - 2 * D) - 0.046 * sin(M + F - 2 * D)
            + 0.033 * sin(F + 2 * D) + 0.017 * sin(2 * M + F)) * deg
        r += -0.58 * cos(M - 2 * D) - 0.46 * cos(2 * D)

        let ecl = (23.4393 - 3.563e-7 * d) * deg
        let xe = cos(lon) * cos(lat)
        let ye = sin(lon) * cos(lat)
        let ze = sin(lat)
        let xq = xe
        let yq = ye * cos(ecl) - ze * sin(ecl)
        let zq = ye * sin(ecl) + ze * cos(ecl)
        return (Equatorial(ra: atan2(yq, xq), dec: atan2(zq, sqrt(xq * xq + yq * yq)), distance: r), lon, lat)
    }

    struct MoonPhase: Sendable {
        var illumination: Double   // 0...1
        var phase: Double          // 0 = new, 0.5 = full, 1 = new (age fraction)
        var waxing: Bool
        var distanceKm: Double

        var name: String {
            switch phase {
            case ..<0.03, 0.97...: return String(localized: "New Moon")
            case ..<0.22: return String(localized: "Waxing Crescent")
            case ..<0.28: return String(localized: "First Quarter")
            case ..<0.47: return String(localized: "Waxing Gibbous")
            case ..<0.53: return String(localized: "Full Moon")
            case ..<0.72: return String(localized: "Waning Gibbous")
            case ..<0.78: return String(localized: "Last Quarter")
            default: return String(localized: "Waning Crescent")
            }
        }
    }

    static func moonPhase(_ date: Date) -> MoonPhase {
        let m = moon(date)
        let s = sun(date)
        var elong = (m.eclipticLon - s.eclipticLon).truncatingRemainder(dividingBy: 2 * .pi)
        if elong < 0 { elong += 2 * .pi }
        let illum = (1 - cos(elong)) / 2
        return MoonPhase(illumination: illum, phase: elong / (2 * .pi), waxing: elong < .pi, distanceKm: m.eq.distance * Geo.earthRadiusKm)
    }

    static func sublunarPoint(_ date: Date) -> GeoPoint {
        let m = moon(date).eq
        return GeoPoint(lat: m.dec / deg, lon: Geo.normalizeLon((m.ra - gmst(date)) / deg))
    }

    // MARK: Observer geometry

    struct Horizontal: Sendable {
        var altitude: Double // degrees
        var azimuth: Double  // degrees from north, clockwise
    }

    static func horizontal(_ eq: Equatorial, at date: Date, observer: GeoPoint) -> Horizontal {
        let φ = observer.lat * deg
        let H = gmst(date) + observer.lon * deg - eq.ra
        let alt = asin(sin(φ) * sin(eq.dec) + cos(φ) * cos(eq.dec) * cos(H))
        let az = atan2(-sin(H) * cos(eq.dec), sin(eq.dec) * cos(φ) - cos(eq.dec) * cos(H) * sin(φ))
        return Horizontal(altitude: alt / deg, azimuth: (az / deg + 360).truncatingRemainder(dividingBy: 360))
    }

    static func sunAltitude(at date: Date, observer: GeoPoint) -> Double {
        horizontal(sun(date).eq, at: date, observer: observer).altitude
    }

    static func moonHorizontal(at date: Date, observer: GeoPoint) -> Horizontal {
        let m = moon(date).eq
        var h = horizontal(m, at: date, observer: observer)
        // Topocentric parallax lowers the Moon by up to ~1°.
        h.altitude -= asin(cos(h.altitude * deg) / m.distance) / deg
        return h
    }

    /// Finds the next time after `start` when `altitude` crosses `threshold` in the given direction.
    static func nextCrossing(after start: Date, within hours: Double = 36, threshold: Double, rising: Bool,
                             altitude: (Date) -> Double) -> Date? {
        let step: TimeInterval = 300
        var t0 = start
        var a0 = altitude(t0)
        let end = start.addingTimeInterval(hours * 3600)
        while t0 < end {
            let t1 = t0.addingTimeInterval(step)
            let a1 = altitude(t1)
            let crossed = rising ? (a0 < threshold && a1 >= threshold) : (a0 > threshold && a1 <= threshold)
            if crossed {
                var lo = t0, hi = t1
                for _ in 0..<12 {
                    let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
                    let am = altitude(mid)
                    if rising ? (am < threshold) : (am > threshold) { lo = mid } else { hi = mid }
                }
                return hi
            }
            t0 = t1
            a0 = a1
        }
        return nil
    }

    struct SunTimes: Sendable {
        var sunrise: Date?
        var sunset: Date?
        var goldenHourEvening: Date?
        var blueHourEvening: Date?
        var nightStart: Date?
        var goldenHourMorning: Date?
        var dawn: Date?
    }

    static func sunTimes(from start: Date, observer: GeoPoint) -> SunTimes {
        let alt: (Date) -> Double = { sunAltitude(at: $0, observer: observer) }
        return SunTimes(
            sunrise: nextCrossing(after: start, threshold: -0.833, rising: true, altitude: alt),
            sunset: nextCrossing(after: start, threshold: -0.833, rising: false, altitude: alt),
            goldenHourEvening: nextCrossing(after: start, threshold: 6, rising: false, altitude: alt),
            blueHourEvening: nextCrossing(after: start, threshold: -4, rising: false, altitude: alt),
            nightStart: nextCrossing(after: start, threshold: -12, rising: false, altitude: alt),
            goldenHourMorning: nextCrossing(after: start, threshold: 6, rising: true, altitude: alt),
            dawn: nextCrossing(after: start, threshold: -6, rising: true, altitude: alt)
        )
    }

    static func moonRiseSet(from start: Date, observer: GeoPoint) -> (rise: Date?, set: Date?) {
        let alt: (Date) -> Double = { moonHorizontal(at: $0, observer: observer).altitude + 0.27 }
        return (nextCrossing(after: start, threshold: -0.566, rising: true, altitude: alt),
                nextCrossing(after: start, threshold: -0.566, rising: false, altitude: alt))
    }

    /// Direction from Earth's centre to the Sun in Earth-fixed (ECEF, Z = north) coordinates.
    static func sunECEF(_ date: Date) -> SIMD3<Double> {
        let s = sun(date).eq
        let g = gmst(date)
        let x = cos(s.dec) * cos(s.ra), y = cos(s.dec) * sin(s.ra), z = sin(s.dec)
        return SIMD3(cos(g) * x + sin(g) * y, -sin(g) * x + cos(g) * y, z)
    }
}
