import Charts
import SwiftUI

struct SpaceWeatherView: View {
    @Environment(AppModel.self) private var model
    @State private var north = true

    var body: some View {
        let space = model.planet.snapshot.space
        let chance = model.planet.auroraChance(at: model.location.point)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SPACE WEATHER").eyebrow(Theme.sun)
                    Text("The Sun–Earth connection").font(.display(26, weight: .bold)).foregroundStyle(.white)
                }

                SunViewer()

                HStack(alignment: .top, spacing: 12) {
                    KpGauge(kp: space?.kpNow ?? 0, gScale: space?.gScale ?? 0)
                        .frame(maxWidth: .infinity)
                    AuroraChanceCard(chance: chance, place: model.location.placeName)
                        .frame(maxWidth: .infinity)
                }

                Card {
                    HStack {
                        Text("AURORAL OVAL · LIVE").eyebrow(Theme.aurora)
                        Spacer()
                        Picker("", selection: $north) {
                            Text("North").tag(true)
                            Text("South").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }
                    AuroraPolarMap(grid: model.planet.auroraGrid, north: north, user: model.location.point, date: Date())
                        .padding(.vertical, 6)
                    Text("NOAA OVATION model. Green shows where aurora is likely right now; you can often see it low on the horizon up to ~1,000 km away.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }

                if let space { SolarWindCard(space: space) }
                if let space { XrayCard(space: space) }
                if let fc = space?.kpForecast, !fc.isEmpty { KpForecastCard(forecast: fc) }
                if let alerts = space?.alerts, !alerts.isEmpty { AlertsCard(alerts: alerts) }

                Text("Data: NOAA Space Weather Prediction Center · GOES-19 · DSCOVR/ACE/IMAP")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(PanelBackground())
        .onAppear {
            if let user = model.location.point { north = user.lat >= 0 }
        }
    }
}

// MARK: - Live Sun

/// The live Sun from GOES-19 SUVI: the latest frame at once, then the last six hours as a
/// time-lapse. Frames are added as light onto a deep-space backdrop, so the image's black
/// surroundings vanish instead of showing as a pasted square.
struct SunViewer: View {
    @State private var band = "304"
    @State private var stills: [String: UIImage] = [:]
    @State private var loop: (band: String, frames: [UIImage], times: [Date])?
    @State private var observed: Date?
    @State private var failed = false
    @State private var playing = true

    private let bands: [(id: String, name: LocalizedStringKey, tint: Color)] = [
        ("304", "Chromosphere", Color(red: 1, green: 0.45, blue: 0.2)),
        ("171", "Corona", Color(red: 1, green: 0.82, blue: 0.3)),
        ("195", "Hot corona", Color(red: 0.75, green: 0.9, blue: 0.45)),
    ]

    var body: some View {
        Card(padding: 0) {
            ZStack(alignment: .bottomLeading) {
                let frames = loop?.band == band ? loop?.frames ?? [] : []
                SunStage(still: stills[band], frames: frames, times: loop?.band == band ? loop?.times ?? [] : [],
                         tint: bandTint, playing: playing, failed: failed)
                    .frame(height: 330)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard frames.count > 1 else { return }
                        Haptics.shared.select()
                        playing.toggle()
                    }
                    .accessibilityLabel(Text("The Sun, live from GOES-19"))
                    .accessibilityHint(frames.count > 1 ? Text("Double-tap to pause or play the six-hour time-lapse.") : Text(""))
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        PulsingDot(color: bandTint)
                        Text(frames.count > 1 ? "THE SUN · LAST 6 HOURS" : "THE SUN · LIVE").eyebrow(.white)
                        if let observed {
                            Text("· \(Fmt.relative(observed))").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                        if frames.count > 1 {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.7))
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach(bands, id: \.id) { b in
                            Button {
                                Haptics.shared.select()
                                withAnimation(.easeInOut(duration: 0.5)) { band = b.id }
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(b.id) Å").font(.system(size: 12, weight: .bold, design: .rounded))
                                    Text(b.name).font(.system(size: 10, weight: .medium)).opacity(0.75)
                                }
                                .foregroundStyle(band == b.id ? .black : .white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(band == b.id ? b.tint : Color.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(14)
            }
        }
        .task(id: band) { await load(band) }
    }

    private var bandTint: Color { bands.first { $0.id == band }?.tint ?? .orange }

    private func load(_ b: String) async {
        failed = false
        if stills[b] == nil {
            do {
                let (data, obs) = try await APIClient.shared.sunImage(band: b)
                if let ui = await UIImage(data: data)?.byPreparingForDisplay() {
                    withAnimation(.easeOut(duration: 0.6)) { stills[b] = ui }
                    observed = obs
                }
            } catch {
                failed = stills[b] == nil
            }
        }
        guard loop?.band != b else { return }
        // Only one band's time-lapse stays decoded at a time (about 25 MB).
        guard let list = try? await APIClient.shared.sunFrames(band: b), list.frames.count > 1 else { return }
        var images = [UIImage?](repeating: nil, count: list.frames.count)
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (i, f) in list.frames.enumerated() {
                group.addTask {
                    guard let data = try? await APIClient.shared.sunFrame(band: b, id: f.id) else { return (i, nil) }
                    return (i, await UIImage(data: data)?.byPreparingForDisplay())
                }
            }
            for await (i, img) in group { images[i] = img }
        }
        guard !Task.isCancelled, band == b else { return }
        let pairs = zip(images, list.frames).compactMap { img, f in img.map { ($0, f.t) } }
        guard pairs.count > 5 else { return }
        withAnimation(.easeInOut(duration: 0.8)) {
            loop = (b, pairs.map(\.0), pairs.map(\.1))
        }
    }
}

/// Draws the Sun as light: additive frames over a deep-space backdrop with a bloom halo,
/// crossfading through the time-lapse.
private struct SunStage: View {
    let still: UIImage?
    let frames: [UIImage]
    let times: [Date]
    let tint: Color
    let playing: Bool
    let failed: Bool

    private static let frameDuration = 0.16
    private static let hold = 1.4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: frames.count < 2 || !playing)) { ctx in
            let (a, b, mix, index) = blend(at: ctx.date)
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height) * 1.08
                ZStack {
                    LinearGradient(colors: [Color(red: 0.035, green: 0.03, blue: 0.045), Color(red: 0.01, green: 0.01, blue: 0.02)],
                                   startPoint: .top, endPoint: .bottom)
                    // Warm scattered light around (not on) the disc, which spans ~0.32 of the frame.
                    RadialGradient(colors: [tint.opacity(0.22), tint.opacity(0.05), .clear],
                                   center: .center, startRadius: side * 0.3, endRadius: side * 0.78)
                    if a != nil {
                        // Bloom: the same light, blurred wide.
                        disc(a, b, mix, side: side)
                            .blur(radius: side * 0.07)
                            .opacity(0.42)
                        disc(a, b, mix, side: side)
                    } else if failed {
                        Image(systemName: "sun.max.fill").font(.system(size: 80)).foregroundStyle(tint)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .drawingGroup()
                .overlay(alignment: .topTrailing) {
                    if let index, times.indices.contains(index) {
                        Text(times[index], format: .dateTime.hour().minute())
                            .font(.mono(11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(.black.opacity(0.35)))
                            .padding(12)
                            .contentTransition(.numericText())
                    }
                }
            }
        }
    }

    private func disc(_ a: UIImage?, _ b: UIImage?, _ mix: Double, side: CGFloat) -> some View {
        ZStack {
            if let a {
                Image(uiImage: a).resizable().interpolation(.high).scaledToFit()
                    .opacity(1 - mix).blendMode(.plusLighter)
            }
            if let b, mix > 0 {
                Image(uiImage: b).resizable().interpolation(.high).scaledToFit()
                    .opacity(mix).blendMode(.plusLighter)
            }
        }
        .frame(width: side, height: side)
        // A soft circular edge keeps any faint sensor background from drawing a square.
        .mask(RadialGradient(colors: [.white, .white, .clear], center: .center, startRadius: 0, endRadius: side * 0.5))
    }

    /// Frames to show at `date`: two neighbours and how far to crossfade, plus the index for the clock.
    private func blend(at date: Date) -> (UIImage?, UIImage?, Double, Int?) {
        guard frames.count > 1 else { return (still, nil, 0, nil) }
        let run = Double(frames.count - 1) * Self.frameDuration
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: run + Self.hold)
        guard t < run, playing else { return (frames.last, nil, 0, frames.count - 1) }
        let pos = t / Self.frameDuration
        let i = Int(pos)
        let f = pos - Double(i)
        let eased = f * f * (3 - 2 * f)
        return (frames[i], frames[i + 1], eased, eased < 0.5 ? i : i + 1)
    }
}

