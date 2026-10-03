import SwiftUI

struct SkyTonightView: View {
    @Environment(AppModel.self) private var model
    @State private var expandedPass: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TONIGHT'S SKY").eyebrow(Theme.ice)
                    Text(model.location.placeName ?? String(localized: "Above you")).font(.display(26, weight: .bold)).foregroundStyle(.white)
                }

                if let observer = model.location.point {
                    MoonCard(observer: observer)
                    SunTimelineCard(observer: observer)
                    passes
                } else {
                    Card {
                        Label("Location needed", systemImage: "location.slash").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        Text("Tonight's Sky predicts Space Station passes, moonrise and twilight for where you are. Your location stays on this device.")
                            .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        HStack {
                            Button("Use my location") { model.location.useDeviceLocation() }
                                .buttonStyle(.glassProminent)
                            Button("Choose a place") { model.panel = .settings }
                                .buttonStyle(.glass)
                        }
                    }
                }

                LaunchesCard()
                AsteroidsCard()
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(PanelBackground())
        .task {
            await model.recomputePasses()
            if model.screenshotScene == "sky", let first = model.passes.filter({ $0.end > Date() }).max(by: { $0.maxElevation < $1.maxElevation }) {
                try? await Task.sleep(for: .milliseconds(600))
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { expandedPass = first.id }
            }
        }
    }

    private var passes: some View {
        Card {
            HStack {
                Text("SPACE STATION PASSES").eyebrow(Theme.ice)
                Spacer()
                Image(systemName: "person.2.fill").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            let upcoming = model.passes.filter { $0.end > Date() }
            if upcoming.isEmpty {
                Text("No visible passes in the next few days. The station is only visible when it's lit by the Sun while your sky is dark.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(upcoming.prefix(6)) { pass in
                    PassRow(pass: pass, expanded: expandedPass == pass.id) {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                            expandedPass = expandedPass == pass.id ? nil : pass.id
                        }
                    }
                    if pass.id != upcoming.prefix(6).last?.id { Divider().overlay(Theme.hairline) }
                }
            }
        }
    }
}

// MARK: - Moon

struct MoonCard: View {
    let observer: GeoPoint
    @State private var image: CGImage?

    var body: some View {
        let now = Date()
        let phase = Astro.moonPhase(now)
        let riseSet = Astro.moonRiseSet(from: now.addingTimeInterval(-3600), observer: observer)
        Card {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(RadialGradient(colors: [.white.opacity(0.10), .clear], center: .center, startRadius: 30, endRadius: 80))
                        .frame(width: 140, height: 140)
                    if let image {
                        Image(decorative: image, scale: 1).resizable().frame(width: 104, height: 104)
                            .shadow(color: .white.opacity(0.25), radius: 18)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 4) {
                    Text("THE MOON").eyebrow()
                    Text(phase.name).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    Text("\(Int((phase.illumination * 100).rounded()))% lit · \(Int(phase.distanceKm).formatted()) km")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 14) {
                        if let rise = riseSet.rise { TimeTag(icon: "moonrise.fill", time: rise) }
                        if let set = riseSet.set { TimeTag(icon: "moonset.fill", time: set) }
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
        .task {
            let south = observer.lat < 0
            let img = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let url = Bundle.main.url(forResource: "moon", withExtension: "jpg"),
                      let tex = OrthoSphere.loadTexture(url: url, gray: false) else { return nil }
                return OrthoSphere.moon(size: 320, texture: tex, phase: Astro.moonPhase(Date()), southernHemisphere: south)
            }.value
            withAnimation(.easeOut(duration: 0.8)) { image = img }
        }
    }
}

struct TimeTag: View {
    var icon: String
    var time: Date

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.ice).symbolRenderingMode(.hierarchical)
            Text(Fmt.dayTime(time)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
        }
    }
}

// MARK: - Sun timeline

struct SunTimelineCard: View {
    let observer: GeoPoint

