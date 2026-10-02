import SwiftUI

/// Wordmark that resolves letter by letter while the Sun rises over the limb.
struct IntroTitleView: View {
    let visible: Bool

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("KÁRMÁN")
                .font(.display(46, weight: .bold))
                .tracking(visible ? 16 : 30)
                .foregroundStyle(LinearGradient(colors: [.white, Color(red: 0.75, green: 0.9, blue: 1.0)], startPoint: .top, endPoint: .bottom))
                .shadow(color: Theme.ice.opacity(0.55), radius: 22)
                .textRenderer(StaggeredReveal(progress: visible ? 1 : 0))
            Text("THE LIVING PLANET · LIVE")
                .font(.label(11, weight: .semibold))
                .tracking(visible ? 5 : 1)
                .foregroundStyle(Theme.textSecondary)
                .opacity(visible ? 1 : 0)
                .blur(radius: visible ? 0 : 6)
            Spacer().frame(height: 150)
        }
        .animation(.easeOut(duration: 1.9), value: visible)
    }
}

/// Reveals glyphs one after another with a blur-to-sharp rise.
struct StaggeredReveal: TextRenderer, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        let slices = layout.flatMap { line in line.flatMap { run in run.map { $0 } } }
        let count = max(Double(slices.count), 1)
        for (i, slice) in slices.enumerated() {
            let start = Double(i) / count * 0.55
            let t = min(1, max(0, (progress - start) / 0.45))
            let eased = 1 - pow(1 - t, 3)
            var c = ctx
            c.opacity = eased
            if eased < 1 { c.addFilter(.blur(radius: (1 - eased) * 14)) }
            c.translateBy(x: 0, y: (1 - eased) * 18)
            c.draw(slice)
        }
    }
}
