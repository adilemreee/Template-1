import CoreHaptics
import UIKit

/// Haptics, including a "feel it" seismogram whose intensity and length follow the magnitude.
@MainActor
final class Haptics {
    static let shared = Haptics()
    var enabled = true
    private var engine: CHHapticEngine?
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let selection = UISelectionFeedbackGenerator()

    private init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        engine?.isAutoShutdownEnabled = true
        engine?.resetHandler = { [weak self] in
            Task { @MainActor in try? self?.engine?.start() }
        }
    }

    func tap() { guard enabled else { return }; light.impactOccurred(intensity: 0.7) }
    func select() { guard enabled else { return }; selection.selectionChanged() }
    func thud() { guard enabled else { return }; soft.impactOccurred(intensity: 1) }

    /// A synthetic seismogram: P-wave flutter, then the stronger S-wave and a decaying surface coda.
    func seismic(magnitude: Double) {
        guard enabled, let engine else { return }
        let m = max(2.5, min(magnitude, 9.0))
        let strength = Float((m - 2.5) / 6.5)
        let duration = 1.2 + (m - 2.5) * 0.55
        var events: [CHHapticEvent] = []
        // P-wave: light, high-frequency taps
        var t = 0.0
        while t < duration * 0.22 {
            events.append(CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.25 + strength * 0.25),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9),
            ], relativeTime: t))
            t += 0.045
        }
        // S-wave + surface waves: a strong continuous rumble that decays
        let sStart = duration * 0.25
        events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.55 + strength * 0.45),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25),
        ], relativeTime: sStart, duration: duration - sStart))
        // Jolts riding on the rumble
        var j = sStart
        var k = 0
        while j < duration * 0.8 {
            let decay = Float(1 - (j - sStart) / (duration - sStart))
            events.append(CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: (0.6 + strength * 0.4) * decay),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4 + 0.1 * Float(k % 3)),
            ], relativeTime: j))
            j += 0.09 + Double(k % 4) * 0.03
            k += 1
        }
        let curve = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
            .init(relativeTime: sStart, value: 1.0),
            .init(relativeTime: sStart + (duration - sStart) * 0.35, value: 0.75),
            .init(relativeTime: duration, value: 0.0),
        ], relativeTime: 0)
        do {
            try engine.start()
            let pattern = try CHHapticPattern(events: events, parameterCurves: [curve])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            thud()
        }
    }
}
