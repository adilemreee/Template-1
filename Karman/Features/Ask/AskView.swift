import SwiftUI

struct AskView: View {
    @Environment(AppModel.self) private var model
    @State private var service = AskService()
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if service.messages.isEmpty {
                            emptyState
                        }
                        ForEach(service.messages) { m in
                            MessageView(message: m)
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
            inputBar
        }
        .background(PanelBackground())
        .task { await service.refreshQuota() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ASK KÁRMÁN").eyebrow(Theme.aurora)
                Text("Your planetary scientist").font(.display(24, weight: .bold)).foregroundStyle(.white)
            }
            Spacer()
            if let r = service.remaining {
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

    private var inputBar: some View {
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

private struct MessageView: View {
    let message: AskService.Message

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
                if message.text.isEmpty && message.streaming {
                    TypingDots().padding(.top, 8)
                } else {
                    Text("\(Text(verbatim: message.text))\(Text(verbatim: message.streaming ? " ▍" : "").foregroundStyle(Theme.aurora))")
                        .font(.system(size: 15))
                        .foregroundStyle(message.failed ? Color.orange : .white.opacity(0.92))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 20)
            }
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
            let w: (Float, Float) -> SIMD2<Float> = { x, y in
                SIMD2(x + 0.08 * sin(t * 0.9 + y * 3), y + 0.08 * cos(t * 0.7 + x * 3))
            }
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                w(0, 0.5), w(0.5, 0.5), w(1, 0.5),
                [0, 1], [0.5, 1], [1, 1],
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
