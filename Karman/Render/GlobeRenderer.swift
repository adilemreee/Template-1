import Foundation
import Metal
import MetalKit
import QuartzCore
import simd

/// Renders the living globe: stars, Sun, Earth, atmosphere, aurora, events, satellites,
/// then a dual-filter bloom, lens flare and filmic tone mapping.
@MainActor
final class GlobeRenderer: NSObject, MTKViewDelegate {
    static let fovY: Double = 40 * .pi / 180
    static let sceneFormat: MTLPixelFormat = .rgba16Float
    static let depthFormat: MTLPixelFormat = .depth32Float
    /// Devices with less memory (iPhone 11–13) get 2× MSAA; everything newer gets 4×.
    static let isHighEnd = ProcessInfo.processInfo.physicalMemory >= 5_500_000_000
    static let sampleCount = isHighEnd ? 4 : 2

    let device: MTLDevice
    let queue: MTLCommandQueue
    let controller: GlobeController
    weak var satellites: SatelliteEngine?

    // Pipelines
    private var earthPSO: MTLRenderPipelineState!
    private var atmospherePSO: MTLRenderPipelineState!
    private var auroraPSO: MTLRenderPipelineState!
    private var starPSO: MTLRenderPipelineState!
    private var sunPSO: MTLRenderPipelineState!
    private var ringPSO: MTLRenderPipelineState!
    private var iconPSO: MTLRenderPipelineState!
    private var stormPSO: MTLRenderPipelineState!
    private var satellitePSO: MTLRenderPipelineState!
    private var pathPSO: MTLRenderPipelineState!
    private var windPSO: MTLRenderPipelineState!
    private var windStepPSO: MTLComputePipelineState!
    private var prefilterPSO: MTLRenderPipelineState!
    private var downsamplePSO: MTLRenderPipelineState!
    private var upsamplePSO: MTLRenderPipelineState!
    private var compositePSO: MTLRenderPipelineState!
    private var depthWrite: MTLDepthStencilState!
    private var depthTest: MTLDepthStencilState!
    private var depthOff: MTLDepthStencilState!
    private var surfaceSampler: MTLSamplerState!
    private var clampSampler: MTLSamplerState!
    private var auroraSampler: MTLSamplerState!
    private var detailSampler: MTLSamplerState!
    /// Regional NASA GIBS imagery for close-ups (nil if the device can't spare the memory).
    private var detail: DetailImagery?
    /// Live GFS weather: texture array for the temperature and rain maps, and the wind swarm.
    private var weatherLayer: WeatherLayer?
    private var weatherPlaceholder: MTLTexture?
    private var temperatureFade: Float = 0
    private var rainFade: Float = 0
    private var lastFadeStep: CFTimeInterval = 0

    // Geometry
    private var earthMesh: (vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int)?
    private var shellMesh: (vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int)?
    private var starBuffer: MTLBuffer?
    private var starCount = 0

    // Textures
    private var dayTex: MTLTexture?
    private var lightsTex: MTLTexture?
    private var cloudTex: MTLTexture?
    private var waterTex: MTLTexture?
    private var normalTex: MTLTexture?
    private var blackTex: MTLTexture?
    private var flatNormalTex: MTLTexture?
    private var iconAtlas: MTLTexture?
    private var auroraTex: MTLTexture?
    private(set) var texturesReady = false

    // Render targets
    private var msaaColor: MTLTexture?
    private var msaaDepth: MTLTexture?
    private var hdr: MTLTexture?
    private var bloomChain: [MTLTexture] = []
    private var drawableSize: CGSize = .zero

    // Scene buffers
    private var builtVersion = -1
    private var builtAt: CFTimeInterval = 0
    private var ringBuffer: MTLBuffer?
    private var ringCount = 0
    private var iconBuffer: MTLBuffer?
    private var iconCount = 0
    private var stormBuffer: MTLBuffer?
    private var stormCount = 0
    private var trackBuffer: MTLBuffer?
    private var trackRanges: [(start: Int, count: Int)] = []
    private var issPathBuffer: MTLBuffer?
    private var issPathCount = 0
    private var issPathVersion = -1
    private var auroraVersion = -1
    /// Plate boundaries, one path buffer per boundary type (built once).
    private var plateBuffers: [(kind: PlateBoundaries.Kind, buffer: MTLBuffer, count: Int)] = []
    private var platesFade: Float = 0

    // Frame state for picking/projection
    private(set) var viewProj = matrix_identity_float4x4
    private(set) var eye = SIMD3<Float>(0, 0, 5)
    private var viewSizePoints: CGSize = .zero
    private let startTime = CACurrentMediaTime()

    // Pickable items rebuilt with the scene
    private struct Pickable {
        var item: GlobeItem
        var position: SIMD3<Float>
        var weight: Float
    }
    private var pickables: [Pickable] = []

    /// Never block the main thread waiting for the GPU; drop a frame instead.
    #if targetEnvironment(simulator)
    private let inFlight = DispatchSemaphore(value: 1)
    #else
    private let inFlight = DispatchSemaphore(value: 2)
    #endif
    private var lastFrameRateChange: CFTimeInterval = 0

    var auroraIntensity: Float = 1
    var exposure: Float = 1.05
    var onIntroFinished: (() -> Void)?

