import SwiftUI
import simd

/// Names the Moon beside its disc whenever it is on screen: its phase and how far away it is.
struct CosmicLabels: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let units = model.settings.units
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let phase = Astro.moonPhase(context.date)
            Canvas { ctx, size in
                let projection = model.globe.projection
                let moon = projection.moon
                let eye = projection.eye
                guard let pt = projection.screenPoint(moon) else { return }
                // Behind the Earth?
                let toMoon = moon - eye
                let distance = simd_length(toMoon)
                let dir = toMoon / distance
                let closest = simd_dot(-eye, dir)
                if closest > 0, closest < distance, simd_length(eye + dir * closest) < 1.02 { return }
                guard pt.x > 24, pt.x < size.width - 24, pt.y > 120, pt.y < size.height - 160 else { return }

                // Below the disc, whatever its apparent size.
                let radius = CGFloat(GlobeRenderer.moonRadius / Double(distance) / tan(GlobeRenderer.fovY / 2)) * size.height / 2
                var text = ctx
                text.addFilter(.shadow(color: .black.opacity(0.9), radius: 3))
                let title = Text("MOON").font(.label(10, weight: .bold)).tracking(1.6).foregroundStyle(.white.opacity(0.9))
                let detail = Text("\(phase.name) · \(Fmt.distance(phase.distanceKm, units: units))")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.62))
                text.draw(title, at: CGPoint(x: pt.x, y: pt.y + radius + 8), anchor: .top)
                text.draw(detail, at: CGPoint(x: pt.x, y: pt.y + radius + 22), anchor: .top)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
