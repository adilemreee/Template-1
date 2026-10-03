import CoreGraphics
import ImageIO
import Metal
import UIKit

/// Wraps Metal objects so they can cross concurrency domains; Metal resources are thread-safe.
struct SendableTexture: @unchecked Sendable { let texture: MTLTexture }

enum TextureKind {
    case colorSRGB, color, gray
}

enum MetalResources {
    /// Decodes an image file straight into a shared buffer and blits it into a mipmapped private texture.
    static func loadTexture(url: URL, kind: TextureKind, device: MTLDevice, queue: MTLCommandQueue, maxWidth: Int? = nil, mipmapped: Bool = true) -> MTLTexture? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        var image: CGImage?
        if let maxWidth, let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, w > maxWidth {
            let thumbOpts = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxWidth,
                             kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let image else { return nil }
        return makeTexture(from: image, kind: kind, device: device, queue: queue, mipmapped: mipmapped)
    }

    static func makeTexture(from image: CGImage, kind: TextureKind, device: MTLDevice, queue: MTLCommandQueue, mipmapped: Bool = true) -> MTLTexture? {
        let w = image.width, h = image.height
        let bpp = kind == .gray ? 1 : 4
        let bytesPerRow = w * bpp
        guard let buffer = device.makeBuffer(length: bytesPerRow * h, options: .storageModeShared) else { return nil }
        let space: CGColorSpace = kind == .gray ? CGColorSpaceCreateDeviceGray() : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        let info: UInt32 = kind == .gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: buffer.contents(), width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let format: MTLPixelFormat = switch kind {
        case .gray: .r8Unorm
        case .colorSRGB: .rgba8Unorm_srgb
        case .color: .rgba8Unorm
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: mipmapped)
        desc.usage = .shaderRead
        desc.storageMode = .private
        guard let texture = device.makeTexture(descriptor: desc),
              let cmd = queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytesPerRow * h,
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        if mipmapped { blit.generateMipmaps(for: texture) }
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return texture
    }

