import CoreGraphics
import Foundation

/// A 3×3 matrix stored by rows; `apply` multiplies a column vector.
nonisolated struct Mat3: Sendable {
    var r0: SIMD3<Double>
    var r1: SIMD3<Double>
    var r2: SIMD3<Double>

    static let identity = Mat3(r0: SIMD3(1, 0, 0), r1: SIMD3(0, 1, 0), r2: SIMD3(0, 0, 1))

    func apply(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3((r0 * v).sum(), (r1 * v).sum(), (r2 * v).sum())
    }

    var transposed: Mat3 {
        Mat3(r0: SIMD3(r0.x, r1.x, r2.x), r1: SIMD3(r0.y, r1.y, r2.y), r2: SIMD3(r0.z, r1.z, r2.z))
    }

    /// (a * b).apply(v) == a.apply(b.apply(v))
    static func * (a: Mat3, b: Mat3) -> Mat3 {
        let bt = b.transposed
        func row(_ r: SIMD3<Double>) -> SIMD3<Double> { SIMD3((r * bt.r0).sum(), (r * bt.r1).sum(), (r * bt.r2).sum()) }
        return Mat3(r0: row(a.r0), r1: row(a.r1), r2: row(a.r2))
    }
}

/// Geometry for the Sky Lens. Directions live in three frames:
/// - equatorial (J2000): x toward RA 0, z toward the celestial pole;
/// - local: x north, y west, z up (Core Motion's `xTrueNorthZVertical` reference frame);
/// - device: x right, y toward the top of the phone, z out of the screen (the back camera looks along −z).
nonisolated enum SkyLensMath {
    static func equatorial(raDegrees ra: Double, decDegrees dec: Double) -> SIMD3<Double> {
        let a = ra * Astro.deg, d = dec * Astro.deg
        return SIMD3(cos(d) * cos(a), cos(d) * sin(a), sin(d))
    }

    static func equatorial(_ eq: Astro.Equatorial) -> SIMD3<Double> {
        SIMD3(cos(eq.dec) * cos(eq.ra), cos(eq.dec) * sin(eq.ra), sin(eq.dec))
    }

    /// Rotation from equatorial to local coordinates for an observer at a moment.
    static func equatorialToLocal(date: Date, observer: GeoPoint) -> Mat3 {
        let lst = Astro.gmst(date) + observer.lon * Astro.deg
        let phi = observer.lat * Astro.deg
        let c = cos(lst), s = sin(lst)
        // Hour-angle frame: (cos δ cos H, −cos δ sin H, sin δ).
        let hx = SIMD3(c, s, 0), hy = SIMD3(-s, c, 0), hz = SIMD3<Double>(0, 0, 1)
        let north = -sin(phi) * hx + cos(phi) * hz
        let east = hy
        let up = cos(phi) * hx + sin(phi) * hz
        return Mat3(r0: north, r1: -east, r2: up)
    }

    static func local(altitude: Double, azimuth: Double) -> SIMD3<Double> {
        let a = altitude * Astro.deg, z = azimuth * Astro.deg
        return SIMD3(cos(a) * cos(z), -cos(a) * sin(z), sin(a))
    }

    static func altAz(_ v: SIMD3<Double>) -> (altitude: Double, azimuth: Double) {
        let len = (v * v).sum().squareRoot()
        guard len > 0 else { return (0, 0) }
        let alt = asin(max(-1, min(1, v.z / len))) / Astro.deg
        var az = atan2(-v.y, v.x) / Astro.deg
        if az < 0 { az += 360 }
        return (alt, az)
    }

    /// Screen point for a device-frame direction seen by the back camera (portrait), or nil when behind it.
    static func project(_ d: SIMD3<Double>, center: CGPoint, focal: Double) -> CGPoint? {
        guard d.z < -1e-3 else { return nil }
        return CGPoint(x: center.x + focal * d.x / -d.z, y: center.y - focal * d.y / -d.z)
    }

    /// Device-frame direction through a screen point.
    static func direction(at p: CGPoint, center: CGPoint, focal: Double) -> SIMD3<Double> {
        let v = SIMD3((Double(p.x - center.x)) / focal, -(Double(p.y - center.y)) / focal, -1)
        return v / (v * v).sum().squareRoot()
    }

    /// Focal length in points for a vertical field of view across a view height.
    static func focal(height: Double, verticalFOVDegrees fov: Double) -> Double {
        (height / 2) / tan(fov * Astro.deg / 2)
    }

    /// The part of the screen below the horizon: a polygon (the horizon projects to a straight
    /// line because it is a great circle through the camera). `up` is the local zenith in device coordinates.
    static func groundPolygon(up: SIMD3<Double>, size: CGSize, focal: Double) -> [CGPoint] {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        func below(_ p: CGPoint) -> Double { (direction(at: p, center: c, focal: focal) * up).sum() }
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0), CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
        var out: [CGPoint] = []
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            let fa = below(a), fb = below(b)
            if fa < 0 { out.append(a) }
            if (fa < 0) != (fb < 0) {
                // Bisect the edge for the crossing (the sign function is monotonic along it).
                var lo = a, hi = b
                for _ in 0..<18 {
                    let mid = CGPoint(x: (lo.x + hi.x) / 2, y: (lo.y + hi.y) / 2)
                    if (below(mid) < 0) == (fa < 0) { lo = mid } else { hi = mid }
                }
                out.append(CGPoint(x: (lo.x + hi.x) / 2, y: (lo.y + hi.y) / 2))
            }
        }
        return out
    }

    /// Angle in degrees between two directions.
    static func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let la = (a * a).sum().squareRoot(), lb = (b * b).sum().squareRoot()
        guard la > 0, lb > 0 else { return 180 }
        return acos(max(-1, min(1, (a * b).sum() / (la * lb)))) / Astro.deg
    }

    struct Star: Sendable {
        var direction: SIMD3<Double>
        var magnitude: Double
        var r: Double, g: Double, b: Double
    }

    /// Stars from the bundled catalogue (stars.bin: float32 x, y, z, magnitude, then RGBA bytes).
    static func loadStars(data: Data, maxMagnitude: Double) -> [Star] {
        let stride = 20
        var out: [Star] = []
        data.withUnsafeBytes { raw in
            let count = raw.count / stride
            out.reserveCapacity(count / 4)
            for i in 0..<count {
                let base = i * stride
                let mag = Double(raw.loadUnaligned(fromByteOffset: base + 12, as: Float.self))
                guard mag <= maxMagnitude else { continue }
                let x = Double(raw.loadUnaligned(fromByteOffset: base, as: Float.self))
                let y = Double(raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self))
                let z = Double(raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self))
                out.append(Star(direction: SIMD3(x, y, z), magnitude: mag,
                                r: Double(raw[base + 16]) / 255, g: Double(raw[base + 17]) / 255, b: Double(raw[base + 18]) / 255))
            }
        }
        return out.sorted { $0.magnitude < $1.magnitude }
    }
}
