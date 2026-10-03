import SwiftUI

struct AskView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var service: AskService { model.askService }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.settings.askConsent {
                conversation
                inputBar
            } else {
                AskConsentCard {
                    Haptics.shared.tap()
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { model.settings.askConsent = true }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .background(PanelBackground())
        .task(id: model.settings.askConsent) {
            if model.settings.askConsent { await service.refreshQuota() }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if service.messages.isEmpty {
                        emptyState
                    }
                    ForEach(service.messages) { m in
                        MessageView(message: m) { model.fly(toFocus: $0) }
                            .id(m.id)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: service.messages.last?.text) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ASK KÁRMÁN").eyebrow(Theme.aurora)
                Text("Your planetary scientist").font(.display(24, weight: .bold)).foregroundStyle(.white)
            }
            Spacer()
            if let r = service.remaining, model.settings.askConsent {
                Text("\(r) left today")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
            }
            if !service.messages.isEmpty {
                Button {
                    withAnimation(.snappy) { service.reset() }
                } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 6)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 56)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            AIOrb()
                .frame(width: 150, height: 150)
                .padding(.top, 20)
            Text("Ask anything about what's happening on Earth and above it. Answers use live data from USGS, NOAA and NASA.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button {
                        Haptics.shared.tap()
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { service.send(s, model: model) }
                    } label: {
                        HStack {
                            Text(s).font(.system(size: 14, weight: .medium)).foregroundStyle(.white).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var suggestions: [String] {
        if let c = service.context { return Self.suggestions(for: c) }
        var out: [String] = []
        if let q = model.planet.strongestRecentQuake, q.mag >= 5 {
            out.append(String(localized: "Why did a magnitude \(Fmt.magnitude(q.mag)) earthquake happen near \(q.place.components(separatedBy: " of ").last ?? q.place)?"))
        }
        if let s = model.planet.activeStorms.first {
            out.append(String(localized: "How strong is \(s.title) and where is it heading?"))
        }
        out.append(String(localized: "Could I see the aurora tonight from where I am?"))
        out.append(String(localized: "What is the solar wind doing right now, and why does it matter?"))
        if out.count < 4 { out.append(String(localized: "When can I see the Space Station from here?")) }
        return Array(out.prefix(4))
    }

    static func suggestions(for c: APIClient.AskAbout) -> [String] {
        switch c.kind {
        case "quake": return [String(localized: "Why do earthquakes happen here?"),
                              String(localized: "Should people nearby expect aftershocks?"),
                              String(localized: "How does this compare with the biggest quakes in this region?")]
        case "storm": return [String(localized: "Where is this storm heading, and how strong will it get?"),
                              String(localized: "What makes a storm like this intensify?")]
        case "wildfire": return [String(localized: "How is the weather affecting this fire?"),
                                 String(localized: "How do satellites spot wildfires?")]
        case "volcano": return [String(localized: "What kind of volcano is this and how dangerous is it?")]
        case "launch": return [String(localized: "What is this mission going to do?"),
                               String(localized: "Could I see this launch from where I am?")]
        case "aurora": return [String(localized: "Could I see the aurora tonight from where I am?"),
                               String(localized: "What drives the aurora right now?")]
        case "spot": return [String(localized: "What is the weather doing here over the next day?"),
                             String(localized: "What is this place like? Climate, geography and what's nearby."),
                             String(localized: "Why is it this warm or cold here right now?")]
        default: return [String(localized: "Tell me about this.")]
        }
    }

    private var contextChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.aurora)
            Text("About \(service.context?.title ?? "")")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                Haptics.shared.select()
                withAnimation(.snappy) { service.setContext(nil) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Stop asking about this"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.aurora.opacity(0.10)))
        .overlay(Capsule().strokeBorder(Theme.aurora.opacity(0.3)))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            if service.context != nil { contextChip.transition(.move(edge: .bottom).combined(with: .opacity)) }
            inputField
        }
    }

    private var inputField: some View {
        HStack(spacing: 10) {
            TextField("Ask about the planet…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .font(.system(size: 15))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .submitLabel(.send)
                .onSubmit(send)
            Button {
                if service.isStreaming { service.stop() } else { send() }
            } label: {
                Image(systemName: service.isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(draft.isEmpty && !service.isStreaming ? Color.white.opacity(0.3) : Color.white))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(draft.isEmpty && !service.isStreaming)
            .padding(.trailing, 6)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        draft = ""
        Haptics.shared.tap()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { service.send(text, model: model) }
    }
}

/// Asks once, explicitly, before any question is shared with a third-party AI (App Review 5.1.2(i)).
private struct AskConsentCard: View {
    let agree: () -> Void
    @State private var showPrivacy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                AIOrb()
                    .frame(width: 118, height: 118)
                    .padding(.top, 22)
                VStack(spacing: 10) {
                    Text("Before your first question")
                        .font(.display(22, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Ask Kármán is powered by Claude, an AI model made by Anthropic. To answer, your question and your approximate location, rounded to about 50 km, are sent to Kármán's server and to Anthropic.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
                VStack(alignment: .leading, spacing: 14) {
                    point("person.crop.circle.badge.xmark", "Not linked to your identity")
                    point("hand.raised.fill", "Never used for advertising or profiling, and Anthropic does not train on it")
                    point("switch.2", "You can stop sharing any time in Settings")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
                Button(action: agree) {
                    Text("Agree and continue").frame(maxWidth: .infinity)
                }
                .primaryAction()
                .controlSize(.large)
                Button("Privacy Policy") { showPrivacy = true }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .sheet(isPresented: $showPrivacy) {
            NavigationStack {
                PrivacyView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showPrivacy = false } }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func point(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.aurora)
                .frame(width: 22)
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MessageView: View {
    let message: AskService.Message
    var onFocus: (APIClient.GlobeFocus) -> Void = { _ in }

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 50)
                Text(message.text)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.ice.opacity(0.22)))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.ice.opacity(0.3)))
            }
        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                AIOrb(small: true).frame(width: 22, height: 22).padding(.top, 2)
                VStack(alignment: .leading, spacing: 10) {
                    if !message.focus.isEmpty {
                        FocusChips(items: message.focus, onTap: onFocus)
                    }
                    if message.text.isEmpty && message.streaming {
                        TypingDots().padding(.top, 8)
                    } else {
                        Text("\(Text(verbatim: message.text))\(Text(verbatim: message.streaming ? " ▍" : "").foregroundStyle(Theme.aurora))")
                            .font(.system(size: 15))
                            .foregroundStyle(message.failed ? Color.orange : .white.opacity(0.92))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 20)
            }
        }
    }
}

