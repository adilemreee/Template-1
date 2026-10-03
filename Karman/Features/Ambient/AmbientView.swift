import SwiftUI
import UIKit

/// The nightstand globe: a slow tour of the living planet behind a big clock, dimmed at night,
/// with the screen kept awake. Tap to reveal the controls.
struct AmbientView: View {
    @Environment(AppModel.self) private var model
    @State private var caption: String = ""
    @State private var showControls = false
    @State private var shift = CGSize.zero

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let night = Self.isNight(ctx.date)
            ZStack {
                // Dim the whole scene at night so the room stays dark.
                Color.black.opacity(night ? 0.38 : 0.0).ignoresSafeArea().allowsHitTesting(false)
                VStack(spacing: 6) {
                    Text(ctx.date, format: .dateTime.hour().minute())
                        .font(.system(size: 76, weight: .thin, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(night ? Color(red: 1, green: 0.55, blue: 0.45) : .white)
                        .contentTransition(.numericText())
                        .shadow(color: .black.opacity(0.6), radius: 12)
                    Text(ctx.date, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle((night ? Color(red: 1, green: 0.55, blue: 0.45) : .white).opacity(0.7))
                    if !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(night ? 0.45 : 0.75))
                            .multilineTextAlignment(.center)
                            .padding(.top, 6)
                            .transition(.opacity)
                            .id(caption)
                    }
                }
                .padding(.top, 70)
                .frame(maxHeight: .infinity, alignment: .top)
                .offset(shift)
                .allowsHitTesting(false)

                VStack {
                    Spacer()
                    stats(night: night)
                        .padding(.bottom, 24)
                        .offset(x: -shift.width, y: -abs(shift.height) / 2)
                }
                .allowsHitTesting(false)

                if showControls {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                Haptics.shared.tap()
                                model.stopAmbient()
                            } label: {
                                Label("Exit", systemImage: "xmark").font(.system(size: 14, weight: .semibold)).padding(.horizontal, 6)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                        Spacer()
                    }
                    .transition(.opacity)
                }
            }
            .onChange(of: Calendar.current.component(.minute, from: ctx.date)) {
                // Drift the clock a little each minute so nothing burns into an OLED screen.
                withAnimation(.easeInOut(duration: 3)) {
                    shift = CGSize(width: Double.random(in: -14...14), height: Double.random(in: -10...16))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) { showControls.toggle() }
            if showControls {
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    withAnimation(.easeInOut(duration: 0.4)) { showControls = false }
                }
            }
        }
        .task { await tour() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .statusBarHidden()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Ambient globe"))
        .accessibilityHint(Text("Double-tap to show the exit button."))
    }

    private func stats(night: Bool) -> some View {
        let tint = night ? Color(red: 1, green: 0.55, blue: 0.45) : Color.white
        let kp = model.planet.snapshot.space?.kpNow ?? 0
        let pass = model.passes.first { $0.end > Date() }
        return HStack(spacing: 18) {
            stat("waveform.path.ecg", "\(model.planet.quakesLast24h.count)", String(localized: "quakes today"), tint)
            stat("sparkles", kp.formatted(.number.precision(.fractionLength(1))), "Kp", tint)
            if let pass {
                stat("person.2.fill", Fmt.time(pass.start), pass.noradID == 25544 ? "ISS" : "Tiangong", tint)
            }
        }
        .opacity(night ? 0.55 : 0.85)
    }

    private func stat(_ icon: String, _ value: String, _ label: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 11, weight: .medium)).opacity(0.7)
        }
        .foregroundStyle(tint)
    }

    static func isNight(_ date: Date) -> Bool {
        let h = Calendar.current.component(.hour, from: date)
        return h >= 22 || h < 6
    }

    // MARK: The tour

    private enum Scene: CaseIterable { case home, sunrise, quake, storm, aurora, night }

    /// Every 45 seconds the camera glides somewhere worth looking at, turning slowly in between.
    private func tour() async {
        var index = 0
        let order: [Scene] = [.home, .sunrise, .quake, .night, .storm, .aurora]
        while !Task.isCancelled {
            for _ in 0..<order.count {
                let scene = order[index % order.count]
                index += 1
                if let (pose, text) = shot(scene) {
                    model.globe.fly(to: pose, duration: 6)
                    model.globe.drift = (0.9, 0)
                    withAnimation(.easeInOut(duration: 1.2)) { caption = text }
                    break
                }
            }
            try? await Task.sleep(for: .seconds(45))
        }
    }

    private func shot(_ scene: Scene) -> (CameraPose, String)? {
        let now = Date()
        let sun = Astro.subsolarPoint(now)
        switch scene {
        case .home:
            guard let user = model.location.point else { return nil }
            return (CameraPose(lat: user.lat - 6, lon: user.lon, distance: 4.4, tilt: 18), model.location.placeName.map { String(localized: "Above \($0)") } ?? String(localized: "Above you"))
        case .sunrise:
            let lat = model.location.point?.lat ?? 20
            return (CameraPose(lat: max(-50, min(55, lat)), lon: Geo.normalizeLon(sun.lon - 88), distance: 3.0, tilt: 34, heading: 90),
                    String(localized: "Dawn sweeps west at 1,670 km/h at the equator"))
        case .quake:
            guard let q = model.planet.strongestRecentQuake, q.mag >= 4.5 else { return nil }
            return (CameraPose(lat: q.lat - 8, lon: q.lon, distance: 3.2, tilt: 26), "M\(Fmt.magnitude(q.mag)) · \(q.place) · \(Fmt.relative(q.time))")
        case .storm:
            guard let s = model.planet.activeStorms.first else { return nil }
            return (CameraPose(lat: s.lat - 6, lon: s.lon, distance: 3.0, tilt: 28), s.title)
        case .aurora:
            guard let a = model.planet.snapshot.aurora, max(a.maxNorth, a.maxSouth) >= 25 else { return nil }
            let north = a.maxNorth >= a.maxSouth
            return (CameraPose(lat: north ? 52 : -52, lon: Geo.normalizeLon(sun.lon + 180), distance: 3.6, tilt: 30),
                    String(localized: "Aurora \(north ? String(localized: "borealis") : String(localized: "australis")) · oval peak \(north ? a.maxNorth : a.maxSouth)%"))
        case .night:
            let lat = model.location.point.map { max(-45, min(55, $0.lat)) } ?? 30
            return (CameraPose(lat: lat, lon: Geo.normalizeLon(sun.lon + 165), distance: 3.4, tilt: 22),
                    String(localized: "The night side, lit by cities"))
        }
    }
}
