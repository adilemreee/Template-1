import simd
import SwiftUI

extension GlobeItem: Identifiable {
    var id: String {
        switch self {
        case .quake(let s): "q:" + s
        case .event(let s): "e:" + s
        case .launch(let s): "l:" + s
        case .satellite(let n): "s:\(n)"
        case .aurora(let north): "a:\(north)"
        case .user: "user"
        }
    }
}

/// Leader line from the selected marker on the globe to the inspector card.
struct SelectionCallout: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let anchor = model.globe.anchor
        Canvas { ctx, size in
            guard model.selection != nil, anchor.visible, let p = anchor.point, let card = model.inspectorFrame,
                  card.minY > p.y + 30 else { return }
            let end = CGPoint(x: min(max(p.x, card.minX + 40), card.maxX - 40), y: card.minY - 2)
            var path = Path()
            path.move(to: p)
            let mid = CGPoint(x: p.x, y: p.y + (end.y - p.y) * 0.55)
            path.addQuadCurve(to: end, control: mid)
            ctx.stroke(path, with: .linearGradient(Gradient(colors: [.white.opacity(0.9), .white.opacity(0.15)]), startPoint: p, endPoint: end),
                       style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 4]))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5)), with: .color(.white.opacity(0.6)))
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .opacity(model.hudVisible && !model.briefingActive ? 1 : 0)
    }
}