/// The places an answer is about; tapping one flies the globe there.
private struct FocusChips: View {
    let items: [APIClient.GlobeFocus]
    let onTap: (APIClient.GlobeFocus) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.refId) { f in
                    Button {
                        Haptics.shared.select()
                        onTap(f)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: Self.icon(f.kind)).font(.system(size: 10, weight: .bold))
                            Text(f.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Image(systemName: "location.fill").font(.system(size: 8, weight: .bold)).opacity(0.6)
                        }
                        .foregroundStyle(Self.tint(f.kind))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Self.tint(f.kind).opacity(0.13)))
                        .overlay(Capsule().strokeBorder(Self.tint(f.kind).opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Show \(f.title) on the globe"))
                }
            }
        }
        .scrollClipDisabled()
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "quake": "waveform.path.ecg"
        case "launch": "airplane.departure"
        case "aurora": "light.beacon.max.fill"
        case "sun": "sun.max.fill"
        case "weather": "thermometer.medium"
        case "spot": "mappin"
        default: EventKind(rawValue: kind)?.symbol ?? "mappin"
        }
    }

    static func tint(_ kind: String) -> Color {
        switch kind {
        case "quake": Theme.quake
        case "launch": Theme.launch
        case "aurora": Theme.aurora
        case "sun": Theme.sun
        case "weather", "spot": Theme.ice
        default: EventKind(rawValue: kind).map(Theme.color(for:)) ?? Theme.ice
        }
    }
}

private struct TypingDots: View {
    @State private var phase = 0.0

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle().fill(Theme.aurora).frame(width: 6, height: 6)
                        .opacity(0.3 + 0.7 * (0.5 + 0.5 * sin(t * 5 - Double(i) * 0.7)))
                }
            }
        }
    }
}

/// A living gradient orb that represents the assistant.
struct AIOrb: View {
    var small = false

    var body: some View {
        TimelineView(.animation(minimumInterval: small ? 1 / 20 : 1 / 60)) { ctx in
            let t = Float(ctx.date.timeIntervalSinceReferenceDate)
            // Edge midpoints only slide along their edge so the mesh always covers the circle.
            let top: Float = 0.5 + 0.12 * sin(t * 0.7 + 3)
            let bottom: Float = 0.5 + 0.12 * cos(t * 0.5 + 4)
            let left: Float = 0.5 + 0.12 * sin(t * 0.6 + 1)
            let right: Float = 0.5 + 0.12 * cos(t * 0.8 + 2)
            let centre = SIMD2<Float>(0.5 + 0.09 * sin(t * 0.9 + 1.5), 0.5 + 0.09 * cos(t * 0.7))
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [top, 0], [1, 0],
                [0, left], centre, [1, right],
                [0, 1], [bottom, 1], [1, 1],
            ], colors: [
                Theme.ice, Theme.aurora, Theme.auroraViolet,
                Theme.auroraViolet, .white, Theme.ice,
                Theme.aurora, Theme.ice, Theme.auroraViolet,
            ])
            .clipShape(Circle())
            .overlay(Circle().fill(RadialGradient(colors: [.clear, .black.opacity(0.35)], center: .center, startRadius: 0, endRadius: small ? 14 : 80)))
            .shadow(color: Theme.aurora.opacity(small ? 0.3 : 0.55), radius: small ? 4 : 30)
            .scaleEffect(1 + 0.03 * CGFloat(sin(t * 1.6)))
        }
    }
}
