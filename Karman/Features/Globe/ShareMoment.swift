import SwiftUI

/// A shareable postcard of the planet right now: the live render plus the day's numbers.
struct ShareMomentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let card: UIImage

    var body: some View {
        VStack(spacing: 18) {
            Text("SHARE THIS MOMENT").eyebrow(Theme.ice)
                .padding(.top, 24)
            Image(uiImage: card)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Theme.ice.opacity(0.25), radius: 30)
                .padding(.horizontal, 28)
            ShareLink(item: Image(uiImage: card), preview: SharePreview(Text("Earth, right now — Kármán"), image: Image(uiImage: card))) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal, 28)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PanelBackground())
    }
}

/// The postcard layout rendered with ImageRenderer (1080 × 1350, 4:5).
struct MomentCard: View {
    let globe: Image
    let date: Date
    let quakes: Int
    let storms: Int
    let kp: Double
    let place: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            globe
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 1080, height: 1350)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.92)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 18) {
                Text("EARTH · RIGHT NOW")
                    .font(.system(size: 30, weight: .bold).width(.expanded))
                    .tracking(6)
                    .foregroundStyle(Theme.ice)
                Text(date.formatted(.dateTime.day().month(.wide).year().hour().minute()))
                    .font(.system(size: 60, weight: .bold))
                    .foregroundStyle(.white)
                HStack(spacing: 44) {
                    stat("\(quakes)", String(localized: "earthquakes · 24h"))
                    stat("\(storms)", String(localized: "storms"))
                    stat(kp.formatted(.number.precision(.fractionLength(1))), "Kp")
                }
                HStack {
                    if let place {
                        Label(place, systemImage: "location.fill")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Text("KÁRMÁN")
                        .font(.system(size: 34, weight: .heavy).width(.expanded))
                        .tracking(10)
                        .foregroundStyle(.white)
                }
                .padding(.top, 10)
            }
            .padding(64)
        }
        .frame(width: 1080, height: 1350)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 54, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text(label).font(.system(size: 24, weight: .medium)).foregroundStyle(.white.opacity(0.6))
        }
    }
}

extension AppModel {
    /// Captures the globe (without the HUD) and composes the postcard.
    func shareMoment() {
        Haptics.shared.tap()
        globe.captureRequest = { [weak self] cg in
            guard let self, let cg else { return }
            let card = MomentCard(globe: Image(decorative: cg, scale: 1), date: Date(),
                                  quakes: self.planet.quakesLast24h.count, storms: self.planet.activeStorms.count,
                                  kp: self.planet.snapshot.space?.kpNow ?? 0, place: self.location.placeName)
            let renderer = ImageRenderer(content: card)
            renderer.scale = 1
            if let image = renderer.uiImage {
                self.shareCard = image
            }
        }
    }
}
