import AVFoundation
import Foundation

/// A generative ambient pad for the briefing: a slowly breathing chord through a large reverb.
/// Everything is synthesised in real time, so there are no audio assets to ship or license.
final class Soundscape: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let reverb = AVAudioUnitReverb()
    private var source: AVAudioSourceNode?
    private let state: UnsafeMutablePointer<PadState>
    private(set) var isRunning = false

    struct PadState {
        var phases: (Double, Double, Double, Double, Double, Double) = (0, 0, 0, 0, 0, 0)
        var lfo: Double = 0
        var gain: Double = 0
        var targetGain: Double = 0
        var lowpass: Double = 0
    }

    init() {
        state = UnsafeMutablePointer<PadState>.allocate(capacity: 1)
        state.initialize(to: PadState())
    }

    deinit {
        engine.stop()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    func start() {
        guard !isRunning else { return }
        let format = engine.outputNode.inputFormat(forBus: 0)
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : 48000
        let s = state
        // D major add 9, spread over three octaves.
        let freqs: [Double] = [73.42, 110.0, 146.83, 185.0, 220.0, 329.63]
        let amps: [Double] = [0.30, 0.22, 0.20, 0.13, 0.11, 0.06]
        let node = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            var st = s.pointee
            let twoPi = 2.0 * Double.pi
            for frame in 0..<Int(frameCount) {
                st.lfo += 0.06 / sampleRate
                if st.lfo > 1 { st.lfo -= 1 }
                st.gain += (st.targetGain - st.gain) * 0.00002
                let breathe = 0.75 + 0.25 * sin(st.lfo * twoPi)
                var sample = 0.0
                withUnsafeMutableBytes(of: &st.phases) { raw in
                    let ph = raw.bindMemory(to: Double.self)
                    for i in 0..<6 {
                        let detune = 1 + 0.0015 * sin(st.lfo * twoPi * Double(i + 1))
                        ph[i] += freqs[i] * detune / sampleRate
                        if ph[i] > 1 { ph[i] -= 1 }
                        let shimmer = 0.6 + 0.4 * sin((st.lfo * Double(i + 2) + Double(i) * 0.37) * twoPi)
                        sample += sin(ph[i] * twoPi) * amps[i] * shimmer
                    }
                }
                // One-pole low-pass for warmth.
                st.lowpass += (sample - st.lowpass) * 0.08
                let out = Float(st.lowpass * st.gain * breathe * 0.32)
                for buffer in abl {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = out
                }
            }
            s.pointee = st
            return noErr
        }
        source = node
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        engine.attach(node)
        engine.attach(reverb)
        reverb.loadFactoryPreset(.cathedral)
        reverb.wetDryMix = 62
        engine.connect(node, to: reverb, format: mono)
        engine.connect(reverb, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 0.9
        do {
            try engine.start()
            isRunning = true
            state.pointee.targetGain = 1
        } catch {
            isRunning = false
        }
    }

    func duck(_ ducked: Bool) {
        state.pointee.targetGain = ducked ? 0.55 : 1
    }

    func stop() {
        guard isRunning else { return }
        state.pointee.targetGain = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            self.engine.stop()
            if let source = self.source { self.engine.detach(source) }
            self.engine.detach(self.reverb)
            self.source = nil
            self.isRunning = false
            self.state.pointee = PadState()
        }
    }
}
