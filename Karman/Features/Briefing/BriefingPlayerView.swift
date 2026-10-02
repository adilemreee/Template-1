import SwiftUI

/// Cinematic overlay for a Planet Briefing: letterbox, title card, karaoke captions, controls.
struct BriefingPlayerView: View {
    @Environment(AppModel.self) private var model
    @State private var bars = false
    private var director: BriefingDirector { BriefingDirector.shared }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Letterbox
                VStack(spacing: 0) {
                    Rectangle().fill(.black).frame(height: bars ? geo.safeAreaInsets.top + 64 : 0)
                    Spacer()
                    Rectangle().fill(LinearGradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black.opacity(0.72), location: 0.32),
                                                            .init(color: .black.opacity(0.92), location: 0.6), .init(color: .black, location: 1)],
                                                    startPoint: .top, endPoint: .bottom))
                        .frame(height: bars ? geo.size.height * 0.5 + geo.safeAreaInsets.bottom : 0)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottom
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.0)) { bars = true } }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("PLANET BRIEFING").font(.label(11)).tracking(2.5).foregroundStyle(.white.opacity(0.9))
            if director.briefing?.source == "ai" {
                Image(systemName: "sparkle").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.aurora)
            }
            Spacer()
            if !director.stages.isEmpty, director.phase == .playing || director.phase == .paused {
                Text(String(format: "%02d / %02d", director.index + 1, director.stages.count))
                    .font(.mono(12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
            }
            Button {
                Haptics.shared.tap()
                director.stop()
            } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: 34, height: 34)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var bottom: some View {
        switch director.phase {
        case .loading:
            VStack(spacing: 16) {
                AIOrb().frame(width: 70, height: 70)
                Text("Composing your briefing…").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.bottom, 60)
            .transition(.opacity)
        case .title:
            VStack(alignment: .leading, spacing: 10) {
                Text(Date().formatted(date: .complete, time: .omitted).uppercased()).eyebrow(Theme.ice)
                Text(director.briefing?.title ?? "")
                    .font(.display(34, weight: .bold))
                    .foregroundStyle(.white)
                    .textRenderer(StaggeredReveal(progress: 1))
                Text(director.briefing?.dek ?? "")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 70)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 20)), removal: .opacity))
        case .playing, .paused:
            if let stage = director.current {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: stage.focus)).font(.system(size: 12, weight: .bold)).foregroundStyle(tint(for: stage.focus))
                        Text(label(for: stage.focus)).eyebrow(tint(for: stage.focus))
                    }
                    Text(stage.headline)
                        .font(.display(28, weight: .bold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .id("h\(director.index)")
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 16)).combined(with: .scale(scale: 0.98, anchor: .leading)), removal: .opacity))
                    Caption(text: stage.narration, range: director.spokenRange)
                        .id("c\(director.index)")
                        .transition(.opacity)
                    progress
                    controls
                }
                .animation(.spring(response: 0.6, dampingFraction: 0.86), value: director.index)
            }
        case .outro:
            VStack(spacing: 12) {
                Text(director.briefing?.signoff ?? "")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("KÁRMÁN").font(.display(13, weight: .bold)).tracking(6).foregroundStyle(Theme.textSecondary)
            }
            .padding(.bottom, 70)
            .transition(.opacity)
        case .idle:
            EmptyView()
        }
    }

    private var progress: some View {
        HStack(spacing: 4) {
            ForEach(Array(director.stages.enumerated()), id: \.offset) { i, _ in
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(Color.white)
                            .frame(width: g.size.width * (i < director.index ? 1 : (i == director.index ? director.sceneProgress : 0)))
                    }
                }
                .frame(height: 3)
            }
        }
    }

    private var controls: some View {
        HStack {
            Button { Haptics.shared.tap(); director.previous() } label: {
                Image(systemName: "backward.fill").frame(width: 52, height: 44)
            }
            Spacer()
            Button { Haptics.shared.tap(); director.togglePause() } label: {
                Image(systemName: director.phase == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 64, height: 52)
                    .contentTransition(.symbolEffect(.replace))
            }
            Spacer()
            Button { Haptics.shared.tap(); director.next() } label: {
                Image(systemName: "forward.fill").frame(width: 52, height: 44)
            }
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private func icon(for focus: String) -> String {
        switch focus {
        case "quake": "waveform.path.ecg"
        case "storm": "hurricane"
        case "wildfire": "flame.fill"
        case "volcano": "mountain.2.fill"
        case "aurora": "light.beacon.max.fill"
        case "sun": "sun.max.fill"
        case "launch": "airplane.departure"
        case "asteroid": "circle.hexagongrid.fill"
        case "user": "location.fill"
        case "ice": "snowflake"
        default: "globe.americas.fill"
        }
    }

    private func label(for focus: String) -> String {
        switch focus {
        case "quake": String(localized: "Earthquake")
        case "storm": String(localized: "Storm")
        case "wildfire": String(localized: "Wildfire")
        case "volcano": String(localized: "Volcano")
        case "aurora": String(localized: "Aurora")
        case "sun": String(localized: "Space weather")
        case "launch": String(localized: "Launch")
        case "asteroid": String(localized: "Asteroid")
        case "user": String(localized: "Above you")
        case "ice": String(localized: "Ice")
        default: String(localized: "The planet")
        }
    }

    private func tint(for focus: String) -> Color {
        switch focus {
        case "quake": Theme.quake
        case "storm": Theme.storm
        case "wildfire": Theme.fire
        case "volcano": Theme.volcano
        case "aurora": Theme.aurora
        case "sun": Theme.sun
        case "launch": Theme.launch
        case "user": Theme.ice
        default: Theme.ice
        }
    }
}

/// Narration caption: words already spoken are bright, the rest are dim.
private struct Caption: View {
    let text: String
    let range: NSRange?

    var body: some View {
        Text(attributed)
            .font(.system(size: 17, weight: .medium))
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .animation(.easeOut(duration: 0.15), value: range?.location)
    }

    private var attributed: AttributedString {
        var a = AttributedString(text)
        a.foregroundColor = .white.opacity(0.38)
        let ns = text as NSString
        let spokenEnd = range.map { min(ns.length, $0.location + $0.length) } ?? 0
        if spokenEnd > 0, let r = Range(NSRange(location: 0, length: spokenEnd), in: text), let ar = Range(r, in: a) {
            a[ar].foregroundColor = .white
        }
        return a
    }
}
