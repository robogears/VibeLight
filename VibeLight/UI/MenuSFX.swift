import AVFoundation

/// Tiny synthesized UI sounds for menu navigation — the console-style "tick"
/// vocabulary Big Picture UIs have. No asset files: each effect is a short
/// generated PCM buffer (sine blip with a fast exponential decay), so the whole
/// soundbank is a few hundred bytes of math.
///
/// Playback is fire-and-forget through one AVAudioEngine; failures are logged
/// once and the app stays silent rather than broken. UI sounds deliberately use
/// the default (ambient) audio session on iOS so the silent switch mutes them —
/// game audio during a stream uses its own .playback session.
@MainActor
final class MenuSFX {

    enum Effect {
        case move       // focus tick — quiet, short
        case select     // confirm — bright two-tone up
        case back       // dismiss — soft tone down
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffers: [Effect: AVAudioPCMBuffer] = [:]
    private var engineStarted = false
    private var loggedFailure = false

    private static let sampleRate: Double = 44_100

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.5

        // move: single 1.8 kHz tick, 25 ms, quiet — felt more than heard.
        buffers[.move] = Self.blip(segments: [(1800, 0.025)], gain: 0.10, format: format)
        // select: quick fifth upward (A5 → E6), 70 ms — a positive "yes".
        buffers[.select] = Self.blip(segments: [(880, 0.035), (1318.5, 0.035)], gain: 0.22, format: format)
        // back: soft step down (E5 → A4), 70 ms — a gentle "closing".
        buffers[.back] = Self.blip(segments: [(659.3, 0.035), (440, 0.035)], gain: 0.18, format: format)
    }

    func play(_ effect: Effect) {
        guard let buffer = buffers[effect] else { return }
        if !engineStarted {
            do {
                try engine.start()
                engineStarted = true
                player.play()
            } catch {
                if !loggedFailure {
                    loggedFailure = true
                    NSLog("[VibeLight] menu SFX engine failed to start: \(error.localizedDescription)")
                }
                return
            }
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
    }

    /// Renders consecutive sine segments (`hz`, `duration`) into one buffer with
    /// a per-segment exponential decay envelope and a 3 ms attack to avoid clicks.
    private static func blip(segments: [(hz: Double, duration: Double)],
                             gain: Float, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let totalFrames = AVAudioFrameCount(segments.reduce(0) { $0 + $1.duration } * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = totalFrames

        var frame = 0
        for segment in segments {
            let frames = Int(segment.duration * sampleRate)
            let attackFrames = min(Int(0.003 * sampleRate), frames)
            for i in 0..<frames {
                let t = Double(i) / sampleRate
                let attack = i < attackFrames ? Float(i) / Float(attackFrames) : 1
                let decay = Float(exp(-Double(i) / (Double(frames) * 0.45)))
                let sample = Float(sin(2 * .pi * segment.hz * t))
                samples[frame] = sample * attack * decay * gain
                frame += 1
            }
        }
        return buffer
    }
}
