import Foundation
import Observation
import QuartzCore
import simd

struct GlobeLayers: Equatable, Codable, Sendable {
    var quakes = true
    var storms = true
    var fires = true
    var otherEvents = true
    var aurora = true
    var satellites = true
    var starlink = false
    var launches = true
    var clouds = true
    var cityLights = true
    var liveImagery = false
    // Live weather (NOAA GFS)
    var wind = true
    var temperature = false
    var rain = false
    var plates = false

    var anyWeather: Bool { wind || temperature || rain }

    enum CodingKeys: String, CodingKey {
        case quakes, storms, fires, otherEvents, aurora, satellites, starlink, launches, clouds, cityLights, liveImagery
        case wind, temperature, rain, plates
    }
}

extension GlobeLayers {
    /// Tolerates layer sets saved by older versions (missing keys keep their defaults).
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read(_ key: CodingKeys, _ value: inout Bool) {
            if let v = try? c.decodeIfPresent(Bool.self, forKey: key) { value = v }
        }
        read(.quakes, &quakes); read(.storms, &storms); read(.fires, &fires); read(.otherEvents, &otherEvents)
        read(.aurora, &aurora); read(.satellites, &satellites); read(.starlink, &starlink); read(.launches, &launches)
        read(.clouds, &clouds); read(.cityLights, &cityLights); read(.liveImagery, &liveImagery)
        read(.wind, &wind); read(.temperature, &temperature); read(.rain, &rain); read(.plates, &plates)
    }
}

enum GlobeItem: Hashable, Sendable {
    case quake(String)
    case event(String)
    case launch(String)
    case satellite(Int)
    case aurora(north: Bool)
    case user
    /// Any point on Earth the user tapped: its weather, daylight and distance.
    case spot(GeoPoint)
}

struct GlobeSceneData {
    var quakes: [Quake] = []
    /// A year of M4.5+ earthquakes for the year replay.
    var yearQuakes: [Quake] = []
    var events: [NaturalEvent] = []
    var launches: [Launch] = []
    var aurora: [UInt8]?
    var user: GeoPoint?
    /// Watched places (family, second homes).
    var places: [GeoPoint] = []
    var now = Date()
}

/// The renderer's latest camera, for projecting points to the screen outside the draw call.
struct GlobeProjection {
    var viewProj = matrix_identity_float4x4
    var eye = SIMD3<Float>(0, 0, 5)
    var viewSize: CGSize = .zero

    /// View-space point for a render-frame position; nil when behind the globe or the camera.
    func project(_ p: SIMD3<Float>) -> CGPoint? {
        let clip = viewProj * SIMD4(p, 1)
        guard clip.w > 0.001, viewSize.width > 0 else { return nil }
        let toCam = simd_normalize(eye - p)
        let n = simd_normalize(p)
        if simd_length(p) < 1.2 && simd_dot(n, toCam) < 0.02 { return nil }
        let ndc = SIMD2(clip.x, clip.y) / clip.w
        return CGPoint(x: CGFloat(ndc.x * 0.5 + 0.5) * viewSize.width, y: CGFloat(0.5 - ndc.y * 0.5) * viewSize.height)
    }

    /// Screen point for any position in front of the camera, hidden or not (points inside the
    /// planet, such as on the Inside the Earth cut).
    func screenPoint(_ p: SIMD3<Float>) -> CGPoint? {
        let clip = viewProj * SIMD4(p, 1)
        guard clip.w > 0.001, viewSize.width > 0 else { return nil }
        let ndc = SIMD2(clip.x, clip.y) / clip.w
        return CGPoint(x: CGFloat(ndc.x * 0.5 + 0.5) * viewSize.width, y: CGFloat(0.5 - ndc.y * 0.5) * viewSize.height)
    }

    /// How squarely a surface point faces the camera (1 = straight on, ≤ 0 = hidden).
    func facing(_ p: SIMD3<Float>) -> Float {
        let n = simd_normalize(p)
        return simd_dot(n, simd_normalize(eye - n))
    }
}

/// Screen-space anchor for the selection callout, published at frame rate.
@MainActor
@Observable
final class GlobeAnchor {
    var point: CGPoint?
    var visible = false
}

/// Bridges SwiftUI and the renderer: camera choreography, layers, scene data and picking.
@MainActor
final class GlobeController {
    // Camera
    private(set) var pose: CameraPose = CameraPose(lat: 15, lon: 10, distance: 11)
    private var flight: CameraFlight?
    private var velocity = SIMD2<Double>(0, 0)   // degrees per second (lon, lat)
    private var lastInteraction: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = CACurrentMediaTime()
    var autoRotate = true
    var homePose: CameraPose = .home
    var drift: (heading: Double, zoom: Double) = (0, 0)
    var minDistance = 1.22
    var maxDistance = 16.0

