import Charts
import SwiftUI

/// Something the Sky Lens can point you to.
enum SkyTarget: Hashable, Sendable {
    case planet(Planets.Body)
    case moon
    case star(String)
    case constellation(String)
    case station(Int)
    case radiant(String)
}

extension Planets.Body {
    var color: Color {
        switch self {
        case .mercury: Color(red: 0.78, green: 0.74, blue: 0.70)
        case .venus: Color(red: 1.0, green: 0.95, blue: 0.80)
        case .mars: Color(red: 1.0, green: 0.52, blue: 0.36)
        case .jupiter: Color(red: 0.96, green: 0.86, blue: 0.70)
        case .saturn: Color(red: 0.96, green: 0.84, blue: 0.56)
        }
    }
}

// MARK: - Stargazing score

/// Tonight's stargazing outlook: an hourly score from darkness, cloud cover and moonlight.
struct StargazingCard: View {
    @Environment(AppModel.self) private var model
    let observer: GeoPoint

    var body: some View {
        let hours = Stargazing.forecast(observer: observer, clouds: model.sky.clouds)
        let window = Stargazing.bestWindow(hours)
        let best = window?.score ?? hours.map(\.score).max() ?? 0
        Card {
            HStack {
                Text("STARGAZING TONIGHT").eyebrow(Theme.ice)
                Spacer()
                if model.sky.isLoading {
                    ProgressView().controlSize(.mini)
                } else if !model.sky.clouds.isEmpty {
                    Label("Clouds: MET Norway", systemImage: "cloud.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            HStack(spacing: 16) {
                ScoreRing(score: best)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Stargazing.verdict(best)).font(.display(22, weight: .bold)).foregroundStyle(.white)
                    if let window {
                        Text("Best \(Fmt.time(window.start))–\(Fmt.time(window.end))")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.ice)
                    }
                    Text(summary(hours: hours))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Chart(hours) { h in
                BarMark(x: .value("hour", h.date, unit: .hour), y: .value("score", max(h.score, 2)))
                    .foregroundStyle(Self.color(h.score).gradient)
                    .cornerRadius(3)
            }
            .chartYScale(domain: 0...100)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                    AxisValueLabel(format: .dateTime.hour(), centered: true)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(height: 74)
            .accessibilityLabel(Text("Hourly stargazing score"))
            if let overhead = SkyCatalog.bundled?.overhead(observer: observer, at: window?.start ?? hours.first?.date ?? Date()), !overhead.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Overhead").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        ForEach(overhead, id: \.0.id) { c, _ in
                            Button {
                                model.openSkyLens(target: .constellation(c.id))
                            } label: {
                                Text(c.meaning.map { "\(c.name) · \($0)" } ?? c.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color.white.opacity(0.07)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .task(id: Int(observer.lat * 2) * 1000 + Int(observer.lon * 2)) {
            await model.sky.refresh(for: observer)
        }
    }

    private func summary(hours: [Stargazing.Hour]) -> String {
        let night = hours.filter { $0.sunAltitude < -12 }
        guard !night.isEmpty else { return String(localized: "The sky doesn't get properly dark in the next hours.") }
        var parts: [String] = []
        if let clouds = night.compactMap(\.cloud).max() {
            let mean = night.compactMap(\.cloud).reduce(0, +) / Double(max(1, night.compactMap(\.cloud).count))
            parts.append(mean < 20 ? String(localized: "Mostly clear") : (mean < 60 ? String(localized: "Some cloud") : (clouds > 90 ? String(localized: "Overcast") : String(localized: "Cloudy"))))
        } else if model.sky.failed {
            parts.append(String(localized: "No cloud forecast"))
        }
        let phase = Astro.moonPhase(night[night.count / 2].date)
        if phase.illumination > 0.6, night.contains(where: { $0.moonAltitude > 10 }) {
            parts.append(String(localized: "a bright Moon washes out faint stars"))
        } else if phase.illumination < 0.25 || !night.contains(where: { $0.moonAltitude > 0 }) {
            parts.append(String(localized: "dark, moonless hours"))
        }
        return parts.joined(separator: ", ").capitalizingFirst
    }

    static func color(_ score: Int) -> Color {
        switch score {
        case 75...: Theme.aurora
        case 50..<75: Theme.ice
        case 25..<50: Color(red: 0.55, green: 0.55, blue: 0.85)
        default: Color.white.opacity(0.18)
        }
    }
}

private struct ScoreRing: View {
    let score: Int

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 7)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(StargazingCard.color(score).gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)").font(.display(24, weight: .bold)).foregroundStyle(.white).contentTransition(.numericText())
        }
        .frame(width: 72, height: 72)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Stargazing score \(score) out of 100"))
    }
}

private extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Planets

struct PlanetsCard: View {
    @Environment(AppModel.self) private var model
    let observer: GeoPoint

