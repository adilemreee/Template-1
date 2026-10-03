import QuartzCore
import SwiftUI
import simd

/// The Earth's layers as drawn on the Inside the Earth cut: radii as fractions of the 6,371 km
/// radius, matching earthInterior in Globe.metal (the crust is drawn thicker than life).
enum EarthLayer: Int, CaseIterable, Identifiable {
    case crust, upperMantle, lowerMantle, outerCore, innerCore

    var id: Int { rawValue }

    /// Inner and outer radius on the cut.
    var drawn: (inner: Double, outer: Double) {
        switch self {
        case .crust: (0.985, 1.0)
        case .upperMantle: (0.8948, 0.985)
        case .lowerMantle: (0.5462, 0.8948)
        case .outerCore: (0.1917, 0.5462)
        case .innerCore: (0, 0.1917)
        }
    }

    /// Where the callout touches the cut: a radius and an angle above the equator (degrees),
    /// staggered so the labels fan out.
    var anchor: (r: Double, angle: Double) {
        switch self {
        case .crust: (0.993, 62)
        case .upperMantle: (0.94, 47)
        case .lowerMantle: (0.72, 33)
        case .outerCore: (0.37, 18)
        case .innerCore: (0.07, 2)
        }
    }

    var title: String {
        switch self {
        case .crust: String(localized: "Crust")
        case .upperMantle: String(localized: "Upper mantle")
        case .lowerMantle: String(localized: "Lower mantle")
        case .outerCore: String(localized: "Outer core")
        case .innerCore: String(localized: "Inner core")
        }
    }

    func detail(units: UnitSystem) -> String {
        switch self {
        case .crust:
            String(localized: "\(Fmt.distance(5, units: units).components(separatedBy: " ").first ?? "5")–\(Fmt.distance(70, units: units)) thick")
        case .upperMantle:
            String(localized: "to \(Fmt.distance(660, units: units)) · slowly flowing rock")
        case .lowerMantle:
            String(localized: "to \(Fmt.distance(2_890, units: units)) · up to \(EarthLayer.heat(4_000, units: units))")
        case .outerCore:
            String(localized: "to \(Fmt.distance(5_150, units: units)) · liquid iron")
        case .innerCore:
            String(localized: "solid iron · \(EarthLayer.heat(5_400, units: units))")
        }
    }

    var tint: Color {
        switch self {
        case .crust: Color(red: 0.72, green: 0.62, blue: 0.52)
        case .upperMantle: Color(red: 0.92, green: 0.36, blue: 0.16)
        case .lowerMantle: Color(red: 1.0, green: 0.52, blue: 0.18)
        case .outerCore: Color(red: 1.0, green: 0.74, blue: 0.28)
        case .innerCore: Color(red: 1.0, green: 0.95, blue: 0.82)
        }
    }

    /// Thousands of degrees with grouping and the unit, e.g. "5,400 °C".
    static func heat(_ celsius: Double, units: UnitSystem) -> String {
        let v = units == .metric ? celsius : celsius * 9 / 5 + 32
        let rounded = (v / 100).rounded() * 100
        return rounded.formatted(.number.precision(.fractionLength(0))) + (units == .metric ? " °C" : " °F")
    }
}

/// Inside the Earth: the planet sliced open like an orange, each layer named on the cut, and a
/// few facts about the journey down.
struct InsideEarthOverlay: View {
    @Environment(AppModel.self) private var model
    @State private var factIndex = 0
    @State private var antipode: String?

    var body: some View {
        ZStack {
            LayerCallouts()
                .allowsHitTesting(false)
            VStack(spacing: 10) {
                header
                Spacer()
                factCard
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .task {
            if let p = model.location.point {
                antipode = await SpotNamer.info(for: GeoPoint(lat: -p.lat, lon: Geo.normalizeLon(p.lon + 180))).name
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(9))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.45)) { factIndex += 1 }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PulsingDot(color: Theme.sun)
                Text("INSIDE THE EARTH").eyebrow(Theme.sun)
                Spacer()
                Button {
                    Haptics.shared.tap()
                    model.stopInsideEarth()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(Text("Close"))
            }
            Text(String(localized: "\(Fmt.distance(6_371, units: model.settings.units)) to the centre"))
                .font(.display(24, weight: .bold))
                .foregroundStyle(.white)
            Text("Drag to turn the planet and look into the cut.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(16)
        .glassPanel(cornerRadius: 26)
        .padding(.top, 8)
    }

    private var facts: [String] {
        let units = model.settings.units
        // Driving straight down at motorway speed.
        let hours = units == .metric ? 6_371.0 / 100 : 3_958.8 / 60
        let days = Int(hours / 24), rest = Int((hours - Double(days) * 24).rounded())
        let speed = units == .metric ? "100 km/h" : "60 mph"
        var list = [
            String(localized: "Driving straight down at \(speed), you'd reach the centre in \(days) days and \(rest) hours."),
            String(localized: "The inner core is about as hot as the surface of the Sun, yet it stays solid: the pressure there is 3.6 million times the air's."),
            String(localized: "The churning outer core is a dynamo. Its currents make the magnetic field that shields us from the solar wind and steers the auroras."),
            String(localized: "S waves can't travel through liquid, so they never cross the outer core. That seismic shadow is how it was discovered."),
            String(localized: "The deepest hole ever drilled, the Kola Superdeep Borehole, reached \(units == .metric ? "12.3 km" : "7.6 mi"): 0.2% of the way to the centre."),
            String(localized: "The mantle flows a few centimetres a year, about as fast as fingernails grow, and that slow churn moves the continents."),
        ]
        if let antipode {
            list.insert(String(localized: "Straight through the centre from you lies \(antipode), \(Fmt.distance(12_742, units: units)) away."), at: 1)
        }
        return list
    }

    private var factCard: some View {
        let list = facts
        let i = factIndex % list.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.sun)
                Text("DID YOU KNOW").eyebrow(Theme.sun)
                Spacer()
                HStack(spacing: 4) {
                    ForEach(list.indices, id: \.self) { k in
                        Capsule().fill(Color.white.opacity(k == i ? 0.9 : 0.25)).frame(width: k == i ? 10 : 4, height: 4)
                    }
                }
            }
            Text(list[i])
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .id(i)
                .transition(.opacity)
        }
        .padding(16)
        .glassPanel(cornerRadius: 26)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.shared.select()
            withAnimation(.easeInOut(duration: 0.3)) { factIndex += 1 }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Tap for another fact"))
    }
}