    static func solidTexture(device: MTLDevice, gray: UInt8 = 0) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        var px: [UInt8] = [gray, gray, gray, 255]
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        return t
    }

    /// Renders map glyphs into a single-row atlas (white glyph in alpha).
    static func iconAtlas(device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture? {
        let cell = 128
        let cells = GlobeIcon.allCases.count
        let size = CGSize(width: cell * 12, height: cell)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            for icon in GlobeIcon.allCases {
                let rect = CGRect(x: CGFloat(icon.rawValue * cell), y: 0, width: CGFloat(cell), height: CGFloat(cell))
                if icon == .rocket {
                    drawRocket(in: rect.insetBy(dx: 26, dy: 22), ctx: ctx.cgContext)
                    continue
                }
                let config = UIImage.SymbolConfiguration(pointSize: 74, weight: .semibold)
                guard let symbol = UIImage(systemName: icon.symbol, withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) else { continue }
                let s = symbol.size
                let scale = min(84 / s.width, 84 / s.height)
                let drawSize = CGSize(width: s.width * scale, height: s.height * scale)
                symbol.draw(in: CGRect(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2, width: drawSize.width, height: drawSize.height))
            }
            _ = cells
        }
        guard let cg = img.cgImage else { return nil }
        return makeTexture(from: cg, kind: .color, device: device, queue: queue, mipmapped: true)
    }

    private static func drawRocket(in r: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(UIColor.white.cgColor)
        let w = r.width, h = r.height
        let body = UIBezierPath()
        body.move(to: CGPoint(x: r.midX, y: r.minY))
        body.addCurve(to: CGPoint(x: r.midX + w * 0.2, y: r.minY + h * 0.62), controlPoint1: CGPoint(x: r.midX + w * 0.2, y: r.minY + h * 0.15), controlPoint2: CGPoint(x: r.midX + w * 0.22, y: r.minY + h * 0.4))
        body.addLine(to: CGPoint(x: r.midX - w * 0.2, y: r.minY + h * 0.62))
        body.addCurve(to: CGPoint(x: r.midX, y: r.minY), controlPoint1: CGPoint(x: r.midX - w * 0.22, y: r.minY + h * 0.4), controlPoint2: CGPoint(x: r.midX - w * 0.2, y: r.minY + h * 0.15))
        body.close()
        body.fill()
        let finL = UIBezierPath()
        finL.move(to: CGPoint(x: r.midX - w * 0.2, y: r.minY + h * 0.42))
        finL.addLine(to: CGPoint(x: r.midX - w * 0.42, y: r.minY + h * 0.72))
        finL.addLine(to: CGPoint(x: r.midX - w * 0.2, y: r.minY + h * 0.66))
        finL.close()
        finL.fill()
        let finR = UIBezierPath()
        finR.move(to: CGPoint(x: r.midX + w * 0.2, y: r.minY + h * 0.42))
        finR.addLine(to: CGPoint(x: r.midX + w * 0.42, y: r.minY + h * 0.72))
        finR.addLine(to: CGPoint(x: r.midX + w * 0.2, y: r.minY + h * 0.66))
        finR.close()
        finR.fill()
        let flame = UIBezierPath()
        flame.move(to: CGPoint(x: r.midX - w * 0.12, y: r.minY + h * 0.68))
        flame.addQuadCurve(to: CGPoint(x: r.midX, y: r.maxY), controlPoint: CGPoint(x: r.midX - w * 0.14, y: r.minY + h * 0.9))
        flame.addQuadCurve(to: CGPoint(x: r.midX + w * 0.12, y: r.minY + h * 0.68), controlPoint: CGPoint(x: r.midX + w * 0.14, y: r.minY + h * 0.9))
        flame.close()
        flame.fill()
        ctx.setBlendMode(.clear)
        UIBezierPath(ovalIn: CGRect(x: r.midX - w * 0.07, y: r.minY + h * 0.26, width: w * 0.14, height: w * 0.14)).fill()
        ctx.restoreGState()
    }

    /// UV sphere with a duplicated seam column so equirectangular textures wrap cleanly.
    static func sphere(device: MTLDevice, segments: Int, rings: Int) -> (vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int)? {
        var verts: [Float] = []
        verts.reserveCapacity((segments + 1) * (rings + 1) * 5)
        for r in 0...rings {
            let v = Double(r) / Double(rings)
            let lat = 90 - v * 180
            for s in 0...segments {
                let u = Double(s) / Double(segments)
                let lon = -180 + u * 360
                let p = GeoPoint(lat: lat, lon: lon).unitVector
                verts += [Float(p.x), Float(p.y), Float(p.z), Float(u), Float(v)]
            }
        }
        var idx: [UInt32] = []
        idx.reserveCapacity(segments * rings * 6)
        let row = UInt32(segments + 1)
        for r in 0..<UInt32(rings) {
            for s in 0..<UInt32(segments) {
                let a = r * row + s, b = a + row
                idx += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        guard let vb = device.makeBuffer(bytes: verts, length: verts.count * 4, options: .storageModeShared),
              let ib = device.makeBuffer(bytes: idx, length: idx.count * 4, options: .storageModeShared) else { return nil }
        return (vb, ib, idx.count)
    }
}

enum GlobeIcon: Int, CaseIterable {
    case storm = 0, fire, volcano, ice, flood, dust, rocket, heat, drought, landslide, snow, other

    var symbol: String {
        switch self {
        case .storm: "hurricane"
        case .fire: "flame.fill"
        case .volcano: "mountain.2.fill"
        case .ice: "snowflake"
        case .flood: "drop.fill"
        case .dust: "aqi.medium"
        case .rocket: "airplane"
        case .heat: "thermometer.sun.fill"
        case .drought: "sun.dust.fill"
        case .landslide: "arrow.down.right.and.arrow.up.left"
        case .snow: "cloud.snow.fill"
        case .other: "exclamationmark"
        }
    }

    init(kind: EventKind) {
        switch kind {
        case .wildfire: self = .fire
        case .storm: self = .storm
        case .volcano: self = .volcano
        case .ice: self = .ice
        case .flood: self = .flood
        case .dust: self = .dust
        case .drought: self = .drought
        case .landslide: self = .landslide
        case .snow: self = .snow
        case .heat: self = .heat
        case .other: self = .other
        }
    }
}
