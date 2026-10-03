import QuartzCore
import SwiftUI

/// Seismic waves racing out from an earthquake at 90× speed: the P front, the slower S front and
/// the surface waves, when each reaches you (felt as haptics as it passes), and how hard the
/// ground would shake where you are.
struct SeismicWavesOverlay: View {
    @Environment(AppModel.self) private var model
    let quake: Quake
    @State private var felt: Set<Seismology.Wave> = []

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { _ in
            let t = max(0, model.globe.seismicTime() ?? 0)
            let user = model.location.point
            let degrees = user.map { quake.coordinate.distanceKm(to: $0) / Seismology.kmPerDegree }
            VStack(spacing: 10) {
                header(t: t)
                Spacer()
                waveCard(t: t, degrees: degrees)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .onChange(of: Int(t)) { feelArrivals(t: t, degrees: degrees) }
            .onChange(of: model.globe.seismicFinished) { _, done in
                if done { model.stopSeismicWaves() }
            }
        }
    }

    private func header(t: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PulsingDot(color: Theme.quake)
                Text("SEISMIC WAVES · M\(Fmt.magnitude(quake.mag))").eyebrow(Theme.quakeColor(mag: quake.mag))
                Spacer()
                Button {
                    Haptics.shared.tap()
                    model.stopSeismicWaves()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(Text("Close"))
            }
            Text(quake.place)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Seismology.clock(t))
                    .font(.mono(30, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text("after the quake · 90× speed")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(16)
        .glassPanel(cornerRadius: 26)
        .padding(.top, 8)
    }

    private func waveCard(t: Double, degrees: Double?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            waveRow(.p, title: "P waves", detail: String(localized: "Compression · fastest, through the mantle"),
                    tint: Color(red: 0.55, green: 0.85, blue: 1), t: t, degrees: degrees)
            waveRow(.s, title: "S waves", detail: String(localized: "Shear · can't cross the liquid core"),
                    tint: Color(red: 1, green: 0.55, blue: 0.25), t: t, degrees: degrees)
            waveRow(.surface, title: "Surface waves", detail: String(localized: "Rolling · slowest, strongest shaking"),
                    tint: Color(red: 1, green: 0.85, blue: 0.45), t: t, degrees: degrees)
            Divider().overlay(Theme.hairline)
            if let degrees {
                let km = degrees * Seismology.kmPerDegree
                let mmi = Seismology.intensity(magnitude: quake.mag, distanceKm: km, depthKm: quake.depthKm)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "house.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ice)
                    Text(mmi < 1.5 ? String(localized: "Too far away to feel where you are")
                         : String(localized: "Shaking where you are: \(Seismology.shakingWord(mmi)) (\(Seismology.intensityRoman(mmi)))"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(footnote(degrees: degrees, km: km))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Share your location to see when the waves would reach you.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(16)
        .glassPanel(cornerRadius: 26)
    }

    private func waveRow(_ wave: Seismology.Wave, title: LocalizedStringKey, detail: String, tint: Color, t: Double, degrees: Double?) -> some View {
        let front = Seismology.front(wave, at: t)
        let arrival = degrees.map { Seismology.travelTime(wave, degrees: $0, depthKm: quake.depthKm) }
        let blocked = wave == .s && (degrees.map(Seismology.inShadowZone) ?? false)
        return HStack(spacing: 10) {
            Capsule().fill(tint).frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                if let arrival, !blocked {
                    if t >= arrival {
                        Text("reached you").font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                        Text(Seismology.clock(arrival)).font(.mono(13, weight: .bold)).foregroundStyle(.white)
                    } else {
                        Text("reaches you in").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        Text(Seismology.clock(arrival - t).dropFirst()).font(.mono(13, weight: .bold)).foregroundStyle(.white)
                            .contentTransition(.numericText(countsDown: true))
                    }
                } else if blocked {
                    Text("blocked by the core").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                } else {
                    Text("\(Int(front))°").font(.mono(13, weight: .bold)).foregroundStyle(.white)
                    Text("from the epicentre").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func footnote(degrees: Double, km: Double) -> String {
        let distance = Fmt.distance(km, units: model.settings.units)
        if Seismology.inShadowZone(degrees: degrees) {
            return String(localized: "You're \(distance) away, in the core's shadow: the direct P and S waves bend around Earth's core and miss you, so only weak diffracted waves arrive. Seismologists found the core this way in 1914.")
        }
        return String(localized: "You're \(distance) away. Estimate from the IASP91 Earth model and the USGS \"Did You Feel It?\" intensity relation; not an alert.")
    }

    /// Haptics as each front passes the user's location.
    private func feelArrivals(t: Double, degrees: Double?) {
        guard let degrees else { return }
        let mmi = Seismology.intensity(magnitude: quake.mag, distanceKm: degrees * Seismology.kmPerDegree, depthKm: quake.depthKm)
        for wave in Seismology.Wave.allCases where !felt.contains(wave) {
            if wave == .s && Seismology.inShadowZone(degrees: degrees) { continue }
            guard t >= Seismology.travelTime(wave, degrees: degrees, depthKm: quake.depthKm) else { continue }
            felt.insert(wave)
            switch wave {
            case .p: Haptics.shared.tap()
            case .s: Haptics.shared.seismic(magnitude: max(3, min(6.5, 2 + mmi * 0.55)))
            case .surface: Haptics.shared.thud()
            }
        }
    }
}
