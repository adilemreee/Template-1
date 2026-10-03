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
    let weather = WeatherStore()
    let history = QuakeHistoryStore()
    let sky = SkyConditionsStore()
    /// The Sky Lens is open (full screen), optionally pointing the user at something.
    var skyLensPresented = false
    var skyLensTarget: SkyTarget?
    /// The Ask Kármán conversation (kept while the panel is closed).
    let askService = AskService()
    /// Height of the Ask sheet; it drops to half height while the globe flies to an answer.
    var askDetent: PresentationDetent = .large
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
        globe.setWeather(weather.grids)
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
        scene.yearQuakes = globe.scene.yearQuakes
        scene.places = settings.places.map(\.point)
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
        if layers.anyWeather { watchWeather() } else if forecastHours != 0 || forecastPlaying { resetForecast() }
    }

    @ObservationIgnored private var weatherWatch: Task<Void, Never>?

    /// Keeps asking for the GFS frames every few seconds until the whole day is in (a freshly
    /// started server publishes them one by one), for as long as weather is on screen.
    func watchWeather() {
        weather.refreshIfNeeded()
        guard weatherWatch == nil else { return }
        weatherWatch = Task { [weak self] in
            for _ in 0..<90 {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                guard self.settings.layers.anyWeather || self.selection.isSpot, !self.weather.isComplete else { break }
                self.weather.refreshIfNeeded()
            }
            self?.weatherWatch = nil
        }
    }

    /// Pushes new GFS frames into the renderer.
    func syncWeather() {
        globe.setWeather(weather.grids)
    }

    // MARK: Forecast scrubber

    /// Hours ahead the weather layers show while paused (0 = now).
    private(set) var forecastHours: Double = 0
    private(set) var forecastPlaying = false

    /// Hours from now to the last GFS frame.
    var forecastSpan: Double {
        guard let last = weather.grids.last?.valid else { return 0 }
        return max(0, last.timeIntervalSinceNow / 3600)
    }

    func scrubForecast(to hours: Double) {
        if forecastPlaying {
            globe.pauseForecast()
            forecastPlaying = false
        }
        forecastHours = max(0, min(forecastSpan, hours))
        globe.forecastHours = forecastHours
    }

    func toggleForecastPlayback() {
        Haptics.shared.select()
        if forecastPlaying {
            globe.pauseForecast()
            forecastHours = globe.forecastHours
            forecastPlaying = false
        } else if forecastSpan > 1 {
            globe.playForecast(span: forecastSpan)
            forecastPlaying = true
        }
    }

    func resetForecast() {
        globe.pauseForecast()
        globe.forecastHours = 0
        forecastHours = 0
        forecastPlaying = false
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

    // MARK: Replay the last 24 hours

    var replaying = false

    func startReplay() {
        if briefingActive { BriefingDirector.shared.stop() }
        if yearReplaying { stopYearReplay() }
        stopSeismicWaves()
        resetForecast()
        if ridingISS { stopRideAlong() }
        panel = nil
        detailItem = nil
        withAnimation(.easeInOut(duration: 0.4)) { selection = nil }
        Haptics.shared.tap()
        let p = globe.pose
        globe.fly(to: CameraPose(lat: max(-35, min(35, p.lat)), lon: p.lon, distance: max(p.distance, 5.2)), duration: 1.4)
        globe.startReplay(hours: 24, duration: 36, delay: 1.4)
        withAnimation(.easeInOut(duration: 0.5)) { replaying = true }
    }

    func stopReplay() {
        guard replaying else { return }
        globe.stopReplay()
        withAnimation(.easeInOut(duration: 0.5)) { replaying = false }
    }

    // MARK: Ambient globe

    private(set) var ambientActive = false

    func startAmbient() {
        if briefingActive { BriefingDirector.shared.stop() }
        if ridingISS { stopRideAlong() }
        if replaying { stopReplay() }
        if yearReplaying { stopYearReplay() }
        stopSeismicWaves()
        resetForecast()
        panel = nil
        detailItem = nil
        withAnimation(.easeInOut(duration: 0.4)) { selection = nil }
        withAnimation(.easeInOut(duration: 0.8)) { ambientActive = true }
    }

    func stopAmbient() {
        guard ambientActive else { return }
        globe.drift = (0, 0)
        globe.fly(to: globe.homePose, duration: 2.2)
        withAnimation(.easeInOut(duration: 0.6)) { ambientActive = false }
    }

    // MARK: Sky Lens

    func openSkyLens(target: SkyTarget?) {
        Haptics.shared.tap()
        skyLensTarget = target
        if panel != nil {
            panel = nil
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                skyLensPresented = true
            }
        } else {
            skyLensPresented = true
        }
    }

    // MARK: A year of earthquakes

    private(set) var yearReplaying = false
    private(set) var yearLoading = false

    func startYearReplay() {
        guard !yearReplaying, !yearLoading else { return }
        if briefingActive { BriefingDirector.shared.stop() }
        if ridingISS { stopRideAlong() }
        if replaying { stopReplay() }
        stopSeismicWaves()
        resetForecast()
        panel = nil
        detailItem = nil
        withAnimation(.easeInOut(duration: 0.4)) { selection = nil }
        Haptics.shared.tap()
        yearLoading = true
        Task {
            let year = await history.load()
            yearLoading = false
            guard let year, !year.quakes.isEmpty else { return }
            var scene = globe.scene
            scene.yearQuakes = year.quakes
            globe.update(scene: scene)
            // Open on the Pacific, where the Ring of Fire lights up first.
            globe.fly(to: CameraPose(lat: 8, lon: -165, distance: 5.6), duration: 1.8)
            globe.startYearReplay(from: year.from, to: year.to, duration: 52, delay: 1.8)
            withAnimation(.easeInOut(duration: 0.5)) { yearReplaying = true }
        }
    }

    func stopYearReplay() {
        guard yearReplaying else { return }
        globe.stopReplay()
        var scene = globe.scene
        scene.yearQuakes = []
        globe.update(scene: scene)
        withAnimation(.easeInOut(duration: 0.5)) { yearReplaying = false }
    }

    // MARK: Seismic waves

    /// The earthquake whose waves are on screen.
    private(set) var wavesQuake: Quake?

    func startSeismicWaves(_ quake: Quake) {
        if briefingActive { BriefingDirector.shared.stop() }
        if ambientActive { stopAmbient() }
        if ridingISS { stopRideAlong() }
        if replaying { stopReplay() }
        if yearReplaying { stopYearReplay() }
        resetForecast()
        panel = nil
        detailItem = nil
        Haptics.shared.thud()
        withAnimation(.easeInOut(duration: 0.4)) { selection = .quake(quake.id) }
        // Frame the epicentre and you together when you're on the same side of the planet.
        var center = quake.coordinate
        var distance = 3.6
        if let user = location.point {
            let angle = quake.coordinate.distanceKm(to: user) / Geo.earthRadiusKm
            if angle < 1.6 {
                let v = simd_normalize(quake.coordinate.unitVector * 0.6 + user.unitVector * 0.4)
                center = GeoPoint(vector: v)
                distance = max(3.0, min(5.2, 2.6 + angle * 1.8))
            }
        }
        globe.fly(to: CameraPose(lat: center.lat, lon: center.lon, distance: distance), duration: 1.6)
        globe.startSeismicWaves(for: quake, delay: 1.4)
        globe.drift = (0, 0.016)   // ease out as the waves spread round the planet
        withAnimation(.easeInOut(duration: 0.5)) { wavesQuake = quake }
    }

    func stopSeismicWaves() {
        guard wavesQuake != nil else { return }
        globe.stopSeismicWaves()
        globe.drift = (0, 0)
        withAnimation(.easeInOut(duration: 0.5)) { wavesQuake = nil }
    }

    // MARK: Ride along with the ISS

    var canRideAlong: Bool {
        _ = satellites.catalogs[.stations] // observed, so views update once the stations load
        return satellites.iss != nil
    }

    func startRideAlong() {
        guard let iss = satellites.iss else { return }
        if briefingActive { BriefingDirector.shared.stop() }
        if replaying { stopReplay() }
        if yearReplaying { stopYearReplay() }
        stopSeismicWaves()
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
        case .spot: max(2.0, min(globe.pose.distance, 3.0))
        }
        globe.focus(on: p, distance: distance)
    }

    // MARK: Ask Kármán on the globe

    /// Opens Ask with what the user is looking at as context.
    func ask(about context: APIClient.AskAbout) {
        askService.setContext(context)
        askDetent = .large
        Haptics.shared.tap()
        if detailItem != nil || panel != nil {
            detailItem = nil
            panel = nil
            // Let the open sheet finish dismissing before presenting Ask.
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                panel = .ask
            }
        } else {
            panel = .ask
        }
    }

    /// Context for "Ask about this" on a globe item.
    func askContext(for item: GlobeItem) -> APIClient.AskAbout? {
        switch item {
        case .quake(let id):
            guard let q = planet.quake(id: id) else { return nil }
            return .init(refId: q.id, kind: "quake", title: q.place,
                         details: "M\(Fmt.magnitude(q.mag)), \(Int(q.depthKm)) km deep, \(Fmt.relative(q.time)) ago" + (q.isTsunamiFlagged ? ", tsunami flag" : ""))
        case .event(let id):
            guard let e = planet.event(id: id) else { return nil }
            return .init(refId: e.id, kind: e.kind.rawValue, title: e.title, details: e.valueText.isEmpty ? nil : e.valueText)
        case .launch(let id):
            guard let l = planet.launch(id: id) else { return nil }
            return .init(refId: l.id, kind: "launch", title: "\(l.missionName) on \(l.rocket)", details: "\(l.location), NET \(l.net.formatted(.iso8601))")
        case .aurora(let north):
            return .init(refId: north ? "aurora-north" : "aurora-south", kind: "aurora", title: north ? "Northern auroral oval" : "Southern auroral oval", details: nil)
        case .satellite(let id):
            let name = satellites.propagator(id: id)?.name ?? "satellite \(id)"
            return .init(refId: "sat-\(id)", kind: "satellite", title: name.capitalized, details: "NORAD \(id)")
        case .user, .spot:
            return nil
        }
    }

    /// The globe item an Ask answer points at, if it is on the globe.
    func globeItem(for f: APIClient.GlobeFocus) -> GlobeItem? {
        switch f.kind {
        case "quake": return planet.quake(id: f.refId) != nil ? .quake(f.refId) : .spot(GeoPoint(lat: f.lat, lon: f.lon))
        case "launch": return planet.launch(id: f.refId) != nil ? .launch(f.refId) : nil
        case "aurora": return .aurora(north: f.refId != "aurora-south")
        case "sun", "asteroid", "satellite": return nil
        default:
            if planet.event(id: f.refId) != nil { return .event(f.refId) }
            return .spot(GeoPoint(lat: f.lat, lon: f.lon))
        }
    }

    /// Flies the globe to what an answer is about while it streams, at half sheet height.
    func showAskFocus(_ items: [APIClient.GlobeFocus]) {
        guard let first = items.first else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { askDetent = .medium }
        fly(toFocus: first)
    }

    func fly(toFocus f: APIClient.GlobeFocus) {
        let point = GeoPoint(lat: f.lat, lon: f.lon)
        if let item = globeItem(for: f) {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) { selection = item }
        }
        if ridingISS { stopRideAlong() }
        if replaying { stopReplay() }
        let distance = f.kind == "aurora" ? 3.6 : (f.kind == "sun" ? 6.0 : 2.5)
        focusAbovePanel(point, distance: distance)
    }

    /// Frames a point in the upper half of the screen, above a half-height sheet.
    func focusAbovePanel(_ point: GeoPoint, distance: Double) {
        // Seen from `distance` radii, a point this far south of the target sits about halfway up the upper half.
        let tanBeta = 0.5 * tan(GlobeRenderer.fovY / 2)
        var shift = 0.0
        for _ in 0..<8 { shift = asin(min(1, tanBeta * (distance - cos(shift)))) }
        let target = point.destination(bearing: 180, angle: min(shift, 0.6))
        globe.fly(to: CameraPose(lat: target.lat, lon: target.lon, distance: distance), duration: 2.2)
    }

    func coordinate(of item: GlobeItem) -> GeoPoint? {
        switch item {
        case .quake(let id): planet.quake(id: id)?.coordinate
        case .event(let id): planet.event(id: id)?.coordinate
        case .launch(let id): planet.launch(id: id)?.coordinate
        case .user: location.point
        case .spot(let p): p
        case .aurora(let north): GeoPoint(lat: north ? 68 : -68, lon: Geo.normalizeLon(Astro.subsolarPoint(Date()).lon + 180))
        case .satellite(let id):
            satellites.propagator(id: id).flatMap { try? $0.ecef(at: Date()) }.map { SatGeo.subpoint(ecef: $0).point }
        }
    }
}

private func MTLCreateSystemDefaultDeviceSafe() -> MTLDevice? { MTLCreateSystemDefaultDevice() }
