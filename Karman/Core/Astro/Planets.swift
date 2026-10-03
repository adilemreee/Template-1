import Foundation

/// Naked-eye planets from JPL's approximate Keplerian elements (E. M. Standish, valid 1800–2050;
/// about an arcminute for the inner planets, a few for Jupiter and Saturn): where each is in the
/// sky, how bright, and when it is best seen tonight.
nonisolated enum Planets {
    enum Body: String, CaseIterable, Sendable, Identifiable {
        case mercury, venus, mars, jupiter, saturn
        var id: String { rawValue }

        var name: String {
            switch self {
            case .mercury: String(localized: "Mercury")
            case .venus: String(localized: "Venus")
            case .mars: String(localized: "Mars")
            case .jupiter: String(localized: "Jupiter")
            case .saturn: String(localized: "Saturn")
            }
        }

        /// One line about what you are looking at.
        var blurb: String {
            switch self {
            case .mercury: String(localized: "The innermost planet never strays far from the Sun; catch it low in twilight.")
            case .venus: String(localized: "Wrapped in brilliant clouds, the brightest point in the sky after the Moon.")
            case .mars: String(localized: "Its rusty dust gives the Red Planet its colour.")
            case .jupiter: String(localized: "Binoculars show its four largest moons lined up beside it.")
            case .saturn: String(localized: "Any small telescope shows the rings.")
            }
        }
    }

    /// J2000 elements and rates per Julian century: a (au), e, I, L, ϖ (long. of perihelion), Ω (deg).
    struct Elements: Sendable { var a, e, i, l, peri, node: Double; var da, de, di, dl, dperi, dnode: Double }

    /// The Earth-Moon barycentre.
    static let earth = Elements(a: 1.00000261, e: 0.01671123, i: -0.00001531, l: 100.46457166, peri: 102.93768193, node: 0,
                                        da: 0.00000562, de: -0.00004392, di: -0.01294668, dl: 35999.37244981, dperi: 0.32327364, dnode: 0)

    static func elements(_ b: Body) -> Elements {
        switch b {
        case .mercury: Elements(a: 0.38709927, e: 0.20563593, i: 7.00497902, l: 252.25032350, peri: 77.45779628, node: 48.33076593,
                                da: 0.00000037, de: 0.00001906, di: -0.00594749, dl: 149472.67411175, dperi: 0.16047689, dnode: -0.12534081)
        case .venus: Elements(a: 0.72333566, e: 0.00677672, i: 3.39467605, l: 181.97909950, peri: 131.60246718, node: 76.67984255,
                              da: 0.00000390, de: -0.00004107, di: -0.00078890, dl: 58517.81538729, dperi: 0.00268329, dnode: -0.27769418)
        case .mars: Elements(a: 1.52371034, e: 0.09339410, i: 1.84969142, l: -4.55343205, peri: -23.94362959, node: 49.55953891,
                             da: 0.00001847, de: 0.00007882, di: -0.00813131, dl: 19140.30268499, dperi: 0.44441088, dnode: -0.29257343)
        case .jupiter: Elements(a: 5.20288700, e: 0.04838624, i: 1.30439695, l: 34.39644051, peri: 14.72847983, node: 100.47390909,
                                da: -0.00011607, de: -0.00013253, di: -0.00183714, dl: 3034.74612775, dperi: 0.21252668, dnode: 0.20469106)
        case .saturn: Elements(a: 9.53667594, e: 0.05386179, i: 2.48599187, l: 49.95424423, peri: 92.59887831, node: 113.66242448,
                               da: -0.00125060, de: -0.00050991, di: 0.00193609, dl: 1222.49362201, dperi: -0.41897216, dnode: -0.28867794)
        }
    }

    /// Heliocentric ecliptic (J2000) position in au, t in Julian centuries from J2000. Pass a mean
    /// anomaly (radians) to place the body elsewhere on the orbit those elements describe.
    static func heliocentric(_ el: Elements, t: Double, meanAnomaly: Double? = nil) -> (x: Double, y: Double, z: Double) {
        let d = Astro.deg
        let a = el.a + el.da * t, e = el.e + el.de * t, i = (el.i + el.di * t) * d
        let l = el.l + el.dl * t, peri = el.peri + el.dperi * t, node = (el.node + el.dnode * t) * d
        let w = peri * d - node
        var m = (l - peri).truncatingRemainder(dividingBy: 360)
        if m > 180 { m -= 360 } else if m < -180 { m += 360 }
        let mr = meanAnomaly ?? m * d
        var E = mr + e * sin(mr)
        for _ in 0..<8 { E -= (E - e * sin(E) - mr) / (1 - e * cos(E)) }
        let xp = a * (cos(E) - e), yp = a * (1 - e * e).squareRoot() * sin(E)
        let cw = cos(w), sw = sin(w), cn = cos(node), sn = sin(node), ci = cos(i), si = sin(i)
        return ((cw * cn - sw * sn * ci) * xp + (-sw * cn - cw * sn * ci) * yp,
                (cw * sn + sw * cn * ci) * xp + (-sw * sn + cw * cn * ci) * yp,
                (sw * si) * xp + (cw * si) * yp)
    }

    struct Position: Sendable {
        var body: Body
        var eq: Astro.Equatorial          // distance in au
        var eclipticLon: Double           // degrees, geocentric
        var sunDistance: Double           // au
        var magnitude: Double
        /// Angle from the Sun in the sky, degrees.
        var elongation: Double
    }

    static func position(_ body: Body, at date: Date) -> Position {
        let t = (Astro.julianDate(date) - 2451545.0) / 36525
        let p = heliocentric(elements(body), t: t)
        let g = heliocentric(earth, t: t)
        let x = p.x - g.x, y = p.y - g.y, z = p.z - g.z
        let delta = (x * x + y * y + z * z).squareRoot()
        let r = (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot()
        let R = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        let eps = 23.43928 * Astro.deg
        let ye = y * cos(eps) - z * sin(eps), ze = y * sin(eps) + z * cos(eps)
        let eq = Astro.Equatorial(ra: atan2(ye, x), dec: atan2(ze, (x * x + ye * ye).squareRoot()), distance: delta)
        // Phase angle (Sun–planet–Earth) and elongation (Sun–Earth–planet).
        let alpha = acos(max(-1, min(1, (r * r + delta * delta - R * R) / (2 * r * delta)))) / Astro.deg
        let elong = acos(max(-1, min(1, (R * R + delta * delta - r * r) / (2 * R * delta)))) / Astro.deg
        var lon = atan2(y, x) / Astro.deg
        if lon < 0 { lon += 360 }
        // Saturn's rings brighten it as they open toward us: sine of the ring-plane tilt seen from Earth.
        var ringTilt = 0.0
        if body == .saturn {
            let poleRA = 40.589 * Astro.deg, poleDec = 83.537 * Astro.deg
            let pole = (cos(poleDec) * cos(poleRA), cos(poleDec) * sin(poleRA), sin(poleDec))
            let u = (cos(eq.dec) * cos(eq.ra), cos(eq.dec) * sin(eq.ra), sin(eq.dec))
            ringTilt = abs(pole.0 * u.0 + pole.1 * u.1 + pole.2 * u.2)
        }
        return Position(body: body, eq: eq, eclipticLon: lon, sunDistance: r,
                        magnitude: magnitude(body, r: r, delta: delta, alpha: alpha, ringTilt: ringTilt), elongation: elong)
    }

    /// Apparent visual magnitude (Mallama & Hilton 2018).
    static func magnitude(_ body: Body, r: Double, delta: Double, alpha: Double, ringTilt: Double = 0) -> Double {
        let d = 5 * log10(r * delta)
        let a = alpha
        switch body {
        case .mercury:
            return -0.613 + 6.3280e-2 * a - 1.6336e-3 * a * a + 3.3644e-5 * pow(a, 3) - 3.4265e-7 * pow(a, 4)
                + 1.6893e-9 * pow(a, 5) - 3.0334e-12 * pow(a, 6) + d
        case .venus:
            return -4.384 - 1.044e-3 * a + 3.687e-4 * a * a - 2.814e-6 * pow(a, 3) + 8.938e-9 * pow(a, 4) + d
        case .mars:
            return -1.601 + 2.267e-2 * a - 1.302e-4 * a * a + d
        case .jupiter:
            return -9.395 - 3.7e-4 * a + 6.16e-4 * a * a + d
        case .saturn:
            return -8.914 - 1.825 * ringTilt + 0.026 * a - 0.378 * ringTilt * exp(-2.25 * a) + d
        }
    }

    // MARK: Tonight

    struct Visibility: Sendable, Identifiable {
        var body: Body
        var magnitude: Double
        var constellation: String
        /// Darkness window when it is at least 8° up (nil when it never is tonight).
        var visibleFrom: Date?
        var visibleUntil: Date?
        var bestTime: Date?
        var bestAltitude: Double
        var bestAzimuth: Double
        var id: String { body.rawValue }
        var isVisible: Bool { visibleFrom != nil }
    }

    /// What each planet does between dusk and dawn for an observer.
    static func tonight(observer: GeoPoint, from start: Date = Date()) -> [Visibility] {
        let night = Self.night(observer: observer, from: start)
        let step: TimeInterval = 600
        return Body.allCases.map { body in
            var v = Visibility(body: body, magnitude: 0, constellation: "", visibleFrom: nil, visibleUntil: nil, bestTime: nil, bestAltitude: -90, bestAzimuth: 0)
            var t = night.lowerBound
            while t <= night.upperBound {
                let pos = position(body, at: t)
                let h = Astro.horizontal(pos.eq, at: t, observer: observer)
                let sun = Astro.sunAltitude(at: t, observer: observer)
                // Venus shines through twilight close to the horizon; fainter planets need a darker, higher sky.
                let (maxSun, minAlt): (Double, Double) = pos.magnitude <= -3 ? (-3, 4) : (pos.magnitude <= 0.5 ? (-6, 6) : (-9, 8))
                if sun < maxSun && h.altitude >= minAlt {
                    if v.visibleFrom == nil { v.visibleFrom = t }
                    v.visibleUntil = t
                    if h.altitude > v.bestAltitude {
                        v.bestAltitude = h.altitude
                        v.bestAzimuth = h.azimuth
                        v.bestTime = t
                        v.magnitude = pos.magnitude
                        v.constellation = zodiacConstellation(eclipticLon: pos.eclipticLon)
                    }
                }
                t = t.addingTimeInterval(step)
            }
            if v.bestTime == nil {
                let pos = position(body, at: night.lowerBound)
                v.magnitude = pos.magnitude
                v.constellation = zodiacConstellation(eclipticLon: pos.eclipticLon)
            }
            return v
        }
    }

    /// From dusk (or now, if it is already dark) to the next dawn.
    static func night(observer: GeoPoint, from start: Date) -> ClosedRange<Date> {
        let sunNow = Astro.sunAltitude(at: start, observer: observer)
        let alt: (Date) -> Double = { Astro.sunAltitude(at: $0, observer: observer) }
        let dusk = sunNow < -3 ? start : (Astro.nextCrossing(after: start, threshold: -3, rising: false, altitude: alt) ?? start)
        let dawn = Astro.nextCrossing(after: dusk, within: 30, threshold: -3, rising: true, altitude: alt) ?? dusk.addingTimeInterval(10 * 3600)
        return dusk...max(dusk, dawn)
    }

    /// The zodiac constellation (IAU boundaries) at an ecliptic longitude — planets stay near the ecliptic.
    static func zodiacConstellation(eclipticLon: Double) -> String {
        let bounds: [(Double, String)] = [
            (29.0, String(localized: "Pisces")), (53.4, String(localized: "Aries")), (90.1, String(localized: "Taurus")),
            (117.9, String(localized: "Gemini")), (138.2, String(localized: "Cancer")), (173.9, String(localized: "Leo")),
            (218.0, String(localized: "Virgo")), (241.0, String(localized: "Libra")), (247.7, String(localized: "Scorpius")),
            (266.3, String(localized: "Ophiuchus")), (299.7, String(localized: "Sagittarius")), (327.5, String(localized: "Capricornus")),
            (351.6, String(localized: "Aquarius")),
        ]
        let lon = (eclipticLon.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return bounds.first { lon < $0.0 }?.1 ?? String(localized: "Pisces")
    }
}
