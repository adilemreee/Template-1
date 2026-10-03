import SwiftUI
import simd

/// The Solar System right now, seen from outside: the eight planets on their real orbits (distances
/// compressed so Mercury and Neptune share the screen), the asteroid belt, and a time machine to
/// watch them move. Drag to turn it, pinch to zoom, tap a planet for its story.
struct OrreryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var dayOffset: Double = 0
    @State private var playAnchor: (start: Date, offset: Double)?
    @State private var speed: Speed = .week
    @State private var azimuth: Double = -0.6
    @State private var tilt: Double = 0.85
    @State private var zoom: Double = 1
    @State private var gestureStart: (azimuth: Double, tilt: Double)?
    @State private var zoomStart: Double?
    @State private var selected: SolarSystem.Planet? = .earth
    @State private var tonight: [Planets.Visibility] = []

    /// Days of simulated time per second of playback.
    enum Speed: Double, CaseIterable, Identifiable {
        case day = 1, week = 7, month = 30, year = 365
        var id: Double { rawValue }
        var label: String {
            switch self {
            case .day: String(localized: "1 day / s")
            case .week: String(localized: "1 week / s")
            case .month: String(localized: "1 month / s")
            case .year: String(localized: "1 year / s")
            }
        }
    }

    static let span: ClosedRange<Double> = -3_650...3_650

    private var playing: Bool { playAnchor != nil }

    private func offset(at now: Date) -> Double {
        guard let a = playAnchor else { return dayOffset }
        let v = a.offset + now.timeIntervalSince(a.start) * speed.rawValue
        return min(Self.span.upperBound, max(Self.span.lowerBound, v))
    }

    var body: some View {
        TimelineView(.animation(paused: !playing)) { context in
            let days = offset(at: context.date)
            let date = Date().addingTimeInterval(days * 86_400)
            ZStack {
                GeometryReader { geo in
                    OrreryCanvas(date: date, view: OrreryProjection(size: geo.size, azimuth: azimuth, tilt: tilt, zoom: zoom), selected: selected)
                        .contentShape(Rectangle())
                        .gesture(rotate.simultaneously(with: magnify))
                        .onTapGesture(coordinateSpace: .local) { location in
                            select(near: location, view: OrreryProjection(size: geo.size, azimuth: azimuth, tilt: tilt, zoom: zoom), date: date)
                        }
                }
                .ignoresSafeArea()

                VStack(spacing: 10) {
                    header(date: date, days: days)
                    Spacer()
                    if let selected {
                        PlanetCard(planet: selected, date: date, tonight: tonight.first { $0.body == selected.skyBody }) {
                            withAnimation(.snappy) { self.selected = nil }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    controls(days: days)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            if let observer = model.location.point {
                tonight = await Task.detached(priority: .utility) { Planets.tonight(observer: observer) }.value
            }
        }
    }

    // MARK: Gestures

    private var rotate: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                let start = gestureStart ?? (azimuth, tilt)
                gestureStart = start
                azimuth = start.azimuth + v.translation.width * 0.008
                tilt = min(1.45, max(0, start.tilt - v.translation.height * 0.006))
            }
            .onEnded { _ in gestureStart = nil }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let start = zoomStart ?? zoom
                zoomStart = start
                zoom = min(7, max(0.6, start * v.magnification))
            }
            .onEnded { _ in zoomStart = nil }
    }

    private func select(near location: CGPoint, view: OrreryProjection, date: Date) {
        var best: (planet: SolarSystem.Planet, distance: CGFloat)?
        for p in SolarSystem.Planet.allCases {
            let pt = view.project(SolarSystem.position(p, at: date)).point
            let d = hypot(pt.x - location.x, pt.y - location.y)
            if d < 30, d < (best?.distance ?? .infinity) { best = (p, d) }
        }
        Haptics.shared.select()
        withAnimation(.snappy) { selected = best?.planet }
    }

    // MARK: Chrome

    private func header(date: Date, days: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sun.max.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.sun)
                Text("SOLAR SYSTEM").eyebrow(Theme.sun)
                Spacer()
                if abs(days) > 0.5 {
                    Button {
                        Haptics.shared.tap()
                        playAnchor = nil
                        withAnimation(.snappy) { dayOffset = 0 }
                    } label: {
                        Text("Today").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 12).frame(height: 34)
                    }
                    .buttonStyle(.glass)
                }
                Button {
                    Haptics.shared.tap()
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(Text("Close"))
            }
            Text(date.formatted(.dateTime.day().month(.wide).year()))
                .font(.display(24, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text(abs(days) < 0.5 ? String(localized: "Where the planets are right now. Distances compressed to fit.")
                 : Fmt.relativeDays(days))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(16)
        .glassPanel(cornerRadius: 26)
        .padding(.top, 8)
    }

    private func controls(days: Double) -> some View {
        HStack(spacing: 10) {
            Button {
                Haptics.shared.tap()
                if playing {
                    dayOffset = offset(at: Date())
                    playAnchor = nil
                } else {
                    if dayOffset >= Self.span.upperBound - 1 { dayOffset = 0 }
                    playAnchor = (Date(), dayOffset)
                }
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.sun))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(playing ? "Pause" : "Play"))

            Slider(value: Binding(get: { days }, set: { v in
                dayOffset = v
                if playing { playAnchor = (Date(), v) }
            }), in: Self.span)
            .tint(Theme.sun)
            .accessibilityLabel(Text("Date"))
            .accessibilityValue(Text(Date().addingTimeInterval(days * 86_400).formatted(date: .abbreviated, time: .omitted)))

            Menu {
                Picker("Speed", selection: Binding(get: { speed }, set: { newSpeed in
                    // Keep the playhead where it is: re-anchor at the old speed before switching.
                    if playing {
                        let now = Date()
                        playAnchor = (now, offset(at: now))
                    }
                    speed = newSpeed
                })) {
                    ForEach(Speed.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Text(speed.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .glassEffect(.regular.interactive(), in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: 26)
    }
}

// MARK: - Projection

/// Orthographic view of the ecliptic from outside: turned by an azimuth, tipped by a tilt
/// (0 = straight down from ecliptic north), with distances from the Sun compressed by r^0.3.
struct OrreryProjection {
    var size: CGSize
    var azimuth: Double
    var tilt: Double
    var zoom: Double

    static let exponent = 0.3

    var center: CGPoint { CGPoint(x: size.width / 2, y: size.height * 0.47) }

    /// Points per compressed unit: Neptune's orbit spans the width at zoom 1.
    var scale: Double { Double(min(size.width, size.height * 0.8)) / 2 / pow(30.3, Self.exponent) * 0.94 * zoom }

    func compress(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let r = simd_length(p)
        return r < 1e-9 ? p : p / r * pow(r, Self.exponent)
    }

    /// Screen offset (x right, y up, in compressed units) and depth (larger is farther) of a vector.
    func rotate(_ v: SIMD3<Double>) -> (x: Double, y: Double, depth: Double) {
        let ca = cos(azimuth), sa = sin(azimuth)
        let x = v.x * ca - v.y * sa
        let y = v.x * sa + v.y * ca
        return (x, y * cos(tilt) + v.z * sin(tilt), y * sin(tilt) - v.z * cos(tilt))
    }

    func project(_ p: SIMD3<Double>) -> (point: CGPoint, depth: Double) {
        let r = rotate(compress(p))
        return (CGPoint(x: center.x + r.x * scale, y: center.y - r.y * scale), r.depth)
    }
}

// MARK: - Canvas

private struct OrreryCanvas: View {
    let date: Date
    let view: OrreryProjection
    let selected: SolarSystem.Planet?

    /// Orbits change too slowly to matter over the playback span: drawn from today's elements.
    private static let orbits: [SolarSystem.Planet: [SIMD3<Double>]] =
        Dictionary(uniqueKeysWithValues: SolarSystem.Planet.allCases.map { ($0, SolarSystem.orbit($0, at: Date())) })

    private struct Asteroid { var a: Double; var phase: Double; var incl: Double; var node: Double }
    /// A sprinkling of the main belt, each on its own Keplerian clock.
    private static let belt: [Asteroid] = {
        var rng = SplitMix64(seed: 2026)
        return (0..<720).map { _ in
            let u = (rng.unit() + rng.unit() + rng.unit()) / 3   // bunched toward the middle of the belt
            return Asteroid(a: 2.1 + 1.25 * u, phase: rng.unit() * 2 * .pi, incl: (rng.unit() - 0.5) * 0.25, node: rng.unit() * 2 * .pi)
        }
    }()

    private static let stars: [(x: Double, y: Double, b: Double)] = {
        var rng = SplitMix64(seed: 7)
        return (0..<260).map { _ in (rng.unit(), rng.unit(), pow(rng.unit(), 3)) }
    }()

    var body: some View {
        Canvas { ctx, size in
            // Background stars.
            for s in Self.stars {
                let r = 0.5 + s.b * 1.1
                ctx.fill(Path(ellipseIn: CGRect(x: s.x * size.width - r, y: s.y * size.height - r, width: r * 2, height: r * 2)),
                         with: .color(.white.opacity(0.15 + 0.55 * s.b)))
            }

            // Orbits, Earth's highlighted.
            for planet in SolarSystem.Planet.allCases {
                guard let loop = Self.orbits[planet] else { continue }
                var path = Path()
                for (k, p) in loop.enumerated() {
                    let pt = view.project(p).point
                    if k == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                let isEarth = planet == .earth, isSelected = planet == selected
                ctx.stroke(path, with: .color(isEarth ? Color(red: 0.45, green: 0.72, blue: 1.0).opacity(0.5) : .white.opacity(isSelected ? 0.4 : 0.14)),
                           lineWidth: isEarth || isSelected ? 1.3 : 0.8)
            }

            // A fading trail behind each planet: the last eighth of its year.
            for planet in SolarSystem.Planet.allCases {
                let span = planet.period * 365.25 * 86_400 * 0.12
                let tint = Self.colors(planet).light
                var previous = view.project(SolarSystem.position(planet, at: date)).point
                for k in 1...24 {
                    let f = Double(k) / 24
                    let pt = view.project(SolarSystem.position(planet, at: date.addingTimeInterval(-span * f))).point
                    var segment = Path()
                    segment.move(to: previous)
                    segment.addLine(to: pt)
                    ctx.stroke(segment, with: .color(tint.opacity(0.55 * (1 - f))), lineWidth: 1.6)
                    previous = pt
                }
            }

            // The asteroid belt.
            let days = (Astro.julianDate(date) - 2451545.0)
            for rock in Self.belt {
                let angle = rock.phase + 2 * .pi * days / (365.25 * pow(rock.a, 1.5))
                let p = SIMD3(rock.a * cos(angle), rock.a * sin(angle), rock.a * rock.incl * sin(angle - rock.node))
                let pt = view.project(p).point
                ctx.fill(Path(CGRect(x: pt.x - 0.5, y: pt.y - 0.5, width: 1.1, height: 1.1)), with: .color(Color(red: 0.85, green: 0.78, blue: 0.68).opacity(0.38)))
            }

            // Planets and the Sun, far to near.
            let sun = view.project(.zero).point
            var bodies: [(planet: SolarSystem.Planet?, point: CGPoint, depth: Double)] = [(nil, sun, 0)]
            for planet in SolarSystem.Planet.allCases {
                let pr = view.project(SolarSystem.position(planet, at: date))
                bodies.append((planet, pr.point, pr.depth))
            }
            bodies.sort { $0.depth > $1.depth }
            let sizeScale = min(1.6, max(0.8, sqrt(view.zoom)))
            for b in bodies {
                guard let planet = b.planet else {
                    drawSun(&ctx, at: sun, zoom: view.zoom)
                    continue
                }
                let r = Self.radius(planet) * sizeScale
                drawPlanet(&ctx, planet, at: b.point, radius: r, sun: sun)
                if planet == selected {
                    ctx.stroke(Path(ellipseIn: CGRect(x: b.point.x - r - 6, y: b.point.y - r - 6, width: (r + 6) * 2, height: (r + 6) * 2)),
                               with: .color(Theme.sun.opacity(0.9)), lineWidth: 1.2)
                }
            }

            // Names where there is room: the selected planet first, then Earth, then outward.
            var taken: [CGRect] = []
            var text = ctx
            text.addFilter(.shadow(color: .black, radius: 2))
            let order = SolarSystem.Planet.allCases.sorted { a, b in
                func rank(_ p: SolarSystem.Planet) -> Int { p == selected ? 0 : (p == .earth ? 1 : 2) }
                return rank(a) != rank(b) ? rank(a) < rank(b) : a.period > b.period
            }
            for planet in order {
                guard let b = bodies.first(where: { $0.planet == planet }) else { continue }
                let isSelected = planet == selected
                let r = Self.radius(planet) * sizeScale
                let label = text.resolve(Text(planet.name.uppercased())
                    .font(.system(size: 9.5, weight: isSelected ? .heavy : .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.62)))
                let m = label.measure(in: size)
                let top = b.point.y + r + (isSelected ? 10 : 5)
                let rect = CGRect(x: b.point.x - m.width / 2, y: top, width: m.width, height: m.height).insetBy(dx: -3, dy: -1)
                guard isSelected || !taken.contains(where: { $0.intersects(rect) }) else { continue }
                taken.append(rect)
                text.draw(label, at: CGPoint(x: b.point.x, y: top), anchor: .top)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("The Solar System on \(date.formatted(date: .long, time: .omitted))"))
    }

    /// Not to scale (Jupiter would be a pixel at this zoom): sized so each reads at a glance.
    static func radius(_ p: SolarSystem.Planet) -> Double {
        switch p {
        case .mercury: 3.2
        case .venus: 4.6
        case .earth: 5.0
        case .mars: 4.0
        case .jupiter: 9.5
        case .saturn: 8.0
        case .uranus: 6.2
        case .neptune: 6.0
        }
    }

    static func colors(_ p: SolarSystem.Planet) -> (light: Color, dark: Color) {
        switch p {
        case .mercury: (Color(red: 0.82, green: 0.78, blue: 0.74), Color(red: 0.25, green: 0.23, blue: 0.22))
        case .venus: (Color(red: 1.0, green: 0.94, blue: 0.78), Color(red: 0.45, green: 0.36, blue: 0.22))
        case .earth: (Color(red: 0.55, green: 0.80, blue: 1.0), Color(red: 0.05, green: 0.16, blue: 0.40))
        case .mars: (Color(red: 1.0, green: 0.58, blue: 0.40), Color(red: 0.38, green: 0.12, blue: 0.06))
        case .jupiter: (Color(red: 0.98, green: 0.88, blue: 0.72), Color(red: 0.45, green: 0.32, blue: 0.22))
        case .saturn: (Color(red: 0.98, green: 0.88, blue: 0.62), Color(red: 0.42, green: 0.34, blue: 0.18))
        case .uranus: (Color(red: 0.70, green: 0.94, blue: 0.96), Color(red: 0.12, green: 0.34, blue: 0.40))
        case .neptune: (Color(red: 0.45, green: 0.62, blue: 1.0), Color(red: 0.06, green: 0.12, blue: 0.40))
        }
    }

    private func drawSun(_ ctx: inout GraphicsContext, at p: CGPoint, zoom: Double) {
        let glow = 32 * min(1.8, max(0.8, pow(zoom, 0.4)))
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - glow, y: p.y - glow, width: glow * 2, height: glow * 2)),
                 with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.78, blue: 0.4).opacity(0.55), Color(red: 1, green: 0.5, blue: 0.15).opacity(0.12), .clear]),
                                       center: p, startRadius: 0, endRadius: glow))
        let core = 9 * min(1.5, max(0.9, pow(zoom, 0.3)))
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - core, y: p.y - core, width: core * 2, height: core * 2)),
                 with: .radialGradient(Gradient(colors: [.white, Color(red: 1, green: 0.92, blue: 0.62), Color(red: 1, green: 0.66, blue: 0.24)]),
                                       center: p, startRadius: 0, endRadius: core))
    }

    private func drawPlanet(_ ctx: inout GraphicsContext, _ planet: SolarSystem.Planet, at p: CGPoint, radius r: Double, sun: CGPoint) {
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        // Lit from the Sun: the highlight leans toward it on screen.
        let dx = sun.x - p.x, dy = sun.y - p.y
        let len = max(1, hypot(dx, dy))
        let highlight = CGPoint(x: p.x + dx / len * r * 0.45, y: p.y + dy / len * r * 0.45)
        let tones = Self.colors(planet)

        if planet == .saturn { drawRings(&ctx, at: p, radius: r, front: false) }
        ctx.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [tones.light, tones.light.opacity(0.9), tones.dark]),
                                                              center: highlight, startRadius: 0, endRadius: r * 1.9))
        if planet == .jupiter {
            // A few cloud belts.
            var bands = ctx
            bands.clip(to: Path(ellipseIn: rect))
            for (y, h, a) in [(-0.42, 0.16, 0.22), (-0.08, 0.20, 0.28), (0.30, 0.14, 0.2)] {
                bands.fill(Path(CGRect(x: p.x - r, y: p.y + y * r, width: r * 2, height: h * r)), with: .color(Color(red: 0.55, green: 0.35, blue: 0.22).opacity(a)))
            }
        }
        if planet == .earth {
            ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -1, dy: -1)), with: .color(Color(red: 0.5, green: 0.8, blue: 1).opacity(0.5)), lineWidth: 1)
        }
        if planet == .saturn { drawRings(&ctx, at: p, radius: r, front: true) }
    }

    /// Saturn's rings, tipped like the real ones (pole at RA 40.6°, Dec 83.5°): the half behind the
    /// globe is drawn before it, the near half after.
    private func drawRings(_ ctx: inout GraphicsContext, at p: CGPoint, radius r: Double, front: Bool) {
        let ra = 40.589 * Astro.deg, dec = 83.537 * Astro.deg, eps = 23.43928 * Astro.deg
        let eq = SIMD3(cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec))
        let pole = SIMD3(eq.x, eq.y * cos(eps) + eq.z * sin(eps), -eq.y * sin(eps) + eq.z * cos(eps))
        let u = simd_normalize(simd_cross(pole, SIMD3(0, 0, 1)))
        let v = simd_cross(pole, u)
        // Two bands (the C/B rings and the A ring) as thick strokes at their middle radius.
        for (middle, width, alpha) in [(1.42, 0.30, 0.5), (1.88, 0.50, 0.72)] {
            var path = Path()
            var drawing = false
            for k in 0...72 {
                let a = 2 * Double.pi * Double(k) / 72
                let rot = view.rotate(u * cos(a) + v * sin(a))
                guard (rot.depth < 0) == front else { drawing = false; continue }
                let pt = CGPoint(x: p.x + rot.x * r * middle, y: p.y - rot.y * r * middle)
                if drawing { path.addLine(to: pt) } else { path.move(to: pt); drawing = true }
            }
            ctx.stroke(path, with: .color(Color(red: 0.92, green: 0.82, blue: 0.6).opacity(alpha)), lineWidth: max(0.8, width * r))
        }
    }
}

