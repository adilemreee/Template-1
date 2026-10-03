import SwiftUI
import WidgetKit

struct PlanetEntry: TimelineEntry {
    let date: Date
    let state: WidgetState
    let globe: CGImage?
}

/// Builds timelines from the state the app shares, refreshing it from the API when stale,
/// and renders the Earth for each entry with the correct day/night terminator.
struct PlanetProvider: TimelineProvider {
    var renderGlobe = true

    func placeholder(in context: Context) -> PlanetEntry {
        PlanetEntry(date: Date(), state: .placeholder, globe: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (PlanetEntry) -> Void) {
        // The gallery preview may use sample data; real timelines never do.
        let state = WidgetState.load() ?? .placeholder
        let size = globeSize(for: context)
        let image = renderGlobe ? WidgetEarth.render(state: state, date: Date(), size: size) : nil
        completion(PlanetEntry(date: Date(), state: state, globe: image))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlanetEntry>) -> Void) {
        let size = globeSize(for: context)
        let render = renderGlobe
        let done = UncheckedBox(value: completion)
        Task {
            var state = WidgetState.load() ?? .empty
            if Date().timeIntervalSince(state.updatedAt) > 40 * 60, let fresh = await WidgetRefresher.refresh(state) {
                state = fresh
                fresh.save()
            }
            let now = Date()
            var entries: [PlanetEntry] = []
            for i in 0..<6 {
                let d = now.addingTimeInterval(Double(i) * 20 * 60)
                entries.append(PlanetEntry(date: d, state: state, globe: render ? WidgetEarth.render(state: state, date: d, size: size) : nil))
            }
            done.value(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
        }
    }

    private func globeSize(for context: Context) -> Int {
        let h = context.displaySize.height
        let w = context.displaySize.width
        let side: CGFloat = switch context.family {
        case .systemSmall: min(w, h)
        case .systemMedium: h
        case .systemLarge: min(w, h) * 0.7
        default: min(w, h)
        }
        return Int(max(120, min(side * 2.2, 460)))
    }
}

struct UncheckedBox<T>: @unchecked Sendable { let value: T }

enum WidgetEarth {
    nonisolated(unsafe) private static var day: OrthoSphere.Texture? = {
        Bundle.main.url(forResource: "widget_day", withExtension: "jpg").flatMap { OrthoSphere.loadTexture(url: $0, gray: false) }
    }()
    nonisolated(unsafe) private static var lights: OrthoSphere.Texture? = {
        Bundle.main.url(forResource: "widget_lights", withExtension: "jpg").flatMap { OrthoSphere.loadTexture(url: $0, gray: true) }
    }()

    static func render(state: WidgetState, date: Date, size: Int) -> CGImage? {
        guard let day else { return nil }
        let center = state.location.map { GeoPoint(lat: max(-50, min(50, $0.lat - 8)), lon: $0.lon) } ?? GeoPoint(lat: 20, lon: Astro.subsolarPoint(date).lon)
        let sun = Astro.subsolarPoint(date).unitVector
        var markers: [OrthoSphere.Marker] = state.recentQuakes.prefix(40).map {
            OrthoSphere.Marker(point: GeoPoint(lat: $0.lat, lon: $0.lon), color: SIMD3(1.0, 0.45, 0.2), radius: Double(size) / 220 * max(1, $0.mag - 3.2))
        }
        if let loc = state.location {
            markers.append(OrthoSphere.Marker(point: loc, color: SIMD3(0.4, 0.8, 1.0), radius: Double(size) / 140))
        }
        return OrthoSphere.render(size: size, day: day, nightLights: lights, center: center, light: sun, atmosphere: true, markers: markers, ambient: 0.05)
    }
}

/// Lets a widget refresh itself when the app has not run for a while.
enum WidgetRefresher {
    static func refresh(_ old: WidgetState) async -> WidgetState? {
        guard let (snap, _, _) = try? await APIClient.shared.snapshot(etag: nil) else { return nil }
        var s = old
        let day = Date().addingTimeInterval(-86400)
        s.updatedAt = Date()
        s.kp = snap.space?.kpNow ?? s.kp
        s.gScale = snap.space?.gScale ?? s.gScale
        s.windSpeed = snap.space?.windSpeed ?? s.windSpeed
        s.bz = snap.space?.bz ?? s.bz
        let recent = snap.quakes.filter { $0.time > day }
        s.quakes24h = recent.count
        if let top = recent.max(by: { $0.mag < $1.mag }) {
            s.topQuake = WidgetState.TopQuake(id: top.id, mag: top.mag, place: top.place, time: top.time, distanceKm: s.location.map { top.coordinate.distanceKm(to: $0) })
        }
        s.recentQuakes = recent.filter { $0.mag >= 3.5 }.prefix(80).map { WidgetState.QuakeDot(lat: $0.lat, lon: $0.lon, mag: $0.mag, time: $0.time) }
        if let loc = s.location, let grid = snap.aurora?.decoded() {
            s.auroraChance = AuroraMath.visibleChance(grid: grid, width: 360, at: loc)
        }
        if let next = snap.launches.filter({ $0.net > Date() }).min(by: { $0.net < $1.net }) {
            s.nextLaunch = WidgetState.NextLaunch(name: next.missionName, rocket: next.rocket, provider: next.provider, net: next.net, location: next.location)
        }
        return s
    }
}