    init?(controller: GlobeController, satellites: SatelliteEngine?) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.controller = controller
        self.satellites = satellites
        super.init()
        do {
            try buildPipelines()
        } catch {
            print("Pipeline error: \(error)")
            return nil
        }
        weatherLayer = WeatherLayer(device: device, stepPSO: windStepPSO, drawPSO: windPSO)
        weatherPlaceholder = makeWeatherPlaceholder()
        buildPlateBuffers()
        earthMesh = MetalResources.sphere(device: device, segments: 256, rings: 128)
        shellMesh = MetalResources.sphere(device: device, segments: 128, rings: 64)
        blackTex = MetalResources.solidTexture(device: device, gray: 0)
        flatNormalTex = makeFlatNormal()
        loadStars()
        let auroraDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 360, height: 181, mipmapped: false)
        auroraDesc.usage = .shaderRead
        auroraDesc.storageMode = .shared
        auroraTex = device.makeTexture(descriptor: auroraDesc)
        loadTexturesAsync()
    }

    private func buildPlateBuffers() {
        guard let plates = PlateBoundaries.bundled else { return }
        for kind in PlateBoundaries.Kind.allCases {
            var verts: [PathVertex] = []
            for line in plates.lines where line.kind == kind {
                if !verts.isEmpty { verts.append(PathVertex(position: .zero, alpha: -1)) }
                for p in line.points { verts.append(PathVertex(position: p.unitVectorF * 1.0015, alpha: 1)) }
            }
            if verts.count > 1, let b = device.makeBuffer(bytes: verts, length: MemoryLayout<PathVertex>.stride * verts.count, options: .storageModeShared) {
                plateBuffers.append((kind, b, verts.count))
            }
        }
    }

    /// One calm, dry 1×1 frame so the Earth shader always has a weather array bound.
    private func makeWeatherPlaceholder() -> MTLTexture? {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .rgba8Unorm
        desc.width = 1
        desc.height = 1
        desc.arrayLength = 1
        desc.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        var px: [UInt8] = [128, 128, 200, 0]
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: 0, withBytes: &px, bytesPerRow: 4, bytesPerImage: 4)
        return t
    }

    private func makeFlatNormal() -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        var px: [UInt8] = [128, 128, 255, 255]
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        return t
    }

    // MARK: - Setup

    private func buildPipelines() throws {
        guard let library = device.makeDefaultLibrary() else { throw NSError(domain: "Karman", code: 1) }
        func fn(_ name: String) -> MTLFunction? { library.makeFunction(name: name) }

        func pipeline(_ v: String, _ f: String, blend: BlendMode, format: MTLPixelFormat = GlobeRenderer.sceneFormat,
                      depth: Bool = true, samples: Int = GlobeRenderer.sampleCount) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = fn(v)
            d.fragmentFunction = fn(f)
            d.colorAttachments[0].pixelFormat = format
            d.rasterSampleCount = samples
            if depth { d.depthAttachmentPixelFormat = GlobeRenderer.depthFormat }
            let c = d.colorAttachments[0]!
            switch blend {
            case .opaque:
                c.isBlendingEnabled = false
            case .additive:
                c.isBlendingEnabled = true
                c.rgbBlendOperation = .add
                c.alphaBlendOperation = .add
                c.sourceRGBBlendFactor = .one
                c.destinationRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .zero
                c.destinationAlphaBlendFactor = .one
            case .premultiplied:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }

        earthPSO = try pipeline("sphere_vertex", "earth_fragment", blend: .opaque)
        atmospherePSO = try pipeline("sphere_vertex", "atmosphere_fragment", blend: .additive)
        auroraPSO = try pipeline("sphere_vertex", "aurora_fragment", blend: .additive)
        starPSO = try pipeline("star_vertex", "star_fragment", blend: .additive)
        sunPSO = try pipeline("sun_vertex", "sun_fragment", blend: .additive)
        ringPSO = try pipeline("ring_vertex", "ring_fragment", blend: .additive)
        iconPSO = try pipeline("icon_vertex", "icon_fragment", blend: .premultiplied)
        stormPSO = try pipeline("storm_vertex", "storm_fragment", blend: .premultiplied)
        satellitePSO = try pipeline("satellite_vertex", "satellite_fragment", blend: .additive)
        pathPSO = try pipeline("path_vertex", "path_fragment", blend: .additive)
        windPSO = try pipeline("wind_vertex", "wind_fragment", blend: .additive)
        guard let step = fn("wind_step") else { throw NSError(domain: "Karman", code: 2) }
        windStepPSO = try device.makeComputePipelineState(function: step)
        prefilterPSO = try pipeline("fullscreen_vertex", "bloom_prefilter", blend: .opaque, depth: false, samples: 1)
        downsamplePSO = try pipeline("fullscreen_vertex", "bloom_downsample", blend: .opaque, depth: false, samples: 1)
        upsamplePSO = try pipeline("fullscreen_vertex", "bloom_upsample", blend: .additive, depth: false, samples: 1)
        compositePSO = try pipeline("fullscreen_vertex", "composite_fragment", blend: .opaque, format: .bgra8Unorm_srgb, depth: false, samples: 1)

        let dw = MTLDepthStencilDescriptor()
        dw.depthCompareFunction = .less
        dw.isDepthWriteEnabled = true
        depthWrite = device.makeDepthStencilState(descriptor: dw)
        let dt = MTLDepthStencilDescriptor()
        dt.depthCompareFunction = .less
        dt.isDepthWriteEnabled = false
        depthTest = device.makeDepthStencilState(descriptor: dt)
        let doff = MTLDepthStencilDescriptor()
        doff.depthCompareFunction = .always
        doff.isDepthWriteEnabled = false
        depthOff = device.makeDepthStencilState(descriptor: doff)

        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.mipFilter = .linear
        s.sAddressMode = .repeat
        s.tAddressMode = .clampToEdge
        s.maxAnisotropy = 8
        surfaceSampler = device.makeSamplerState(descriptor: s)
        let c = MTLSamplerDescriptor()
        c.minFilter = .linear
        c.magFilter = .linear
        c.mipFilter = .linear
        c.sAddressMode = .clampToEdge
        c.tAddressMode = .clampToEdge
        clampSampler = device.makeSamplerState(descriptor: c)
        let a = MTLSamplerDescriptor()
        a.minFilter = .linear
        a.magFilter = .linear
        a.sAddressMode = .repeat
        a.tAddressMode = .clampToEdge
        auroraSampler = device.makeSamplerState(descriptor: a)
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear
        d.magFilter = .linear
        d.mipFilter = .linear
        d.sAddressMode = .clampToEdge
        d.tAddressMode = .clampToEdge
        d.maxAnisotropy = 8
        detailSampler = device.makeSamplerState(descriptor: d)
    }

    private enum BlendMode { case opaque, additive, premultiplied }

    private func loadStars() {
        guard let url = Bundle.main.url(forResource: "stars", withExtension: "bin"),
              let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        starCount = data.count / 20
        starBuffer = data.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: data.count, options: .storageModeShared) }
    }

    private func loadTexturesAsync() {
        let device = self.device
        let queue = self.queue
        Task.detached(priority: .userInitiated) {
            func url(_ name: String) -> URL? { Bundle.main.url(forResource: name, withExtension: nil) }
            let small = url("earth_lights.jpg").flatMap { MetalResources.loadTexture(url: $0, kind: .gray, device: device, queue: queue) }
            let clouds = url("earth_clouds.jpg").flatMap { MetalResources.loadTexture(url: $0, kind: .gray, device: device, queue: queue) }
            let water = url("earth_water.png").flatMap { MetalResources.loadTexture(url: $0, kind: .gray, device: device, queue: queue) }
            let normal = url("earth_normal.jpg").flatMap { MetalResources.loadTexture(url: $0, kind: .color, device: device, queue: queue) }
            let maxDay = ProcessInfo.processInfo.physicalMemory > 5_000_000_000 ? 8192 : 4096
            let day = url("earth_day.jpg").flatMap { MetalResources.loadTexture(url: $0, kind: .colorSRGB, device: device, queue: queue, maxWidth: maxDay) }
            let atlas = await MainActor.run { MetalResources.iconAtlas(device: device, queue: queue).map(SendableTexture.init) }
            let pack = (day.map(SendableTexture.init), small.map(SendableTexture.init), clouds.map(SendableTexture.init),
                        water.map(SendableTexture.init), normal.map(SendableTexture.init), atlas)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.dayTex = pack.0?.texture
                self.lightsTex = pack.1?.texture
                self.cloudTex = pack.2?.texture
                self.waterTex = pack.3?.texture
                self.normalTex = pack.4?.texture
                self.iconAtlas = pack.5?.texture
                self.texturesReady = self.dayTex != nil
            }
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuildTargets(size: size)
    }

    private func rebuildTargets(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        drawableSize = size
        let w = Int(size.width), h = Int(size.height)
        let msaa = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.sceneFormat, width: w, height: h, mipmapped: false)
        msaa.textureType = .type2DMultisample
        msaa.sampleCount = Self.sampleCount
        msaa.usage = .renderTarget
        #if targetEnvironment(simulator)
        msaa.storageMode = .private
        #else
        msaa.storageMode = .memoryless
        #endif
        msaaColor = device.makeTexture(descriptor: msaa)
        let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.depthFormat, width: w, height: h, mipmapped: false)
        depth.textureType = .type2DMultisample
        depth.sampleCount = Self.sampleCount
        depth.usage = .renderTarget
        depth.storageMode = msaa.storageMode
        msaaDepth = device.makeTexture(descriptor: depth)
        let hdrDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.sceneFormat, width: w, height: h, mipmapped: false)
        hdrDesc.usage = [.renderTarget, .shaderRead]
        hdrDesc.storageMode = .private
        hdr = device.makeTexture(descriptor: hdrDesc)
        bloomChain = []
        var bw = w / 2, bh = h / 2
        for _ in 0..<6 {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.sceneFormat, width: max(bw, 1), height: max(bh, 1), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            if let t = device.makeTexture(descriptor: d) { bloomChain.append(t) }
            bw /= 2
            bh /= 2
        }
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        viewSizePoints = view.bounds.size
        if drawableSize != view.drawableSize { rebuildTargets(size: view.drawableSize) }
        guard let hdr, let msaaColor, let msaaDepth, bloomChain.count >= 5 else { return }
        guard inFlight.wait(timeout: .now()) == .success else { return }
        var committed = false
        defer { if !committed { inFlight.signal() } }
        adaptFrameRate(view, now: now)

        var pose = controller.step(now: now)
        var starIntensity: Float = 1
        var date = controller.lightingDate(at: now)
        var sunDir = Astro.sunDirection(date)
        if controller.isYearReplay {
            // A year flies by: hold the Sun beside the camera and let it nod through the seasons
            // instead of strobing round the planet 365 times.
            let declination = Astro.subsolarPoint(date).lat
            sunDir = GeoPoint(lat: declination, lon: Geo.normalizeLon(controller.pose.lon + 38)).unitVectorF
            date = Date()
        }
        if let introStart = controller.introStart {
            let t = now - introStart
            let intro = introPose(t: t, sun: sunDir)
            pose = intro.pose
            controller.sceneFade = intro.fade
            starIntensity = Float(intro.stars)
            if intro.done {
                controller.introStart = nil
                controller.set(pose: pose)
                controller.markInteraction()
                // Leave the draw call stack before touching SwiftUI state.
                let callback = onIntroFinished
                DispatchQueue.main.async { callback?() }
            } else {
                controller.set(pose: pose)
            }
        } else if controller.sceneFade < 1 {
            controller.sceneFade = min(1, controller.sceneFade + 0.03)
        }

        rebuildSceneIfNeeded(now: now)
        updateISSPath()

        // Camera matrices
        let aspect = Double(max(drawableSize.width, 1) / max(drawableSize.height, 1))
        let basis = pose.basis()
        let viewM = pose.viewMatrix()
        let projM = Self.perspective(fovY: Self.fovY, aspect: aspect, near: 0.01, far: 300)
        viewProj = projM * viewM
        eye = SIMD3<Float>(basis.eye)
        controller.projection = GlobeProjection(viewProj: viewProj, eye: eye, viewSize: viewSizePoints)

        let elapsed = Float(now - startTime)
        let gmst = Astro.gmst(date)
        var u = FrameUniforms()
        u.viewProj = viewProj
        u.view = viewM
        u.proj = projM
        u.starRotation = Self.starRotation(gmst: gmst)
        u.cameraPos = eye
        u.time = elapsed
        u.sunDir = sunDir
        u.exposure = exposure
        u.cameraRight = SIMD3<Float>(basis.right)
        u.cameraUp = SIMD3<Float>(basis.up)
        u.cloudOpacity = controller.layers.clouds ? 0.92 : 0
        u.cityLights = controller.layers.cityLights ? 1 : 0.15
        u.viewport = SIMD2(Float(drawableSize.width), Float(drawableSize.height))
        u.liveImagery = controller.layers.liveImagery && controller.liveImageryTexture != nil ? 1 : 0
        u.auroraIntensity = controller.layers.aurora ? auroraIntensity : 0
        u.sceneFade = Float(controller.sceneFade)
        u.pixelScale = Float(view.contentScaleFactor)
        u.cloudDrift = Float((date.timeIntervalSince1970 / 86400).truncatingRemainder(dividingBy: 1) * 0.012)
        u.starIntensity = starIntensity
        u.markerFade = Float(controller.markerFade) * Float(controller.introStart == nil ? 1 : 0)
        u.atmosphereIntensity = 1
        u.reliefStrength = 1.0

        // Seismic wave fronts racing out from an earthquake.
        if let waves = controller.seismic, let t = controller.seismicTime(at: now) {
            let rad = Float.pi / 180
            u.seismicCenter = SIMD4(waves.epicenter.unitVectorF, Float(controller.seismicStrength(at: now)))
            u.seismicFronts = SIMD4(Float(Seismology.front(.p, at: t)) * rad, Float(Seismology.front(.s, at: t)) * rad,
                                    Float(Seismology.front(.surface, at: t)) * rad, 0)
        }

        // Live weather maps fade in and out with their layers.
        let layers = controller.layers
        weatherLayer?.sync(controller.weather, version: controller.weatherVersion)
        let hasWeather = weatherLayer?.hasData ?? false
        let fadeStep = Float(min(1, max(0, now - lastFadeStep) * 4))
        lastFadeStep = now
        let liveWeather = hasWeather && !controller.isYearReplay
        temperatureFade += ((layers.temperature && liveWeather ? 1 : 0) - temperatureFade) * fadeStep
        rainFade += ((layers.rain && liveWeather ? 1 : 0) - rainFade) * fadeStep
        if let weatherLayer, hasWeather {
            u.weatherSlice = weatherLayer.slice(at: date)
            u.weatherSlices = weatherLayer.sliceCount
        }
        u.temperatureOverlay = temperatureFade < 0.003 ? 0 : temperatureFade
        u.rainOverlay = rainFade < 0.003 ? 0 : rainFade

        if detail == nil, texturesReady { detail = DetailImagery(device: device, queue: queue, grid: Self.isHighEnd ? 6 : 4) }
        if let detail, controller.introStart == nil {
            let moving = controller.isFlying || now - controller.lastInteractionTime < 0.35
            detail.update(pose: pose, center: controller.followFocus, sunDir: sunDir, isMoving: moving, now: now)
            u.detailBounds = detail.bounds
            u.detailBlend = detail.blend
            u.detailNight = detail.hasNight ? 1 : 0
        }

        if let s = satellites, let k = s.keyframes(for: .visual) ?? s.keyframes(for: .stations) {
            let span = max(0.001, k.nextTime - k.prevTime)
            u.satelliteLerp = Float(min(1.5, max(0, (now - k.prevTime) / span)))
        }

        guard let drawable = view.currentDrawable, let cmd = queue.makeCommandBuffer() else { return }

        // ---- Wind particles step on the GPU before the scene that draws them
        weatherLayer?.encodeWind(cmd, enabled: layers.wind && controller.introStart == nil && !controller.isYearReplay, now: now, date: date,
                                 pose: pose, eye: eye, aspect: aspect)

        // ---- Scene pass
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = msaaColor
        rp.colorAttachments[0].resolveTexture = hdr
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.0015, green: 0.002, blue: 0.004, alpha: 1)
        rp.colorAttachments[0].storeAction = .multisampleResolve
        rp.depthAttachment.texture = msaaDepth
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.clearDepth = 1
        rp.depthAttachment.storeAction = .dontCare
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }

        if let starBuffer, starCount > 0 {
            enc.setRenderPipelineState(starPSO)
            enc.setDepthStencilState(depthOff)
            enc.setVertexBuffer(starBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: starCount)
        }

        if let mesh = earthMesh {
            var radius: Float = 1
            enc.setRenderPipelineState(earthPSO)
            enc.setDepthStencilState(depthWrite)
            enc.setCullMode(.back)
            enc.setFrontFacing(.counterClockwise)
            enc.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.setVertexBytes(&radius, length: 4, index: 2)
            enc.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            enc.setFragmentTexture(dayTex ?? blackTex, index: 0)
            enc.setFragmentTexture(lightsTex ?? blackTex, index: 1)
            enc.setFragmentTexture(cloudTex ?? blackTex, index: 2)
            enc.setFragmentTexture(waterTex ?? blackTex, index: 3)
            enc.setFragmentTexture(normalTex ?? flatNormalTex, index: 4)
            enc.setFragmentTexture(controller.liveImageryTexture?.texture ?? blackTex, index: 5)
            enc.setFragmentTexture(detail?.texture ?? blackTex, index: 6)
            enc.setFragmentTexture(detail?.mask ?? blackTex, index: 7)
            enc.setFragmentTexture(weatherLayer?.texture ?? weatherPlaceholder, index: 8)
            enc.setFragmentSamplerState(surfaceSampler, index: 0)
            enc.setFragmentSamplerState(detailSampler, index: 1)
            enc.setFragmentSamplerState(weatherLayer?.sampler ?? clampSampler, index: 2)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
        }

        enc.setCullMode(.none)
        enc.setRenderPipelineState(sunPSO)
        enc.setDepthStencilState(depthTest)
        enc.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // Wind ribbons skim the surface, under the cyclones' cloud tops.
        weatherLayer?.drawWind(enc, uniforms: &u, depth: depthTest)

        // Tropical cyclones as cloud spirals on the surface (under the atmosphere's haze).
        if let stormBuffer, stormCount > 0 {
            enc.setRenderPipelineState(stormPSO)
            enc.setDepthStencilState(depthTest)
            enc.setVertexBuffer(stormBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: stormCount)
        }

        if let shell = shellMesh {
            var outer: Float = 1.045
            enc.setRenderPipelineState(atmospherePSO)
            enc.setDepthStencilState(depthTest)
            enc.setCullMode(.front)
            enc.setVertexBuffer(shell.vertices, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.setVertexBytes(&outer, length: 4, index: 2)
            enc.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            enc.setFragmentBytes(&outer, length: 4, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: shell.indexCount, indexType: .uint32, indexBuffer: shell.indices, indexBufferOffset: 0)

            if controller.layers.aurora, let auroraTex, controller.scene.aurora != nil {
                enc.setRenderPipelineState(auroraPSO)
                enc.setCullMode(.back)
                enc.setFragmentTexture(auroraTex, index: 0)
                enc.setFragmentSamplerState(auroraSampler, index: 0)
                for (radius, layer) in [(Float(1.014), Float(0)), (Float(1.024), Float(1))] {
                    var r = radius, l = layer
                    enc.setVertexBytes(&r, length: 4, index: 2)
                    enc.setFragmentBytes(&l, length: 4, index: 1)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: shell.indexCount, indexType: .uint32, indexBuffer: shell.indices, indexBufferOffset: 0)
                }
            }
        }
        enc.setCullMode(.none)

        // Storm tracks
        if let trackBuffer, !trackRanges.isEmpty {
            var style = PathStyle(color: SIMD4(0.75, 0.62, 1.0, 0.9), widthPx: 1.6, glow: 0.8, dash: 0, pad: 0)
            enc.setRenderPipelineState(pathPSO)
            enc.setDepthStencilState(depthTest)
            enc.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.setVertexBytes(&style, length: MemoryLayout<PathStyle>.stride, index: 2)
            enc.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            enc.setFragmentBytes(&style, length: MemoryLayout<PathStyle>.stride, index: 1)
            for r in trackRanges where r.count > 1 {
                enc.setVertexBuffer(trackBuffer, offset: r.start * MemoryLayout<PathVertex>.stride, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: r.count - 1)
            }
        }

        // Tectonic plate boundaries (always during the year replay: the quakes trace them).
        let platesTarget: Float = layers.plates ? 1 : (controller.isYearReplay ? 0.55 : 0)
        platesFade += (platesTarget - platesFade) * Float(min(1, fadeStep))
        if platesFade > 0.01, !plateBuffers.isEmpty {
            enc.setRenderPipelineState(pathPSO)
            enc.setDepthStencilState(depthTest)
            enc.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            for plate in plateBuffers {
                var style = Self.plateStyle(plate.kind, alpha: platesFade)
                enc.setVertexBuffer(plate.buffer, offset: 0, index: 0)
                enc.setVertexBytes(&style, length: MemoryLayout<PathStyle>.stride, index: 2)
                enc.setFragmentBytes(&style, length: MemoryLayout<PathStyle>.stride, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: plate.count - 1)
            }
        }

        // ISS orbit
        if controller.layers.satellites, !controller.isFollowing, controller.replay == nil, let issPathBuffer, issPathCount > 1 {
            var style = PathStyle(color: SIMD4(0.45, 0.75, 1.0, 0.42), widthPx: 1.0, glow: 0.5, dash: 0, pad: 0)
            enc.setRenderPipelineState(pathPSO)
            enc.setDepthStencilState(depthTest)
            enc.setVertexBuffer(issPathBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.setVertexBytes(&style, length: MemoryLayout<PathStyle>.stride, index: 2)
            enc.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            enc.setFragmentBytes(&style, length: MemoryLayout<PathStyle>.stride, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: issPathCount - 1)
        }

        if let ringBuffer, ringCount > 0 {
            enc.setRenderPipelineState(ringPSO)
            enc.setDepthStencilState(depthTest)
            enc.setVertexBuffer(ringBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: ringCount)
        }

        // Satellites (live only: they would orbit at real speed while a replay races through the day)
        if let sats = satellites, controller.replay == nil {
            enc.setRenderPipelineState(satellitePSO)
            enc.setDepthStencilState(depthTest)
            enc.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 2)
            enc.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            var groups: [(SatelliteEngine.Group, PointInstance)] = []
            if controller.layers.starlink { groups.append((.starlink, PointInstance(position: .zero, sizePx: 2.2, color: SIMD4(0.55, 0.72, 1.0, 0.9)))) }
            if controller.layers.satellites {
                groups.append((.visual, PointInstance(position: .zero, sizePx: 3.0, color: SIMD4(0.85, 0.93, 1.0, 0.75))))
                // Riding along, the station is right in front of the camera: draw it bigger and brighter.
                let station: Float = controller.isFollowing ? 9 : 5.5
                groups.append((.stations, PointInstance(position: .zero, sizePx: station, color: SIMD4(1.0, 1.0, 1.0, controller.isFollowing ? 1.8 : 1.1))))
            }
            for (group, var style) in groups {
                guard let k = sats.keyframes(for: group), k.count > 0 else { continue }
                var gu = u
                gu.satelliteLerp = Float(min(1.5, max(0, (now - k.prevTime) / max(0.001, k.nextTime - k.prevTime))))
                enc.setVertexBytes(&gu, length: MemoryLayout<FrameUniforms>.stride, index: 2)
                enc.setVertexBuffer(k.prev, offset: 0, index: 0)
                enc.setVertexBuffer(k.next, offset: 0, index: 1)
                enc.setVertexBytes(&style, length: MemoryLayout<PointInstance>.stride, index: 3)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: k.count)
            }
        }

        if let iconBuffer, iconCount > 0, let iconAtlas {
            enc.setRenderPipelineState(iconPSO)
            enc.setDepthStencilState(depthTest)
            enc.setVertexBuffer(iconBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            enc.setFragmentTexture(iconAtlas, index: 0)
            enc.setFragmentSamplerState(clampSampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: iconCount)
        }
        enc.endEncoding()

        // ---- Bloom
        var threshold: Float = 1.25
        fullscreen(cmd, target: bloomChain[0], pso: prefilterPSO, load: false) { e in
            e.setFragmentTexture(hdr, index: 0)
            e.setFragmentSamplerState(self.clampSampler, index: 0)
            e.setFragmentBytes(&threshold, length: 4, index: 0)
        }
        for i in 1..<bloomChain.count {
            fullscreen(cmd, target: bloomChain[i], pso: downsamplePSO, load: false) { e in
                e.setFragmentTexture(self.bloomChain[i - 1], index: 0)
                e.setFragmentSamplerState(self.clampSampler, index: 0)
            }
        }
        for i in stride(from: bloomChain.count - 1, to: 0, by: -1) {
            var radius: Float = 1
            fullscreen(cmd, target: bloomChain[i - 1], pso: upsamplePSO, load: true) { e in
                e.setFragmentTexture(self.bloomChain[i], index: 0)
                e.setFragmentSamplerState(self.clampSampler, index: 0)
                e.setFragmentBytes(&radius, length: 4, index: 0)
            }
        }

        // ---- Composite
        var post = PostUniforms()
        let sunInfo = sunScreenInfo(sunDir: sunDir, aspect: aspect)
        post.sunScreen = sunInfo.ndc
        post.sunVisible = sunInfo.visible * Float(controller.sceneFade)
        post.bloomStrength = 0.8
        post.vignette = 0.55
        post.grain = 0.012
        post.time = elapsed
        post.exposure = exposure
        post.flareStrength = 0.7
        post.aspect = Float(aspect)
        post.saturation = 1.08
        post.fade = 1
        let crp = MTLRenderPassDescriptor()
        crp.colorAttachments[0].texture = drawable.texture
        crp.colorAttachments[0].loadAction = .dontCare
        crp.colorAttachments[0].storeAction = .store
        if let ce = cmd.makeRenderCommandEncoder(descriptor: crp) {
            ce.setRenderPipelineState(compositePSO)
            ce.setFragmentTexture(hdr, index: 0)
            ce.setFragmentTexture(bloomChain[0], index: 1)
            ce.setFragmentTexture(bloomChain[2], index: 2)
            ce.setFragmentSamplerState(clampSampler, index: 0)
            ce.setFragmentBytes(&post, length: MemoryLayout<PostUniforms>.stride, index: 0)
            ce.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            ce.endEncoding()
        }
        if let capture = controller.captureRequest, !view.framebufferOnly {
            controller.captureRequest = nil
            encodeCapture(cmd, texture: drawable.texture, completion: capture)
        } else if controller.captureRequest != nil {
            view.framebufferOnly = false   // takes effect on the next drawable
        }
        cmd.present(drawable)
        let semaphore = inFlight
        cmd.addCompletedHandler { _ in semaphore.signal() }
        cmd.commit()
        committed = true

        DispatchQueue.main.async { [weak self] in self?.updateAnchor() }
    }

    static func plateStyle(_ kind: PlateBoundaries.Kind, alpha: Float) -> PathStyle {
        switch kind {
        case .divergent: PathStyle(color: SIMD4(0.30, 0.85, 1.0, 0.85 * alpha), widthPx: 1.5, glow: 0.9, dash: 0, pad: 0)
        case .convergent: PathStyle(color: SIMD4(1.0, 0.36, 0.22, 0.95 * alpha), widthPx: 1.8, glow: 1.0, dash: 0, pad: 0)
        case .transform: PathStyle(color: SIMD4(1.0, 0.86, 0.36, 0.85 * alpha), widthPx: 1.3, glow: 0.6, dash: 2.5, pad: 0)
        }
    }

    /// Copies the finished frame into a CPU buffer and hands it back as a CGImage.
    private func encodeCapture(_ cmd: MTLCommandBuffer, texture: MTLTexture, completion: @escaping (CGImage?) -> Void) {
        let w = texture.width, h = texture.height, bpr = w * 4
        guard let buffer = device.makeBuffer(length: bpr * h, options: .storageModeShared), let blit = cmd.makeBlitCommandEncoder() else {
            completion(nil)
            return
        }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
        blit.endEncoding()
        let box = UncheckedCapture(buffer: buffer, completion: completion)
        cmd.addCompletedHandler { _ in
            let data = Data(bytes: box.buffer.contents(), count: bpr * h)
            let image = CGDataProvider(data: data as CFData).flatMap {
                CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                        provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }
            DispatchQueue.main.async { box.completion(image) }
        }
    }

    private struct UncheckedCapture: @unchecked Sendable {
        let buffer: MTLBuffer
        let completion: (CGImage?) -> Void
    }

    /// 120 Hz while something moves, 60 Hz when the globe is just breathing.
    private func adaptFrameRate(_ view: MTKView, now: CFTimeInterval) {
        guard now - lastFrameRateChange > 0.5 else { return }
        #if targetEnvironment(simulator)
        let target = 30
        #else
        // Full rate while something moves; a calm 30 fps when the planet is just breathing.
        let busy = controller.isFlying || controller.introStart != nil || now - controller.lastInteractionTime < 3
            || controller.drift.heading != 0 || controller.autoRotateActive(now: now)
        // Flowing wind needs a steady 60 fps to read as motion; Low Power Mode keeps the calm 30.
        let flowing = (weatherLayer?.isAnimating ?? false) && !ProcessInfo.processInfo.isLowPowerModeEnabled
        let target = busy ? (Self.isHighEnd ? 120 : 60) : (flowing ? 60 : 30)
        #endif
        if view.preferredFramesPerSecond != target {
            view.preferredFramesPerSecond = target
            lastFrameRateChange = now
        }
    }

    private func fullscreen(_ cmd: MTLCommandBuffer, target: MTLTexture, pso: MTLRenderPipelineState, load: Bool, configure: (MTLRenderCommandEncoder) -> Void) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = load ? .load : .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let e = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        e.setRenderPipelineState(pso)
        configure(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
    }

    // MARK: - Intro choreography

    private struct IntroFrame {
        var pose: CameraPose
        var fade: Double
        var stars: Double
        var done: Bool
    }

    static let introDuration: Double = 6.2

    private func introPose(t: Double, sun: SIMD3<Float>) -> IntroFrame {
        let sunPoint = GeoPoint(vector: SIMD3<Double>(sun))
        let anti = GeoPoint(lat: -sunPoint.lat * 0.5, lon: Geo.normalizeLon(sunPoint.lon + 180))
        let home = controller.homePose
        // 0–2.6 s: on the night side, dolly out so the Sun rises over the limb.
        let p1 = min(1, t / 2.6)
        let e1 = Easing.inOutSine(p1)
        var pose = CameraPose(lat: anti.lat + 6 * e1, lon: Geo.normalizeLon(anti.lon + 11 + 9 * e1), distance: 2.35 + 4.4 * e1)
        if t > 2.6 {
            let flight = CameraFlight(from: pose, to: home, start: 2.6, duration: Self.introDuration - 2.6)
            pose = flight.pose(at: t).0
        }
        let fade = min(1, t / 1.1)
        let stars = min(1, t / 0.8)
        return IntroFrame(pose: pose, fade: Easing.smooth(fade), stars: stars, done: t >= Self.introDuration)
    }

    // MARK: - Scene buffers

    private func rebuildSceneIfNeeded(now: CFTimeInterval) {
        // While replaying, quakes appear as the clock sweeps: rebuild a few times a second.
        let maxAge: CFTimeInterval = controller.replay != nil ? 0.08 : 30
        guard builtVersion != controller.sceneVersion || now - builtAt > maxAge else { return }
        builtVersion = controller.sceneVersion
        builtAt = now
        let scene = controller.scene
        let layers = controller.layers
        let selected = controller.selection
        let nowDate = controller.renderDate(at: now)

        var rings: [RingInstance] = []
        var icons: [IconInstance] = []
        var storms: [StormInstance] = []
        var picks: [Pickable] = []
        var tracks: [PathVertex] = []
        var ranges: [(Int, Int)] = []

        if controller.isYearReplay {
            // A year of M4.5+ quakes: each flares as its day comes round, then settles into a dim
            // ember, so the year's seismicity builds up into a map of the plate boundaries.
            let quakes = scene.yearQuakes
            var hi = quakes.count
            if let last = quakes.last, last.time > nowDate {
                var lo = 0
                hi = quakes.count
                while lo < hi { let mid = (lo + hi) / 2; if quakes[mid].time <= nowDate { lo = mid + 1 } else { hi = mid } }
            }
            rings.reserveCapacity(hi + 4)
            for q in quakes[0..<hi] {
                let ageDays = nowDate.timeIntervalSince(q.time) / 86400
                let m = q.mag
                let base = Float(0.0055 + pow(max(m, 4.5) - 2.0, 1.55) * 0.0032)
                let phase = Float(abs(q.id.hashValue % 1000)) / 1000
                if ageDays < 4 {
                    let f = Float(ageDays / 4)
                    rings.append(RingInstance(position: q.coordinate.unitVectorF, size: base * (1.25 - 0.4 * f),
                                              color: m >= 6.5 ? Palette.quakeFresh : Palette.quakeDay, phase: phase, speed: 0.9,
                                              kind: 0, intensity: Float(min(1.3, 0.55 + (m - 4.5) * 0.28)) * (1 - 0.5 * f)))
                } else {
                    let color: SIMD4<Float> = m >= 6.5 ? Palette.quakeFresh : (m >= 5.5 ? Palette.quakeDay : Palette.quakeWeek)
                    rings.append(RingInstance(position: q.coordinate.unitVectorF, size: base * 0.42, color: color, phase: phase, speed: 0,
                                              kind: 0, intensity: Float(min(0.75, 0.28 + (m - 4.5) * 0.14))))
                }
            }
        } else if layers.quakes {
            for q in scene.quakes {
                let ageH = nowDate.timeIntervalSince(q.time) / 3600
                guard ageH >= 0, ageH < 24 * 7.5 else { continue } // not yet happened while replaying
                let pos = q.coordinate.unitVectorF
                let m = max(q.mag, 2.5)
                let fresh = ageH < 1, day = ageH < 24
                let color: SIMD4<Float> = fresh ? Palette.quakeFresh : (day ? Palette.quakeDay : Palette.quakeWeek)
                let base = 0.0055 + pow(m - 2.0, 1.55) * 0.0032
                let size = Float(base * (day ? 1.0 : 0.6))
                let speed: Float = fresh ? 0.75 : (day ? 0.32 : 0)
                let intensity = Float(day ? min(1.15, 0.45 + (m - 2.5) * 0.2) : min(0.6, 0.2 + (m - 2.5) * 0.1))
                let phase = Float(abs(q.id.hashValue % 1000)) / 1000
                rings.append(RingInstance(position: pos, size: size, color: color, phase: phase, speed: speed, kind: 0, intensity: intensity))
                picks.append(Pickable(item: .quake(q.id), position: pos * 1.002, weight: Float(m)))
            }
        }

        for e in scene.events where !controller.isYearReplay {
            let pos = e.coordinate.unitVectorF
            switch e.kind {
            case .wildfire:
                guard layers.fires else { continue }
                let phase = Float(abs(e.id.hashValue % 1000)) / 1000
                rings.append(RingInstance(position: pos, size: 0.0085, color: Palette.fire, phase: phase, speed: 0, kind: 1, intensity: 1.0))
                picks.append(Pickable(item: .event(e.id), position: pos * 1.002, weight: 3))
            case .storm:
                guard layers.storms else { continue }
                let emphasis: Float = selected == .event(e.id) ? 1 : 0
                // Cloud shield grows with wind speed: ~220 km for a tropical storm, ~560 km at category 5.
                let knots = e.value ?? 45
                let radiusKm = 220 + min(max(knots - 35, 0), 120) * 2.8
                storms.append(StormInstance(position: pos, radius: Float(radiusKm / 6371),
                                            strength: Float(min(max((knots - 30) / 110, 0), 1)),
                                            hemisphere: e.lat >= 0 ? 1 : -1,
                                            phase: Float(abs(e.id.hashValue % 1000)) / 1000, emphasis: emphasis))
                picks.append(Pickable(item: .event(e.id), position: pos * 1.01, weight: 7))
                if let track = e.track, track.count > 1 {
                    let start = tracks.count
                    for (i, p) in track.enumerated() {
                        let f = Float(i) / Float(track.count - 1)
                        tracks.append(PathVertex(position: GeoPoint(lat: p.lat, lon: p.lon).unitVectorF * 1.003, alpha: 0.15 + 0.85 * f))
                    }
                    ranges.append((start, track.count))
                }
            default:
                guard layers.otherEvents else { continue }
                let icon = GlobeIcon(kind: e.kind)
                let emphasis: Float = selected == .event(e.id) ? 1 : 0
                icons.append(IconInstance(position: pos, sizePx: 15, color: Palette.color(for: e.kind), atlasIndex: Float(icon.rawValue), rotationSpeed: 0, altitude: 0.01, emphasis: emphasis))
                picks.append(Pickable(item: .event(e.id), position: pos * 1.01, weight: 5))
            }
        }

        if layers.launches && !controller.isYearReplay {
            for l in scene.launches where l.net > nowDate.addingTimeInterval(-6 * 3600) && l.net < nowDate.addingTimeInterval(7 * 86400) {
                let pos = l.coordinate.unitVectorF
                let emphasis: Float = selected == .launch(l.id) ? 1 : 0
                icons.append(IconInstance(position: pos, sizePx: 15, color: Palette.launch, atlasIndex: Float(GlobeIcon.rocket.rawValue), rotationSpeed: 0, altitude: 0.01, emphasis: emphasis))
                picks.append(Pickable(item: .launch(l.id), position: pos * 1.01, weight: 6))
            }
        }

        if let user = scene.user {
            rings.append(RingInstance(position: user.unitVectorF, size: 0.016, color: Palette.user, phase: 0, speed: 0.5, kind: 2, intensity: 1.2))
            picks.append(Pickable(item: .user, position: user.unitVectorF * 1.002, weight: 2))
        }
        for place in scene.places where !controller.isYearReplay {
            rings.append(RingInstance(position: place.unitVectorF, size: 0.012, color: Palette.place, phase: 0.5, speed: 0.35, kind: 2, intensity: 1.0))
            picks.append(Pickable(item: .spot(place), position: place.unitVectorF * 1.002, weight: 2))
        }

        if let sel = selected, let p = position(of: sel, in: scene) {
            rings.append(RingInstance(position: p, size: 0.03, color: SIMD4(1, 1, 1, 1), phase: 0, speed: 0, kind: 3, intensity: 0.9))
        }

        if let grid = scene.aurora, grid.count == 360 * 181, let auroraTex, auroraVersion != builtVersion {
            grid.withUnsafeBytes { raw in
                auroraTex.replace(region: MTLRegionMake2D(0, 0, 360, 181), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: 360)
            }
            auroraVersion = builtVersion
        }

        ringCount = rings.count
        ringBuffer = rings.isEmpty ? nil : device.makeBuffer(bytes: rings, length: MemoryLayout<RingInstance>.stride * rings.count, options: .storageModeShared)
        iconCount = icons.count
        iconBuffer = icons.isEmpty ? nil : device.makeBuffer(bytes: icons, length: MemoryLayout<IconInstance>.stride * icons.count, options: .storageModeShared)
        stormCount = storms.count
        stormBuffer = storms.isEmpty ? nil : device.makeBuffer(bytes: storms, length: MemoryLayout<StormInstance>.stride * storms.count, options: .storageModeShared)
        trackRanges = ranges.map { (start: $0.0, count: $0.1) }
        trackBuffer = tracks.isEmpty ? nil : device.makeBuffer(bytes: tracks, length: MemoryLayout<PathVertex>.stride * tracks.count, options: .storageModeShared)
        pickables = picks
    }

    private func updateISSPath() {
        guard let s = satellites, s.issPathVersion != issPathVersion else { return }
        issPathVersion = s.issPathVersion
        let path = s.issPath
        issPathCount = path.count
        issPathBuffer = path.isEmpty ? nil : device.makeBuffer(bytes: path, length: MemoryLayout<PathVertex>.stride * path.count, options: .storageModeShared)
    }

    private func position(of item: GlobeItem, in scene: GlobeSceneData) -> SIMD3<Float>? {
        switch item {
        case .quake(let id): return scene.quakes.first { $0.id == id }?.coordinate.unitVectorF
        case .event(let id): return scene.events.first { $0.id == id }?.coordinate.unitVectorF
        case .launch(let id): return scene.launches.first { $0.id == id }?.coordinate.unitVectorF
        case .user: return scene.user?.unitVectorF
        case .spot(let p): return p.unitVectorF
        case .satellite, .aurora: return nil
        }
    }

    // MARK: - Projection & picking

    /// Projects a render-frame position into view points; nil when behind the globe or the camera.
    func project(_ p: SIMD3<Float>) -> CGPoint? {
        let clip = viewProj * SIMD4(p, 1)
        guard clip.w > 0.001 else { return nil }
        let toCam = simd_normalize(eye - p)
        let n = simd_normalize(p)
        if simd_length(p) < 1.2 && simd_dot(n, toCam) < 0.02 { return nil }
        let ndc = SIMD2(clip.x, clip.y) / clip.w
        return CGPoint(x: CGFloat(ndc.x * 0.5 + 0.5) * viewSizePoints.width, y: CGFloat(0.5 - ndc.y * 0.5) * viewSizePoints.height)
    }

    func pick(at point: CGPoint) -> GlobeItem? {
        var best: (GlobeItem, CGFloat)?
        func consider(_ item: GlobeItem, _ p: SIMD3<Float>, radius: CGFloat) {
            guard let s = project(p) else { return }
            let d = hypot(s.x - point.x, s.y - point.y)
            guard d < radius else { return }
            if best == nil || d < best!.1 { best = (item, d) }
        }
        for p in pickables {
            consider(p.item, p.position, radius: 18 + CGFloat(p.weight) * 1.8)
        }
        if let sats = satellites, controller.layers.satellites {
            for group in [SatelliteEngine.Group.stations, .visual] {
                let list = sats.tracked[group] ?? []
                let positions = sats.positions(for: group)
                for (i, t) in list.enumerated() where i < positions.count {
                    let r = Geo.renderFrame(fromECEF: positions[i]) / Geo.earthRadiusKm
                    consider(.satellite(t.id), SIMD3<Float>(r), radius: group == .stations ? 30 : 20)
                }
            }
        }
        if best == nil, controller.layers.aurora, let hit = globeHit(at: point) {
            if abs(hit.lat) > 55 { return .aurora(north: hit.lat > 0) }
        }
        return best?.0
    }

    /// Geographic point under a screen location, if the ray hits the globe.
    func globeHit(at point: CGPoint) -> GeoPoint? {
        guard viewSizePoints.width > 0 else { return nil }
        let ndc = SIMD4<Float>(Float(point.x / viewSizePoints.width) * 2 - 1, 1 - Float(point.y / viewSizePoints.height) * 2, 1, 1)
        let inv = viewProj.inverse
        var far = inv * ndc
        far /= far.w
        let dir = simd_normalize(SIMD3(far.x, far.y, far.z) - eye)
        let b = simd_dot(eye, dir)
        let c = simd_dot(eye, eye) - 1
        let disc = b * b - c
        guard disc >= 0 else { return nil }
        let t = -b - sqrt(disc)
        guard t > 0 else { return nil }
        return GeoPoint(vector: SIMD3<Double>(eye + dir * t))
    }

    private func updateAnchor() {
        guard let sel = controller.selection else {
            if controller.anchor.visible { controller.anchor.visible = false }
            return
        }
        var p: SIMD3<Float>?
        if case .satellite(let id) = sel, let sats = satellites {
            for group in SatelliteEngine.Group.allCases {
                if let idx = sats.tracked[group]?.firstIndex(where: { $0.id == id }), idx < sats.positions(for: group).count {
                    p = SIMD3<Float>(Geo.renderFrame(fromECEF: sats.positions(for: group)[idx]) / Geo.earthRadiusKm)
                    break
                }
            }
        } else {
            p = position(of: sel, in: controller.scene).map { $0 * 1.01 }
        }
        guard let p, let screen = project(p) else {
            if controller.anchor.visible { controller.anchor.visible = false }
            return
        }
        if let old = controller.anchor.point, abs(old.x - screen.x) < 0.4, abs(old.y - screen.y) < 0.4, controller.anchor.visible { return }
        controller.anchor.point = screen
        controller.anchor.visible = true
    }

    private func sunScreenInfo(sunDir: SIMD3<Float>, aspect: Double) -> (ndc: SIMD2<Float>, visible: Float) {
        let p = sunDir * 80
        let clip = viewProj * SIMD4(p, 1)
        guard clip.w > 0 else { return (.zero, 0) }
        let ndc = SIMD2(clip.x, clip.y) / clip.w
        // Occlusion by the globe (with a soft edge through the atmosphere).
        let dir = simd_normalize(sunDir)
        let along = simd_dot(-eye, dir)
        var occlusion: Float = 1
        if along > 0 {
            let closest = simd_length(eye + dir * along)
            occlusion = smoothstep(1.0, 1.05, closest)
        }
        let onScreen = 1 - smoothstep(0.9, 1.6, max(abs(ndc.x), abs(ndc.y)))
        return (ndc, occlusion * onScreen)
    }

    // MARK: - Math

    static func perspective(fovY: Double, aspect: Double, near: Float, far: Float) -> simd_float4x4 {
        let y = Float(1 / tan(fovY / 2))
        let x = y / Float(aspect)
        let z = far / (near - far)
        return simd_float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }

    /// Rotation from J2000 equatorial (ECI) into the render frame at the given sidereal time.
    static func starRotation(gmst: Double) -> simd_float4x4 {
        let c = Float(cos(gmst)), s = Float(sin(gmst))
        // ECI -> ECEF: x' = c x + s y, y' = -s x + c y, z' = z. ECEF -> render: (y', z', x').
        let col0 = SIMD4<Float>(-s, 0, c, 0)   // image of ECI x
        let col1 = SIMD4<Float>(c, 0, s, 0)    // image of ECI y
        let col2 = SIMD4<Float>(0, 1, 0, 0)    // image of ECI z
        return simd_float4x4(columns: (col0, col1, col2, SIMD4(0, 0, 0, 1)))
    }
}

