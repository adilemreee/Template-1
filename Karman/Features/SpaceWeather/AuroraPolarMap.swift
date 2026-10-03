import CoreGraphics
import ImageIO
import simd
import SwiftUI

/// Polar (azimuthal equidistant) view of the auroral oval over the real continents,
/// with the night side shaded and the user's location marked.
struct AuroraPolarMap: View {
    var grid: [UInt8]?
    var north: Bool
    var user: GeoPoint?
    var date: Date

    @State private var image: CGImage?
    @State private var shimmer = false

    nonisolated static let edgeLatitude = 40.0

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(Color(red: 0.02, green: 0.04, blue: 0.08))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .clipShape(Circle())
                        .transition(.opacity)
                }
                // Latitude rings and meridians
                Canvas { ctx, sz in
                    let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                    let r = sz.width / 2
                    for lat in stride(from: 50.0, through: 80.0, by: 10.0) {
                        let rr = r * (90 - lat) / (90 - Self.edgeLatitude)
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                                   with: .color(.white.opacity(0.10)), style: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
                    }
                    for k in 0..<12 {
                        let a = Double(k) * .pi / 6
                        var p = Path()
                        p.move(to: c)
                        p.addLine(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
                        ctx.stroke(p, with: .color(.white.opacity(0.05)), lineWidth: 0.5)
                    }
                    if let user, (user.lat > 0) == north, abs(user.lat) > Self.edgeLatitude - 6 {
                        let pt = Self.project(user, north: north, center: c, radius: r)
                        ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 9, y: pt.y - 9, width: 18, height: 18)), with: .color(Theme.ice.opacity(0.25)))
                        ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)), with: .color(.white))
                    }
                }
                Circle().strokeBorder(LinearGradient(colors: [Theme.aurora.opacity(0.5), Theme.ice.opacity(0.15)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(shimmer ? 1 : 0.92)
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: "\(north)-\(grid?.count ?? 0)-\(grid?.reduce(0) { $0 &+ Int($1) } ?? 0)") {
            let g = grid, n = north, d = date
            let img = await Task.detached(priority: .userInitiated) { Self.render(grid: g, north: n, date: d, size: 520) }.value
            withAnimation(.easeOut(duration: 0.6)) { image = img }
            withAnimation(.easeInOut(duration: 2.4).repeatForever()) { shimmer = true }
        }
    }

    static func project(_ p: GeoPoint, north: Bool, center c: CGPoint, radius r: Double) -> CGPoint {
        let colat = north ? 90 - p.lat : 90 + p.lat
        let rr = r * colat / (90 - edgeLatitude)
        // Longitude 0 points down (toward the viewer), east counter-clockwise when looking at the north pole.
        let a = (north ? p.lon : -p.lon) * .pi / 180
        return CGPoint(x: c.x + sin(a) * rr, y: c.y + cos(a) * rr)
    }

    nonisolated private static let mask: (pixels: [UInt8], width: Int, height: Int)? = {
        guard let url = Bundle.main.url(forResource: "earth_mask_small", withExtension: "png"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (px, w, h)
    }()

    nonisolated static func render(grid: [UInt8]?, north: Bool, date: Date, size: Int) -> CGImage? {
        var buf = [UInt8](repeating: 0, count: size * size * 4)
        let sun = Astro.subsolarPoint(date).unitVector
        let m = mask
        let half = Double(size) / 2
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x) - half + 0.5, dy = Double(y) - half + 0.5
                let rr = sqrt(dx * dx + dy * dy) / half
                guard rr <= 1 else { continue }
                let colat = rr * (90 - edgeLatitude)
                let lat = north ? 90 - colat : -90 + colat
                var lon = atan2(dx, dy) * 180 / .pi
                if !north { lon = -lon }
                let p = GeoPoint(lat: lat, lon: lon)
                // land / water
                var land = 0.0
                if let m {
                    let u = Int((lon + 180) / 360 * Double(m.width)) % m.width
                    let v = min(m.height - 1, max(0, Int((90 - lat) / 180 * Double(m.height))))
                    land = 1 - Double(m.pixels[v * m.width + u]) / 255
                }
                let daylight = max(0, min(1, (simd_dot(p.unitVector, sun) + 0.12) / 0.3))
                var r = 0.020 + land * 0.10, g = 0.035 + land * 0.11, b = 0.075 + land * 0.10
                let shade = 0.45 + 0.55 * daylight
                r *= shade; g *= shade; b *= shade
                if let grid, grid.count == 360 * 181 {
                    let lo = ((Int(lon.rounded()) % 360) + 360) % 360
                    let la = Int(lat.rounded()) + 90
                    let prob = Double(grid[la * 360 + lo]) / 100
                    let a = pow(min(1, prob * 1.6), 0.8)
                    r += a * 0.10; g += a * 0.95; b += a * 0.45
                    if prob > 0.35 { r += (prob - 0.35) * 0.6; b += (prob - 0.35) * 0.4 }
                }
                let edge = min(1, (1 - rr) * 30)
                let i = (y * size + x) * 4
                buf[i] = UInt8(min(255, r * 255 * edge))
                buf[i + 1] = UInt8(min(255, g * 255 * edge))
                buf[i + 2] = UInt8(min(255, b * 255 * edge))
                buf[i + 3] = UInt8(255 * edge)
            }
        }
        guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
