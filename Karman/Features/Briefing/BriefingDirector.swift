import AVFoundation
import Foundation
import Observation
import SwiftUI

/// Performs a Planet Briefing: flies the camera scene by scene while a voice narrates and
/// captions highlight word by word, over a generative ambient score.
@MainActor
@Observable
final class BriefingDirector: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = BriefingDirector()

    enum Phase: Equatable { case idle, loading, title, playing, paused, outro }

    struct Stage: Identifiable, Equatable {
        let id = UUID()
        var focus: String
        var point: GeoPoint
        var pose: CameraPose
        var headline: String
        var narration: String
        var item: GlobeItem?
    }

    private(set) var phase: Phase = .idle
    private(set) var briefing: Briefing?
    private(set) var stages: [Stage] = []
    private(set) var index = 0
    private(set) var spokenRange: NSRange?
    private(set) var sceneProgress: Double = 0
    private(set) var errorMessage: String?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let synth = AVSpeechSynthesizer()
    @ObservationIgnored private let soundscape = Soundscape()
    @ObservationIgnored private var advanceTask: Task<Void, Never>?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var sceneStart = Date()
    @ObservationIgnored private var expectedDuration: TimeInterval = 8

    override init() {
        super.init()
        synth.delegate = self
    }

    var current: Stage? { stages.indices.contains(index) ? stages[index] : nil }

    // MARK: Lifecycle

    func start(model: AppModel) {
        guard phase == .idle else { return }
        self.model = model
        errorMessage = nil
        phase = .loading
        withAnimation(.easeInOut(duration: 0.6)) { model.briefingActive = true }
        model.selection = nil
        model.globe.autoRotate = false
        configureAudio(active: true)
        if model.settings.soundscape { soundscape.start() }
        model.globe.fly(to: CameraPose(lat: model.globe.pose.lat, lon: model.globe.pose.lon, distance: 7.5), duration: 2.0)

        Task {
            let lang = Locale.current.language.languageCode?.identifier ?? "en"
            do {
                let b = try await APIClient.shared.briefing(language: lang)
                briefing = b
                stages = buildStages(b, model: model)
            } catch {
                // Offline: build a local briefing from whatever data we have.
                let local = LocalBriefing.make(model: model, language: lang)
                briefing = local
                stages = buildStages(local, model: model)
            }
            guard phase == .loading else { return }
            withAnimation(.easeInOut(duration: 0.8)) { phase = .title }
            speak(title: true)
        }
    }

    func stop() {
        advanceTask?.cancel()
        progressTask?.cancel()
        synth.stopSpeaking(at: .immediate)
        soundscape.stop()
        configureAudio(active: false)
        guard let model else { phase = .idle; return }
        model.selection = nil
        model.globe.drift = (0, 0)
        model.globe.autoRotate = true
        model.globe.fly(to: model.globe.homePose, duration: 2.2)
        withAnimation(.easeInOut(duration: 0.6)) {
            model.briefingActive = false
            phase = .idle
        }
        stages = []
        index = 0
        spokenRange = nil
    }

    func togglePause() {
        switch phase {
        case .playing, .title:
            if synth.isSpeaking { synth.pauseSpeaking(at: .word) }
            advanceTask?.cancel()
            model?.globe.drift = (0, 0)
            withAnimation(.snappy) { phase = .paused }
        case .paused:
            withAnimation(.snappy) { phase = .playing }
            if synth.isPaused { synth.continueSpeaking() } else { play(index: index) }
        default: break
        }
    }

    func next() {
        guard !stages.isEmpty else { return }
        if index + 1 < stages.count { play(index: index + 1) } else { outro() }
    }

    func previous() {
        play(index: max(0, index - 1))
    }

    // MARK: Scenes

    private func buildStages(_ b: Briefing, model: AppModel) -> [Stage] {
        var out: [Stage] = []
        for (i, s) in b.scenes.enumerated() {
            let p = GeoPoint(lat: s.lat, lon: s.lon)
            var distance = 1 + s.altitudeKm / 6371 * 1.45
            var tilt = 0.0
            switch s.focus {
            case "quake", "wildfire", "volcano": tilt = 34; distance = max(1.32, min(distance, 2.2))
            case "storm": tilt = 28; distance = max(1.5, min(distance, 2.6))
            case "launch": tilt = 38; distance = max(1.35, min(distance, 2.2))
            case "aurora": tilt = 22; distance = max(2.2, min(distance, 3.6))
            case "sun", "asteroid", "overview": tilt = 0; distance = 6.8
            default: tilt = 20
            }
            let heading = Double((i * 47) % 120) - 60
            let pose = CameraPose(lat: p.lat - (tilt > 0 ? 2.5 : 0), lon: p.lon, distance: distance, tilt: tilt, heading: heading)
            out.append(Stage(focus: s.focus, point: p, pose: pose, headline: s.headline, narration: s.narration, item: item(for: s, model: model)))
        }
        if let personal = personalStage(model: model) { out.append(personal) }
        return out
    }

    private func item(for s: BriefingScene, model: AppModel) -> GlobeItem? {
        switch s.focus {
        case "quake": model.planet.quake(id: s.refId).map { .quake($0.id) }
        case "storm", "wildfire", "volcano", "ice", "other": model.planet.event(id: s.refId).map { .event($0.id) }
        case "launch": model.planet.launch(id: s.refId).map { .launch($0.id) }
        default: nil
        }
    }

    /// A closing scene about the user's own sky, computed on device.
    private func personalStage(model: AppModel) -> Stage? {
        guard let user = model.location.point else { return nil }
        let place = model.location.placeName ?? String(localized: "your location")
        var parts: [String] = []
        if let pass = model.passes.first(where: { $0.noradID == 25544 && $0.start > Date() && $0.start < Date().addingTimeInterval(36 * 3600) }) {
            parts.append(String(localized: "The International Space Station will pass over \(place) at \(Fmt.time(pass.start)), climbing \(Int(pass.maxElevation)) degrees above the \(GeoPoint.compassName(pass.peakAzimuth)) horizon."))
        }
        if let chance = model.planet.auroraChance(at: user), chance >= 10 {
            parts.append(String(localized: "Your chance of seeing the aurora tonight is about \(chance) percent."))
        }
        let moon = Astro.moonPhase(Date())
        parts.append(String(localized: "Tonight's Moon is \(moon.name.lowercased()), \(Int((moon.illumination * 100).rounded())) percent lit."))
        let narration = parts.joined(separator: " ")
        return Stage(focus: "user", point: user, pose: CameraPose(lat: user.lat - 3, lon: user.lon, distance: 1.9, tilt: 30, heading: 0),
                     headline: String(localized: "Your sky tonight"), narration: narration, item: .user)
    }

    private func play(index i: Int) {
        guard let model, stages.indices.contains(i) else { return }
        advanceTask?.cancel()
        synth.stopSpeaking(at: .immediate)
        index = i
        spokenRange = nil
        let stage = stages[i]
        withAnimation(.easeInOut(duration: 0.6)) { phase = .playing }
        model.globe.drift = (0, 0)
        model.globe.fly(to: stage.pose, duration: i == 0 ? 3.0 : 2.6)
        if let item = stage.item { model.selection = item } else { model.selection = nil }
        Haptics.shared.select()
        sceneStart = Date()
        expectedDuration = 2.6 + Double(stage.narration.split(separator: " ").count) / 2.6
        startProgressTicker()
        advanceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard let self, !Task.isCancelled, self.phase == .playing else { return }
            self.model?.globe.drift = (heading: 2.2, zoom: -0.004)
            if self.model?.settings.narration == true {
                self.speak(text: stage.narration)
            } else {
                try? await Task.sleep(for: .seconds(self.expectedDuration - 2.2))
                guard !Task.isCancelled, self.phase == .playing else { return }
                self.next()
            }
        }
    }

    private func outro() {
        guard let model else { return }
        withAnimation(.easeInOut(duration: 0.8)) { phase = .outro }
        model.selection = nil
        model.globe.drift = (0, 0)
        model.globe.fly(to: CameraPose(lat: model.globe.homePose.lat, lon: model.globe.homePose.lon, distance: 8.5), duration: 3.5)
        if model.settings.narration, let signoff = briefing?.signoff, !signoff.isEmpty {
            speak(text: signoff)
        } else {
            advanceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        }
    }

    private func startProgressTicker() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.phase == .playing {
                    let p = Date().timeIntervalSince(self.sceneStart) / max(1, self.expectedDuration)
                    self.sceneProgress = min(1, p)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    // MARK: Speech

    private func speak(title: Bool) {
        guard let b = briefing else { return }
        if model?.settings.narration == true {
            speak(text: b.title + ". " + b.dek)
        } else {
            advanceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3.2))
                guard !Task.isCancelled else { return }
                self?.play(index: 0)
            }
        }
    }

    private func speak(text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice(for: briefing?.language ?? "en")
        utterance.rate = 0.46
        utterance.pitchMultiplier = 0.96
        utterance.preUtteranceDelay = 0.1
        utterance.postUtteranceDelay = 0.4
        soundscape.duck(true)
        synth.speak(utterance)
    }

    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
        let ranked = voices.sorted { a, b in
            func score(_ v: AVSpeechSynthesisVoice) -> Int {
                var s = v.quality.rawValue * 10
                if v.voiceTraits.contains(.isNoveltyVoice) { s -= 100 }
                if v.language == Locale.current.identifier.replacingOccurrences(of: "_", with: "-") { s += 3 }
                return s
            }
            return score(a) > score(b)
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: language)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in self.spokenRange = characterRange }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.soundscape.duck(false)
            switch self.phase {
            case .title:
                try? await Task.sleep(for: .seconds(0.4))
                if self.phase == .title { self.play(index: 0) }
            case .playing:
                try? await Task.sleep(for: .seconds(0.9))
                if self.phase == .playing { self.next() }
            case .outro:
                try? await Task.sleep(for: .seconds(1.8))
                if self.phase == .outro { self.stop() }
            default: break
            }
        }
    }

    private func configureAudio(active: Bool) {
        let session = AVAudioSession.sharedInstance()
        if active {
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? session.setActive(true)
        } else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// On-device briefing used when the API cannot be reached.
enum LocalBriefing {
    @MainActor
    static func make(model: AppModel, language: String) -> Briefing {
        var scenes: [BriefingScene] = []
        if let q = model.planet.strongestRecentQuake {
            scenes.append(BriefingScene(focus: "quake", refId: q.id, lat: q.lat, lon: q.lon, altitudeKm: 3800,
                                        headline: String(localized: "Magnitude \(Fmt.magnitude(q.mag))"),
                                        narration: String(localized: "A magnitude \(Fmt.magnitude(q.mag)) earthquake struck \(q.place), \(Fmt.relative(q.time)), at a depth of \(Int(q.depthKm)) kilometres.")))
        }
        if let s = model.planet.activeStorms.first {
            scenes.append(BriefingScene(focus: "storm", refId: s.id, lat: s.lat, lon: s.lon, altitudeKm: 6000, headline: s.title,
                                        narration: String(localized: "\(s.title) is being tracked over open water. \(s.valueText).")))
        }
        let kp = model.planet.snapshot.space?.kpNow ?? 0
        let sun = Astro.subsolarPoint(Date())
        scenes.append(BriefingScene(focus: "aurora", refId: "aurora-north", lat: 67, lon: Geo.normalizeLon(sun.lon + 180), altitudeKm: 14000,
                                    headline: String(localized: "Kp \(kp.formatted(.number.precision(.fractionLength(1))))"),
                                    narration: String(localized: "Space weather: the planetary K index stands at \(kp.formatted(.number.precision(.fractionLength(1)))). Aurora circles both poles tonight.")))
        return Briefing(id: "local", language: language, title: String(localized: "The Planet, Right Now"), dek: String(localized: "A short tour of the latest data."),
                        scenes: scenes, signoff: String(localized: "That is the planet, right now. Kármán keeps watching."), generatedAt: Date(), source: "local")
    }
}
