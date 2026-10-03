import Foundation
import simd

/// The eight planets around the Sun for the orrery: heliocentric positions from the same JPL
/// approximate elements as the sky (Standish, valid 1800–2050), with Uranus and Neptune added.
nonisolated enum SolarSystem {
    enum Planet: String, CaseIterable, Identifiable, Sendable {
        case mercury, venus, earth, mars, jupiter, saturn, uranus, neptune

        var id: String { rawValue }

        var name: String {
            switch self {
            case .mercury: String(localized: "Mercury")
            case .venus: String(localized: "Venus")
            case .earth: String(localized: "Earth")
            case .mars: String(localized: "Mars")
            case .jupiter: String(localized: "Jupiter")
            case .saturn: String(localized: "Saturn")
            case .uranus: String(localized: "Uranus")
            case .neptune: String(localized: "Neptune")
            }
        }

        /// Sidereal orbital period in years.
        var period: Double {
            switch self {
            case .mercury: 0.2408467
            case .venus: 0.6151973
            case .earth: 1.0000174
            case .mars: 1.8808476
            case .jupiter: 11.862615
            case .saturn: 29.447498
            case .uranus: 84.016846
            case .neptune: 164.79132
            }
        }

        /// Mean radius in km.
        var radiusKm: Double {
            switch self {
            case .mercury: 2_439.7
            case .venus: 6_051.8
            case .earth: 6_371.0
            case .mars: 3_389.5
            case .jupiter: 69_911
            case .saturn: 58_232
            case .uranus: 25_362
            case .neptune: 24_622
            }
        }

        /// The same planet in the sky, for the five seen with the naked eye.
        var skyBody: Planets.Body? {
            switch self {
            case .mercury: .mercury
            case .venus: .venus
            case .mars: .mars
            case .jupiter: .jupiter
            case .saturn: .saturn
            case .earth, .uranus, .neptune: nil
            }
        }

        var fact: String {
            switch self {
            case .mercury: String(localized: "A year lasts 88 days, but one sunrise to the next takes 176.")
            case .venus: String(localized: "Hotter than Mercury: its thick carbon dioxide air traps heat at about 465 °C.")
            case .earth: String(localized: "Home: the only world known to have liquid oceans on its surface, and life.")
            case .mars: String(localized: "Olympus Mons, its largest volcano, stands two and a half times as tall as Everest.")
            case .jupiter: String(localized: "More than twice as massive as all the other planets put together.")
            case .saturn: String(localized: "On average lighter than water: it would float, given a big enough bath.")
            case .uranus: String(localized: "It rolls round the Sun on its side, its axis tipped over by 98°.")
            case .neptune: String(localized: "Its winds are the fastest measured on any planet, above 2,000 km/h.")
            }
        }
    }

    /// Standish's elements for the two planets the sky module doesn't need.
    private static let uranus = Planets.Elements(a: 19.18916464, e: 0.04725744, i: 0.77263783, l: 313.23810451, peri: 170.95427630, node: 74.01692503,
                                                 da: -0.00196176, de: -0.00004397, di: -0.00242939, dl: 428.48202785, dperi: 0.40805281, dnode: 0.04240589)
    private static let neptune = Planets.Elements(a: 30.06992276, e: 0.00859048, i: 1.77004347, l: -55.12002969, peri: 44.96476227, node: 131.78422574,
                                                  da: 0.00026291, de: 0.00005105, di: 0.00035372, dl: 218.45945325, dperi: -0.32241464, dnode: -0.00508664)

    static func elements(_ p: Planet) -> Planets.Elements {
        switch p {
        case .mercury: Planets.elements(.mercury)
        case .venus: Planets.elements(.venus)
        case .earth: Planets.earth
        case .mars: Planets.elements(.mars)
        case .jupiter: Planets.elements(.jupiter)
        case .saturn: Planets.elements(.saturn)
        case .uranus: uranus
        case .neptune: neptune
        }
    }

    static func centuries(_ date: Date) -> Double {
        (Astro.julianDate(date) - 2451545.0) / 36525
    }

    /// Heliocentric ecliptic (J2000) position in au.
    static func position(_ p: Planet, at date: Date) -> SIMD3<Double> {
        let h = Planets.heliocentric(elements(p), t: centuries(date))
        return SIMD3(h.x, h.y, h.z)
    }

    /// The orbit at a date's elements as a closed loop (au), sampled evenly in eccentric anomaly
    /// so the curve is smooth at perihelion and aphelion alike.
    static func orbit(_ p: Planet, at date: Date, samples: Int = 192) -> [SIMD3<Double>] {
        let el = elements(p)
        let t = centuries(date)
        let e = el.e + el.de * t
        return (0...samples).map { k in
            let E = 2 * Double.pi * Double(k) / Double(samples)
            let h = Planets.heliocentric(el, t: t, meanAnomaly: E - e * sin(E))
            return SIMD3(h.x, h.y, h.z)
        }
    }

    /// Seconds light takes to cross a distance in au.
    static func lightSeconds(au: Double) -> Double { au * 499.004784 }

    static let kmPerAU = 149_597_870.7
}
