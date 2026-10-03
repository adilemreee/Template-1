import SwiftUI

enum Theme {
    // Core palette
    static let space = Color(red: 0.012, green: 0.016, blue: 0.031)
    static let ink = Color(red: 0.04, green: 0.055, blue: 0.09)
    static let ice = Color(red: 0.50, green: 0.83, blue: 1.0)
    static let aurora = Color(red: 0.24, green: 1.0, blue: 0.63)
    static let auroraViolet = Color(red: 0.72, green: 0.45, blue: 1.0)
    static let quake = Color(red: 1.0, green: 0.36, blue: 0.20)
    static let quakeWarm = Color(red: 1.0, green: 0.56, blue: 0.24)
    static let fire = Color(red: 1.0, green: 0.48, blue: 0.10)
    static let storm = Color(red: 0.79, green: 0.66, blue: 1.0)
    static let volcano = Color(red: 1.0, green: 0.35, blue: 0.29)
    static let launch = Color(red: 1.0, green: 0.86, blue: 0.62)
    static let sun = Color(red: 1.0, green: 0.80, blue: 0.40)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)
    static let hairline = Color.white.opacity(0.10)

    static func color(for kind: EventKind) -> Color {
        switch kind {
        case .wildfire: fire
        case .storm: storm
        case .volcano: volcano
        case .ice, .snow: Color(red: 0.66, green: 0.9, blue: 1.0)
        case .flood: Color(red: 0.35, green: 0.7, blue: 1.0)
        case .dust, .drought: Color(red: 0.91, green: 0.76, blue: 0.48)
        case .heat: Color(red: 1.0, green: 0.6, blue: 0.35)
        case .landslide, .other: Color(white: 0.8)
        }
    }

    static func quakeColor(mag: Double) -> Color {
        switch mag {
        case 7...: Color(red: 1.0, green: 0.18, blue: 0.25)
        case 6..<7: Color(red: 1.0, green: 0.30, blue: 0.20)
        case 5..<6: quake
        case 4..<5: quakeWarm
        default: Color(red: 1.0, green: 0.78, blue: 0.45)
        }
    }

    static func kpColor(_ kp: Double) -> Color {
        switch kp {
        case 7...: Color(red: 1.0, green: 0.25, blue: 0.45)
        case 5..<7: auroraViolet
        case 4..<5: aurora
        default: ice
        }
    }
}

extension Font {
    /// Wide display face used for big numerals and headlines.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default).width(.expanded)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func label(_ size: CGFloat = 11, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }
}

extension View {
    /// Small uppercase tracking label used throughout the HUD.
    func eyebrow(_ color: Color = Theme.textSecondary) -> some View {
        self.font(.label(10.5)).tracking(1.6).textCase(.uppercase).foregroundStyle(color)
    }

    /// Primary call to action: tinted Liquid Glass with a dark, high-contrast label
    /// (Kármán's accent colours are light, so white text would wash out).
    func primaryAction(_ tint: Color = Theme.ice) -> some View {
        self.buttonStyle(.glassProminent).tint(tint).foregroundStyle(Theme.ink)
    }

    /// Glass panel (Liquid Glass on iOS 26).
    func glassPanel(cornerRadius: CGFloat = 26, tint: Color? = nil, interactive: Bool = false) -> some View {
        self.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.18)).interactive(interactive) } ?? Glass.regular.interactive(interactive),
                         in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
