import SwiftUI

/// The heads-up display over the globe: live status, quick stats, briefing and the dock.
struct HomeHUD: View {
    @Environment(AppModel.self) private var model
    @State private var showLayers = false
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .offset(y: appeared ? 0 : -30)
                .opacity(appeared ? 1 : 0)

            StatusChips()
                .padding(.top, 10)
                .offset(y: appeared ? 0 : -20)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.08), value: appeared)

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                if !model.onboardingDone {
                    OnboardingCard()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if showLayers {
                    LayersPanel(isPresented: $showLayers)
                        .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottom)))
                } else if model.selection != nil {
                    InspectorCard()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    BriefingCard()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Dock(showLayers: $showLayers)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            .offset(y: appeared ? 0 : 120)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.75, dampingFraction: 0.82).delay(0.15), value: appeared)
        }
        .background(alignment: .top) {
            // Soft scrims keep the HUD legible over bright clouds and ice.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.62), .black.opacity(0.32), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 230)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 240)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: model.selection)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: showLayers)
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: model.onboardingDone)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { appeared = true }
        }
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("KÁRMÁN")
                    .font(.display(17, weight: .bold))
                    .tracking(5)
                    .foregroundStyle(.white)
                LiveClock()
            }
            .shadow(color: .black.opacity(0.65), radius: 8)
            Spacer()
            Button {
                model.panel = .settings
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(Text("Settings"))
        }
    }
}

struct LiveClock: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 6) {
                PulsingDot(color: model.planet.isOffline ? .orange : Theme.aurora)
                Text(model.planet.isOffline ? "OFFLINE" : "LIVE")
                    .font(.label(10, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(model.planet.isOffline ? .orange : Theme.aurora)
                Text(Fmt.utcClock(ctx.date) + " UTC")
                    .font(.mono(11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
            }
        }
    }
}

struct PulsingDot: View {
    var color: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35)).frame(width: 12, height: 12).scaleEffect(pulse ? 1.6 : 0.6).opacity(pulse ? 0 : 1)
            Circle().fill(color).frame(width: 6, height: 6)
        }
        .frame(width: 12, height: 12)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

// MARK: - Status chips

private struct StatusChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let space = model.planet.snapshot.space
        let kp = space?.kpNow ?? 0
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Chip(icon: "sparkles", tint: Theme.kpColor(kp), title: "Kp \(kp.formatted(.number.precision(.fractionLength(1))))", subtitle: kpWord(kp)) {
                        model.panel = .space
                    }
                    Chip(icon: "waveform.path.ecg", tint: Theme.quake, title: "\(model.planet.quakesLast24h.count)", subtitle: String(localized: "quakes · 24h")) {
                        model.panel = .pulse
                    }
                    if !model.planet.activeStorms.isEmpty {
                        Chip(icon: "hurricane", tint: Theme.storm, title: "\(model.planet.activeStorms.count)", subtitle: String(localized: "storms")) {
                            if let s = model.planet.activeStorms.first { model.select(.event(s.id)) }
                        }
                    }
                    if !model.planet.wildfires.isEmpty {
                        Chip(icon: "flame.fill", tint: Theme.fire, title: "\(model.planet.wildfires.count)", subtitle: String(localized: "fires")) {
                            model.panel = .pulse
                        }
                    }
                    if let chance = model.planet.auroraChance(at: model.location.point), chance > 0 {
                        Chip(icon: "light.beacon.max.fill", tint: Theme.aurora, title: "\(chance)%", subtitle: String(localized: "aurora here")) {
                            model.panel = .space
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .scrollClipDisabled()
    }

    private func kpWord(_ kp: Double) -> String {
        switch kp {
        case 7...: String(localized: "severe storm")
        case 5..<7: String(localized: "storm")
        case 4..<5: String(localized: "active")
        case 3..<4: String(localized: "unsettled")
        default: String(localized: "calm")
        }
    }
}

private struct Chip: View {
    var icon: String
    var tint: Color
    var title: String
    var subtitle: String
    var action: () -> Void

    var body: some View {
        Button(action: { Haptics.shared.select(); action() }) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, options: .repeating.speed(0.4))
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(tint.opacity(0.10)).interactive(), in: Capsule())
    }
}

// MARK: - Briefing card

private struct BriefingCard: View {
    @Environment(AppModel.self) private var model
    @State private var shimmer = false

    var body: some View {
        Button {
            Haptics.shared.thud()
            BriefingDirector.shared.start(model: model)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(AngularGradient(colors: [Theme.ice, Theme.aurora, Theme.auroraViolet, Theme.ice], center: .center))
                        .frame(width: 46, height: 46)
                        .rotationEffect(.degrees(shimmer ? 360 : 0))
                        .blur(radius: 0.5)
                    Circle().fill(.black.opacity(0.55)).frame(width: 40, height: 40)
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: 1)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("PLANET BRIEFING").eyebrow(Theme.ice)
                    Text(briefingLine)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("Narrated tour of what is happening right now")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onAppear { withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) { shimmer = true } }
    }

    private var briefingLine: String {
        if let q = model.planet.strongestRecentQuake, q.mag >= 5.5 {
            return String(localized: "M\(Fmt.magnitude(q.mag)) · \(q.place)")
        }
        if let s = model.planet.activeStorms.first { return s.title }
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? String(localized: "This morning on Earth") : (hour < 18 ? String(localized: "This afternoon on Earth") : String(localized: "Tonight on Earth"))
    }
}

// MARK: - Dock

private struct Dock: View {
    @Environment(AppModel.self) private var model
    @Binding var showLayers: Bool

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 0) {
                DockButton(icon: "dot.radiowaves.left.and.right", title: "Pulse") { model.panel = .pulse }
                DockButton(icon: "sun.max.fill", title: "Space") { model.panel = .space }
                DockButton(icon: "moon.stars.fill", title: "Sky") { model.panel = .sky }
                DockButton(icon: "sparkle", title: "Ask") { model.panel = .ask }
                DockButton(icon: showLayers ? "xmark" : "square.3.layers.3d", title: "Layers", active: showLayers) {
                    model.selection = nil
                    showLayers.toggle()
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .glassEffect(.regular, in: Capsule())
        }
    }
}

private struct DockButton: View {
    var icon: String
    var title: LocalizedStringKey
    var active = false
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.shared.select()
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(active ? Theme.ice : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