    var body: some View {
        let now = Date()
        let start = now.addingTimeInterval(-2 * 3600)
        let samples = (0...144).map { i -> (Date, Double) in
            let t = start.addingTimeInterval(Double(i) * 600)
            return (t, Astro.sunAltitude(at: t, observer: observer))
        }
        let times = Astro.sunTimes(from: now.addingTimeInterval(-1800), observer: observer)
        Card {
            Text("LIGHT · NEXT 24 HOURS").eyebrow(Theme.sun)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                            Rectangle().fill(color(for: s.1)).frame(width: w / CGFloat(samples.count))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    // Altitude curve
                    Path { p in
                        for (i, s) in samples.enumerated() {
                            let x = CGFloat(i) / CGFloat(samples.count - 1) * w
                            let y = 30 - CGFloat(max(-30, min(70, s.1))) / 70 * 26
                            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    let nowX = CGFloat(now.timeIntervalSince(start) / (24 * 3600)) * w
                    Rectangle().fill(.white).frame(width: 2, height: 46).offset(x: nowX - 1)
                    Text("now").font(.system(size: 9, weight: .bold)).foregroundStyle(.white).offset(x: nowX + 4, y: -16)
                }
            }
            .frame(height: 46)
            HStack(spacing: 0) {
                SunStat(icon: "sunrise.fill", title: "Sunrise", date: times.sunrise)
                SunStat(icon: "sun.horizon.fill", title: "Golden hour", date: times.goldenHourEvening)
                SunStat(icon: "sunset.fill", title: "Sunset", date: times.sunset)
                SunStat(icon: "moon.haze.fill", title: "Blue hour", date: times.blueHourEvening)
            }
        }
    }

    private func color(for alt: Double) -> Color {
        switch alt {
        case 6...: Color(red: 0.36, green: 0.62, blue: 0.95)
        case 0..<6: Color(red: 0.98, green: 0.66, blue: 0.30)
        case -6..<0: Color(red: 0.40, green: 0.36, blue: 0.70)
        case -12 ..< -6: Color(red: 0.14, green: 0.18, blue: 0.42)
        case -18 ..< -12: Color(red: 0.07, green: 0.09, blue: 0.24)
        default: Color(red: 0.03, green: 0.04, blue: 0.10)
        }
    }
}

private struct SunStat: View {
    var icon: String
    var title: LocalizedStringKey
    var date: Date?

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon).symbolRenderingMode(.multicolor).font(.system(size: 15))
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1).minimumScaleFactor(0.8)
            Text(date.map(Fmt.time) ?? "—").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Passes

struct PassRow: View {
    @Environment(AppModel.self) private var model
    let pass: PassPredictor.Pass
    let expanded: Bool
    var toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Fmt.dayTime(pass.start)).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        Text("\(stationName) · \(GeoPoint.compassName(pass.startAzimuth)) → \(GeoPoint.compassName(pass.endAzimuth)) · \(Int(pass.end.timeIntervalSince(pass.start) / 60)) min")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(pass.maxElevation))°").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(elevationColor)
                        Text(brightness).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textTertiary)
                    }
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                SkyDome(pass: pass)
                    .frame(height: 230)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                Text(pass.noradID == 25544
                     ? String(localized: "Look \(GeoPoint.compassName(pass.startAzimuth)) at \(Fmt.time(pass.start)). A bright, steady star moving fast with no blinking lights — that's seven people living in orbit.")
                     : String(localized: "Look \(GeoPoint.compassName(pass.startAzimuth)) at \(Fmt.time(pass.start)). China's Tiangong space station glides across your sky as a steady, bright point."))
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var stationName: String { pass.noradID == 25544 ? "ISS" : "Tiangong" }

    private var elevationColor: Color { pass.maxElevation > 60 ? Theme.aurora : (pass.maxElevation > 30 ? Theme.ice : Theme.textSecondary) }

    private var brightness: String {
        switch pass.magnitude {
        case ..<(-2.5): String(localized: "very bright")
        case ..<(-1.0): String(localized: "bright")
        default: String(localized: "visible")
        }
    }
}