/// A tiny deterministic generator so the belt and the stars look the same every launch.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

// MARK: - Planet card

private struct PlanetCard: View {
    @Environment(AppModel.self) private var model
    let planet: SolarSystem.Planet
    let date: Date
    let tonight: Planets.Visibility?
    let close: () -> Void

    var body: some View {
        let units = model.settings.units
        let helio = SolarSystem.position(planet, at: date)
        let fromSun = simd_length(helio)
        let fromEarth = simd_length(helio - SolarSystem.position(.earth, at: date))
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(RadialGradient(colors: [OrreryCanvas.colors(planet).light, OrreryCanvas.colors(planet).dark], center: .init(x: 0.35, y: 0.35),
                                         startRadius: 1, endRadius: 16))
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(planet.name).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                    Text(String(localized: "A year lasts \(Self.period(planet.period))"))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textSecondary).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
            }
            HStack(spacing: 14) {
                stat(title: "FROM THE SUN", value: Self.au(fromSun))
                if planet != .earth {
                    stat(title: "FROM EARTH", value: Fmt.bigDistance(fromEarth * SolarSystem.kmPerAU, units: units))
                    stat(title: "LIGHT TAKES", value: Fmt.lightTime(SolarSystem.lightSeconds(au: fromEarth)))
                } else {
                    stat(title: "SUNLIGHT TAKES", value: Fmt.lightTime(SolarSystem.lightSeconds(au: fromSun)))
                }
            }
            Text(planet.fact)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            if let v = tonight, abs(date.timeIntervalSinceNow) < 86_400 {
                HStack(spacing: 6) {
                    Image(systemName: v.isVisible ? "eye.fill" : "eye.slash").font(.system(size: 11, weight: .semibold))
                    if v.isVisible, let best = v.bestTime {
                        Text("Visible tonight in \(v.constellation), best around \(best.formatted(date: .omitted, time: .shortened))")
                    } else {
                        Text("Not visible from you tonight")
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(v.isVisible ? Theme.sun : Theme.textTertiary)
            }
        }
        .padding(16)
        .glassPanel(cornerRadius: 26)
    }

    private func stat(title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.label(9, weight: .bold)).tracking(1.2).foregroundStyle(Theme.textTertiary)
            Text(value).font(.mono(13, weight: .semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    static func au(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(v < 10 ? 2 : 1))) + " au"
    }

    static func period(_ years: Double) -> String {
        years < 1.5 ? String(localized: "\(Int((years * 365.25).rounded())) days") : String(localized: "\(years.formatted(.number.precision(.fractionLength(1)))) years")
    }
}