    // Content
    var layers = GlobeLayers() { didSet { if layers != oldValue { sceneVersion &+= 1 } } }
    private(set) var scene = GlobeSceneData()
    private(set) var sceneVersion = 0
    var selection: GlobeItem? { didSet { if selection != oldValue { sceneVersion &+= 1 } } }
    let anchor = GlobeAnchor()

    // Visual state
    var markerFade: Double = 1
    var sceneFade: Double = 0
    var introStart: CFTimeInterval?
    var liveImageryTexture: SendableTexture? { didSet { liveImageryVersion &+= 1 } }
    private(set) var liveImageryVersion = 0
    var onTap: ((GlobeItem?) -> Void)?
    /// Set to receive the next rendered frame (without the HUD) as an image.
    var captureRequest: ((CGImage?) -> Void)?

    weak var satellites: SatelliteEngine?

    // Live weather (GFS frames, oldest first)
    private(set) var weather: [WeatherGrid] = []
    private(set) var weatherVersion = 0
    /// Hours ahead of now that the weather (and daylight) show while the forecast is paused.
    var forecastHours: Double = 0
    /// A full day of forecast plays in this many seconds.
    static let forecastSecondsPerDay = 16.0
    private var forecastPlayback: (startedAt: CFTimeInterval, from: Double, span: Double)?
    var isPlayingForecast: Bool { forecastPlayback != nil }

    func setWeather(_ grids: [WeatherGrid]) {
        weather = grids
        weatherVersion &+= 1
    }

    /// Forecast hours shown at a moment: the paused value, or the playhead looping through the span
    /// (with a short hold on the last frame).
    func forecastHours(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        guard let p = forecastPlayback, p.span > 0 else { return forecastHours }
        let hold = 3.0
        let h = p.from + (now - p.startedAt) / Self.forecastSecondsPerDay * 24
        return min(p.span, h.truncatingRemainder(dividingBy: p.span + hold))
    }

    func playForecast(span: Double) {
        let start = forecastHours >= span - 0.25 ? 0 : forecastHours
        forecastPlayback = (CACurrentMediaTime(), start, span)
    }

    func pauseForecast() {
        forecastHours = forecastHours(at: CACurrentMediaTime())
        forecastPlayback = nil
    }

    /// The instant whose sunlight and weather are drawn: the render date plus the forecast offset.
    func lightingDate(at now: CFTimeInterval = CACurrentMediaTime()) -> Date {
        renderDate(at: now).addingTimeInterval(forecastHours(at: now) * 3600)
    }

    // Follow mode (ride along with the ISS)
    private var follow: (@MainActor (Date) -> RideAlongMath.Frame?)?
    private var followEngaged = false
    /// Ground point the detail imagery should centre on while following.
    private(set) var followFocus: GeoPoint?
    var isFollowing: Bool { follow != nil }
    /// True once the fly-in has finished and the camera is locked to the station.
    var isFollowEngaged: Bool { follow != nil && followEngaged }
    /// Called when the user takes the camera back with a gesture.
    var onFollowEnded: (() -> Void)?

    // MARK: Replay (time machine)

    struct Replay: Equatable {
        enum Kind: Equatable { case day, year }
        var from: Date
        var to: Date
        var startedAt: CFTimeInterval
        var duration: CFTimeInterval
        var kind: Kind = .day
    }

    private(set) var replay: Replay?

    /// The instant being rendered: now, or a moment inside the replayed window.
    func renderDate(at now: CFTimeInterval = CACurrentMediaTime()) -> Date {
        guard let r = replay else { return Date() }
        let f = min(1, max(0, (now - r.startedAt) / r.duration))
        return r.from.addingTimeInterval(f * r.to.timeIntervalSince(r.from))
    }

    /// 0…1 through the replay, nil when live.
    func replayProgress(at now: CFTimeInterval = CACurrentMediaTime()) -> Double? {
        replay.map { min(1, max(0, (now - $0.startedAt) / $0.duration)) }
    }

    func startReplay(hours: Double, duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        let end = Date()
        replay = Replay(from: end.addingTimeInterval(-hours * 3600), to: end, startedAt: CACurrentMediaTime() + delay, duration: duration)
        autoRotate = false
        sceneVersion &+= 1
    }

    /// Plays a year of earthquakes; the globe turns slowly under a studio-lit Sun.
    func startYearReplay(from: Date, to: Date, duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        replay = Replay(from: from, to: to, startedAt: CACurrentMediaTime() + delay, duration: duration, kind: .year)
        autoRotate = false
        sceneVersion &+= 1
    }

    var isYearReplay: Bool { replay?.kind == .year }

    // MARK: Seismic waves

