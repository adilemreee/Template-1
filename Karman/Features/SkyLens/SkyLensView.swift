import SwiftUI

/// Something drawn and labelled in the Sky Lens.
struct SkyLensObject: Identifiable, Equatable {
    enum Kind: Equatable { case planet, moon, sun, star, station, radiant }
    var id: String
    var kind: Kind
    var name: String
    var detail: String
    /// Direction in local (north, west, up) coordinates.
    var local: SIMD3<Double>
    var color: Color
    var magnitude: Double?
    var target: SkyTarget?

    static func == (a: SkyLensObject, b: SkyLensObject) -> Bool { a.id == b.id && a.local == b.local }
}

/// Holds the sky for the lens: stars, constellation figures and the moving bodies, recomputed
/// as time passes. Reads the sensors once per frame.
@MainActor
final class SkyLensEngine {
    let motion = SkyLensMotion()
    let camera = SkyLensCamera()
    let stars: [SkyLensMath.Star]
    let catalog = SkyCatalog.bundled
    private(set) var objects: [SkyLensObject] = []
    private(set) var equatorialToLocal = Mat3.identity
    private var computedAt: Date = .distantPast
    private var observer = GeoPoint(lat: 0, lon: 0)

    init() {
        if let url = Bundle.main.url(forResource: "stars", withExtension: "bin"), let data = try? Data(contentsOf: url) {
            stars = SkyLensMath.loadStars(data: data, maxMagnitude: 4.8)
        } else {
            stars = []
        }
    }

    /// Refreshes the slow-moving sky every second; satellites every frame.
    func update(observer: GeoPoint, now: Date, satellites: SatelliteEngine) {
        if now.timeIntervalSince(computedAt) > 1 || observer != self.observer {
            self.observer = observer
            computedAt = now
            equatorialToLocal = SkyLensMath.equatorialToLocal(date: now, observer: observer)
            objects = slowObjects(now: now)
        }
        objects.removeAll { $0.kind == .station }
        for (id, name) in [(25544, "ISS"), (48274, "Tiangong")] {
            guard let sat = satellites.propagator(id: id), let ecef = try? sat.ecef(at: now) else { continue }
            let look = SatGeo.lookAngles(observer: observer, target: ecef)
            objects.append(SkyLensObject(id: "sat-\(id)", kind: .station, name: name,
                                         detail: String(localized: "\(Int(look.rangeKm).formatted()) km away · orbiting at 7.7 km/s"),
                                         local: SkyLensMath.local(altitude: look.elevation, azimuth: look.azimuth),
                                         color: Theme.ice, magnitude: nil, target: .station(id)))
        }
    }

    private func slowObjects(now: Date) -> [SkyLensObject] {
        var out: [SkyLensObject] = []
        let toLocal = equatorialToLocal
        for body in Planets.Body.allCases {
            let p = Planets.position(body, at: now)
            out.append(SkyLensObject(id: body.rawValue, kind: .planet, name: body.name,
                                     detail: String(localized: "Magnitude \(p.magnitude.formatted(.number.precision(.fractionLength(1)))) · \(Self.au(p.eq.distance)) away · in \(Planets.zodiacConstellation(eclipticLon: p.eclipticLon))"),
                                     local: toLocal.apply(SkyLensMath.equatorial(p.eq)), color: body.color, magnitude: p.magnitude, target: .planet(body)))
        }
        let moon = Astro.moonHorizontal(at: now, observer: observer)
        let phase = Astro.moonPhase(now)
        out.append(SkyLensObject(id: "moon", kind: .moon, name: String(localized: "Moon"),
                                 detail: "\(phase.name) · \(Int((phase.illumination * 100).rounded()))% lit · \(Int(phase.distanceKm).formatted()) km",
                                 local: SkyLensMath.local(altitude: moon.altitude, azimuth: moon.azimuth), color: Color(white: 0.92), magnitude: -12, target: .moon))
        let sun = Astro.horizontal(Astro.sun(now).eq, at: now, observer: observer)
        out.append(SkyLensObject(id: "sun", kind: .sun, name: String(localized: "Sun"), detail: String(localized: "Never look at the Sun directly"),
                                 local: SkyLensMath.local(altitude: sun.altitude, azimuth: sun.azimuth), color: Theme.sun, magnitude: -26.7, target: nil))
        for s in catalog?.stars ?? [] {
            out.append(SkyLensObject(id: "star-\(s.name)", kind: .star, name: s.name,
                                     detail: String(localized: "Star · magnitude \(s.magnitude.formatted(.number.precision(.fractionLength(1))))"),
                                     local: toLocal.apply(SkyLensMath.equatorial(raDegrees: s.position.ra, decDegrees: s.position.dec)),
                                     color: .white, magnitude: s.magnitude, target: .star(s.name)))
        }
        for o in MeteorShowers.upcoming(from: now, within: 3) where o.isActive {
            out.append(SkyLensObject(id: "radiant-\(o.shower.id)", kind: .radiant, name: String(localized: "\(o.shower.name) radiant"),
                                     detail: String(localized: "Meteors seem to fly out of this point · up to \(Int(o.shower.zhr)) an hour at the peak"),
                                     local: toLocal.apply(SkyLensMath.equatorial(raDegrees: o.shower.radiantRA, decDegrees: o.shower.radiantDec)),
                                     color: Theme.auroraViolet, magnitude: nil, target: .radiant(o.shower.id)))
        }
        return out
    }

