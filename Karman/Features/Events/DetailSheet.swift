import Charts
import SwiftUI

struct DetailSheet: View {
    @Environment(AppModel.self) private var model
    let item: GlobeItem

    var body: some View {
        ScrollView {
            Group {
                switch item {
                case .quake(let id):
                    if let q = model.planet.quake(id: id) { QuakeDetail(quake: q) }
                case .event(let id):
                    if let e = model.planet.event(id: id) { EventDetail(event: e) }
                case .launch(let id):
                    if let l = model.planet.launch(id: id) { LaunchDetail(launch: l) }
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(PanelBackground())
    }
}

// MARK: - Earthquake

struct QuakeDetail: View {
    @Environment(AppModel.self) private var model
    let quake: Quake

    var body: some View {
        let units = model.settings.units
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                MagnitudeBadge(mag: quake.mag, size: 92)
                VStack(alignment: .leading, spacing: 5) {
                    Text("EARTHQUAKE").eyebrow(Theme.quakeColor(mag: quake.mag))
                    Text(quake.place).font(.system(size: 21, weight: .bold)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                    Text(quake.time.formatted(date: .abbreviated, time: .shortened) + " · " + Fmt.relative(quake.time))
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }

            DepthSection(depthKm: quake.depthKm, magnitude: quake.mag)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatTile(value: "\(Int(quake.depthKm)) km", label: "depth", tint: Theme.quakeWarm)
                StatTile(value: Fmt.tnt(quake.tntTonnes).components(separatedBy: " ").prefix(2).joined(separator: " "), label: "energy (TNT)", tint: Theme.quake)
                if let user = model.location.point {
                    StatTile(value: Fmt.distance(quake.coordinate.distanceKm(to: user), units: units), label: "from you", tint: Theme.ice)
                }
                StatTile(value: quake.felt.map { "\($0)" } ?? "—", label: "felt reports", tint: Theme.aurora)
            }

            Card {
                Text("WHAT THIS MEANS").eyebrow()
                Text(meaning)
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.88)).lineSpacing(3)
                if quake.isTsunamiFlagged {
                    Label("USGS tsunami flag set. This is informational — follow your local tsunami warning center for official guidance.", systemImage: "water.waves")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                }
            }

            HStack(spacing: 10) {
                Button {
                    Haptics.shared.seismic(magnitude: quake.mag)
                } label: {
                    Label("Feel it", systemImage: "hand.tap.fill").frame(maxWidth: .infinity)
                }
                .primaryAction(Theme.quake)
                if let url = quake.url.flatMap(URL.init(string:)) {
                    Link(destination: url) {
                        Label("USGS", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
            .controlSize(.large)

            Aftershocks(quake: quake)
        }
    }

    private var meaning: String {
        let m = quake.mag
        let shaking: String = switch m {
        case 7...: String(localized: "A major earthquake. Strong shaking can reach hundreds of kilometres from the epicentre.")
        case 6..<7: String(localized: "A strong earthquake, capable of damage near the epicentre, especially where buildings are vulnerable.")
        case 5..<6: String(localized: "A moderate earthquake, widely felt nearby; minor damage is possible close to the source.")
        case 4..<5: String(localized: "A light earthquake — usually felt, rarely damaging.")
        default: String(localized: "A minor earthquake, often not felt.")
        }
        let energy = String(localized: "It released about \(Fmt.tnt(quake.tntTonnes)). Each whole step in magnitude means roughly 32 times more energy.")
        return shaking + " " + energy
    }
}

/// Cross-section of the crust and mantle with the hypocentre and expanding seismic waves.
struct DepthSection: View {
    let depthKm: Double
    let magnitude: Double

    var body: some View {
        Card(padding: 0) {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                Canvas { g, size in
                    let w = size.width, h = size.height
                    let maxDepth = max(100, min(700, depthKm * 1.6 + 30))
                    let surfaceY: CGFloat = 34
                    func y(_ km: Double) -> CGFloat { surfaceY + CGFloat(km / maxDepth) * (h - surfaceY - 10) }
                    // Sky and layers
                    g.fill(Path(CGRect(x: 0, y: 0, width: w, height: surfaceY)), with: .linearGradient(Gradient(colors: [Color(red: 0.05, green: 0.08, blue: 0.16), Color(red: 0.1, green: 0.16, blue: 0.3)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: surfaceY)))
                    let layers: [(Double, Double, Color, String)] = [
                        (0, 35, Color(red: 0.36, green: 0.27, blue: 0.20), String(localized: "Crust")),
                        (35, 410, Color(red: 0.42, green: 0.20, blue: 0.12), String(localized: "Upper mantle")),
                        (410, 700, Color(red: 0.50, green: 0.16, blue: 0.10), String(localized: "Transition zone")),
                    ]
                    for (a, b, c, name) in layers where a < maxDepth {
                        let r = CGRect(x: 0, y: y(a), width: w, height: y(min(b, maxDepth)) - y(a))
                        g.fill(Path(r), with: .linearGradient(Gradient(colors: [c.opacity(0.9), c.opacity(0.6)]), startPoint: CGPoint(x: 0, y: r.minY), endPoint: CGPoint(x: 0, y: r.maxY)))
                        g.draw(Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.55)), at: CGPoint(x: 14, y: r.minY + 10), anchor: .leading)
                    }
                    g.stroke(Path { p in p.move(to: CGPoint(x: 0, y: surfaceY)); p.addLine(to: CGPoint(x: w, y: surfaceY)) }, with: .color(.white.opacity(0.5)), lineWidth: 1)
                    // Waves
                    let focus = CGPoint(x: w * 0.6, y: y(depthKm))
                    let period = 2.6
                    for k in 0..<3 {
                        let ph = (t / period + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                        let r = CGFloat(ph) * max(w, h) * 0.9
                        let alpha = (1 - ph) * 0.8
                        g.stroke(Path(ellipseIn: CGRect(x: focus.x - r, y: focus.y - r, width: r * 2, height: r * 2)),
                                 with: .color(Theme.quakeColor(mag: magnitude).opacity(alpha)), lineWidth: 1.6)
                    }
                    // Epicentre marker on the surface
                    g.stroke(Path { p in p.move(to: CGPoint(x: focus.x, y: surfaceY)); p.addLine(to: focus) }, with: .color(.white.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    g.fill(Path(ellipseIn: CGRect(x: focus.x - 6, y: focus.y - 6, width: 12, height: 12)), with: .color(.white))
                    g.fill(Path(ellipseIn: CGRect(x: focus.x - 14, y: focus.y - 14, width: 28, height: 28)), with: .color(Theme.quake.opacity(0.35)))
                    g.draw(Text("\(Int(depthKm)) km").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white), at: CGPoint(x: focus.x + 18, y: focus.y), anchor: .leading)
                    g.draw(Text("EPICENTRE").font(.label(9)).foregroundStyle(.white.opacity(0.8)), at: CGPoint(x: focus.x, y: surfaceY - 10))
                }
            }
            .frame(height: 210)
        }
    }
}

private struct Aftershocks: View {
    @Environment(AppModel.self) private var model
    let quake: Quake

    var body: some View {
        let nearby = model.planet.snapshot.quakes.filter {
            $0.id != quake.id && $0.coordinate.distanceKm(to: quake.coordinate) < 300 && abs($0.time.timeIntervalSince(quake.time)) < 7 * 86400
        }
        if nearby.count >= 2 {
            Card {
                Text("NEARBY ACTIVITY · 300 KM · 7 DAYS").eyebrow()
                Chart {
                    ForEach(nearby) { q in
                        PointMark(x: .value("time", q.time), y: .value("mag", q.mag))
                            .foregroundStyle(Theme.quakeColor(mag: q.mag))
                            .symbolSize(CGFloat(pow(2, q.mag)) * 1.5)
                    }
                    PointMark(x: .value("time", quake.time), y: .value("mag", quake.mag))
                        .foregroundStyle(.white)
                        .symbolSize(CGFloat(pow(2, quake.mag)) * 1.5)
                        .annotation(position: .top) { Text("this").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                }
                .chartYScale(domain: 2...max(6, quake.mag + 0.5))
                .chartYAxis { AxisMarks(position: .trailing) }
                .frame(height: 140)
                Text("\(nearby.count) other earthquakes nearby this week.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: - Natural events

struct EventDetail: View {
    @Environment(AppModel.self) private var model
    let event: NaturalEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                EventGlyph(kind: event.kind, size: 76)
                VStack(alignment: .leading, spacing: 5) {
                    Text(event.kind.label.uppercased()).eyebrow(Theme.color(for: event.kind))
                    Text(event.title).font(.system(size: 21, weight: .bold)).foregroundStyle(.white)
                    Text(Fmt.coordinate(event.coordinate)).font(.mono(11)).foregroundStyle(Theme.textTertiary)
                }
            }
            if event.kind == .storm { StormSection(event: event) }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatTile(value: Fmt.relative(event.time), label: "last update", tint: Theme.color(for: event.kind))
                if let user = model.location.point {
                    StatTile(value: Fmt.distance(event.coordinate.distanceKm(to: user), units: model.settings.units), label: "from you", tint: Theme.ice)
                }
                if !event.valueText.isEmpty {
                    StatTile(value: event.valueText, label: "intensity", tint: Theme.color(for: event.kind))
                }
                if let src = event.source {
                    StatTile(value: src, label: "source", tint: .white)
                }
            }
            Card {
                Text("CONTEXT").eyebrow()
                Text(context).font(.system(size: 14)).foregroundStyle(.white.opacity(0.88)).lineSpacing(3)
            }
            if let url = event.sourceUrl.flatMap(URL.init(string:)) {
                Link(destination: url) { Label("Source", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity) }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
            Text("Tracked by NASA EONET").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
    }

    private var context: String {
        switch event.kind {
        case .storm: String(localized: "Tropical cyclones form over warm ocean water. As moist air rises and condenses it releases heat, which powers the storm and spins it up through Earth's rotation. Hurricanes, typhoons and cyclones are the same phenomenon in different oceans.")
        case .wildfire: String(localized: "Wildfires are tracked by satellites that detect their heat and smoke. Hot, dry and windy conditions let them spread quickly; from orbit their smoke can stretch for hundreds of kilometres.")
        case .volcano: String(localized: "Volcanic activity ranges from gas emissions to explosive eruptions. Ash plumes can rise into the stratosphere and affect aviation far from the volcano itself.")
        case .ice: String(localized: "Large icebergs and sea-ice features are tracked by satellite as they drift and break apart, a visible signal of polar ocean dynamics.")
        default: String(localized: "This natural event is being tracked by NASA's Earth Observatory Natural Event Tracker using satellite observations.")
        }
    }
}

private struct StormSection: View {
    let event: NaturalEvent

    var body: some View {
        let kts = event.value ?? 0
        let cat = Self.category(kts)
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(cat.name).font(.system(size: 18, weight: .bold)).foregroundStyle(cat.color)
                Spacer()
                Text("\(Int(kts)) kt · \(Int(kts * 1.852)) km/h").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
            HStack(spacing: 4) {
                ForEach(0..<6) { i in
                    RoundedRectangle(cornerRadius: 3).fill(i <= cat.level ? Self.colors[i] : Color.white.opacity(0.08)).frame(height: 8)
                }
            }
            if let track = event.track, track.count > 2 {
                Chart(track, id: \.time) { p in
                    LineMark(x: .value("time", p.time), y: .value("kt", p.value ?? 0))
                        .foregroundStyle(Theme.storm)
                        .interpolationMethod(.catmullRom)
                    AreaMark(x: .value("time", p.time), y: .value("kt", p.value ?? 0))
                        .foregroundStyle(LinearGradient(colors: [Theme.storm.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                }
                .chartYAxis { AxisMarks(position: .trailing) }
                .frame(height: 110)
                if let motion = Self.motion(track) {
                    Text("Moving \(motion.direction) at about \(Int(motion.kmh)) km/h")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    static let colors: [Color] = [Color(red: 0.5, green: 0.8, blue: 1), Color(red: 1, green: 0.95, blue: 0.6), Color(red: 1, green: 0.8, blue: 0.4),
                                  Color(red: 1, green: 0.6, blue: 0.3), Color(red: 1, green: 0.4, blue: 0.3), Color(red: 1, green: 0.3, blue: 0.6)]

    static func category(_ kts: Double) -> (name: String, level: Int, color: Color) {
        switch kts {
        case 137...: (String(localized: "Category 5"), 5, colors[5])
        case 113..<137: (String(localized: "Category 4"), 4, colors[4])
        case 96..<113: (String(localized: "Category 3"), 3, colors[3])
        case 83..<96: (String(localized: "Category 2"), 2, colors[2])
        case 64..<83: (String(localized: "Category 1"), 1, colors[1])
        default: (String(localized: "Tropical storm"), 0, colors[0])
        }
    }

    static func motion(_ track: [TrackPoint]) -> (direction: String, kmh: Double)? {
        guard track.count >= 2 else { return nil }
        let a = track[track.count - 2], b = track[track.count - 1]
        let dt = b.time.timeIntervalSince(a.time) / 3600
        guard dt > 0 else { return nil }
        let pa = GeoPoint(lat: a.lat, lon: a.lon), pb = GeoPoint(lat: b.lat, lon: b.lon)
        return (GeoPoint.compassName(pa.bearing(to: pb)), pa.distanceKm(to: pb) / dt)
    }
}

// MARK: - Launch

struct LaunchDetail: View {
    let launch: Launch
    @State private var reminded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let img = launch.image.flatMap(URL.init(string:)) {
                AsyncImage(url: img) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        LinearGradient(colors: [Theme.launch.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom)
                    }
                }
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text(launch.statusAbbrev.uppercased())
                        .font(.label(10)).foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.launch))
                        .padding(12)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(launch.provider.uppercased()).eyebrow(Theme.launch)
                Text(launch.missionName).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                Text("\(launch.rocket) · \(launch.pad)").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                Text(launch.location).font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .leading, spacing: 4) {
                    Text(launch.net > ctx.date ? "LIFTOFF IN" : "LIFTOFF").eyebrow()
                    Text(Fmt.countdown(to: launch.net, now: ctx.date))
                        .font(.mono(36, weight: .bold))
                        .foregroundStyle(LinearGradient(colors: [.white, Theme.launch], startPoint: .top, endPoint: .bottom))
                        .contentTransition(.numericText(countsDown: true))
                    Text(launch.net.formatted(date: .complete, time: .shortened)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            if let mission = launch.mission, !mission.isEmpty {
                Card {
                    Text("MISSION").eyebrow()
                    Text(mission).font(.system(size: 14)).foregroundStyle(.white.opacity(0.88)).lineSpacing(3)
                    if let orbit = launch.orbit { Text("Orbit: \(orbit)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.launch) }
                }
            }
            HStack(spacing: 10) {
                if launch.net > Date().addingTimeInterval(16 * 60) {
                    Button {
                        Task { reminded = await NotificationService.shared.scheduleLaunchReminder(launch) }
                    } label: {
                        Label(reminded ? "Reminder set" : "Remind me", systemImage: reminded ? "bell.badge.fill" : "bell").frame(maxWidth: .infinity)
                    }
                    .primaryAction(Theme.launch)
                }
                if let w = launch.webcast.flatMap(URL.init(string:)) {
                    Link(destination: w) { Label("Watch", systemImage: "play.rectangle.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.glass)
                }
            }
            .controlSize(.large)
            Text("Launch data: The Space Devs · Launch Library 2").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
    }
}