    struct SeismicWaves: Equatable {
        var quakeID: String
        var epicenter: GeoPoint
        var depthKm: Double
        var magnitude: Double
        var startedAt: CFTimeInterval
        /// Seismic seconds shown per second on screen.
        static let speed = 90.0
        /// Seconds on screen before the display fades away.
        static let duration = 38.0
    }

    private(set) var seismic: SeismicWaves?

    func startSeismicWaves(for quake: Quake, delay: CFTimeInterval = 0) {
        seismic = SeismicWaves(quakeID: quake.id, epicenter: quake.coordinate, depthKm: quake.depthKm, magnitude: quake.mag,
                               startedAt: CACurrentMediaTime() + delay)
    }

    func stopSeismicWaves() { seismic = nil }

    /// Seconds after the earthquake being shown (negative before the display starts).
    func seismicTime(at now: CFTimeInterval = CACurrentMediaTime()) -> Double? {
        seismic.map { (now - $0.startedAt) * SeismicWaves.speed }
    }

    /// 0…1 brightness of the wave display (fades in, then out at the end).
    func seismicStrength(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        guard let s = seismic else { return 0 }
        let t = now - s.startedAt
        guard t > 0 else { return 0 }
        return min(1, t / 0.6) * min(1, max(0, (SeismicWaves.duration - t) / 3))
    }

    var seismicFinished: Bool {
        guard let s = seismic else { return true }
        return CACurrentMediaTime() - s.startedAt > SeismicWaves.duration
    }

    // MARK: Inside the Earth

    /// An orange-slice wedge cut out of the planet, pole to pole, opening and closing smoothly.
    struct Cutaway: Equatable {
        /// Longitude at the middle of the removed wedge.
        var longitude: Double
        var openedAt: CFTimeInterval
        var closedAt: CFTimeInterval?
        /// Half the wedge's angle when fully open (a quarter of the planet removed).
        static let halfAngle = Double.pi / 4
        static let animation: CFTimeInterval = 1.6
    }

    private(set) var cutaway: Cutaway?

    func openCutaway(longitude: Double, delay: CFTimeInterval = 0) {
        let now = CACurrentMediaTime()
        if var c = cutaway, let closed = c.closedAt {
            // Still closing: reopen from wherever it has got to.
            let progress = min(1, max(0, 1 - (now - closed) / Cutaway.animation))
            c.openedAt = now - progress * Cutaway.animation
            c.closedAt = nil
            cutaway = c
            return
        }
        cutaway = Cutaway(longitude: longitude, openedAt: now + delay)
        sceneVersion &+= 1
    }

    /// Closes from wherever the opening has got to; the cut is dropped once shut.
    func closeCutaway() {
        guard var c = cutaway, c.closedAt == nil else { return }
        let now = CACurrentMediaTime()
        let progress = min(1, max(0, (now - c.openedAt) / Cutaway.animation))
        c.closedAt = now - (1 - progress) * Cutaway.animation
        cutaway = c
    }

    /// 0 (whole planet) … 1 (wedge fully open).
    func cutawayOpening(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        guard let c = cutaway else { return 0 }
        let t = c.closedAt.map { 1 - (now - $0) / Cutaway.animation } ?? (now - c.openedAt) / Cutaway.animation
        return Easing.inOutCubic(min(1, max(0, t)))
    }

    var isCutawayOpen: Bool { cutaway != nil && cutaway?.closedAt == nil }

    // MARK: Projection

    /// Updated by the renderer every frame.
    var projection = GlobeProjection()

    #if DEBUG
    /// Screenshots only: render the scene's lighting at a fixed instant (the data stays live).
    func freezeTime(at date: Date) {
        replay = Replay(from: date, to: date, startedAt: CACurrentMediaTime(), duration: 1)
        sceneVersion &+= 1
    }
    #endif

    func stopReplay() {
        replay = nil
        autoRotate = true
        sceneVersion &+= 1
    }

    func startFollow(_ provider: @escaping @MainActor (Date) -> RideAlongMath.Frame?) {
        guard let first = provider(Date()) else { return }
        follow = provider
        followEngaged = false
        followFocus = first.focus
        autoRotate = false
        drift = (0, 0)
        fly(to: first.pose, duration: 3.2)
    }

    func stopFollow() {
        follow = nil
        followEngaged = false
        followFocus = nil
        autoRotate = true
    }

    private func endFollowByGesture() {
        guard follow != nil else { return }
        stopFollow()
        onFollowEnded?()
    }

    func update(scene newScene: GlobeSceneData) {
        scene = newScene
        sceneVersion &+= 1
    }

    // MARK: Camera control

    func fly(to target: CameraPose, duration: CFTimeInterval? = nil) {
        flight = CameraFlight(from: pose, to: target, start: CACurrentMediaTime(), duration: duration)
        velocity = .zero
        markInteraction()
    }

