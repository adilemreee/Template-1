import Foundation
import Metal
import QuartzCore
import simd

/// GPU side of the live weather: the GFS frames as a texture array (the Earth shader reads it
/// for the temperature and rain maps) and the wind particle swarm advected through it.
@MainActor
final class WeatherLayer {
    /// Recorded positions per particle; with one record every 1/30 s that is about half a second of trail.
    static let trailLength = 14
    static let recordInterval: CFTimeInterval = 1.0 / 30

    private let device: MTLDevice
    private let stepPSO: MTLComputePipelineState
    private let drawPSO: MTLRenderPipelineState
    let sampler: MTLSamplerState

    private(set) var texture: MTLTexture?
    private var times: [Date] = []
    private var builtVersion = -1

    private var particles: MTLBuffer?
    private var trail: MTLBuffer?
    private var capacity = 0
    private var head: UInt32 = 0
    private var seed: UInt32 = 1
    private var lastStep: CFTimeInterval = 0
    private var sinceRecord: CFTimeInterval = 0
    /// Eases the swarm in and out when the layer is toggled.
    private var visibility: Float = 0
    private var params = WindParams()

    init?(device: MTLDevice, stepPSO: MTLComputePipelineState, drawPSO: MTLRenderPipelineState) {
        self.device = device
        self.stepPSO = stepPSO
        self.drawPSO = drawPSO
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.sAddressMode = .repeat
        s.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: s) else { return nil }
        self.sampler = sampler
    }

    var hasData: Bool { texture != nil && !times.isEmpty }
    var sliceCount: Float { Float(times.count) }

    /// Uploads new frames when the controller's set changed.
    func sync(_ grids: [WeatherGrid], version: Int) {
        guard version != builtVersion else { return }
        builtVersion = version
        guard !grids.isEmpty else {
            texture = nil
            times = []
            return
        }
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .rgba8Unorm
        desc.width = WeatherGrid.width
        desc.height = WeatherGrid.height
        desc.arrayLength = grids.count
        desc.usage = .shaderRead
        desc.storageMode = .shared
        // A fresh texture each time, so frames still in flight keep reading the old one.
        guard let t = device.makeTexture(descriptor: desc) else { return }
        let rowBytes = WeatherGrid.width * 4
        for (i, g) in grids.enumerated() where g.bytes.count == WeatherGrid.byteCount {
            g.bytes.withUnsafeBytes { raw in
                t.replace(region: MTLRegionMake2D(0, 0, WeatherGrid.width, WeatherGrid.height), mipmapLevel: 0, slice: i,
                          withBytes: raw.baseAddress!, bytesPerRow: rowBytes, bytesPerImage: rowBytes * WeatherGrid.height)
            }
        }
        texture = t
        times = grids.map(\.valid)
    }

    /// Fractional frame index for a moment (clamped to the forecast span).
    func slice(at date: Date) -> Float {
        guard let (i, f) = WeatherTimeline.position(of: date, in: times) else { return 0 }
        return Float(Double(i) + f)
    }

    // MARK: Wind

    private static var particleBudget: Int {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical { return 3500 }
        return GlobeRenderer.isHighEnd ? 9000 : 6000
    }

    private func ensureBuffers(count: Int) -> Bool {
        if capacity >= count, particles != nil, trail != nil { return true }
        // Zeroed particles respawn on the first step (their position is not on the sphere).
        guard let p = device.makeBuffer(length: MemoryLayout<WindParticle>.stride * count, options: .storageModePrivate),
              let t = device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride * count * Self.trailLength, options: .storageModePrivate) else { return false }
        particles = p
        trail = t
        capacity = count
        needsClear = true
        return true
    }

    private var needsClear = false

    /// True while the swarm is on screen (the renderer keeps a smooth frame rate for it).
    var isAnimating: Bool { visibility > 0.001 }

    /// Advances the particles; encode before the scene pass that draws them.
    func encodeWind(_ cmd: MTLCommandBuffer, enabled: Bool, now: CFTimeInterval, date: Date, pose: CameraPose, eye: SIMD3<Float>, aspect: Double) {
        let target: Float = enabled && hasData ? 1 : 0
        let dt = lastStep == 0 ? 1.0 / 60 : min(0.05, max(0, now - lastStep))
        lastStep = now
        visibility += (target - visibility) * Float(min(1, dt * 3.5))
        if target == 0 && visibility < 0.01 { visibility = 0 }
        guard visibility > 0, let texture else { return }
        let count = Self.particleBudget
        guard ensureBuffers(count: count), let particles, let trail else { return }

        if needsClear, let blit = cmd.makeBlitCommandEncoder() {
            blit.fill(buffer: particles, range: 0..<particles.length, value: 0)
            blit.fill(buffer: trail, range: 0..<trail.length, value: 0)
            blit.endEncoding()
            needsClear = false
        }

        let cap = Self.visibleCap(pose: pose, eye: eye, aspect: aspect)
        sinceRecord += dt
        var record: UInt32 = 0
        if sinceRecord >= Self.recordInterval {
            sinceRecord = min(sinceRecord - Self.recordInterval, Self.recordInterval)
            head = (head + 1) % UInt32(Self.trailLength)
            record = 1
        }
        seed &+= 1
        params.cap = SIMD4(cap.center, cos(cap.radius))
        params.dt = Float(dt)
        // Trails cover a similar share of the screen at every zoom.
        params.speedScale = 0.018 * cap.radius
        params.slice = slice(at: date)
        params.slices = sliceCount
        params.count = UInt32(min(count, capacity))
        params.trailLength = UInt32(Self.trailLength)
        params.head = head
        params.record = record
        params.seed = seed
        params.maxAge = 4.2
        params.intensity = visibility
        params.widthPx = 1.25

        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(stepPSO)
        enc.setBuffer(particles, offset: 0, index: 0)
        enc.setBuffer(trail, offset: 0, index: 1)
        enc.setBytes(&params, length: MemoryLayout<WindParams>.stride, index: 2)
        enc.setTexture(texture, index: 0)
        enc.setSamplerState(sampler, index: 0)
        let width = max(1, min(stepPSO.maxTotalThreadsPerThreadgroup, stepPSO.threadExecutionWidth * 2))
        enc.dispatchThreads(MTLSize(width: Int(params.count), height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        enc.endEncoding()
    }

    /// Draws the ribbons into the scene pass (additive, depth-tested against the globe).
    func drawWind(_ enc: MTLRenderCommandEncoder, uniforms: inout FrameUniforms, depth: MTLDepthStencilState) {
        guard visibility > 0, let particles, let trail, params.count > 0 else { return }
        enc.setRenderPipelineState(drawPSO)
        enc.setDepthStencilState(depth)
        enc.setVertexBuffer(particles, offset: 0, index: 0)
        enc.setVertexBuffer(trail, offset: 0, index: 1)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 2)
        enc.setVertexBytes(&params, length: MemoryLayout<WindParams>.stride, index: 3)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        enc.setFragmentBytes(&params, length: MemoryLayout<WindParams>.stride, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: (Self.trailLength + 1) * 2, instanceCount: Int(params.count))
    }

    /// The part of the globe that can be on screen, as a cap around the camera's nadir.
    static func visibleCap(pose: CameraPose, eye: SIMD3<Float>, aspect: Double) -> (center: SIMD3<Float>, radius: Float) {
        let d = Double(max(simd_length(eye), 1.0001))
        let horizon = acos(1 / d)
        var radius = horizon
        if pose.tilt < 3 {
            // Looking straight down: the screen's half-diagonal limits what is visible.
            let halfY = GlobeRenderer.fovY / 2
            let halfDiagonal = atan(tan(halfY) * sqrt(1 + aspect * aspect))
            let s = d * sin(halfDiagonal)
            if s < 1 { radius = min(horizon, asin(s) - halfDiagonal + 0.04) }
        }
        return (simd_normalize(eye), Float(max(0.02, radius)))
    }
}
