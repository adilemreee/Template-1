import Foundation

/// Constellation stick figures, their label points and the brightest named stars, bundled as
/// `sky.json` by tools/build_sky.py from d3-celestial (© Olaf Frohn, BSD-3-Clause).
nonisolated struct SkyCatalog: Sendable {
    struct Point: Sendable, Hashable {
        var ra: Double   // degrees, J2000
        var dec: Double  // degrees
        var equatorial: Astro.Equatorial { Astro.Equatorial(ra: ra * Astro.deg, dec: dec * Astro.deg, distance: 1) }
    }

    struct Constellation: Sendable, Identifiable {
        var id: String
        /// IAU (Latin) name.
        var name: String
        /// What the name means in English ("Swan" for Cygnus), when it differs.
        var meaning: String?
        /// 1 = most prominent, 3 = faint.
        var rank: Int
        var label: Point
        var lines: [[Point]]
    }

    struct Star: Sendable, Identifiable, Hashable {
        var name: String
        var position: Point
        var magnitude: Double
        var constellation: String
        var id: String { name }
    }

    let constellations: [Constellation]
    let stars: [Star]
    let attribution: String

    private struct File: Decodable {
        struct C: Decodable { var id: String; var name: String; var meaning: String?; var rank: Int; var label: [Double]; var lines: [[Double]] }
        struct S: Decodable { var name: String; var ra: Double; var dec: Double; var mag: Double; var con: String }
        var attribution: String
        var constellations: [C]
        var stars: [S]
    }

    init(data: Data) throws {
        let f = try JSONDecoder().decode(File.self, from: data)
        constellations = f.constellations.map { c in
            Constellation(id: c.id, name: c.name, meaning: c.meaning, rank: c.rank,
                          label: Point(ra: c.label.first ?? 0, dec: c.label.count > 1 ? c.label[1] : 0),
                          lines: c.lines.map { flat in stride(from: 0, to: flat.count - 1, by: 2).map { Point(ra: flat[$0], dec: flat[$0 + 1]) } })
        }
        stars = f.stars.map { Star(name: $0.name, position: Point(ra: $0.ra, dec: $0.dec), magnitude: $0.mag, constellation: $0.con) }
        attribution = f.attribution
    }

    static let bundled: SkyCatalog? = {
        guard let url = Bundle.main.url(forResource: "sky", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? SkyCatalog(data: data)
    }()

    /// Prominent constellations highest in the sky at a moment, for "overhead tonight".
    func overhead(observer: GeoPoint, at date: Date, count: Int = 4) -> [(Constellation, Astro.Horizontal)] {
        constellations
            .filter { $0.rank <= 2 }
            .map { ($0, Astro.horizontal($0.label.equatorial, at: date, observer: observer)) }
            .filter { $0.1.altitude > 25 }
            .sorted { $0.1.altitude > $1.1.altitude }
            .prefix(count)
            .map { $0 }
    }
}
