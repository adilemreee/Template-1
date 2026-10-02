import Foundation
import WidgetKit

@MainActor
enum WidgetBridge {
    private static var lastReload: Date = .distantPast

    /// Asks WidgetKit to refresh, at most every few minutes to respect its budget.
    static func reload(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastReload) > 300 else { return }
        lastReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
