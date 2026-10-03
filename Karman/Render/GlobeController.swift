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
}

enum GlobeItem: Hashable, Sendable {
    case quake(String)
    case event(String)
    case launch(String)
    case satellite(Int)
    case aurora(north: Bool)
    case user
}

struct GlobeSceneData {
    var quakes: [Quake] = []
    var events: [NaturalEvent] = []
    var launches: [Launch] = []
    var aurora: [UInt8]?
    var user: GeoPoint?
    var now = Date()
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
            } else if autoRotate && now - lastInteraction > 25 {
                let ramp = min(1, (now - lastInteraction - 25) / 4)
                pose.lon = Geo.normalizeLon(pose.lon - 1.4 * ramp * dt * min(1, pose.distance / 3))
            }
        }
        return pose
    }
}
