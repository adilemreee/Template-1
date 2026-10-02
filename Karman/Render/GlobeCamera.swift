import Foundation
import QuartzCore
import simd

/// Orbit camera around the globe. The camera looks at a surface point (lat/lon) from
/// `distance` globe radii from the centre, optionally tilted toward the horizon.
struct CameraPose: Equatable, Sendable {
    var lat: Double
    var lon: Double
    var distance: Double
    var tilt: Double = 0      // degrees, 0 = straight down
    var heading: Double = 0   // degrees, direction the camera looks along the surface

    static let home = CameraPose(lat: 22, lon: 20, distance: 6.4)

    var target: SIMD3<Double> { GeoPoint(lat: lat, lon: lon).unitVector }

    struct Basis {
        var eye: SIMD3<Double>
        var target: SIMD3<Double>
        var forward: SIMD3<Double>
        var right: SIMD3<Double>
        var up: SIMD3<Double>
    }

    func basis() -> Basis {
        let t = target
        let worldUp = SIMD3<Double>(0, 1, 0)
        var east = simd_cross(worldUp, t)
        if simd_length(east) < 1e-6 { east = SIMD3(1, 0, 0) }
        east = simd_normalize(east)
        let north = simd_cross(t, east)
        let h = heading * .pi / 180
        let along = north * cos(h) + east * sin(h)
        let τ = max(0, min(tilt, 80)) * .pi / 180
        let altitude = max(distance - 1, 0.02)
        let eye = t + (t * cos(τ) - along * sin(τ)) * altitude
        // When tilted we aim slightly beyond the target so the horizon frames the shot.
        let aim = t + along * altitude * sin(τ) * 0.15
        let forward = simd_normalize(aim - eye)
        var right = simd_cross(forward, along)
        if simd_length(right) < 1e-6 { right = east }
        right = simd_normalize(right)
        let up = simd_cross(right, forward)
        return Basis(eye: eye, target: aim, forward: forward, right: right, up: up)
    }

    func viewMatrix() -> simd_float4x4 {
        let b = basis()
        let f = SIMD3<Float>(b.forward), r = SIMD3<Float>(b.right), u = SIMD3<Float>(b.up), e = SIMD3<Float>(b.eye)
        return simd_float4x4(columns: (
            SIMD4(r.x, u.x, -f.x, 0),
            SIMD4(r.y, u.y, -f.y, 0),
            SIMD4(r.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(r, e), -simd_dot(u, e), simd_dot(f, e), 1)
        ))
    }
}

enum Easing {
    static func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }
    static func inOutCubic(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    static func inOutSine(_ t: Double) -> Double { -(cos(.pi * t) - 1) / 2 }
    static func outQuint(_ t: Double) -> Double { 1 - pow(1 - t, 5) }
}

/// A single camera move with a "hop" that zooms out over long distances.
struct CameraFlight {
    var from: CameraPose
    var to: CameraPose
    var start: CFTimeInterval
    var duration: CFTimeInterval
    var hop: Double

    init(from: CameraPose, to: CameraPose, start: CFTimeInterval, duration: CFTimeInterval? = nil) {
        self.from = from
        self.to = to
        self.start = start
        let angle = acos(max(-1, min(1, simd_dot(from.target, to.target))))
        self.duration = duration ?? min(3.2, 1.2 + angle * 0.9 + abs(log(to.distance / from.distance)) * 0.35)
        self.hop = min(2.6, angle / .pi * 3.4) * max(0, 1 - (from.distance - 1) / 8)
    }

    func pose(at now: CFTimeInterval) -> (CameraPose, Bool) {
        let raw = min(1, max(0, (now - start) / duration))
        let e = Easing.inOutCubic(raw)
        let a = from.target, b = to.target
        let dot = max(-1, min(1, simd_dot(a, b)))
        let ω = acos(dot)
        var v: SIMD3<Double>
        if ω < 1e-5 {
            v = b
        } else {
            v = (sin((1 - e) * ω) * a + sin(e * ω) * b) / sin(ω)
        }
        let g = GeoPoint(vector: v)
        var p = CameraPose(lat: g.lat, lon: g.lon, distance: 0)
        let logD = log(from.distance) + (log(to.distance) - log(from.distance)) * e
        p.distance = exp(logD) + hop * sin(.pi * e)
        p.tilt = from.tilt + (to.tilt - from.tilt) * Easing.inOutSine(raw)
        var dh = (to.heading - from.heading).truncatingRemainder(dividingBy: 360)
        if dh > 180 { dh -= 360 }
        if dh < -180 { dh += 360 }
        p.heading = from.heading + dh * e
        return (p, raw >= 1)
    }
}
