import Foundation

/// One packed GFS time step from the Kármán API: 360×181 RGBA8, rows from 90° N to 90° S and
/// columns from 0° E eastward. R and G hold the eastward and northward 10 m wind in 0.5 m/s
/// steps around 128, B the 2 m temperature in 0.5 °C steps from −80 °C, and A precipitation
/// as √(mm/h ÷ 50) × 255. The same bytes go straight into a Metal texture array.
nonisolated struct WeatherGrid: Sendable {
    static let width = 360
    static let height = 181
    static let byteCount = width * height * 4

    let id: String
    let valid: Date
    let bytes: Data

    struct Sample: Sendable, Equatable {
        var u: Double        // m/s toward the east
        var v: Double        // m/s toward the north
        var tempC: Double
        var rainMMH: Double

        var windSpeed: Double { hypot(u, v) }
        /// Where the wind blows from, in degrees clockwise from north (the way forecasts say it).
        var windFrom: Double { (atan2(-u, -v) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360) }

        static func mix(_ a: Sample, _ b: Sample, _ t: Double) -> Sample {
            Sample(u: a.u + (b.u - a.u) * t, v: a.v + (b.v - a.v) * t,
                   tempC: a.tempC + (b.tempC - a.tempC) * t, rainMMH: a.rainMMH + (b.rainMMH - a.rainMMH) * t)
        }
    }

    static func decode(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> Sample {
        let rain = Double(a) / 255
        return Sample(u: (Double(r) - 128) * 0.5, v: (Double(g) - 128) * 0.5, tempC: Double(b) * 0.5 - 80, rainMMH: rain * rain * 50)
    }

    /// Bilinear sample at a point.
    func sample(at p: GeoPoint) -> Sample {
        let x = p.lon < 0 ? p.lon + 360 : p.lon
        let y = max(0, min(Double(Self.height - 1), 90 - p.lat))
        let x0 = Int(floor(x)) % Self.width, y0 = Int(floor(y))
        let x1 = (x0 + 1) % Self.width, y1 = min(y0 + 1, Self.height - 1)
        let fx = x - floor(x), fy = y - floor(y)
        return bytes.withUnsafeBytes { raw -> Sample in
            let b = raw.bindMemory(to: UInt8.self)
            func at(_ i: Int, _ j: Int) -> Sample {
                let o = (j * Self.width + i) * 4
                return Self.decode(b[o], b[o + 1], b[o + 2], b[o + 3])
            }
            return Sample.mix(Sample.mix(at(x0, y0), at(x1, y0), fx), Sample.mix(at(x0, y1), at(x1, y1), fx), fy)
        }
    }

    /// The most extreme grid cells right now (hottest, coldest, windiest, wettest).
    func extremes() -> [WeatherExtreme] {
        var hottest = (0, -Double.infinity), coldest = (0, Double.infinity), windiest = (0, -1.0), wettest = (0, -1.0)
        bytes.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            for j in 1..<(Self.height - 1) {
                for i in 0..<Self.width {
                    let cell = j * Self.width + i, o = cell * 4
                    let s = Self.decode(b[o], b[o + 1], b[o + 2], b[o + 3])
                    if s.tempC > hottest.1 { hottest = (cell, s.tempC) }
                    if s.tempC < coldest.1 { coldest = (cell, s.tempC) }
                    let w = s.windSpeed
                    if w > windiest.1 { windiest = (cell, w) }
                    if s.rainMMH > wettest.1 { wettest = (cell, s.rainMMH) }
                }
            }
        }
        func point(_ cell: Int) -> GeoPoint {
            GeoPoint(lat: 90 - Double(cell / Self.width), lon: Geo.normalizeLon(Double(cell % Self.width)))
        }
        return [WeatherExtreme(kind: .hottest, point: point(hottest.0), value: hottest.1),
                WeatherExtreme(kind: .coldest, point: point(coldest.0), value: coldest.1),
                WeatherExtreme(kind: .windiest, point: point(windiest.0), value: windiest.1),
                WeatherExtreme(kind: .wettest, point: point(wettest.0), value: wettest.1)]
    }
}

nonisolated struct WeatherExtreme: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable { case hottest, coldest, windiest, wettest }
    var kind: Kind
    var point: GeoPoint
    var value: Double
    var id: String { kind.rawValue }
}

nonisolated enum WeatherTimeline {
    /// The frame at or before `date` and how far it is toward the next one (clamped to the span).
    static func position(of date: Date, in times: [Date]) -> (index: Int, fraction: Double)? {
        guard let first = times.first else { return nil }
        if date <= first || times.count == 1 { return (0, 0) }
        for i in 0..<(times.count - 1) where date < times[i + 1] {
            let span = times[i + 1].timeIntervalSince(times[i])
            return (i, span > 0 ? date.timeIntervalSince(times[i]) / span : 0)
        }
        return (times.count - 1, 0)
    }
}
