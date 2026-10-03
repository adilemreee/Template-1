import Foundation
import Metal
import Observation
import QuartzCore
import simd
import SwiftUI
import UIKit

/// Root state shared by every screen.
@MainActor
@Observable
final class AppModel {
    enum Panel: String, Identifiable {
        case pulse, space, sky, ask, settings, briefing
        var id: String { rawValue }
    }

    let globe = GlobeController()
    let satellites: SatelliteEngine
    let planet = PlanetStore()
    let location = LocationService()
    let settings = AppSettings()

    var selection: GlobeItem? {
        didSet {
            globe.selection = selection
        }
    }
    var panel: Panel?
    var detailItem: GlobeItem?
    var shareCard: UIImage?
    var inspectorFrame: CGRect?
    /// DEBUG-only: drives the UI into a named state for App Store screenshots.
    var screenshotScene: String?
    var introPlaying = true
    var showTitle = false
    var hudVisible = false
    var briefingActive = false
    /// True while the camera rides along with the ISS.
    var ridingISS = false
    var onboardingDone = UserDefaults.standard.bool(forKey: "onboardingDone") {
        didSet { UserDefaults.standard.set(onboardingDone, forKey: "onboardingDone") }
    }

    /// Visible ISS / bright-satellite passes for the user's location.
    private(set) var passes: [PassPredictor.Pass] = []
    @ObservationIgnored private var passesComputedAt: Date = .distantPast
    @ObservationIgnored private var passesLocation: GeoPoint?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var observedVersion = -1

