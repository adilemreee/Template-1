#if DEBUG
import Foundation
import SwiftUI

/// Debug-only helper that puts the app into a named state so App Store screenshots are
/// reproducible: launch with KARMAN_SCREEN=<scene>.
@MainActor
enum ScreenshotDirector {
    static func prepare(_ model: AppModel) {
        var layers = GlobeLayers()
        layers.starlink = model.screenshotScene == "starlink"
        layers.liveImagery = model.screenshotScene == "realearth"
        model.applyLayers(layers)
    }

    /// A flattering hero framing: centred just inside the night side so city lights and the
    /// sunlit limb share the frame.
    static func heroPose() -> CameraPose {
        let sun = Astro.subsolarPoint(Date())
        return CameraPose(lat: 22, lon: Geo.normalizeLon(sun.lon - 104), distance: 6.5)
    }

    static func run(_ model: AppModel) async {
        // KARMAN_SHIFT_HOURS=-6 lights the scene as it was six hours ago (e.g. a storm in daylight).
        if let shift = ProcessInfo.processInfo.environment["KARMAN_SHIFT_HOURS"].flatMap(Double.init) {
            model.globe.freezeTime(at: Date().addingTimeInterval(shift * 3600))
        }
        if ["hero", "starlink", "briefing", "pulse"].contains(model.screenshotScene ?? "") {
            model.globe.set(pose: heroPose())
            model.globe.homePose = heroPose()
        }
        try? await Task.sleep(for: .seconds(2.5))
        switch model.screenshotScene {
        case "briefing":
            BriefingDirector.shared.start(model: model)
        case "quake":
            if let q = model.planet.strongestRecentQuake {
                model.select(.quake(q.id))
                try? await Task.sleep(for: .seconds(3.2))
                model.detailItem = .quake(q.id)
            }
        case "quakeglobe":
            if let q = model.planet.strongestRecentQuake { model.select(.quake(q.id)) }
        case "storm":
            // KARMAN_STORM=<name fragment> picks a particular storm (e.g. one on the day side).
            let wanted = ProcessInfo.processInfo.environment["KARMAN_STORM"]?.lowercased()
            let storm = wanted.flatMap { w in model.planet.activeStorms.first { $0.title.lowercased().contains(w) } }
            if let s = storm ?? model.planet.activeStorms.first {
                model.select(.event(s.id), fly: false)
                model.globe.fly(to: CameraPose(lat: s.lat - 4, lon: s.lon, distance: 1.9, tilt: 30, heading: -15), duration: 2.5)
            }
        case "space": model.panel = .space
        case "sky": model.panel = .sky
        case "ask":
            model.settings.askConsent = true
            model.panel = .ask
        case "askconsent":
            model.settings.askConsent = false
            model.panel = .ask
        case "pulse": model.panel = .pulse
        case "realearth":
            let sun = Astro.subsolarPoint(Date())
            model.globe.fly(to: CameraPose(lat: max(-30, min(40, sun.lat + 12)), lon: Geo.normalizeLon(sun.lon - 35), distance: 4.6, tilt: 0, heading: 0), duration: 2.5)
        case "pose":
            // KARMAN_POSE="lat,lon,distance[,tilt,heading]" flies anywhere (close-up checks).
            let v = (ProcessInfo.processInfo.environment["KARMAN_POSE"] ?? "").split(separator: ",").compactMap { Double($0) }
            if v.count >= 3 {
                model.globe.fly(to: CameraPose(lat: v[0], lon: v[1], distance: v[2], tilt: v.count > 3 ? v[3] : 0,
                                               heading: v.count > 4 ? v[4] : 0), duration: 2.5)
            }
        case "replay":
            model.startReplay()
        case "ride":
            model.startRideAlong()
        case "iss":
            model.select(.satellite(25544))
        case "liveactivity":
            if var next = model.planet.upcomingLaunches.first {
                next.net = Date().addingTimeInterval(2 * 3600 + 17 * 60)
                NotificationService.shared.startLaunchActivity(next)
            }
        default: break
        }
    }
}
#endif
