import StoreKit
import UIKit

/// Asks for an App Store rating at a genuinely good moment: just after a Planet Briefing has
/// played to the end, once Kármán has been opened on three different days, at most once per version.
@MainActor
enum ReviewPrompter {
    private static let defaults = UserDefaults.standard

    static func noteActiveDay() {
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var days = defaults.array(forKey: "review.days") as? [Double] ?? []
        guard !days.contains(today) else { return }
        days.append(today)
        defaults.set(Array(days.suffix(30)), forKey: "review.days")
    }

    static func briefingCompleted() {
        defaults.set(defaults.integer(forKey: "review.briefings") + 1, forKey: "review.briefings")
    }

    static func askIfAppropriate() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
        let days = (defaults.array(forKey: "review.days") as? [Double] ?? []).count
        guard defaults.integer(forKey: "review.briefings") >= 2, days >= 3,
              defaults.string(forKey: "review.askedVersion") != version,
              let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
        defaults.set(version, forKey: "review.askedVersion")
        AppStore.requestReview(in: scene)
    }
}
