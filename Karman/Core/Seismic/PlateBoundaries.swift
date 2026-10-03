import Foundation
import simd

/// Tectonic plate boundaries from Peter Bird's PB2002 model (ODC-By 1.0), bundled as
/// `plates.json` by tools/build_plates.py: polylines grouped by boundary type plus label points.
nonisolated struct PlateBoundaries: Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case divergent, convergent, transform

        var title: String {
            switch self {
            case .divergent: String(localized: "Spreading ridge")
            case .convergent: String(localized: "Subduction or collision zone")
            case .transform: String(localized: "Transform fault")
            }
        }

        var explanation: String {
            switch self {
            case .divergent: String(localized: "Plates pull apart here and new crust wells up from the mantle.")
            case .convergent: String(localized: "Plates collide here; one often dives beneath the other, building mountains, volcanoes and the deepest earthquakes.")
            case .transform: String(localized: "Plates grind sideways past each other here, like the San Andreas Fault.")
            }
        }
    }

    struct Line: Sendable {
        var kind: Kind
        var points: [GeoPoint]
    }

    struct Plate: Sendable, Decodable, Hashable {
        var code: String
        var name: String
        var lat: Double
        var lon: Double
        var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }
    }

    let lines: [Line]
    let plates: [Plate]
    let attribution: String
    /// Unit vectors of every segment, for nearest-boundary queries.
    private let segments: [(a: SIMD3<Double>, b: SIMD3<Double>, kind: Kind)]

    private struct File: Decodable {
        var attribution: String
        var kinds: [String: [[Double]]]
        var plates: [Plate]
    }

    init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        var lines: [Line] = []
        for kind in Kind.allCases {
            for flat in file.kinds[kind.rawValue] ?? [] where flat.count >= 4 {
                let pts = stride(from: 0, to: flat.count - 1, by: 2).map { GeoPoint(lat: flat[$0 + 1], lon: flat[$0]) }
                lines.append(Line(kind: kind, points: pts))
            }
        }
        self.lines = lines
        plates = file.plates
        attribution = file.attribution
        segments = lines.flatMap { line in
            zip(line.points, line.points.dropFirst()).map { (a: $0.unitVector, b: $1.unitVector, kind: line.kind) }
        }
    }

    static let bundled: PlateBoundaries? = {
        guard let url = Bundle.main.url(forResource: "plates", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? PlateBoundaries(data: data)
    }()

    /// The closest boundary to a point within `maxKm`, with its type and distance.
    func nearest(to p: GeoPoint, maxKm: Double = 500) -> (kind: Kind, km: Double)? {
        let v = p.unitVector
        var best: (Kind, Double)?
        let limit = maxKm / Geo.earthRadiusKm
        for s in segments {
            // Cheap reject: both ends far away (segments are under ~2° long).
            if simd_dot(v, s.a) < cos(limit + 0.04) && simd_dot(v, s.b) < cos(limit + 0.04) { continue }
            let angle = Self.angleToArc(v, s.a, s.b)
            if angle <= limit, angle < (best?.1 ?? .infinity) { best = (s.kind, angle) }
        }
        return best.map { ($0.0, $0.1 * Geo.earthRadiusKm) }
    }

    /// Angular distance (radians) from a point to the great-circle arc between two points.
    static func angleToArc(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        func angle(_ x: SIMD3<Double>, _ y: SIMD3<Double>) -> Double { acos(max(-1, min(1, simd_dot(x, y)))) }
        let c = simd_cross(a, b)
        let len = simd_length(c)
        guard len > 1e-12 else { return angle(p, a) }
        let n = c / len
        let off = simd_dot(p, n)
        let projected = p - n * off
        let pl = simd_length(projected)
        if pl > 1e-12 {
            let q = projected / pl
            if simd_dot(simd_cross(a, q), n) >= 0 && simd_dot(simd_cross(q, b), n) >= 0 {
                return abs(asin(max(-1, min(1, off))))
            }
        }
        return min(angle(p, a), angle(p, b))
    }
}
