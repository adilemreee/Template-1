import SwiftUI
import WidgetKit

@main
struct KarmanWidgetsBundle: WidgetBundle {
    var body: some Widget {
        EarthNowWidget()
        AuroraWidget()
        StationWidget()
        LaunchLiveActivity()
    }
}

// MARK: - Palette

enum WTheme {
    static let ice = Color(red: 0.50, green: 0.83, blue: 1.0)
    static let aurora = Color(red: 0.24, green: 1.0, blue: 0.63)
    static let violet = Color(red: 0.72, green: 0.45, blue: 1.0)
    static let quake = Color(red: 1.0, green: 0.42, blue: 0.22)
    static let launchTint = Color(red: 1.0, green: 0.86, blue: 0.62)
    static let secondary = Color.white.opacity(0.62)
    static let background = LinearGradient(colors: [Color(red: 0.02, green: 0.03, blue: 0.07), Color(red: 0.0, green: 0.0, blue: 0.02)], startPoint: .top, endPoint: .bottom)

    static func kp(_ v: Double) -> Color {
        switch v {
        case 7...: Color(red: 1, green: 0.25, blue: 0.45)
        case 5..<7: violet
        case 4..<5: aurora
        default: ice
        }
    }
}

private extension View {
    func eyebrowStyle(_ c: Color = WTheme.secondary) -> some View {
        self.font(.system(size: 9.5, weight: .bold).width(.expanded)).tracking(1.2).foregroundStyle(c)
    }
}

// MARK: - Earth Now

struct EarthNowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EarthNow", provider: PlanetProvider()) { entry in
            EarthNowView(entry: entry)
                .containerBackground(for: .widget) { WTheme.background }
                .widgetURL(URL(string: "karman://pulse"))
        }
        .configurationDisplayName("Earth Now")
        .description("The planet live: day and night, city lights and today's earthquakes.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct EarthNowView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PlanetEntry

    var body: some View {
        switch family {
        case .systemMedium: medium
        case .systemLarge: large
        default: small
        }
    }

    private var globe: some View {
        Group {
            if let g = entry.globe {
                Image(decorative: g, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Circle().fill(RadialGradient(colors: [Color(red: 0.1, green: 0.3, blue: 0.6), .black], center: .center, startRadius: 4, endRadius: 80))
            }
        }
    }

    private var small: some View {
        ZStack(alignment: .bottomLeading) {
            globe.padding(6)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Circle().fill(WTheme.aurora).frame(width: 5, height: 5)
                    Text("LIVE").eyebrowStyle(WTheme.aurora)
                }
                Text("\(entry.state.quakes24h) quakes · Kp \(entry.state.kp.formatted(.number.precision(.fractionLength(1))))")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(10)
        }
    }

    private var medium: some View {
        HStack(spacing: 0) {
            globe.padding(8)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Circle().fill(WTheme.aurora).frame(width: 5, height: 5)
                    Text("KÁRMÁN · LIVE").eyebrowStyle(WTheme.aurora)
                }
                if let q = entry.state.topQuake {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("M\(q.mag.formatted(.number.precision(.fractionLength(1))))").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(WTheme.quake)
                        Text(q.place).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                        Text(q.time, style: .relative).font(.system(size: 10)).foregroundStyle(WTheme.secondary)
                    }
                }
                HStack(spacing: 12) {
                    stat("\(entry.state.quakes24h)", "quakes 24h", WTheme.quake)
                    stat(entry.state.kp.formatted(.number.precision(.fractionLength(1))), "Kp", WTheme.kp(entry.state.kp))
                    if let a = entry.state.auroraChance { stat(percentString(a), "aurora", WTheme.aurora) }
                }
            }
            .padding(.vertical, 12)
            .padding(.trailing, 12)
            Spacer(minLength: 0)
        }
    }

    private var large: some View {
        VStack(spacing: 10) {
            HStack {
                HStack(spacing: 4) {
                    Circle().fill(WTheme.aurora).frame(width: 5, height: 5)
                    Text("KÁRMÁN · LIVE").eyebrowStyle(WTheme.aurora)
                }
                Spacer()
                Text(entry.date, style: .time).font(.system(size: 11, weight: .medium)).foregroundStyle(WTheme.secondary)
            }
            globe.frame(maxHeight: .infinity)
            HStack(spacing: 14) {
                stat("\(entry.state.quakes24h)", "quakes 24h", WTheme.quake)
                if let q = entry.state.topQuake { stat("M\(q.mag.formatted(.number.precision(.fractionLength(1))))", "strongest", WTheme.quake) }
                stat(entry.state.kp.formatted(.number.precision(.fractionLength(1))), "Kp index", WTheme.kp(entry.state.kp))
                if let a = entry.state.auroraChance { stat(percentString(a), "aurora", WTheme.aurora) }
            }
            if let pass = entry.state.nextPass {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill").font(.system(size: 10)).foregroundStyle(WTheme.ice)
                    Text("\(pass.stationName) visible \(pass.start, style: .relative) · \(Int(pass.maxElevation))°").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .padding(14)
    }

    private func stat(_ value: String, _ label: LocalizedStringKey, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(tint)
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(WTheme.secondary)
        }
    }
}