    /// Local direction of a target (constellations by their label point; radiants even when not active).
    func direction(of target: SkyTarget) -> (SIMD3<Double>, String)? {
        switch target {
        case .constellation(let id):
            guard let c = catalog?.constellations.first(where: { $0.id == id }) else { return nil }
            return (equatorialToLocal.apply(SkyLensMath.equatorial(raDegrees: c.label.ra, decDegrees: c.label.dec)), c.name)
        case .radiant(let id):
            if let o = objects.first(where: { $0.target == target }) { return (o.local, o.name) }
            guard let s = MeteorShowers.all.first(where: { $0.id == id }) else { return nil }
            return (equatorialToLocal.apply(SkyLensMath.equatorial(raDegrees: s.radiantRA, decDegrees: s.radiantDec)), String(localized: "\(s.name) radiant"))
        default:
            guard let o = objects.first(where: { $0.target == target }) else { return nil }
            return (o.local, o.name)
        }
    }

    static func au(_ d: Double) -> String {
        d < 0.1 ? "\(Int(d * 149_597_870.7).formatted()) km" : "\(d.formatted(.number.precision(.fractionLength(2)))) au"
    }
}

/// Point the phone at the sky: stars, constellations, planets, the Moon and the space stations,
/// labelled where they really are, with a finder that guides you to any of them.
struct SkyLensView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var engine = SkyLensEngine()
    @State private var cameraOn = false
    @State private var nightMode = false
    @State private var fov = 66.0
    @State private var pinchBase: Double?
    @State private var focused: SkyLensObject?
    @State private var foundTarget = false
    @State private var showPicker = false
    @State private var cameraDenied = false
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if cameraOn {
                SkyLensCameraPreview(session: engine.camera.session)
                    .ignoresSafeArea()
                    .opacity(nightMode ? 0.3 : 0.85)
            } else {
                LinearGradient(colors: [Color(red: 0.01, green: 0.02, blue: 0.06), Color(red: 0.03, green: 0.05, blue: 0.12)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
            if let observer = model.location.point {
                sky(observer: observer)
                    .ignoresSafeArea()
                    .gesture(MagnifyGesture()
                        .onChanged { value in
                            guard !cameraOn else { return }
                            let base = pinchBase ?? fov
                            pinchBase = base
                            fov = max(18, min(100, base / value.magnification))
                        }
                        .onEnded { _ in pinchBase = nil })
                chrome
            } else {
                noLocation
            }
        }
        .colorMultiply(nightMode ? Color(red: 1, green: 0.28, blue: 0.22) : .white)
        .statusBarHidden()
        .onAppear {
            engine.motion.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            engine.motion.stop()
            engine.camera.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            model.skyLensTarget = nil
        }
        .sheet(isPresented: $showPicker) {
            SkyLensPicker(engine: engine) { target in
                model.skyLensTarget = target
                foundTarget = false
                showPicker = false
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.ultraThinMaterial)
        }
        .alert("Camera access is off", isPresented: $cameraDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Allow camera access in Settings to see the sky labels over the live view. The Sky Lens works without it, too.")
        }
    }

    // MARK: The sky

    private func sky(observer: GeoPoint) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            Canvas { ctx, size in
                engine.motion.update()
                engine.update(observer: observer, now: timeline.date, satellites: model.satellites)
                guard let deviceFromLocal = engine.motion.deviceFromLocal else { return }
                draw(&ctx, size: size, deviceFromLocal: deviceFromLocal)
            }
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
        .onTapGesture { point in focus(at: point) }
        .accessibilityElement()
        .accessibilityLabel(Text("Sky Lens. Point your phone at the sky."))
        .accessibilityValue(Text(focused.map { "\($0.name). \($0.detail)" } ?? ""))
    }

    private var verticalFOV: Double { cameraOn ? (engine.camera.verticalFOV ?? 66) : fov }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, deviceFromLocal: Mat3) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let focal = SkyLensMath.focal(height: size.height, verticalFOVDegrees: verticalFOV)
        let zoom = max(0.8, min(2.2, 66 / verticalFOV))
        let e2l = engine.equatorialToLocal
        func screen(_ local: SIMD3<Double>) -> CGPoint? {
            SkyLensMath.project(deviceFromLocal.apply(local), center: center, focal: focal)
        }
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)

        // Ground below the horizon.
        let up = deviceFromLocal.apply(SIMD3(0, 0, 1))
        let ground = SkyLensMath.groundPolygon(up: up, size: size, focal: focal)
        if ground.count >= 3 {
            var path = Path()
            path.addLines(ground)
            path.closeSubpath()
            ctx.fill(path, with: .color(Color(red: 0.06, green: 0.05, blue: 0.04).opacity(cameraOn ? 0.45 : 0.82)))
        }

        // Horizon and compass points.
        var horizon = Path()
        var last: CGPoint?
        for az in stride(from: 0.0, through: 360, by: 2) {
            if let p = screen(SkyLensMath.local(altitude: 0, azimuth: az)), bounds.contains(p) {
                if let l = last, hypot(l.x - p.x, l.y - p.y) < size.height { horizon.addLine(to: p) } else { horizon.move(to: p) }
                last = p
            } else {
                last = nil
            }
        }
        ctx.stroke(horizon, with: .color(Theme.ice.opacity(0.55)), lineWidth: 1)
        for (az, label) in [(0.0, "N"), (45, "NE"), (90, "E"), (135, "SE"), (180, "S"), (225, "SW"), (270, "W"), (315, "NW")] {
            if let p = screen(SkyLensMath.local(altitude: 1.5, azimuth: az)), bounds.contains(p) {
                ctx.draw(Text(verbatim: label).font(.system(size: label.count == 1 ? 15 : 11, weight: .bold)).foregroundStyle(label == "N" ? Theme.quake : Theme.ice), at: p, anchor: .bottom)
            }
        }

        // Constellation figures and names.
        if let catalog = engine.catalog {
            var above = Path(), below = Path()
            for c in catalog.constellations {
                for line in c.lines {
                    var prev: (CGPoint, Bool)?
                    for pt in line {
                        let l = e2l.apply(SkyLensMath.equatorial(raDegrees: pt.ra, decDegrees: pt.dec))
                        guard let p = screen(l) else { prev = nil; continue }
                        if let (q, qUp) = prev, bounds.contains(p) || bounds.contains(q) {
                            let target = (qUp && l.z > 0) ? 0 : 1
                            if target == 0 { above.move(to: q); above.addLine(to: p) } else { below.move(to: q); below.addLine(to: p) }
                        }
                        prev = (p, l.z > 0)
                    }
                }
            }
            ctx.stroke(above, with: .color(Theme.ice.opacity(0.32)), lineWidth: 1)
            ctx.stroke(below, with: .color(Theme.ice.opacity(0.10)), lineWidth: 1)
            for c in catalog.constellations where c.rank <= (verticalFOV < 45 ? 3 : 2) {
                let l = e2l.apply(SkyLensMath.equatorial(raDegrees: c.label.ra, decDegrees: c.label.dec))
                guard let p = screen(l), bounds.contains(p) else { continue }
                ctx.draw(Text(c.name.uppercased()).font(.system(size: 9.5, weight: .heavy)).tracking(1.6)
                            .foregroundStyle(Theme.ice.opacity(l.z > 0 ? 0.55 : 0.2)), at: p)
            }
        }

        // Stars, batched by brightness.
        let radii: [Double] = [3.4, 2.6, 2.0, 1.5, 1.15, 0.85]
        let alphas: [Double] = [1, 0.95, 0.85, 0.7, 0.55, 0.42]
        var buckets = Array(repeating: Path(), count: 12)
        for s in engine.stars {
            let l = e2l.apply(s.direction)
            guard let p = screen(l), bounds.contains(p) else { continue }
            let b = s.magnitude < 0.5 ? 0 : (s.magnitude < 1.5 ? 1 : (s.magnitude < 2.5 ? 2 : (s.magnitude < 3.5 ? 3 : (s.magnitude < 4.2 ? 4 : 5))))
            let r = radii[b] * zoom
            buckets[b + (l.z > 0 ? 0 : 6)].addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
        for i in 0..<12 {
            ctx.fill(buckets[i], with: .color(.white.opacity(alphas[i % 6] * (i < 6 ? 1 : 0.28))))
        }

        // Named stars, planets, the Moon, the Sun, stations and radiants.
        for o in engine.objects {
            guard let p = screen(o.local), bounds.contains(p) else { continue }
            let visible = o.local.z > 0
            let dim = visible ? 1.0 : 0.35
            switch o.kind {
            case .star:
                guard (o.magnitude ?? 9) < (verticalFOV < 45 ? 2.6 : 1.6) else { continue }
                ctx.draw(Text(o.name).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.7 * dim)),
                         at: CGPoint(x: p.x + 7, y: p.y), anchor: .leading)
            case .planet, .station, .radiant:
                let r = o.kind == .planet ? max(3.5, 5.5 - (o.magnitude ?? 1)) * zoom : 4 * zoom
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 3, y: p.y - r * 3, width: r * 6, height: r * 6)),
                         with: .radialGradient(Gradient(colors: [o.color.opacity(0.5 * dim), o.color.opacity(0)]), center: p, startRadius: r * 0.5, endRadius: r * 3))
                if o.kind == .radiant {
                    for k in 0..<8 {
                        let a = Double(k) * .pi / 4
                        var ray = Path()
                        ray.move(to: CGPoint(x: p.x + cos(a) * r, y: p.y + sin(a) * r))
                        ray.addLine(to: CGPoint(x: p.x + cos(a) * r * 2.6, y: p.y + sin(a) * r * 2.6))
                        ctx.stroke(ray, with: .color(o.color.opacity(dim)), lineWidth: 1.2)
                    }
                } else {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(o.color.opacity(dim)))
                }
                ctx.draw(Text(o.name).font(.system(size: 12, weight: .bold)).foregroundStyle(o.color.opacity(dim)),
                         at: CGPoint(x: p.x + r + 6, y: p.y), anchor: .leading)
            case .moon, .sun:
                // True angular size (about half a degree), but never smaller than a fingertip target.
                let r = max(9, focal * tan(0.26 * Astro.deg))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 3, y: p.y - r * 3, width: r * 6, height: r * 6)),
                         with: .radialGradient(Gradient(colors: [o.color.opacity(0.4 * dim), o.color.opacity(0)]), center: p, startRadius: r, endRadius: r * 3))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(o.color.opacity(dim)))
                ctx.draw(Text(o.name).font(.system(size: 13, weight: .bold)).foregroundStyle(o.color.opacity(dim)),
                         at: CGPoint(x: p.x, y: p.y + r + 6), anchor: .top)
            }
        }

        // Target finder.
        if let target = model.skyLensTarget, let (local, name) = engine.direction(of: target) {
            let d = deviceFromLocal.apply(local)
            let p = SkyLensMath.project(d, center: center, focal: focal)
            if let p, CGRect(origin: .zero, size: size).insetBy(dx: 30, dy: 90).contains(p) {
                let pulse = 18 + 4 * sin(Date().timeIntervalSinceReferenceDate * 4)
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - pulse, y: p.y - pulse, width: pulse * 2, height: pulse * 2)), with: .color(Theme.aurora), lineWidth: 2)
                if SkyLensMath.angle(d, SIMD3(0, 0, -1)) < 7 && !foundTarget {
                    DispatchQueue.main.async {
                        foundTarget = true
                        Haptics.shared.thud()
                    }
                }
            } else {
                drawArrow(&ctx, size: size, toward: d, label: name)
            }
        }

        // Reticle.
        let ring = Path(ellipseIn: CGRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44))
        ctx.stroke(ring, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
        let nearest = engine.objects
            .filter { $0.kind != .star || ($0.magnitude ?? 9) < 2.6 }
            .min { SkyLensMath.angle(deviceFromLocal.apply($0.local), SIMD3(0, 0, -1)) < SkyLensMath.angle(deviceFromLocal.apply($1.local), SIMD3(0, 0, -1)) }
        let found = nearest.flatMap { SkyLensMath.angle(deviceFromLocal.apply($0.local), SIMD3(0, 0, -1)) < 4 ? $0 : nil }
        if found?.id != focused?.id {
            DispatchQueue.main.async {
                withAnimation(.snappy) { focused = found }
                if found != nil { Haptics.shared.select() }
            }
        }
    }

    private func drawArrow(_ ctx: inout GraphicsContext, size: CGSize, toward d: SIMD3<Double>, label: String) {
        let dx = d.x, dy = -d.y
        let len = max(1e-6, hypot(dx, dy))
        let ux = dx / len, uy = dy / len
        let rx = size.width / 2 - 46, ry = size.height / 2 - 130
        let t = min(rx / max(abs(ux), 1e-6), ry / max(abs(uy), 1e-6))
        let tip = CGPoint(x: size.width / 2 + ux * t, y: size.height / 2 + uy * t)
        let angle = atan2(uy, ux)
        var arrow = Path()
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: tip.x - cos(angle - 0.45) * 22, y: tip.y - sin(angle - 0.45) * 22))
        arrow.addLine(to: CGPoint(x: tip.x - cos(angle + 0.45) * 22, y: tip.y - sin(angle + 0.45) * 22))
        arrow.closeSubpath()
        ctx.fill(arrow, with: .color(Theme.aurora))
        ctx.draw(Text(label).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.aurora),
                 at: CGPoint(x: tip.x - ux * 34, y: tip.y - uy * 34))
    }

    private func focus(at point: CGPoint) {
        guard let dfl = engine.motion.deviceFromLocal else { return }
        let size = canvasSize
        guard size.height > 0 else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let focal = SkyLensMath.focal(height: size.height, verticalFOVDegrees: verticalFOV)
        let dir = SkyLensMath.direction(at: point, center: center, focal: focal)
        let best = engine.objects.min { SkyLensMath.angle(dfl.apply($0.local), dir) < SkyLensMath.angle(dfl.apply($1.local), dir) }
        if let best, SkyLensMath.angle(dfl.apply(best.local), dir) < 6 {
            Haptics.shared.select()
            withAnimation(.snappy) { focused = best }
        }
    }

    // MARK: Chrome

    private var chrome: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(Text("Close"))
                VStack(alignment: .leading, spacing: 1) {
                    Text("SKY LENS").eyebrow(Theme.ice)
                    Text(statusLine).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer()
                Button {
                    toggleCamera()
                } label: {
                    Image(systemName: cameraOn ? "camera.fill" : "camera").font(.system(size: 15, weight: .semibold)).frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(Text(cameraOn ? "Hide the camera" : "Show the camera"))
                Button {
                    Haptics.shared.select()
                    nightMode.toggle()
                } label: {
                    Image(systemName: nightMode ? "eye.fill" : "eye").font(.system(size: 15, weight: .semibold)).frame(width: 40, height: 40)
                        .foregroundStyle(nightMode ? Color.red : .white)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(Text("Night vision mode"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            if engine.motion.calibration == .uncalibrated || engine.motion.calibration == .low {
                Label("Wave your phone in a figure eight to calibrate the compass", systemImage: "infinity")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .glassEffect(.regular, in: Capsule())
            }
            Spacer()
            if let focused {
                focusCard(focused)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Button {
                Haptics.shared.tap()
                showPicker = true
            } label: {
                Label(model.skyLensTarget == nil ? "Find a planet, star or constellation" : "Find something else", systemImage: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var statusLine: String {
        if let target = model.skyLensTarget, let (_, name) = engine.direction(of: target) {
            return foundTarget ? String(localized: "Found \(name)") : String(localized: "Follow the arrow to \(name)")
        }
        return cameraOn ? String(localized: "Live view · pinch is off with the camera") : String(localized: "Pinch to zoom · tap a light to name it")
    }

    private func focusCard(_ o: SkyLensObject) -> some View {
        let h = SkyLensMath.altAz(o.local)
        return HStack(spacing: 12) {
            Circle().fill(o.color).frame(width: 12, height: 12).shadow(color: o.color, radius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(o.name).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                Text(o.detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                Text(h.altitude >= 0 ? String(localized: "\(Int(h.altitude))° up, toward \(GeoPoint.compassName(h.azimuth))")
                     : String(localized: "Below the horizon right now"))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(h.altitude >= 0 ? Theme.ice : Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var noLocation: some View {
        VStack(spacing: 14) {
            Image(systemName: "location.slash").font(.system(size: 34)).foregroundStyle(Theme.ice)
            Text("The Sky Lens needs your location").font(.display(20, weight: .bold)).foregroundStyle(.white)
            Text("Where the stars appear depends on where you stand. Your location stays on this device.")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            Button("Use my location") { model.location.useDeviceLocation() }
                .primaryAction()
            Button("Close") { dismiss() }
                .buttonStyle(.glass)
        }
        .padding(30)
    }

    private func toggleCamera() {
        Haptics.shared.select()
        if cameraOn {
            cameraOn = false
            engine.camera.stop()
            return
        }
        if SkyLensCamera.isAuthorized {
            engine.camera.start()
            cameraOn = true
        } else if SkyLensCamera.isDenied {
            cameraDenied = true
        } else {
            Task {
                if await SkyLensCamera.requestAccess() {
                    engine.camera.start()
                    cameraOn = true
                }
            }
        }
    }
}

/// Choose what the Sky Lens should guide you to.
private struct SkyLensPicker: View {
    let engine: SkyLensEngine
    let pick: (SkyTarget) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Planets & Moon") {
                    ForEach(engine.objects.filter { $0.kind == .planet || $0.kind == .moon }) { o in row(o) }
                }
                Section("Space stations") {
                    ForEach(engine.objects.filter { $0.kind == .station }) { o in row(o) }
                }
                Section("Bright stars") {
                    ForEach(engine.objects.filter { $0.kind == .star }.prefix(24)) { o in row(o) }
                }
                if let catalog = engine.catalog {
                    Section("Constellations") {
                        ForEach(catalog.constellations.filter { $0.rank == 1 }.sorted { $0.name < $1.name }) { c in
                            Button {
                                pick(.constellation(c.id))
                            } label: {
                                HStack {
                                    Text(c.name).foregroundStyle(.white)
                                    if let meaning = c.meaning { Text(meaning).foregroundStyle(Theme.textTertiary) }
                                    Spacer()
                                    altitudeTag(engine.direction(of: .constellation(c.id))?.0)
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Find in the sky")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ o: SkyLensObject) -> some View {
        Button {
            if let t = o.target { pick(t) }
        } label: {
            HStack {
                Circle().fill(o.color).frame(width: 9, height: 9)
                Text(o.name).foregroundStyle(.white)
                Spacer()
                altitudeTag(o.local)
            }
        }
    }

    private func altitudeTag(_ local: SIMD3<Double>?) -> some View {
        let alt = local.map { SkyLensMath.altAz($0).altitude } ?? -90
        return Text(alt > 0 ? "\(Int(alt))° up" : String(localized: "below horizon"))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(alt > 0 ? Theme.ice : Theme.textTertiary)
    }
}
