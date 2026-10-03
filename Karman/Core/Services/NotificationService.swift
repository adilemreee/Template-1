import ActivityKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// Alert permissions, APNs registration with the Kármán API, local ISS pass reminders and deep links.
@MainActor
@Observable
final class NotificationService {
    static let shared = NotificationService()

    private(set) var authorized = false
    private(set) var deviceToken: String?
    var pendingDeepLink: (kind: String, id: String?)?

    weak var model: AppModel?

    func refreshStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        if authorized { UIApplication.shared.registerForRemoteNotifications() }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        authorized = granted
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        return granted
    }

    func didRegister(token: String) {
        deviceToken = token
        Task { await syncRegistration() }
    }

    /// Sends the (coarse) location and alert preferences to the API so it can push relevant events.
    func syncRegistration() async {
        guard let token = deviceToken, let model else { return }
        let prefs = model.settings.alerts
        #if DEBUG
        let env = "sandbox"
        #else
        let env = "production"
        #endif
        let p = model.location.point
        let reg = APIClient.DeviceRegistration(
            token: token, env: env, lat: p?.lat, lon: p?.lon,
            language: Locale.current.language.languageCode?.identifier ?? "en",
            tzOffsetMinutes: TimeZone.current.secondsFromGMT() / 60,
            prefs: .init(quakeMinMag: prefs.quakesNearby ? prefs.quakeMinMag : 0, quakeRadiusKm: prefs.quakeRadiusKm,
                         globalMajor: prefs.majorQuakes, aurora: prefs.aurora, auroraMinChance: prefs.auroraMinChance,
                         launches: prefs.launches, spaceStorms: prefs.spaceStorms))
        try? await APIClient.shared.register(device: reg)
    }

    // MARK: Local reminders

    func scheduleStationPasses(_ passes: [WidgetState.Pass], enabled: Bool) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("iss-") }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard enabled, authorized else { return }
        for pass in passes.prefix(6) where pass.start.timeIntervalSinceNow > 15 * 60 && pass.maxElevation >= 25 {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "\(pass.stationName) is about to pass over")
            let from = GeoPoint.compassName(pass.startAzimuth), to = GeoPoint.compassName(pass.endAzimuth)
            content.body = String(localized: "Look \(from) in 10 minutes. It climbs to \(Int(pass.maxElevation))° and sets in the \(to).")
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.threadIdentifier = "iss"
            content.userInfo = ["kind": "iss"]
            let fire = pass.start.addingTimeInterval(-10 * 60)
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
            let req = UNNotificationRequest(identifier: "iss-\(Int(pass.start.timeIntervalSince1970))", content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            try? await center.add(req)
        }
    }

    /// Starts a Lock Screen / Dynamic Island countdown for launches within the next 8 hours.
    func startLaunchActivity(_ launch: Launch) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              launch.net > Date(), launch.net.timeIntervalSinceNow < 8 * 3600,
              !Activity<LaunchActivityAttributes>.activities.contains(where: { $0.attributes.mission == launch.missionName }) else { return }
        let attributes = LaunchActivityAttributes(mission: launch.missionName, rocket: launch.rocket, provider: launch.provider, location: launch.location)
        let state = LaunchActivityAttributes.ContentState(net: launch.net, status: launch.status)
        _ = try? Activity.request(attributes: attributes,
                                  content: ActivityContent(state: state, staleDate: launch.net.addingTimeInterval(1800)))
    }

    func scheduleLaunchReminder(_ launch: Launch) async -> Bool {
        if !authorized { _ = await requestAuthorization() }
        guard authorized else { return false }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(launch.rocket) lifts off in 15 minutes")
        content.body = "\(launch.missionName) · \(launch.location)"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["kind": "launch", "id": launch.id]
        let fire = launch.net.addingTimeInterval(-15 * 60)
        guard fire > Date() else { return false }
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
        let req = UNNotificationRequest(identifier: "launch-\(launch.id)", content: content,
                                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        try? await UNUserNotificationCenter.current().add(req)
        startLaunchActivity(launch)
        return true
    }

    // MARK: Deep links

    func open(kind: String?, id: String?) {
        guard let kind else { return }
        if let model {
            route(kind: kind, id: id, model: model)
        } else {
            pendingDeepLink = (kind, id)
        }
    }

    func route(kind: String, id: String?, model: AppModel) {
        switch kind {
        case "quake": if let id { model.select(.quake(id)) }
        case "launch": if let id { model.select(.launch(id)) }
        case "aurora", "space": model.panel = .space
        case "iss": model.panel = .sky
        default: break
        }
    }
}
