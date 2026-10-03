import SwiftUI

/// Wordmark that resolves letter by letter while the Sun rises over the limb.
///
/// Each letter is its own view so blur and glow follow the glyph shapes; filters drawn inside
/// a TextRenderer are clipped to each glyph's box and showed up as a dark/light slab.
struct IntroTitleView: View {
    let visible: Bool

    private static let letters = Array("KÁRMÁN").map(String.init)

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                // Glow: a blurred, ice-coloured copy of the wordmark, shaped like the letters.
                wordmark(fill: AnyShapeStyle(Theme.ice))
                    .blur(radius: 12)
                    .opacity(visible ? 0.45 : 0)
                    .animation(.easeOut(duration: 2.4).delay(0.5), value: visible)
                wordmark(fill: AnyShapeStyle(LinearGradient(colors: [.white, Color(red: 0.75, green: 0.9, blue: 1.0)],
                                                             startPoint: .top, endPoint: .bottom)))
            }
            Text("THE LIVING PLANET · LIVE")
                .font(.label(11, weight: .semibold))
                .tracking(5)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
                .opacity(visible ? 1 : 0)
                .offset(y: visible ? 0 : 8)
                .animation(.easeOut(duration: 1.4).delay(visible ? 0.9 : 0), value: visible)
            Spacer().frame(height: 150)
        }
        .frame(maxWidth: .infinity)
    }

    private func wordmark(fill: AnyShapeStyle) -> some View {
        HStack(spacing: visible ? 16 : 24) {
            ForEach(Array(Self.letters.enumerated()), id: \.offset) { i, letter in
                Text(letter)
                    .font(.display(46, weight: .bold))
                    .foregroundStyle(fill)
                    .opacity(visible ? 1 : 0)
                    .blur(radius: visible ? 0 : 10)
                    .offset(y: visible ? 0 : 16)
                    .animation(.easeOut(duration: 1.3).delay(visible ? Double(i) * 0.11 : 0), value: visible)
            }
        }
        .animation(.easeOut(duration: 1.9), value: visible)
        .fixedSize()
    }
}