/// Sky chart: horizon at the edge, zenith in the middle, the pass drawn with its direction.
struct SkyDome: View {
    let pass: PassPredictor.Pass
    @State private var appeared = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let t = min(1, tl.date.timeIntervalSince(appeared) / 2.2)
            dome(progress: CGFloat(Easing.inOutSine(t)))
        }
        .onAppear { appeared = Date() }
    }

    private func dome(progress: CGFloat) -> some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2 - 18
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                     with: .radialGradient(Gradient(colors: [Color(red: 0.08, green: 0.12, blue: 0.25), Color(red: 0.02, green: 0.03, blue: 0.08)]), center: c, startRadius: 0, endRadius: r))
            for el in [30.0, 60.0] {
                let rr = r * (90 - el) / 90
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)), with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 0.7, dash: [3, 4]))
            }
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.35)), lineWidth: 1)
            for az in [0.0, 90.0, 180.0, 270.0] {
                let p = point(az: az, el: -9, c: c, r: r)
                ctx.draw(Text(verbatim: GeoPoint.compassName(az)).font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.7)), at: p)
            }
            let pts = pass.track.filter { $0.elevation > 0 }.map { point(az: $0.azimuth, el: $0.elevation, c: c, r: r) }
            guard pts.count > 1 else { return }
            let count = max(2, Int(CGFloat(pts.count) * progress))
            var path = Path()
            path.addLines(Array(pts.prefix(count)))
            ctx.stroke(path, with: .linearGradient(Gradient(colors: [Theme.ice.opacity(0.3), Theme.ice]), startPoint: pts.first!, endPoint: pts.last!),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            let head = pts[count - 1]
            ctx.fill(Path(ellipseIn: CGRect(x: head.x - 5, y: head.y - 5, width: 10, height: 10)), with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: head.x - 11, y: head.y - 11, width: 22, height: 22)), with: .color(Theme.ice.opacity(0.25)))
        }
    }

    private func point(az: Double, el: Double, c: CGPoint, r: CGFloat) -> CGPoint {
        let rr = r * CGFloat((90 - el) / 90)
        let a = az * .pi / 180
        return CGPoint(x: c.x + CGFloat(sin(a)) * rr, y: c.y - CGFloat(cos(a)) * rr)
    }
}

// MARK: - Launches & asteroids

struct LaunchesCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let launches = model.planet.upcomingLaunches.filter { $0.net > Date().addingTimeInterval(-3600) }.prefix(4)
        if !launches.isEmpty {
            Card {
                Text("NEXT LAUNCHES").eyebrow(Theme.launch)
                ForEach(Array(launches)) { l in
                    Button {
                        dismiss()
                        model.select(.launch(l.id))
                    } label: {
                        HStack(spacing: 12) {
                            EventGlyph(icon: "airplane.departure", tint: Theme.launch, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(l.missionName).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                Text("\(l.rocket) · \(l.location)").font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                            Spacer()
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Text(Fmt.countdown(to: l.net, now: ctx.date))
                                    .font(.mono(12, weight: .semibold))
                                    .foregroundStyle(Theme.launch)
                                    .contentTransition(.numericText(countsDown: true))
                            }
                        }
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }
}

struct AsteroidsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let neos = model.planet.snapshot.neos.filter { $0.approach > Date().addingTimeInterval(-86400) }.sorted { $0.missLunar < $1.missLunar }.prefix(4)
        if !neos.isEmpty {
            Card {
                Text("ASTEROID FLYBYS").eyebrow(Color(red: 0.85, green: 0.8, blue: 0.7))
                ForEach(Array(neos)) { n in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(n.name.trimmingCharacters(in: CharacterSet(charactersIn: "()"))).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            if n.hazardous {
                                Text("PHA").font(.label(9)).foregroundStyle(.orange).padding(.horizontal, 5).padding(.vertical, 2).background(Capsule().fill(.orange.opacity(0.15)))
                            }
                            Spacer()
                            Text(Fmt.dayTime(n.approach)).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        }
                        DistanceScale(lunar: n.missLunar)
                        Text("\(n.missLunar.formatted(.number.precision(.fractionLength(1)))) × Moon distance · \(Int(n.diameterMinM))–\(Int(n.diameterMaxM)) m · \(n.velocityKps.formatted(.number.precision(.fractionLength(1)))) km/s")
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 4)
                }
                Text("PHA: potentially hazardous asteroid — a classification by size and orbit, not a threat. NASA JPL / CNEOS.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

private struct DistanceScale: View {
    var lunar: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let maxLD = max(lunar * 1.15, 1.5)
            let moonX = w * CGFloat(1 / maxLD)
            let rockX = w * CGFloat(lunar / maxLD)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08)).frame(height: 3)
                Circle().fill(Color(red: 0.3, green: 0.6, blue: 1)).frame(width: 12, height: 12)
                Circle().fill(Color(white: 0.8)).frame(width: 7, height: 7).offset(x: moonX - 3.5)
                Image(systemName: "circle.hexagongrid.fill").font(.system(size: 11)).foregroundStyle(Color(red: 0.85, green: 0.75, blue: 0.6)).offset(x: rockX - 5.5)
            }
            .frame(height: 14)
        }
        .frame(height: 14)
    }
}
