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

struct OpenSkyLensIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Sky Lens"
    static let description = IntentDescription("Point your phone at the sky to name the stars, planets, constellations and space stations.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await UIApplication.shared.open(URL(string: "karman://lens")!)
        return .result()
    }
}

struct YearOfQuakesIntent: AppIntent {
    static let title: LocalizedStringResource = "Watch a Year of Earthquakes"
    static let description = IntentDescription("Plays the last 365 days of strong earthquakes in under a minute.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await UIApplication.shared.open(URL(string: "karman://year")!)
        return .result()
    }
}

struct WeatherForecastIntent: AppIntent {
    static let title: LocalizedStringResource = "Play the Wind Forecast"
    static let description = IntentDescription("Shows live winds on the globe and plays the next 24 hours.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await UIApplication.shared.open(URL(string: "karman://weather")!)
        return .result()
    }
}

struct AmbientGlobeIntent: AppIntent {
    static let title: LocalizedStringResource = "Start the Ambient Globe"
    static let description = IntentDescription("A slowly turning, dimmed globe with a clock, for your nightstand.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await UIApplication.shared.open(URL(string: "karman://ambient")!)
        return .result()
    }
}

struct InsideEarthIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Inside the Earth"
    static let description = IntentDescription("Slices the globe open to show the crust, mantle and core.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await UIApplication.shared.open(URL(string: "karman://inside")!)
        return .result()
    }
}

struct SolarSystemIntent: AppIntent {
    static let title: LocalizedStringResource = "Show the Solar System"
    static let description = IntentDescription("Shows where the eight planets are around the Sun right now.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await UIApplication.shared.open(URL(string: "karman://orrery")!)
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
        AppShortcut(intent: OpenSkyLensIntent(),
                    phrases: ["Open the Sky Lens in \(.applicationName)", "What's that star with \(.applicationName)", "Find the planets with \(.applicationName)"],
                    shortTitle: "Sky Lens", systemImageName: "scope")
        AppShortcut(intent: YearOfQuakesIntent(),
                    phrases: ["Show a year of earthquakes in \(.applicationName)"],
                    shortTitle: "A Year of Quakes", systemImageName: "globe.asia.australia.fill")
        AppShortcut(intent: WeatherForecastIntent(),
                    phrases: ["Play the wind forecast in \(.applicationName)", "Show the weather on the globe in \(.applicationName)"],
                    shortTitle: "Wind Forecast", systemImageName: "wind")
        AppShortcut(intent: AmbientGlobeIntent(),
                    phrases: ["Start the ambient globe in \(.applicationName)", "Nightstand mode in \(.applicationName)"],
                    shortTitle: "Ambient Globe", systemImageName: "moon.zzz.fill")
        // Apple allows ten app shortcuts; this is the tenth.
        AppShortcut(intent: InsideEarthIntent(),
                    phrases: ["Show inside the Earth in \(.applicationName)", "Slice the planet open in \(.applicationName)"],
                    shortTitle: "Inside the Earth", systemImageName: "circle.circle.fill")
    }
}
