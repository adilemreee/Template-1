import AppIntents
import UIKit

/// Siri, Spotlight, Shortcuts and the Action button can start a briefing or open a panel.
struct PlayBriefingIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Planet Briefing"
    static let description = IntentDescription("Starts Kármán's narrated tour of what is happening on Earth right now.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await UIApplication.shared.open(URL(string: "karman://briefing")!)
        return .result()
    }
}

struct RideWithISSIntent: AppIntent {
    static let title: LocalizedStringResource = "Ride with the ISS"
    static let description = IntentDescription("Flies the camera along with the International Space Station.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await UIApplication.shared.open(URL(string: "karman://ride")!)
        return .result()
    }
}

struct ReplayDayIntent: AppIntent {
    static let title: LocalizedStringResource = "Replay the Last 24 Hours"
    static let description = IntentDescription("Replays the last day on the globe, with every earthquake as it happened.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await UIApplication.shared.open(URL(string: "karman://replay")!)
        return .result()
    }
}

struct OpenSpaceWeatherIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Space Weather"
    static let description = IntentDescription("Opens the live Sun, Kp index and your aurora chances.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await UIApplication.shared.open(URL(string: "karman://space")!)
        return .result()
    }
}

struct OpenTonightsSkyIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Tonight's Sky"
    static let description = IntentDescription("Opens space station passes, the Moon and twilight times for your location.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await UIApplication.shared.open(URL(string: "karman://sky")!)
        return .result()
    }
}

struct KarmanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayBriefingIntent(),
                    phrases: ["Play the planet briefing in \(.applicationName)", "What's happening on Earth with \(.applicationName)"],
                    shortTitle: "Planet Briefing", systemImageName: "play.circle.fill")
        AppShortcut(intent: OpenSpaceWeatherIntent(),
                    phrases: ["Show space weather in \(.applicationName)", "Aurora chances in \(.applicationName)"],
                    shortTitle: "Space Weather", systemImageName: "sun.max.fill")
        AppShortcut(intent: ReplayDayIntent(),
                    phrases: ["Replay the last day in \(.applicationName)", "Replay Earth's day in \(.applicationName)"],
                    shortTitle: "Replay 24 Hours", systemImageName: "clock.arrow.circlepath")
        AppShortcut(intent: RideWithISSIntent(),
                    phrases: ["Ride with the ISS in \(.applicationName)", "Fly with the space station in \(.applicationName)"],
                    shortTitle: "Ride with the ISS", systemImageName: "airplane.departure")
        AppShortcut(intent: OpenTonightsSkyIntent(),
                    phrases: ["Show tonight's sky in \(.applicationName)", "When is the space station visible in \(.applicationName)"],
                    shortTitle: "Tonight's Sky", systemImageName: "moon.stars.fill")
    }
}
