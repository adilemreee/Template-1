import SwiftUI

/// Live feed of everything happening on the planet, newest first.
struct PulseView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all, quakes, storms, fires, volcanoes, launches
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .quakes: "Quakes"
            case .storms: "Storms"
            case .fires: "Fires"
            case .volcanoes: "Volcanoes & more"
            case .launches: "Launches"
            }
        }
    }

    struct FeedItem: Identifiable {
        var id: String
        var date: Date
        var title: String
        var subtitle: String
        var icon: String
        var tint: Color
        var magnitude: Double?
        var target: GlobeItem
        var significance: Double
    }

    var body: some View {
        let items = feed()
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                filters
                if filter == .all { summary }
                LazyVStack(spacing: 8) {
                    ForEach(groups(items), id: \.0) { title, rows in
                        Text(title).eyebrow().frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        ForEach(rows) { row in
                            FeedRow(item: row) {
                                dismiss()
                                model.select(row.target)
                            }
                        }
                    }
                    if items.isEmpty {
                        ContentUnavailableView("Nothing here right now", systemImage: "checkmark.seal", description: Text("The planet is quiet in this category."))
                            .padding(.top, 40)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(PanelBackground())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("PULSE").eyebrow(Theme.ice)
                Spacer()
                if let updated = model.planet.lastUpdated {
                    TimelineView(.periodic(from: .now, by: 10)) { ctx in
                        Text("Updated \(Fmt.relative(updated, now: ctx.date))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.trailing, 40)
                }
            }
            Text("The planet, right now")
                .font(.display(26, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { f in
                    Button {
                        Haptics.shared.select()
                        withAnimation(.snappy) { filter = f }
                    } label: {
                        Text(f.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(filter == f ? .black : .white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(filter == f ? Color.white : Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollClipDisabled()
    }

    private var summary: some View {
        let q24 = model.planet.quakesLast24h
        let strongest = q24.max { $0.mag < $1.mag }
        return HStack(spacing: 10) {
            StatTile(value: "\(q24.count)", label: "quakes · 24h", tint: Theme.quake)
            StatTile(value: strongest.map { "M" + Fmt.magnitude($0.mag) } ?? "—", label: "strongest", tint: Theme.quakeColor(mag: strongest?.mag ?? 0))
            StatTile(value: "\(model.planet.activeStorms.count)", label: "storms", tint: Theme.storm)
            StatTile(value: "\(model.planet.wildfires.count)", label: "fires", tint: Theme.fire)
        }
    }

    private func feed() -> [FeedItem] {
        let snap = model.planet.snapshot
        var out: [FeedItem] = []
        let now = Date()
        if filter == .all || filter == .quakes {
            for q in snap.quakes where (filter == .quakes ? q.mag >= 2.5 : q.mag >= 4.0) && now.timeIntervalSince(q.time) < 7 * 86400 {
                var sub = String(localized: "\(Int(q.depthKm)) km deep")
                if q.isTsunamiFlagged { sub += " · " + String(localized: "tsunami flag") }
                if let felt = q.felt, felt > 0 { sub += " · " + String(localized: "felt by \(felt)") }
                out.append(FeedItem(id: q.id, date: q.time, title: q.place, subtitle: sub, icon: "waveform.path.ecg", tint: Theme.quakeColor(mag: q.mag),
                                    magnitude: q.mag, target: .quake(q.id), significance: Double(q.sig)))
            }
        }
        for e in snap.events {
            let include: Bool = switch filter {
            case .all: e.kind != .wildfire || now.timeIntervalSince(e.time) < 2 * 86400
            case .storms: e.kind == .storm
            case .fires: e.kind == .wildfire
            case .volcanoes: ![.storm, .wildfire].contains(e.kind)
            default: false
            }
            guard include else { continue }
            let sub = [e.kind.label, e.valueText].filter { !$0.isEmpty }.joined(separator: " · ")
            out.append(FeedItem(id: e.id, date: e.time, title: e.title, subtitle: sub, icon: e.kind.symbol, tint: Theme.color(for: e.kind),
                                magnitude: nil, target: .event(e.id), significance: e.kind == .storm ? 600 : 100))
        }
        if filter == .all || filter == .launches {
            for l in model.planet.upcomingLaunches.prefix(filter == .launches ? 20 : 4) {
                out.append(FeedItem(id: l.id, date: l.net, title: l.missionName, subtitle: "\(l.rocket) · \(l.provider)", icon: "airplane.departure",
                                    tint: Theme.launch, magnitude: nil, target: .launch(l.id), significance: 300))
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    private func groups(_ items: [FeedItem]) -> [(String, [FeedItem])] {
        let now = Date()
        var upcoming: [FeedItem] = [], hour: [FeedItem] = [], day: [FeedItem] = [], week: [FeedItem] = []
        for i in items {
            let age = now.timeIntervalSince(i.date)
            if age < 0 { upcoming.append(i) }
            else if age < 3600 { hour.append(i) }
            else if age < 86400 { day.append(i) }
            else { week.append(i) }
        }
        var out: [(String, [FeedItem])] = []
        if !upcoming.isEmpty { out.append((String(localized: "Coming up"), upcoming.sorted { $0.date < $1.date })) }
        if !hour.isEmpty { out.append((String(localized: "Last hour"), hour)) }
        if !day.isEmpty { out.append((String(localized: "Last 24 hours"), day)) }
        if !week.isEmpty { out.append((String(localized: "This week"), Array(week.prefix(120)))) }
        return out
    }
}

private struct FeedRow: View {
    let item: PulseView.FeedItem
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.shared.tap()
            action()
        } label: {
            HStack(spacing: 12) {
                if let m = item.magnitude {
                    ZStack {
                        Circle().fill(item.tint.opacity(0.18))
                        Circle().strokeBorder(item.tint.opacity(0.6), lineWidth: 1)
                        Text(Fmt.magnitude(m)).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    }
                    .frame(width: 42, height: 42)
                } else {
                    EventGlyph(icon: item.icon, tint: item.tint, size: 42)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(item.date > Date() ? Fmt.dayTime(item.date) : Fmt.relative(item.date))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

struct StatTile: View {
    var value: String
    var label: LocalizedStringKey
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Dark, slightly translucent backdrop for panels so the globe glows through.
struct PanelBackground: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(colors: [Theme.space.opacity(0.78), Color.black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.ice.opacity(0.10), .clear], center: .topTrailing, startRadius: 10, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}
