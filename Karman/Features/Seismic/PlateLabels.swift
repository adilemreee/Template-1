import SwiftUI

/// Names of the major tectonic plates, floating over the globe while the plate layer is on.
struct PlateLabels: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let plates = PlateBoundaries.bundled?.plates ?? []
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            Canvas { ctx, _ in
                let projection = model.globe.projection
                for plate in plates {
                    let p = plate.point.unitVectorF * 1.01
                    guard let pt = projection.project(p) else { continue }
                    let alpha = Double(max(0, min(1, (projection.facing(p) - 0.2) / 0.3)))
                    guard alpha > 0.02 else { continue }
                    let label = Text(plate.name.uppercased())
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(2.2)
                        .foregroundStyle(.white.opacity(0.5 * alpha))
                    ctx.draw(label, at: pt)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// What the plate boundary colours mean.
struct PlatesLegend: View {
    static let spreading = Color(red: 0.58, green: 0.93, blue: 1.0)
    static let colliding = Color(red: 1.0, green: 0.60, blue: 0.48)
    static let sliding = Color(red: 1.0, green: 0.92, blue: 0.62)

    var body: some View {
        HStack(spacing: 12) {
            item("Spreading", Self.spreading)
            item("Colliding", Self.colliding)
            item("Sliding", Self.sliding)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func item(_ title: LocalizedStringKey, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 14, height: 3)
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// The tectonic setting of an earthquake: the nearest plate boundary and what happens there.
struct TectonicSettingCard: View {
    let quake: Quake

    var body: some View {
        let nearest = PlateBoundaries.bundled?.nearest(to: quake.coordinate, maxKm: 400)
        Card {
            Text("TECTONIC SETTING").eyebrow()
            if let nearest {
                HStack(spacing: 8) {
                    Capsule().fill(Self.color(nearest.kind)).frame(width: 18, height: 4)
                    Text(nearest.kind.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Spacer(minLength: 0)
                    Text(nearest.km < 15 ? String(localized: "on it") : String(localized: "\(Int(nearest.km)) km away"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(nearest.kind.explanation + (quake.depthKm > 70 && nearest.kind == .convergent
                        ? " " + String(localized: "At \(Int(quake.depthKm)) km deep, this one likely broke inside the sinking slab itself.")
                        : ""))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Far from any plate boundary: an intraplate earthquake, where stress builds up inside a plate instead of at its edge.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Plate boundaries: P. Bird (2003), PB2002")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    static func color(_ kind: PlateBoundaries.Kind) -> Color {
        switch kind {
        case .divergent: PlatesLegend.spreading
        case .convergent: PlatesLegend.colliding
        case .transform: PlatesLegend.sliding
        }
    }
}
