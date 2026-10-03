import CoreGraphics
import ImageIO
import Metal
import QuartzCore

/// Streams NASA GIBS 500 m imagery for the region under the camera into one texture that the
/// Earth shader blends over the global 8K base: Blue Marble relief colour in RGB and Black
/// Marble city lights in A. Tiles load centre-first, are cached on disk, and fade in through a
/// per-tile mask so the coarser base never shows a hard edge.
@MainActor
final class DetailImagery {
    nonisolated static let tileSize = 512

    let grid: Int
    let texture: MTLTexture
    let mask: MTLTexture
    /// West longitude, north latitude, longitude span, latitude span (degrees).
    private(set) var bounds = SIMD4<Float>(0, 0, 1, 1)
    /// How much of the detail to show (eases in/out with the zoom level).
    private(set) var blend: Float = 0
    /// Whether the A channel carries night lights for this window.
    private(set) var hasNight = false

    private struct Window: Equatable {
        var level: Int
        var col0: Int
        var row0: Int
        var night: Bool
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let session: URLSession
    private var window: Window?
    private var pending: Window?
    private var pendingSince: CFTimeInterval = 0
    private var loadTask: Task<Void, Never>?
    private var maskBytes: [UInt8]
    private var mipsDirty = false
    private var lastMips: CFTimeInterval = 0
    private var lastUpdate: CFTimeInterval = 0
    private var scratch: MTLTexture?

