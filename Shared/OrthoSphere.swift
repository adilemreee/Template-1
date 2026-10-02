import CoreGraphics
import Foundation
import ImageIO
import simd

/// CPU orthographic sphere renderer for places where Metal is not available or not worth it:
/// the Earth widget and the Moon phase in Tonight's Sky.
nonisolated enum OrthoSphere {
    struct Texture: Sendable {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let channels: Int

        @inline(__always)
        func sample(u: Double, v: Double) -> SIMD3<Double> {
            let x = min(width - 1, max(0, Int(u * Double(width))))
            let y = min(height - 1, max(0, Int(v * Double(height))))
            let i = (y * width + x) * channels
            if channels == 1 {
                let g = Double(pixels[i]) / 255
                return SIMD3(g, g, g)
            }
            return SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])) / 255
        }
    }

    static func loadTexture(url: URL, gray: Bool) -> Texture? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height, ch = gray ? 1 : 4
        var px = [UInt8](repeating: 0, count: w * h * ch)
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * ch, space: space, bitmapInfo: info) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Texture(pixels: px, width: w, height: h, channels: ch)
    }

    struct Marker: Sendable {
        var point: GeoPoint
        var color: SIMD3<Double>
        var radius: Double   // in pixels at 1x
    }

    /// Renders a lit sphere seen from above `center`. `light` is a unit vector in the render frame
    /// (+Y north, +Z toward lat 0 lon 0). For the Earth, pass night lights and an atmosphere rim.
    static func render(size: Int, day: Texture, nightLights: Texture? = nil, center: GeoPoint, light: SIMD3<Double>,
                       atmosphere: Bool = true, markers: [Marker] = [], ambient: Double = 0.03, viewLight: SIMD3<Double>? = nil) -> CGImage? {
        var buf = [UInt8](repeating: 0, count: size * size * 4)
        // Camera basis: forward = -c, right = east at centre, up = north at centre.
        let c = center.unitVector
        var east = simd_cross(SIMD3<Double>(0, 1, 0), c)
        if simd_length(east) < 1e-6 { east = SIMD3(1, 0, 0) }
        east = simd_normalize(east)
        let north = simd_cross(c, east)
        let half = Double(size) / 2
        let radius = half * (atmosphere ? 0.90 : 0.985)
        let L = simd_normalize(light)

        for y in 0..<size {
            for x in 0..<size {
                let sx = (Double(x) + 0.5 - half) / radius
                let sy = (half - Double(y) - 0.5) / radius
                let r2 = sx * sx + sy * sy
                let i = (y * size + x) * 4
                if r2 > 1 {
                    guard atmosphere else { continue }
                    // Thin glowing limb outside the disc.
                    let d = sqrt(r2) - 1
                    if d < 0.11 {
                        let dir = simd_normalize(east * sx + north * sy)
                        let lit = max(0, min(1, (simd_dot(dir, L) + 0.35) / 0.7))
                        let a = pow(1 - d / 0.11, 2.2) * (0.25 + 0.75 * lit)
                        buf[i] = UInt8(min(255, 90 * a)); buf[i + 1] = UInt8(min(255, 160 * a)); buf[i + 2] = UInt8(min(255, 255 * a)); buf[i + 3] = UInt8(min(255, 255 * a))
                    }
                    continue
                }
                let sz = sqrt(1 - r2)
                let n: SIMD3<Double>
                if let viewLight {
                    // View-space shading (used for the Moon, where light is given relative to the viewer).
                    n = SIMD3(sx, sy, sz)
                    _ = viewLight
                } else {
                    n = east * sx + north * sy + c * sz
                }
                let world = viewLight == nil ? n : (east * sx + north * sy + c * sz)
                let g = GeoPoint(vector: world)
                let u = (g.lon + 180) / 360, v = (90 - g.lat) / 180
                var col = day.sample(u: u, v: v)
                col = SIMD3(pow(col.x, 2.2), pow(col.y, 2.2), pow(col.z, 2.2))
                let lightVec = viewLight ?? L
                let ndl = simd_dot(n, lightVec)
                let dayAmt = max(0, min(1, (ndl + 0.06) / 0.22))
                var out = col * (dayAmt * max(0.0, ndl) * 1.7 + ambient)
                if let nightLights {
                    let lights = nightLights.sample(u: u, v: v).x
                    let night = 1 - max(0, min(1, (ndl + 0.15) / 0.2))
                    out += SIMD3(1.0, 0.68, 0.32) * lights * lights * 1.6 * night
                }
                if atmosphere {
                    let rim = pow(1 - sz, 3)
                    out = out * (1 - rim * 0.6) + SIMD3(0.25, 0.5, 1.0) * rim * 0.9 * max(0.1, min(1, ndl + 0.3))
                }
                for m in markers {
                    let mp = m.point.unitVector
                    let ang = acos(max(-1, min(1, simd_dot(mp, world)))) * radius
                    if ang < m.radius * 2.2 {
                        let a = ang < m.radius ? 1.0 : max(0, 1 - (ang - m.radius) / (m.radius * 1.2)) * 0.6
                        out = out * (1 - a) + m.color * a
                    }
                }
                let edge = min(1, (1 - sqrt(r2)) * radius * 0.9)
                buf[i] = UInt8(min(255, pow(max(0, out.x), 1 / 2.2) * 255 * edge))
                buf[i + 1] = UInt8(min(255, pow(max(0, out.y), 1 / 2.2) * 255 * edge))
                buf[i + 2] = UInt8(min(255, pow(max(0, out.z), 1 / 2.2) * 255 * edge))
                buf[i + 3] = UInt8(255 * edge)
            }
        }
        guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The Moon as seen from Earth with the correct phase. Light is expressed in view space:
    /// +x right, +y up, +z toward the viewer.
    static func moon(size: Int, texture: Texture, phase: Astro.MoonPhase, southernHemisphere: Bool) -> CGImage? {
        let e = phase.phase * 2 * .pi
        let light = SIMD3(sin(e) * (southernHemisphere ? -1 : 1), 0, -cos(e))
        return render(size: size, day: texture, center: GeoPoint(lat: 0, lon: 0), light: SIMD3(0, 0, 1),
                      atmosphere: false, ambient: 0.012, viewLight: simd_normalize(light))
    }
}