    func focus(on point: GeoPoint, distance: Double? = nil, tilt: Double = 0, heading: Double = 0, duration: CFTimeInterval? = nil) {
        let d = distance ?? min(pose.distance, 2.6)
        fly(to: CameraPose(lat: point.lat, lon: point.lon, distance: d, tilt: tilt, heading: heading), duration: duration)
    }

    func set(pose newPose: CameraPose) {
        flight = nil
        pose = newPose
    }

    var isFlying: Bool { flight != nil }

    func markInteraction() { lastInteraction = CACurrentMediaTime() }
    var lastInteractionTime: CFTimeInterval { lastInteraction }

    /// True while the idle auto-rotation is turning the globe (needs a smooth frame rate).
    func autoRotateActive(now: CFTimeInterval) -> Bool {
        autoRotate && flight == nil && now - lastInteraction > 25
    }

    func pan(by delta: CGSize, viewHeight: CGFloat) {
        endFollowByGesture()
        flight = nil
        markInteraction()
        let scale = degreesPerPoint(viewHeight: viewHeight)
        pose.lon -= Double(delta.width) * scale / max(cos(pose.lat * .pi / 180), 0.25)
        pose.lat = max(-85, min(85, pose.lat + Double(delta.height) * scale))
        pose.lon = Geo.normalizeLon(pose.lon)
    }

    func endPan(velocity v: CGPoint, viewHeight: CGFloat) {
        let scale = degreesPerPoint(viewHeight: viewHeight)
        velocity = SIMD2(-Double(v.x) * scale / max(cos(pose.lat * .pi / 180), 0.25), Double(v.y) * scale)
        if simd_length(velocity) > 400 { velocity = simd_normalize(velocity) * 400 }
        markInteraction()
    }

    func zoom(by factor: CGFloat) {
        endFollowByGesture()
        flight = nil
        markInteraction()
        let altitude = (pose.distance - 1) / Double(factor)
        pose.distance = max(minDistance, min(maxDistance, 1 + altitude))
    }

    func adjustTilt(by delta: CGFloat) {
        endFollowByGesture()
        flight = nil
        markInteraction()
        pose.tilt = max(0, min(60, pose.tilt - Double(delta) * 0.25))
    }

    private func degreesPerPoint(viewHeight: CGFloat) -> Double {
        // Roughly keep the touched point under the finger.
        let visibleAngle = 2 * atan(tan(GlobeRenderer.fovY / 2) * (pose.distance - 1)) * 180 / .pi
        return max(0.004, visibleAngle / Double(max(viewHeight, 1))) * 1.15
    }

    /// Advances camera animation; returns the pose to render.
    func step(now: CFTimeInterval) -> CameraPose {
        let dt = min(0.05, max(0, now - lastFrame))
        lastFrame = now
        if let c = cutaway, let closed = c.closedAt, now - closed > Cutaway.animation {
            cutaway = nil
            sceneVersion &+= 1
        }
        // Markers would float over the hole: fade them while the planet is cut open.
        let markerTarget: Double = cutaway == nil ? 1 : 0
        markerFade += (markerTarget - markerFade) * min(1, dt * 5)
        if abs(markerTarget - markerFade) < 0.002 { markerFade = markerTarget }
        if let follow, let frame = follow(Date()) {
            followFocus = frame.focus
            if followEngaged {
                pose = frame.pose
                return pose
            }
            // Fly in, steering the flight's end toward the moving station.
            flight?.to = frame.pose
            if flight == nil { followEngaged = true; pose = frame.pose; return pose }
        }
        if let f = flight {
            let (p, done) = f.pose(at: now)
            pose = p
            if done {
                flight = nil
                if follow != nil { followEngaged = true }
            }
        } else {
            if simd_length(velocity) > 0.01 {
                pose.lon = Geo.normalizeLon(pose.lon + velocity.x * dt)
                pose.lat = max(-85, min(85, pose.lat + velocity.y * dt))
                velocity *= pow(0.06, dt)
            }
            if drift.heading != 0 || drift.zoom != 0 {
                pose.heading += drift.heading * dt
                pose.distance = max(minDistance, pose.distance * (1 + drift.zoom * dt))
            } else if isYearReplay && now - lastInteraction > 2.5 {
                // The year replay turns the planet once in about a minute.
                let ramp = min(1, (now - lastInteraction - 2.5) / 2)
                pose.lon = Geo.normalizeLon(pose.lon - 6 * ramp * dt)
            } else if autoRotate && now - lastInteraction > 25 {
                let ramp = min(1, (now - lastInteraction - 25) / 4)
                pose.lon = Geo.normalizeLon(pose.lon - 1.4 * ramp * dt * min(1, pose.distance / 3))
            }
        }
        return pose
    }
}
