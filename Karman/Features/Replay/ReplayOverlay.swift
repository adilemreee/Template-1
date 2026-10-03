import SwiftUI

/// "The last 24 hours" replay: the clock races through the day while the terminator sweeps
/// round the globe and earthquakes ripple in as they happened; big ones are called out.
struct ReplayOverlay: View {
    @Environment(AppModel.self) private var model
    @State private var lastChecked: Date?
    @State private var count = 0
    @State private var strongest: Quake?
    @State private var callout: Quake?
    @State private var finishedAt: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { ctx in
            let t = model.globe.renderDate()
            let progress = model.globe.replayProgress() ?? 1
            VStack(spacing: 10) {
                Spacer()
                if let callout {
                    HStack(spacing: 10) {
                        MagnitudeBadge(mag: callout.mag, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("M\(Fmt.magnitude(callout.mag)) earthquake").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            Text(callout.place).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .glassPanel(cornerRadius: 22, tint: Theme.quakeColor(mag: callout.mag))
                    .padding(.horizontal, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        PulsingDot(color: Theme.ice)
                        Text(progress >= 1 ? "LAST 24 HOURS · NOW" : "REPLAY · LAST 24 HOURS").eyebrow(Theme.ice)
                        Spacer()
                        Button {
                            Haptics.shared.tap()
                            model.stopReplay()
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: 34, height: 34)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel(Text("Back to live"))
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(t, format: .dateTime.weekday(.abbreviated).hour().minute())
                            .font(.display(30, weight: .bold))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                        Text("\(Fmt.utcClock(t)) UTC").font(.mono(12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    }
                    ProgressView(value: progress).tint(Theme.ice)
                    Text(summary)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .contentTransition(.numericText())
                }
                .padding(16)
                .glassPanel(cornerRadius: 26)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .onChange(of: t) { _, now in advance(to: now, finished: progress >= 1) }
        }
    }

    private var summary: String {
        guard count > 0 else { return String(localized: "Watch the day sweep round the planet.") }
        if let strongest {
            return String(localized: "\(count) earthquakes so far · strongest M\(Fmt.magnitude(strongest.mag))")
        }
        return String(localized: "\(count) earthquakes so far")
    }

    private func advance(to now: Date, finished: Bool) {
        guard let replay = model.globe.replay else { return }
        let from = lastChecked ?? replay.from
        lastChecked = now
        let fresh = model.planet.snapshot.quakes.filter { $0.time > from && $0.time <= now && $0.time >= replay.from }
        if !fresh.isEmpty {
            count += fresh.count
            if let top = fresh.max(by: { $0.mag < $1.mag }) {
                if top.mag > (strongest?.mag ?? 0) { strongest = top }
                if top.mag >= 5 {
                    Haptics.shared.seismic(magnitude: min(top.mag, 6.5))
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { callout = top }
                    let shown = top.id
                    Task {
                        try? await Task.sleep(for: .seconds(2.6))
                        if callout?.id == shown { withAnimation(.easeOut(duration: 0.4)) { callout = nil } }
                    }
                }
            }
        }
        if finished {
            if finishedAt == nil { finishedAt = Date() }
            if let finishedAt, Date().timeIntervalSince(finishedAt) > 3 { model.stopReplay() }
        }
    }
}