// MARK: - Aurora

struct AuroraWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Aurora", provider: PlanetProvider(renderGlobe: false)) { entry in
            AuroraView(entry: entry)
                .containerBackground(for: .widget) {
                    ZStack {
                        WTheme.background
                        RadialGradient(colors: [WTheme.aurora.opacity(0.18), .clear], center: .top, startRadius: 4, endRadius: 140)
                    }
                }
                .widgetURL(URL(string: "karman://space"))
        }
        .configurationDisplayName("Aurora & Kp")
        .description("Geomagnetic activity and your chance of seeing the aurora.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct AuroraView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PlanetEntry

    var body: some View {
        let kp = entry.state.kp
        switch family {
        case .accessoryCircular:
            Gauge(value: min(kp, 9), in: 0...9) {
                Text("Kp")
            } currentValueLabel: {
                Text(kp.formatted(.number.precision(.fractionLength(1))))
            }
            .gaugeStyle(.accessoryCircular)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("AURORA").font(.system(size: 11, weight: .bold).width(.expanded))
                Text("Kp \(kp.formatted(.number.precision(.fractionLength(1)))) · \(entry.state.auroraChance.map { percentString($0) } ?? "—") here")
                    .font(.system(size: 13, weight: .semibold))
                Gauge(value: min(kp, 9), in: 0...9) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity)
            }
        case .accessoryInline:
            Text("Kp \(kp.formatted(.number.precision(.fractionLength(1)))) · aurora \(entry.state.auroraChance.map { percentString($0) } ?? "—")")
        default:
            VStack(alignment: .leading, spacing: 6) {
                Text("AURORA").eyebrowStyle(WTheme.aurora)
                Spacer(minLength: 0)
                ZStack {
                    Circle().trim(from: 0, to: 0.75).stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(135))
                    Circle().trim(from: 0, to: 0.75 * min(1, kp / 9)).stroke(AngularGradient(colors: [WTheme.ice, WTheme.aurora, WTheme.violet], center: .center), style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(135))
                    VStack(spacing: -2) {
                        Text(kp.formatted(.number.precision(.fractionLength(1)))).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        Text("Kp").font(.system(size: 10, weight: .semibold)).foregroundStyle(WTheme.secondary)
                    }
                }
                .frame(width: 84, height: 84)
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                Text(entry.state.auroraChance.map { String(localized: "\($0)% chance here") } ?? String(localized: "Open Kármán to set location"))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(WTheme.aurora).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }
}

// MARK: - Space Station

struct StationWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Station", provider: PlanetProvider(renderGlobe: false)) { entry in
            StationView(entry: entry)
                .containerBackground(for: .widget) { WTheme.background }
                .widgetURL(URL(string: "karman://sky"))
        }
        .configurationDisplayName("Space Station")
        .description("When the International Space Station is next visible from where you are.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline])
    }
}

struct StationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PlanetEntry

    var body: some View {
        let pass = entry.state.passes.first { $0.end > entry.date }
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(pass.map { String(localized: "\($0.stationName.uppercased()) PASS") } ?? String(localized: "ISS PASS")).font(.system(size: 11, weight: .bold).width(.expanded))
                if let pass {
                    Text(pass.start, style: .relative).font(.system(size: 14, weight: .semibold))
                    Text("\(compass(pass.startAzimuth)) → \(compass(pass.endAzimuth)) · \(Int(pass.maxElevation))°").font(.system(size: 12))
                } else {
                    Text("No visible pass soon").font(.system(size: 13))
                }
            }
        case .accessoryInline:
            if let pass { Text("\(pass.stationName) \(pass.start, style: .time) · \(Int(pass.maxElevation))°") } else { Text("ISS — no pass soon") }
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(pass?.stationName.uppercased() ?? String(localized: "SPACE STATION")).eyebrowStyle(WTheme.ice)
                    Spacer()
                    Image(systemName: "person.2.fill").font(.system(size: 10)).foregroundStyle(WTheme.ice)
                }
                Spacer(minLength: 0)
                if let pass {
                    Text(pass.start, style: .time).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text(pass.start, style: .relative).font(.system(size: 12, weight: .medium)).foregroundStyle(WTheme.ice)
                    Text("\(compass(pass.startAzimuth)) → \(compass(pass.endAzimuth)) · \(Int(pass.maxElevation))° high").font(.system(size: 11)).foregroundStyle(WTheme.secondary)
                } else {
                    Text("No visible pass in the next days").font(.system(size: 13, weight: .medium)).foregroundStyle(WTheme.secondary)
                }
            }
        }
    }

    private func compass(_ az: Double) -> String { GeoPoint.compassName(az) }
}