    init?(device: MTLDevice, queue: MTLCommandQueue, grid: Int) {
        let side = grid * Self.tileSize
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: side, height: side, mipmapped: true)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        let maskDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: grid, height: grid, mipmapped: false)
        maskDesc.usage = .shaderRead
        maskDesc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc), let mask = device.makeTexture(descriptor: maskDesc) else { return nil }
        self.grid = grid
        self.texture = texture
        self.mask = mask
        self.device = device
        self.queue = queue
        maskBytes = [UInt8](repeating: 0, count: grid * grid)
        mask.replace(region: MTLRegionMake2D(0, 0, grid, grid), mipmapLevel: 0, withBytes: maskBytes, bytesPerRow: grid)

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "gibs-tiles")
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 400 << 20, directory: caches)
        config.requestCachePolicy = .returnCacheDataElseLoad // static layers never change
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    /// Called every frame; cheap unless the window has to move.
    /// - Parameter center: ground point to keep sharp; defaults to the camera's target.
    func update(pose: CameraPose, center: GeoPoint? = nil, sunDir: SIMD3<Float>, isMoving: Bool, now: CFTimeInterval) {
        let dt = Float(min(0.1, max(0, now - lastUpdate)))
        lastUpdate = now
        var pose = pose
        if let center {
            pose.lat = center.lat
            pose.lon = center.lon
        }
        let target = Self.desiredWindow(pose: pose, sunDir: sunDir, grid: grid)
        let goal: Float = (target != nil && window != nil) ? 1 : 0
        blend += (goal - blend) * min(1, dt * 4)

        if mipsDirty, now - lastMips > 0.35 { rebuildMips(now: now) }

        guard let target else { return }
        if let window, Self.covers(window, pose: pose, grid: grid), window.level == target.level, window.night || !target.night { return }
        // Wait for the camera to settle before re-centring.
        if pending != target {
            pending = target
            pendingSince = now
            return
        }
        guard !isMoving || now - pendingSince > 0.6, now - pendingSince > 0.2 else { return }
        start(target)
    }

    // MARK: Window choice

    private static func levelFor(distance d: Double) -> Int? {
        switch d {
        case ..<1.45: 7   // ~490 m per pixel
        case ..<1.9: 6    // ~980 m
        case ..<2.8: 5    // ~2 km
        default: nil      // the 8K base is sharp enough
        }
    }

    private static func tileDegrees(_ level: Int) -> Double { 288.0 / Double(1 << level) }

    private static func desiredWindow(pose: CameraPose, sunDir: SIMD3<Float>, grid: Int) -> Window? {
        guard let level = levelFor(distance: pose.distance) else { return nil }
        let deg = tileDegrees(level)
        let rows = Int((180 / deg).rounded(.up))
        let fx = (pose.lon + 180) / deg, fy = (90 - pose.lat) / deg
        let col0 = Int((fx - Double(grid) / 2).rounded())
        let row0 = min(max(Int((fy - Double(grid) / 2).rounded()), 0), max(rows - grid, 0))
        // Fetch Black Marble lights only when part of the window is on the night side.
        let span = deg * Double(grid)
        let west = -180 + Double(col0) * deg, north = 90 - Double(row0) * deg
        var night = false
        for (a, b) in [(0.0, 0.0), (1, 0), (0, 1), (1, 1), (0.5, 0.5)] {
            let p = GeoPoint(lat: north - b * span, lon: west + a * span).unitVectorF
            if simd_dot(p, sunDir) < 0.15 { night = true }
        }
        return Window(level: level, col0: col0, row0: row0, night: night)
    }

    /// True while the camera's centre stays at least one tile inside the window.
    private static func covers(_ w: Window, pose: CameraPose, grid: Int) -> Bool {
        let deg = tileDegrees(w.level)
        let cols = Double(Int((360 / deg).rounded()))
        var fx = (pose.lon + 180) / deg - Double(w.col0)
        fx -= cols * (fx / cols).rounded(.down)
        let fy = (90 - pose.lat) / deg - Double(w.row0)
        let rows = (180 / deg).rounded(.up)
        let topClamped = w.row0 == 0, bottomClamped = Double(w.row0 + grid) >= rows
        let yOK = (fy >= 1 || topClamped) && (fy <= Double(grid - 1) || bottomClamped)
        return fx >= 1 && fx <= Double(grid - 1) && yOK
    }

    // MARK: Loading

    private func start(_ target: Window) {
        loadTask?.cancel()
        let old = window
        window = target
        pending = nil
        hasNight = target.night
        let deg = Self.tileDegrees(target.level)
        bounds = SIMD4(Float(-180 + Double(target.col0) * deg), Float(90 - Double(target.row0) * deg),
                       Float(deg * Double(grid)), Float(deg * Double(grid)))
        let cols = Int((360 / deg).rounded())

        // Keep tiles the old window already shows (shifted into their new slots), so panning and
        // following the ISS only fetch the new edge instead of flashing back to the coarse base.
        var newMask = [UInt8](repeating: 0, count: grid * grid)
        if let old, old.level == target.level, old.night || !target.night {
            var dx = (target.col0 - old.col0) % cols
            if dx > cols / 2 { dx -= cols }
            if dx < -cols / 2 { dx += cols }
            let dy = target.row0 - old.row0
            var moves: [(from: Int, to: Int)] = []
            let js = dy >= 0 ? Array(0..<grid) : Array((0..<grid).reversed())
            let iz = dx >= 0 ? Array(0..<grid) : Array((0..<grid).reversed())
            for j in js {
                for i in iz {
                    let oi = i + dx, oj = j + dy
                    guard oi >= 0, oi < grid, oj >= 0, oj < grid, maskBytes[oj * grid + oi] == 255 else { continue }
                    moves.append((oj * grid + oi, j * grid + i))
                }
            }
            if !moves.isEmpty, shiftTiles(moves) {
                for m in moves { newMask[m.to] = 255 }
                mipsDirty = true
            }
        }
        maskBytes = newMask
        mask.replace(region: MTLRegionMake2D(0, 0, grid, grid), mipmapLevel: 0, withBytes: maskBytes, bytesPerRow: grid)

        let center = Double(grid - 1) / 2
        let order = (0..<(grid * grid)).filter { newMask[$0] == 0 }.sorted { a, b in
            let da = pow(Double(a % grid) - center, 2) + pow(Double(a / grid) - center, 2)
            let db = pow(Double(b % grid) - center, 2) + pow(Double(b / grid) - center, 2)
            return da < db
        }
        let session = self.session
        let grid = self.grid
        loadTask = Task { [weak self] in
            await withTaskGroup(of: (Int, Data?).self) { group in
                var queued = order.makeIterator()
                func enqueue() {
                    guard let i = queued.next() else { return }
                    let col = ((target.col0 + i % grid) % cols + cols) % cols
                    let row = target.row0 + i / grid
                    group.addTask {
                        (i, await Self.loadTile(level: target.level, col: col, row: row, night: target.night, session: session))
                    }
                }
                for _ in 0..<6 { enqueue() }
                for await (i, pixels) in group {
                    if Task.isCancelled { group.cancelAll(); return }
                    if let pixels { self?.place(pixels, index: i, for: target) }
                    enqueue()
                }
            }
        }
    }

    /// Moves tiles inside the texture (through a one-tile scratch, in an order where no source is
    /// overwritten before it is read). Waits for the GPU so later CPU uploads land on top.
    private func shiftTiles(_ moves: [(from: Int, to: Int)]) -> Bool {
        if scratch == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: Self.tileSize, height: Self.tileSize, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .private
            scratch = device.makeTexture(descriptor: d)
        }
        guard let scratch, let cmd = queue.makeCommandBuffer() else { return false }
        let size = MTLSize(width: Self.tileSize, height: Self.tileSize, depth: 1)
        func origin(_ index: Int) -> MTLOrigin {
            MTLOrigin(x: (index % grid) * Self.tileSize, y: (index / grid) * Self.tileSize, z: 0)
        }
        for m in moves where m.from != m.to {
            guard let a = cmd.makeBlitCommandEncoder() else { return false }
            a.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin(m.from), sourceSize: size,
                   to: scratch, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
            a.endEncoding()
            guard let b = cmd.makeBlitCommandEncoder() else { return false }
            b.copy(from: scratch, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: size,
                   to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin(m.to))
            b.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        return cmd.status == .completed
    }

    private func place(_ pixels: Data, index: Int, for target: Window) {
        guard window == target else { return }
        let x = (index % grid) * Self.tileSize, y = (index / grid) * Self.tileSize
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(x, y, Self.tileSize, Self.tileSize), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: Self.tileSize * 4)
        }
        maskBytes[index] = 255
        mask.replace(region: MTLRegionMake2D(0, 0, grid, grid), mipmapLevel: 0, withBytes: maskBytes, bytesPerRow: grid)
        mipsDirty = true
    }

    private func rebuildMips(now: CFTimeInterval) {
        mipsDirty = false
        lastMips = now
        guard let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        cmd.commit()
    }

    /// Downloads one tile (and its night lights when needed) and decodes it to RGBA bytes.
    nonisolated private static func loadTile(level: Int, col: Int, row: Int, night: Bool, session: URLSession) async -> Data? {
        let base = "https://gibs.earthdata.nasa.gov/wmts/epsg4326/best"
        guard let dayURL = URL(string: "\(base)/BlueMarble_ShadedRelief_Bathymetry/default/500m/\(level)/\(row)/\(col).jpeg"),
              let (dayData, response) = try? await session.data(from: dayURL),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        var nightData: Data?
        if night, let url = URL(string: "\(base)/VIIRS_Black_Marble/default/2016-01-01/500m/\(level)/\(row)/\(col).png"),
           let (data, response) = try? await session.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200 {
            nightData = data
        }
        return decode(day: dayData, night: nightData)
    }

    nonisolated private static func decode(day: Data, night: Data?) -> Data? {
        let side = tileSize
        guard let dayImage = image(from: day) else { return nil }
        var pixels = Data(count: side * side * 4)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(dayImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return nil }

        var lights = [UInt8](repeating: 0, count: side * side)
        if let night, let nightImage = image(from: night) {
            var rgba = [UInt8](repeating: 0, count: side * side * 4)
            let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                ctx.draw(nightImage, in: CGRect(x: 0, y: 0, width: side, height: side))
                return true
            }
            if drawn {
                // Like the shipped base lights (drop the blue-grey terrain, keep sodium/white light), but
                // with more headroom so dense city cores keep their structure at 500 m.
                for i in 0..<(side * side) {
                    let r = Float(rgba[i * 4]) / 255, g = Float(rgba[i * 4 + 1]) / 255, b = Float(rgba[i * 4 + 2]) / 255
                    let base = min(r, g)
                    let warm = base - max(b - base, 0) * 1.5
                    let v = pow(min(max((warm - 0.06) / 0.94, 0), 1), 1.05)
                    lights[i] = UInt8(v * 255)
                }
            }
        }
        pixels.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<(side * side) { p[i * 4 + 3] = lights[i] }
        }
        return pixels
    }

    nonisolated private static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