    var body: some View {
        let tonight = Planets.tonight(observer: observer).sorted { a, b in
            if a.isVisible != b.isVisible { return a.isVisible }
            return (a.visibleFrom ?? .distantFuture) < (b.visibleFrom ?? .distantFuture)
        }
        Card {
            HStack {
                Text("PLANETS TONIGHT").eyebrow(Theme.sun)
                Spacer()
                Text("\(tonight.filter(\.isVisible).count) of 5 visible")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(tonight) { v in
                Button {
                    model.openSkyLens(target: .planet(v.body))
                } label: {
                    row(v)
                }
                .buttonStyle(.plain)
                .disabled(!v.isVisible)
                if v.id != tonight.last?.id { Divider().overlay(Theme.hairline) }
            }
        }
    }

    private func row(_ v: Planets.Visibility) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(RadialGradient(colors: [v.body.color, v.body.color.opacity(0.35)], center: .init(x: 0.35, y: 0.35), startRadius: 1, endRadius: 14))
                .frame(width: 22, height: 22)
                .shadow(color: v.body.color.opacity(v.isVisible ? 0.6 : 0), radius: 6)
                .opacity(v.isVisible ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                Text(v.body.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(v.isVisible ? .white : Theme.textTertiary)
                Text("In \(v.constellation) · mag \(v.magnitude.formatted(.number.precision(.fractionLength(1))))")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 6)
            if let from = v.visibleFrom, let until = v.visibleUntil, let best = v.bestTime {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Fmt.time(from))–\(Fmt.time(until))").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    Text("\(Int(v.bestAltitude))° \(GeoPoint.compassName(v.bestAzimuth)) at \(Fmt.time(best))")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                Image(systemName: "scope").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ice)
            } else {
                Text("Not visible tonight").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(v.isVisible ? "Find it with the Sky Lens" : ""))
    }
}

// MARK: - Meteor showers

struct MeteorShowersCard: View {
    @Environment(AppModel.self) private var model
    let observer: GeoPoint

    var body: some View {
        let upcoming = Array(MeteorShowers.upcoming().prefix(3))
        if !upcoming.isEmpty {
            Card {
                Text("METEOR SHOWERS").eyebrow(Theme.auroraViolet)
                ForEach(upcoming) { o in
                    showerRow(o)
                    if o.id != upcoming.last?.id { Divider().overlay(Theme.hairline) }
                }
                Text("Rates assume a dark sky far from city lights. IMO meteor shower calendar.")
                    .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func showerRow(_ o: MeteorShowers.Outlook) -> some View {
        let peakNight = Planets.night(observer: observer, from: o.peak.addingTimeInterval(-12 * 3600))
        let best = MeteorShowers.bestTime(o.shower, observer: observer, night: peakNight)
        let rate = best.map { MeteorShowers.expectedRate(o.shower, at: $0.date, observer: observer) } ?? 0
        return Button {
            model.openSkyLens(target: .radiant(o.shower.id))
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.auroraViolet)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(o.shower.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        if o.isActive {
                            Text("ACTIVE").font(.label(9)).foregroundStyle(Theme.aurora)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.aurora.opacity(0.15)))
                        }
                    }
                    Text("Peaks \(o.peak.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · up to \(Int(o.shower.zhr)) an hour · from \(o.shower.parent)")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let best {
                        Text(String(localized: "Best around \(Fmt.time(best.date)): about \(Int(rate.rounded())) an hour from here") + (o.moonIllumination > 0.5 ? String(localized: ", but a \(Int(o.moonIllumination * 100))% Moon will hide the faint ones") : ""))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Its radiant stays low from your latitude.")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "scope").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ice).padding(.top, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

// MARK: - Sky Lens entry

struct SkyLensCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.openSkyLens(target: nil)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Theme.ice.opacity(0.14)).frame(width: 50, height: 50)
                    Image(systemName: "scope").font(.system(size: 21, weight: .semibold)).foregroundStyle(Theme.ice)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("SKY LENS").eyebrow(Theme.ice)
                    Text("Point your phone at the sky").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    Text("Stars, planets, constellations and the ISS, labelled live")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1).minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.textTertiary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
