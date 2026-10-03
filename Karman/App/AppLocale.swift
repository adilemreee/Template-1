import Foundation

/// Kármán is English-only. On devices whose region formats numbers or dates differently, the
/// app pins its own locale to British English (24-hour clock, decimal point, English names) so it
/// never mixes languages, like "M5,8" or Turkish weekday names. Only this app is affected.
enum AppLocale {
    private static let overrideKey = "karman.localeOverride"
    private static let imperialKey = "karman.deviceImperial"

    /// Whether the device's own region measures in miles (for the default units setting).
    static var deviceUsesImperial: Bool {
        UserDefaults.standard.object(forKey: imperialKey) as? Bool ?? (Locale.current.measurementSystem == .us)
    }

    /// Call before anything formats a date or number (first thing at launch).
    static func apply() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: overrideKey) else { return } // already pinned on an earlier launch
        // Read the region without touching Locale.current, which would cache it before the override.
        let device = Locale(identifier: defaults.string(forKey: "AppleLocale") ?? Locale.preferredLanguages.first ?? "en_US")
        defaults.set(device.measurementSystem == .us, forKey: imperialKey)
        let english = device.language.languageCode?.identifier == "en" && device.decimalSeparator == "."
        guard !english else { return }
        defaults.set("en_GB", forKey: "AppleLocale")
        defaults.set(true, forKey: overrideKey)
    }
}