/// Leader lines from each layer on the cut's more visible face to labels along the screen edge.
private struct LayerCallouts: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let units = model.settings.units
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            Canvas { ctx, size in
                let globe = model.globe
                guard let cut = globe.cutaway else { return }
                let opening = globe.cutawayOpening(at: CACurrentMediaTime())
                let reveal = max(0, (opening - 0.75) / 0.25)
                guard reveal > 0.01 else { return }
                let projection = globe.projection

                // The face that looks at the camera most squarely gets the labels.
                let lonC = cut.longitude * .pi / 180
                let half = GlobeController.Cutaway.halfAngle * opening
                var face: (h: SIMD3<Float>, visibility: Float)?
                for side in [-1.0, 1.0] {
                    let lonF = lonC + side * half
                    let h = SIMD3<Float>(Float(sin(lonF)), 0, Float(cos(lonF)))
                    let inward = SIMD3<Float>(Float(cos(lonF)), 0, Float(-sin(lonF))) * Float(-side)
                    let visibility = simd_dot(inward, simd_normalize(projection.eye - h * 0.5))
                    if let best = face, best.visibility >= visibility { continue }
                    face = (h, visibility)
                }
                guard let face, let center = projection.screenPoint(.zero) else { return }
                let alpha = reveal * Double(max(0, min(1, (face.visibility - 0.12) / 0.25)))
                guard alpha > 0.01 else { return }

                // Anchors on the face, then labels stacked along the opposite edge (over the intact
                // surface rather than the cut).
                var items: [(layer: EarthLayer, anchor: CGPoint)] = []
                for layer in EarthLayer.allCases {
                    let a = layer.anchor.angle * .pi / 180
                    let p = face.h * Float(layer.anchor.r * cos(a)) + SIMD3<Float>(0, 1, 0) * Float(layer.anchor.r * sin(a))
                    if let pt = projection.screenPoint(p) { items.append((layer, pt)) }
                }
                guard !items.isEmpty else { return }
                let onRight = (items.map(\.anchor.x).reduce(0, +) / CGFloat(items.count)) < center.x
                items.sort { $0.anchor.y < $1.anchor.y }
                let spacing: CGFloat = 46
                var ys: [CGFloat] = []
                for item in items { ys.append(max(item.anchor.y, (ys.last ?? -.infinity) + spacing)) }
                let top: CGFloat = 190, bottom = size.height - 230
                if let last = ys.last, last > bottom { ys = ys.map { $0 - (last - bottom) } }
                if let first = ys.first, first < top { ys = ys.map { $0 + (top - first) } }

                let edgeX = onRight ? size.width - 16 : 16
                for (k, item) in items.enumerated() {
                    let labelY = ys[k] - 16
                    let title = ctx.resolve(Text(item.layer.title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(alpha)))
                    let detail = ctx.resolve(Text(item.layer.detail(units: units)).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78 * alpha)))
                    let width = max(title.measure(in: size).width, detail.measure(in: size).width)
                    let x0 = onRight ? edgeX - width : edgeX
                    let box = CGRect(x: x0 - 8, y: labelY - 5, width: width + 16, height: 39)
                    ctx.fill(Path(roundedRect: box, cornerRadius: 10), with: .color(.black.opacity(0.45 * alpha)))

                    // Leader line from the layer to the edge of its label.
                    var line = Path()
                    line.move(to: item.anchor)
                    line.addLine(to: CGPoint(x: onRight ? box.minX : box.maxX, y: labelY + 14))
                    ctx.stroke(line, with: .color(.white.opacity(0.65 * alpha)), lineWidth: 1)
                    let dot = CGRect(x: item.anchor.x - 3.5, y: item.anchor.y - 3.5, width: 7, height: 7)
                    ctx.fill(Path(ellipseIn: dot.insetBy(dx: -2, dy: -2)), with: .color(.black.opacity(0.45 * alpha)))
                    ctx.fill(Path(ellipseIn: dot), with: .color(item.layer.tint.opacity(alpha)))

                    ctx.draw(title, at: CGPoint(x: x0, y: labelY), anchor: .topLeading)
                    ctx.draw(detail, at: CGPoint(x: x0, y: labelY + 17), anchor: .topLeading)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityElement()
        .accessibilityLabel(Text(EarthLayer.allCases.map { "\($0.title), \($0.detail(units: units))" }.joined(separator: ". ")))
    }
}