/// Bottom card summarising the selected item.
struct InspectorCard: View {
    @Environment(AppModel.self) private var model
    @State private var detail: GlobeItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let sel = model.selection {
                content(for: sel)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button {
                Haptics.shared.select()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { model.selection = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .padding(12)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.inspectorFrame = $0 }
        .onDisappear { model.inspectorFrame = nil }
        .sheet(item: $detail) { item in
            DetailSheet(item: item)
                .presentationDetents([.large])
                .presentationCornerRadius(34)
                .presentationBackground(.clear)
        }
    }

    @ViewBuilder
    private func content(for item: GlobeItem) -> some View {
        switch item {
        case .quake(let id):
            if let q = model.planet.quake(id: id) { quakeSummary(q) }
        case .event(let id):
            if let e = model.planet.event(id: id) { eventSummary(e) }
        case .launch(let id):
            if let l = model.planet.launch(id: id) { launchSummary(l) }
        case .satellite(let id):
            SatelliteSummary(id: id)
        case .aurora(let north):
            auroraSummary(north: north)
        case .user:
            userSummary
        }
    }

    private func quakeSummary(_ q: Quake) -> some View {
        HStack(alignment: .center, spacing: 14) {
            MagnitudeBadge(mag: q.mag)
            VStack(alignment: .leading, spacing: 4) {
                Text("EARTHQUAKE").eyebrow(Theme.quakeColor(mag: q.mag))
                Text(q.place).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                HStack(spacing: 6) {
                    Text(Fmt.relative(q.time))
                    Text("·")
                    Text("\(Int(q.depthKm)) km deep")
                    if let user = model.location.point {
                        Text("·")
                        Text(Fmt.distance(q.coordinate.distanceKm(to: user), units: model.settings.units) + " " + String(localized: "away"))
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                HStack(spacing: 8) {
                    PillButton(title: "Feel it", icon: "hand.tap.fill", tint: Theme.quake) { Haptics.shared.seismic(magnitude: q.mag) }
                    PillButton(title: "Details", icon: "chevron.up", tint: .white) { detail = .quake(q.id) }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private func eventSummary(_ e: NaturalEvent) -> some View {
        HStack(spacing: 14) {
            EventGlyph(kind: e.kind, size: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(e.kind.label.uppercased()).eyebrow(Theme.color(for: e.kind))
                Text(e.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                HStack(spacing: 6) {
                    if let v = e.value, v > 0 { Text(e.valueText) ; Text("·") }
                    Text(Fmt.relative(e.time))
                }
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                PillButton(title: "Details", icon: "chevron.up", tint: .white) { detail = .event(e.id) }
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private func launchSummary(_ l: Launch) -> some View {
        HStack(spacing: 14) {
            EventGlyph(icon: "airplane.departure", tint: Theme.launch, size: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(l.provider.uppercased()).eyebrow(Theme.launch)
                Text(l.missionName).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(l.rocket + " · " + l.location).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(l.isDone ? l.status : Fmt.countdown(to: l.net, now: ctx.date))
                        .font(.mono(15, weight: .semibold))
                        .foregroundStyle(l.isDone ? Theme.textSecondary : Theme.launch)
                        .contentTransition(.numericText(countsDown: true))
                }
                PillButton(title: "Details", icon: "chevron.up", tint: .white) { detail = .launch(l.id) }
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private func auroraSummary(north: Bool) -> some View {
        let a = model.planet.snapshot.aurora
        let peak = north ? a?.maxNorth ?? 0 : a?.maxSouth ?? 0
        return HStack(spacing: 14) {
            EventGlyph(icon: "light.beacon.max.fill", tint: Theme.aurora, size: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(north ? "AURORA BOREALIS" : "AURORA AUSTRALIS").eyebrow(Theme.aurora)
                Text("Oval peak \(peak)% · Kp \((model.planet.snapshot.space?.kpNow ?? 0).formatted(.number.precision(.fractionLength(1))))")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text("Live NOAA OVATION model · updates every 5 min").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                PillButton(title: "Space weather", icon: "sun.max.fill", tint: Theme.aurora) { model.panel = .space }
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private var userSummary: some View {
        let chance = model.planet.auroraChance(at: model.location.point) ?? 0
        let pass = model.passes.first { $0.end > Date() }
        return HStack(spacing: 14) {
            EventGlyph(icon: "location.fill", tint: Theme.ice, size: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text("YOU ARE HERE").eyebrow(Theme.ice)
                Text(model.location.placeName ?? Fmt.coordinate(model.location.point ?? .init(lat: 0, lon: 0)))
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text(pass.map { String(localized: "Next visible ISS pass \(Fmt.dayTime($0.start))") } ?? String(localized: "Aurora chance tonight \(chance)%"))
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                PillButton(title: "Tonight's sky", icon: "moon.stars.fill", tint: Theme.ice) { model.panel = .sky }
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct SatelliteSummary: View {
    @Environment(AppModel.self) private var model
    let id: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let sat = model.satellites.propagator(id: id)
            let state = sat.flatMap { try? $0.propagate(to: ctx.date) }
            let ecef = sat.flatMap { try? $0.ecef(at: ctx.date) }
            let sub = ecef.map { SatGeo.subpoint(ecef: $0) }
            HStack(spacing: 14) {
                EventGlyph(icon: id == 25544 ? "person.2.fill" : "dot.radiowaves.up.forward", tint: Theme.ice, size: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(id == 25544 ? "INTERNATIONAL SPACE STATION" : "SATELLITE").eyebrow(Theme.ice)
                    Text(sat?.name.capitalized ?? "—").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if let sub, let v = state.map({ simd_length($0.velocity) }) {
                        Text("\(Int(sub.altitudeKm)) km up · \((v * 3600).formatted(.number.precision(.fractionLength(0)))) km/h")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                            .contentTransition(.numericText())
                        Text(Fmt.coordinate(sub.point)).font(.mono(12)).foregroundStyle(Theme.textTertiary)
                    }
                    if id == 25544, let pass = model.passes.first(where: { $0.noradID == 25544 && $0.end > Date() }) {
                        Text("Visible from you \(Fmt.dayTime(pass.start)) · \(Int(pass.maxElevation))° high")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ice)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Small components

struct MagnitudeBadge: View {
    var mag: Double
    var size: CGFloat = 64
    @State private var ping = false

    var body: some View {
        let c = Theme.quakeColor(mag: mag)
        ZStack {
            Circle().stroke(c.opacity(0.5), lineWidth: 2).scaleEffect(ping ? 1.35 : 0.9).opacity(ping ? 0 : 0.9)
            Circle().fill(RadialGradient(colors: [c.opacity(0.55), c.opacity(0.1)], center: .center, startRadius: 2, endRadius: size * 0.6))
            Circle().strokeBorder(c.opacity(0.8), lineWidth: 1.5)
            VStack(spacing: -2) {
                Text(Fmt.magnitude(mag)).font(.display(size * 0.34, weight: .bold)).foregroundStyle(.white)
                Text("MAG").font(.label(size * 0.12)).foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { ping = true } }
    }
}

struct EventGlyph: View {
    var icon: String
    var tint: Color
    var size: CGFloat = 48

    init(kind: EventKind, size: CGFloat = 48) {
        self.icon = kind.symbol
        self.tint = Theme.color(for: kind)
        self.size = size
    }

    init(icon: String, tint: Color, size: CGFloat = 48) {
        self.icon = icon
        self.tint = tint
        self.size = size
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .strokeBorder(tint.opacity(0.45), lineWidth: 1)
            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.breathe, options: .repeating)
        }
        .frame(width: size, height: size)
    }
}

struct PillButton: View {
    var title: LocalizedStringKey
    var icon: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.shared.tap()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

extension EventKind {
    var symbol: String {
        switch self {
        case .wildfire: "flame.fill"
        case .storm: "hurricane"
        case .volcano: "mountain.2.fill"
        case .ice: "snowflake"
        case .flood: "drop.fill"
        case .dust: "aqi.medium"
        case .drought: "sun.dust.fill"
        case .landslide: "arrow.down.right.and.arrow.up.left"
        case .snow: "cloud.snow.fill"
        case .heat: "thermometer.sun.fill"
        case .other: "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch self {
        case .wildfire: String(localized: "Wildfire")
        case .storm: String(localized: "Storm")
        case .volcano: String(localized: "Volcano")
        case .ice: String(localized: "Sea & lake ice")
        case .flood: String(localized: "Flood")
        case .dust: String(localized: "Dust & haze")
        case .drought: String(localized: "Drought")
        case .landslide: String(localized: "Landslide")
        case .snow: String(localized: "Snow")
        case .heat: String(localized: "Extreme heat")
        case .other: String(localized: "Event")
        }
    }
}

extension NaturalEvent {
    var valueText: String {
        guard let v = value, v > 0 else { return "" }
        switch unit {
        case "kts": return String(localized: "\(Int(v)) kt winds")
        case "acres": return String(localized: "\(Int(v).formatted()) acres")
        default: return "\(Int(v)) \(unit ?? "")"
        }
    }
}
