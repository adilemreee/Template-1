import Foundation
import simd

nonisolated struct GeoPoint: Codable, Sendable, Hashable {
    var lat: Double
    var lon: Double

    init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    /// Unit vector in Kármán's render frame: +Y = north pole, +Z = (0°, 0°), +X = (0°, 90°E).
    var unitVector: SIMD3<Double> {
        let φ = lat * .pi / 180, λ = lon * .pi / 180
        return SIMD3(cos(φ) * sin(λ), sin(φ), cos(φ) * cos(λ))
    }

    var unitVectorF: SIMD3<Float> { SIMD3<Float>(unitVector) }

    init(vector v: SIMD3<Double>) {
        let n = simd_normalize(v)
        lat = asin(max(-1, min(1, n.y))) * 180 / .pi
        lon = atan2(n.x, n.z) * 180 / .pi
    }

    /// Great-circle distance in kilometres.
    func distanceKm(to o: GeoPoint) -> Double {
        let r = 6371.0
        let φ1 = lat * .pi / 180, φ2 = o.lat * .pi / 180
        let dφ = (o.lat - lat) * .pi / 180, dλ = (o.lon - lon) * .pi / 180
        let a = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    /// Initial bearing in degrees (0 = north).
    func bearing(to o: GeoPoint) -> Double {
        let φ1 = lat * .pi / 180, φ2 = o.lat * .pi / 180, dλ = (o.lon - lon) * .pi / 180
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    static func compassName(_ bearing: Double) -> String {
        let names = [String(localized: "N", comment: "Compass: north"), String(localized: "NE", comment: "Compass: north-east"),
                     String(localized: "E", comment: "Compass: east"), String(localized: "SE", comment: "Compass: south-east"),
                     String(localized: "S", comment: "Compass: south"), String(localized: "SW", comment: "Compass: south-west"),
                     String(localized: "W", comment: "Compass: west"), String(localized: "NW", comment: "Compass: north-west")]
        let b = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((b + 22.5) / 45) % 8]
    }
}

nonisolated enum Geo {
    static let earthRadiusKm = 6371.0

    /// Converts an Earth-fixed (ECEF-style) vector with Z = north into the render frame.
    @inline(__always)
    static func renderFrame(fromECEF v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(v.y, v.z, v.x)
    }

    static func normalizeLon(_ lon: Double) -> Double {
        var l = lon.truncatingRemainder(dividingBy: 360)
        if l > 180 { l -= 360 }
        if l < -180 { l += 360 }
        return l
    }
}

/// Locale-aware whole percentage ("12%" in English, "%12" in Turkish).
nonisolated func percentString(_ value: Int) -> String {
    (Double(value) / 100).formatted(.percent.precision(.fractionLength(0)))
}