    init() {
        satellites = SatelliteEngine(device: MTLCreateSystemDefaultDeviceSafe())
        globe.satellites = satellites
        globe.layers = settings.layers
        globe.onTap = { [weak self] item in self?.handleTap(item) }
        globe.onFollowEnded = { [weak self] in
            withAnimation(.easeInOut(duration: 0.5)) { self?.ridingISS = false }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        planet.start()
        // First launch asks for location after the intro, in context (OnboardingCard).
        if onboardingDone { location.requestIfNeeded() }
        applyLayers(settings.layers)
        Task { await loadSatellites() }
        #if DEBUG
        screenshotScene = ProcessInfo.processInfo.environment["KARMAN_SCREEN"]
        if screenshotScene != nil { onboardingDone = true }
        if screenshotScene == "preview" {
            // App Preview recording: full intro, then the briefing starts by itself.
            ScreenshotDirector.prepare(self)
            Task {
                try? await Task.sleep(for: .seconds(GlobeRenderer.introDuration + 3.2))
                BriefingDirector.shared.start(model: self)
            }
        } else if screenshotScene != nil {
            ScreenshotDirector.prepare(self)
            introFinished()
            globe.sceneFade = 1
            globe.set(pose: globe.homePose)
            syncScene()
            Task { await ScreenshotDirector.run(self) }
            return
        }
        #endif
        // The full cinematic plays on first launch and at most once every 12 hours; otherwise
        // the globe simply fades in, so returning users get straight to the planet.
        let lastIntro = UserDefaults.standard.double(forKey: "lastIntroAt")
        let fullIntro = settings.playIntro && Date().timeIntervalSince1970 - lastIntro > 12 * 3600
        if !fullIntro {
            syncScene()
            globe.set(pose: globe.homePose)
            introFinished()
            return
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastIntroAt")
        if settings.playIntro {
            globe.introStart = CACurrentMediaTime() + 0.25
            Task {
                try? await Task.sleep(for: .seconds(2.4))
                withAnimation(.easeOut(duration: 1.2)) { showTitle = true }
                try? await Task.sleep(for: .seconds(2.6))
                withAnimation(.easeInOut(duration: 0.9)) { showTitle = false }
            }
        } else {
            introFinished()
        }
        syncScene()
    }

    func introFinished() {
        guard introPlaying || !hudVisible else { return }
        withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) {
            hudVisible = true
            introPlaying = false
        }
    }

    func skipIntro() {
        guard introPlaying else { return }
        globe.introStart = nil
        globe.sceneFade = 1
        globe.fly(to: globe.homePose, duration: 1.0)
        withAnimation(.easeOut(duration: 0.4)) { showTitle = false }
        introFinished()
    }

    /// Pushes the latest data into the renderer when it changes.
    func syncScene(force: Bool = false) {
        let user = location.point
        globe.homePose = Self.homePose(for: user)
        guard force || observedVersion != planet.version || globe.scene.user != user else { return }
        observedVersion = planet.version
        var scene = GlobeSceneData()
        scene.quakes = planet.snapshot.quakes
        scene.events = planet.snapshot.events
        scene.launches = planet.snapshot.launches
        scene.aurora = planet.auroraGrid
        scene.user = settings.showUserLocation ? user : nil
        globe.update(scene: scene)
    }

    /// Frames the user's region, nudged toward the day side when it is deep night so the
    /// terminator — the most beautiful line on the planet — is in view.
    static func homePose(for user: GeoPoint?, date: Date = Date()) -> CameraPose {
        let base = user.map { GeoPoint(lat: max(-45, min(50, $0.lat - 10)), lon: $0.lon) } ?? GeoPoint(lat: 20, lon: 15)
        let sun = Astro.subsolarPoint(date)
        let a = base.unitVector, b = sun.unitVector
        let angle = acos(max(-1, min(1, simd_dot(a, b)))) * 180 / .pi
        var target = base
        if angle > 118 {
            let f = (angle - 118) / angle
            let ω = angle * .pi / 180
            let v = (sin((1 - f) * ω) * a + sin(f * ω) * b) / sin(ω)
            let g = GeoPoint(vector: v)
            target = GeoPoint(lat: max(-45, min(50, g.lat)), lon: g.lon)
        }
        return CameraPose(lat: target.lat, lon: target.lon, distance: 6.4)
    }

    func applyLayers(_ layers: GlobeLayers) {
        settings.layers = layers
        globe.layers = layers
        satellites.enabledGroups = Set([layers.satellites ? SatelliteEngine.Group.visual : nil,
                                        layers.satellites ? .stations : nil,
                                        layers.starlink ? .starlink : nil].compactMap { $0 })
        if layers.starlink && satellites.catalogs[.starlink] == nil {
            Task { await loadGroup(.starlink) }
        }
        if layers.liveImagery {
            Task { await LiveImagery.shared.ensureLoaded(into: globe) }
        }
    }

    private func loadSatellites() async {
        await loadGroup(.stations)
        await loadGroup(.visual)
        if settings.layers.starlink { await loadGroup(.starlink) }
        if settings.layers.liveImagery { await LiveImagery.shared.ensureLoaded(into: globe) }
    }

    func loadGroup(_ group: SatelliteEngine.Group) async {
        if let cached = SatelliteCache.load(group: group), !cached.isStale {
            satellites.load(group: group, elements: cached.elements)
            return
        }
        do {
            let (elements, raw) = try await APIClient.shared.satellites(group: group.rawValue)
            SatelliteCache.save(group: group, raw: raw)
            satellites.load(group: group, elements: elements)
        } catch {
            if let cached = SatelliteCache.load(group: group) {
                satellites.load(group: group, elements: cached.elements)
            }
        }
    }

    // MARK: Derived data (passes, widgets, alert registration)

    func refreshDerived() {
        Task { await recomputePasses() }
        writeWidgetState()
        let launches = planet.upcomingLaunches
        #if DEBUG
        if screenshotScene == "liveactivity" { return } // keeps the staged countdown on screen
        #endif
        Task { await NotificationService.shared.syncLaunchActivities(launches) }
    }

    func recomputePasses(force: Bool = false) async {
        guard let observer = location.point, let iss = satellites.iss else { return }
        let moved = passesLocation.map { $0.distanceKm(to: observer) > 25 } ?? true
        guard force || moved || Date().timeIntervalSince(passesComputedAt) > 1800 else { return }
        passesComputedAt = Date()
        passesLocation = observer
        let tiangong = satellites.propagator(id: 48274)
        let result = await Task.detached(priority: .utility) { () -> [PassPredictor.Pass] in
            var all = PassPredictor.passes(for: iss, observer: observer, hours: 96)
            if let tiangong { all += PassPredictor.passes(for: tiangong, observer: observer, hours: 96, minElevation: 20) }
            return all.sorted { $0.start < $1.start }
        }.value
        passes = result
        writeWidgetState()
        await NotificationService.shared.scheduleStationPasses(result.map(\.widget), enabled: settings.alerts.issPasses)
    }

    func writeWidgetState() {
        let snap = planet.snapshot
        guard !snap.quakes.isEmpty || snap.space != nil else { return }
        let user = location.point
        let day = Date().addingTimeInterval(-86400)
        let recent = snap.quakes.filter { $0.time > day && $0.mag >= 3.5 }.prefix(80)
        let top = snap.quakes.filter { $0.time > day }.max { $0.mag < $1.mag }
        let launch = planet.upcomingLaunches.first { $0.net > Date() }
        let state = WidgetState(
            updatedAt: Date(), kp: snap.space?.kpNow ?? 0, gScale: snap.space?.gScale ?? 0,
            windSpeed: snap.space?.windSpeed ?? 0, bz: snap.space?.bz ?? 0,
            auroraChance: planet.auroraChance(at: user), location: user, locationName: location.placeName,
            quakes24h: snap.quakes.filter { $0.time > day }.count,
            topQuake: top.map { q in WidgetState.TopQuake(id: q.id, mag: q.mag, place: q.place, time: q.time, distanceKm: user.map { q.coordinate.distanceKm(to: $0) }) },
            recentQuakes: recent.map { WidgetState.QuakeDot(lat: $0.lat, lon: $0.lon, mag: $0.mag, time: $0.time) },
            passes: passes.prefix(8).map(\.widget),
            nextLaunch: launch.map { WidgetState.NextLaunch(name: $0.missionName, rocket: $0.rocket, provider: $0.provider, net: $0.net, location: $0.location) })
        state.save()
        WidgetBridge.reload()
    }

    // MARK: Selection

    func handleTap(_ item: GlobeItem?) {
        guard !briefingActive else { return }
        if let item, item == selection {
            focusOnSelection()
            return
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) { selection = item }
        if item != nil { Haptics.shared.tap() }
    }

    // MARK: Ride along with the ISS

    var canRideAlong: Bool { satellites.iss != nil }

    func startRideAlong() {
        guard let iss = satellites.iss else { return }
        if briefingActive { BriefingDirector.shared.stop() }
        panel = nil
        detailItem = nil
        withAnimation(.easeInOut(duration: 0.4)) { selection = nil }
        if !settings.layers.satellites {
            settings.layers.satellites = true
            applyLayers(settings.layers)
        }
        Haptics.shared.tap()
        globe.startFollow { date in RideAlongMath.frame(for: iss, at: date) }
        withAnimation(.easeInOut(duration: 0.6)) { ridingISS = true }
    }

    func stopRideAlong() {
        let below = satellites.iss.flatMap { try? $0.ecef(at: Date()) }.map { SatGeo.subpoint(ecef: $0).point }
        globe.stopFollow()
        withAnimation(.easeInOut(duration: 0.5)) { ridingISS = false }
        if let below { globe.fly(to: CameraPose(lat: below.lat, lon: below.lon, distance: 2.8), duration: 2.6) }
    }

    func select(_ item: GlobeItem, fly: Bool = true) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) { selection = item }
        if fly { focusOnSelection() }
    }

    func focusOnSelection() {
        guard let sel = selection, let p = coordinate(of: sel) else { return }
        let distance: Double = switch sel {
        case .quake, .event: 2.1
        case .launch: 2.3
        case .satellite: 2.6
        case .aurora: 3.4
        case .user: 2.4
        }
        globe.focus(on: p, distance: distance)
    }

    func coordinate(of item: GlobeItem) -> GeoPoint? {
        switch item {
        case .quake(let id): planet.quake(id: id)?.coordinate
        case .event(let id): planet.event(id: id)?.coordinate
        case .launch(let id): planet.launch(id: id)?.coordinate
        case .user: location.point
        case .aurora(let north): GeoPoint(lat: north ? 68 : -68, lon: Geo.normalizeLon(Astro.subsolarPoint(Date()).lon + 180))
        case .satellite(let id):
            satellites.propagator(id: id).flatMap { try? $0.ecef(at: Date()) }.map { SatGeo.subpoint(ecef: $0).point }
        }
    }
}

private func MTLCreateSystemDefaultDeviceSafe() -> MTLDevice? { MTLCreateSystemDefaultDevice() }