// MARK: - Kp gauge

struct KpGauge: View {
    var kp: Double
    var gScale: Int
    @State private var shown: Double = 0

    var body: some View {
        Card {
            Text("Kp INDEX").eyebrow()
            ZStack {
                ArcShape(progress: 1).stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                ArcShape(progress: shown / 9)
                    .stroke(AngularGradient(colors: [Theme.ice, Theme.aurora, Theme.auroraViolet, Color(red: 1, green: 0.25, blue: 0.45)],
                                            center: .center, startAngle: .degrees(150), endAngle: .degrees(390)),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .shadow(color: Theme.kpColor(kp).opacity(0.7), radius: 10)
                VStack(spacing: 0) {
                    Text(shown.formatted(.number.precision(.fractionLength(1))))
                        .font(.display(34, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(value: shown))
                    Text(gScale > 0 ? "G\(gScale) STORM" : levelText)
                        .font(.label(10))
                        .foregroundStyle(Theme.kpColor(kp))
                }
                .offset(y: 6)
            }
            .frame(height: 118)
        }
        .onAppear { withAnimation(.spring(response: 1.4, dampingFraction: 0.8).delay(0.2)) { shown = kp } }
        .onChange(of: kp) { _, v in withAnimation(.spring(response: 1.0, dampingFraction: 0.8)) { shown = v } }
    }

    private var levelText: String {
        switch kp {
        case 4..<5: String(localized: "ACTIVE")
        case 3..<4: String(localized: "UNSETTLED")
        default: String(localized: "QUIET")
        }
    }
}

struct ArcShape: Shape {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(rect.width, rect.height * 1.3) / 2 - 8
        let c = CGPoint(x: rect.midX, y: rect.midY + r * 0.25)
        p.addArc(center: c, radius: r, startAngle: .degrees(150), endAngle: .degrees(150 + 240 * max(0.001, min(1, progress))), clockwise: false)
        return p
    }
}

struct AuroraChanceCard: View {
    var chance: Int?
    var place: String?
    @State private var glow = false

