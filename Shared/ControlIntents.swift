import AppIntents
import SwiftUI

/// Runs from the Planet Briefing control. It is compiled into both the app and the widget
/// extension so the system performs it inside the app (openAppWhenRun); custom URL schemes are
/// not reliable through OpenURLIntent, so the app routes its own deep link from here.
struct OpenBriefingControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Planet Briefing"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        EnvironmentValues().openURL(URL(string: "karman://briefing")!)
        return .result()
    }
}
