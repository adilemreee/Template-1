import SwiftUI
import WidgetKit

/// Control Center, Lock Screen and Action button: open Kármán straight into the Planet Briefing.
struct BriefingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.adilemre.karman.control.briefing") {
            ControlWidgetButton(action: OpenBriefingControlIntent()) {
                Label("Planet Briefing", systemImage: "globe.europe.africa.fill")
            }
        }
        .displayName("Planet Briefing")
        .description("Play the narrated tour of what is happening on Earth right now.")
    }
}