    var body: some View {
        Card {
            Text("AURORA HERE").eyebrow(Theme.aurora)
            Spacer(minLength: 4)
            Text(chance.map { percentString($0) } ?? "—")
                .font(.display(40, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [Theme.aurora, Theme.ice], startPoint: .top, endPoint: .bottom))
                .shadow(color: Theme.aurora.opacity(glow ? 0.7 : 0.2), radius: glow ? 16 : 6)
            Text(place ?? String(localized: "Your location"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Text(advice)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)
        }
        .frame(height: 170)
        .onAppear { withAnimation(.easeInOut(duration: 2).repeatForever()) { glow = true } }
    }

    private var advice: String {
        guard let chance else { return String(localized: "Allow location to see your odds.") }
        switch chance {
        case 50...: return String(localized: "Go outside and look poleward.")
        case 15..<50: return String(localized: "Possible from dark skies.")
        default: return String(localized: "Unlikely tonight.")
        }
    }
}

// MARK: - Solar wind & X-rays

struct SolarWindCard: View {
    let space: SpaceWeather

    var body: some View {
        Card {
            HStack {
                Text("SOLAR WIND").eyebrow(Theme.ice)
                Spacer()
                if let t = space.windTime { Text(Fmt.relative(t)).font(.system(size: 11)).foregroundStyle(Theme.textTertiary) }
            }
            HStack(spacing: 10) {
                Metric(value: space.windSpeed.formatted(.number.precision(.fractionLength(0))), unit: "km/s", label: "speed", tint: Theme.ice)
                Metric(value: space.windDensity.formatted(.number.precision(.fractionLength(1))), unit: "p/cm³", label: "density", tint: Theme.ice)
                Metric(value: space.bz.formatted(.number.precision(.fractionLength(1))), unit: "nT", label: "Bz", tint: space.bz < -5 ? Theme.aurora : Theme.ice)
            }
            if let h = space.windHistory, h.count > 3 {
                Chart(h, id: \.t) { s in
                    AreaMark(x: .value("t", s.t), y: .value("km/s", s.v))
                        .foregroundStyle(LinearGradient(colors: [Theme.ice.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("t", s.t), y: .value("km/s", s.v))
                        .foregroundStyle(Theme.ice)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
                .chartYAxis { AxisMarks(position: .trailing) }
                .frame(height: 110)
            }
            if let bz = space.bzHistory, bz.count > 3 {
                Chart(bz, id: \.t) { s in
                    BarMark(x: .value("t", s.t), y: .value("nT", s.v))
                        .foregroundStyle(s.v < 0 ? Theme.aurora.opacity(0.85) : Theme.textTertiary)
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .trailing, values: [-10, 0, 10]) }
                .frame(height: 60)
                Text("Southward Bz (green) lets solar wind energy into the magnetosphere — the main driver of aurora.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

struct XrayCard: View {
    let space: SpaceWeather

    var body: some View {
        Card {
            HStack {
                Text("SOLAR X-RAYS · GOES").eyebrow(Theme.sun)
                Spacer()
                Text(space.xrayClass)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(flareColor(space.xrayClass))
            }
            if let h = space.xrayHistory, h.count > 3 {
                Chart {
                    ForEach([("C", 1e-6), ("M", 1e-5), ("X", 1e-4)], id: \.0) { c in
                        RuleMark(y: .value("class", log10(c.1)))
                            .foregroundStyle(.white.opacity(0.12))
                            .annotation(position: .top, alignment: .leading) { Text(c.0).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary) }
                    }
                    ForEach(h, id: \.t) { s in
                        LineMark(x: .value("t", s.t), y: .value("flux", log10(max(s.v, 1e-9))))
                            .foregroundStyle(Theme.sun)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                .chartYScale(domain: -8.5 ... -3.5)
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
                .frame(height: 120)
            }
            if let flares = space.flares, !flares.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RECENT FLARES").eyebrow()
                    ForEach(flares.prefix(5), id: \.peak) { f in
                        HStack {
                            Text(f.class).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(flareColor(f.class)).frame(width: 52, alignment: .leading)
                            Text(Fmt.dayTime(f.peak)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text(Fmt.relative(f.peak)).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func flareColor(_ c: String) -> Color {
        switch c.first {
        case "X": Color(red: 1, green: 0.3, blue: 0.4)
        case "M": Color(red: 1, green: 0.55, blue: 0.25)
        case "C": Theme.sun
        default: Theme.textSecondary
        }
    }
}

struct KpForecastCard: View {
    let forecast: [Sample]

    var body: some View {
        Card {
            Text("3-DAY FORECAST · Kp").eyebrow()
            Chart(forecast, id: \.t) { s in
                BarMark(x: .value("t", s.t, unit: .hour), y: .value("Kp", s.v), width: .ratio(0.7))
                    .foregroundStyle(Theme.kpColor(s.v).gradient)
                    .cornerRadius(3)
            }
            .chartYScale(domain: 0...9)
            .chartYAxis { AxisMarks(position: .trailing, values: [0, 3, 5, 7, 9]) }
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
            .frame(height: 120)
        }
    }
}

struct AlertsCard: View {
    let alerts: [SpaceAlert]
    @State private var expanded: String?

    var body: some View {
        Card {
            Text("NOAA ALERTS · 72 H").eyebrow()
            ForEach(alerts.prefix(6)) { a in
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        withAnimation(.snappy) { expanded = expanded == a.id ? nil : a.id }
                    } label: {
                        HStack(alignment: .top) {
                            Text(a.title.capitalized).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).multilineTextAlignment(.leading)
                            Spacer()
                            Text(Fmt.relative(a.time)).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    if expanded == a.id {
                        Text(a.message).font(.mono(10.5, weight: .regular)).foregroundStyle(Theme.textSecondary).transition(.opacity)
                    }
                }
                .padding(.vertical, 4)
                if a.id != alerts.prefix(6).last?.id { Divider().overlay(Theme.hairline) }
            }
        }
    }
}

// MARK: - Shared building blocks

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.hairline))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct Metric: View {
    var value: String
    var unit: String
    var label: LocalizedStringKey
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.white).contentTransition(.numericText())
                Text(unit).font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
            }
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