@inline(__always) func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

enum Palette {
    static func linear(_ hex: UInt32, _ alpha: Float = 1) -> SIMD4<Float> {
        let r = Float((hex >> 16) & 0xFF) / 255, g = Float((hex >> 8) & 0xFF) / 255, b = Float(hex & 0xFF) / 255
        return SIMD4(pow(r, 2.2), pow(g, 2.2), pow(b, 2.2), alpha)
    }
    static let quakeFresh = linear(0xFF4A2A) * SIMD4(2.6, 2.6, 2.6, 1)
    static let quakeDay = linear(0xFF8B3D) * SIMD4(1.9, 1.9, 1.9, 1)
    static let quakeWeek = linear(0xFFC66E) * SIMD4(1.2, 1.2, 1.2, 1)
    static let fire = linear(0xFF7A1A) * SIMD4(2.2, 2.2, 2.2, 1)
    static let storm = linear(0xC9A8FF)
    static let launch = linear(0xFFE2A8)
    static let user = linear(0x5AC8FF) * SIMD4(1.8, 1.8, 1.8, 1)
    static let place = linear(0xFF8CB3) * SIMD4(1.6, 1.6, 1.6, 1)
    static func color(for kind: EventKind) -> SIMD4<Float> {
        switch kind {
        case .volcano: linear(0xFF5A4A)
        case .ice: linear(0xA8E6FF)
        case .flood: linear(0x5AB4FF)
        case .dust, .drought: linear(0xE8C27A)
        case .heat: linear(0xFF9A5A)
        case .snow: linear(0xE6F4FF)
        default: linear(0xD0D8E8)
        }
    }
}
