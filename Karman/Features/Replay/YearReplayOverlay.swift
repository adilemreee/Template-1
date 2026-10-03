import SwiftUI

/// "A year of earthquakes": 365 days of M4.5+ quakes in under a minute. Each flares on its day
/// and settles into an ember, until the year's seismicity has drawn the edges of the plates.
struct YearReplayOverlay: View {
    @Environment(AppModel.self) private var model
    @State private var cursor = 0
    @State private var tally = QuakeHistoryStore.Tally()
    @State private var callout: Quake?
    @State private var finished = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: finished)) { _ in
            let date = model.globe.renderDate()
            let progress = model.globe.replayProgress() ?? 1
            VStack(spacing: 10) {
                header(date: date, progress: progress)
                Spacer()
                if finished {
                    summary
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let callout {
                    calloutCard(callout)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .onChange(of: date) { _, now in advance(to: now, progress: progress) }
        }
    }

    private func header(date: Date, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PulsingDot(color: Theme.quake)
                Text("A YEAR OF EARTHQUAKES · M4.5+").eyebrow(Theme.quakeWarm)
                Spacer()
                Button {
                    Haptics.shared.tap()
                    model.stopYearReplay()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(Text("Back to live"))
            }
            Text(date, format: .dateTime.month(.wide).year())
                .font(.display(30, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            ProgressView(value: progress).tint(Theme.quakeWarm)
            HStack(spacing: 14) {
                stat("\(tally.count.formatted())", "quakes", Theme.quakeWarm)
                stat("\(tally.m6)", "M6+", Theme.quake)
                stat("\(tally.m7)", "M7+", Color(red: 1, green: 0.25, blue: 0.35))
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .glassPanel(cornerRadius: 26)
        .padding(.top, 8)
    }

    private func stat(_ value: String, _ label: LocalizedStringKey, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .monospacedDigit()
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
        }
    }

    private func calloutCard(_ q: Quake) -> some View {
        HStack(spacing: 10) {
            MagnitudeBadge(mag: q.mag, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("M\(Fmt.magnitude(q.mag)) · \(q.time.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(q.place).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassPanel(cornerRadius: 22, tint: Theme.quakeColor(mag: q.mag))
    }

    private var summary: some View {
        let totals = model.history.totals
        return VStack(alignment: .leading, spacing: 10) {
            Text("ONE YEAR ON A RESTLESS PLANET").eyebrow(Theme.quakeWarm)
            Text("\(totals.count.formatted()) earthquakes of magnitude 4.5 or more")
                .font(.display(21, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text("Nearly all of them line the edges of tectonic plates: the Ring of Fire around the Pacific, the belt from the Mediterranean to the Himalaya, and the mid-ocean ridges where new seafloor is born.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let s = totals.strongest {
                Label("Strongest: M\(Fmt.magnitude(s.mag)) · \(s.place) · \(s.time.formatted(date: .abbreviated, time: .omitted))", systemImage: "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.quakeColor(mag: s.mag))
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                Button {
                    restart()
                } label: {
                    Label("Watch again", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Button {
                    Haptics.shared.tap()
                    model.stopYearReplay()
                } label: {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .primaryAction(Theme.quakeWarm)
            }
            .controlSize(.large)
            .padding(.top, 2)
        }
        .padding(16)
        .glassPanel(cornerRadius: 26)
    }

    private func advance(to now: Date, progress: Double) {
        guard let quakes = model.history.year?.quakes, !finished else { return }
        var i = cursor
        var top: Quake?
        while i < quakes.count && quakes[i].time <= now {
            let q = quakes[i]
            tally.count += 1
            if q.mag >= 6 { tally.m6 += 1 }
            if q.mag >= 7 {
                tally.m7 += 1
                if q.mag > (top?.mag ?? 0) { top = q }
            }
            if q.mag > (tally.strongest?.mag ?? 0) { tally.strongest = q }
            i += 1
        }
        cursor = i
        if let top {
            Haptics.shared.seismic(magnitude: min(top.mag - 1, 6.5))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { callout = top }
            let shown = top.id
            Task {
                try? await Task.sleep(for: .seconds(2.4))
                if callout?.id == shown { withAnimation(.easeOut(duration: 0.4)) { callout = nil } }
            }
        }
        if progress >= 1 {
            Haptics.shared.thud()
            withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) {
                callout = nil
                finished = true
            }
        }
    }

    private func restart() {
        Haptics.shared.tap()
        cursor = 0
        tally = QuakeHistoryStore.Tally()
        withAnimation(.easeInOut(duration: 0.4)) { finished = false }
        if let year = model.history.year {
            model.globe.startYearReplay(from: year.from, to: year.to, duration: 52, delay: 0.3)
        }
    }
}
