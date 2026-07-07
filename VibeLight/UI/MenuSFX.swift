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
        case restart    // restart PC — a distinctive power-cycle motif
        case launch     // setup finale — a warm rising "arrival" swell
        case quack      // a buzzy comic duck quack (setup welcome + jump-in)
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffers: [Effect: AVAudioPCMBuffer] = [:]
    private var engineStarted = false
    private var loggedFailure = false
    /// The quack is a real recording (Resources/quack.mp3), played via a simple
    /// AVAudioPlayer; the synthesized `.quack` buffer stays a fallback if the
    /// file is ever missing from the bundle.
    private var quackPlayer: AVAudioPlayer?

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
        // restart: "power down… power up" — two falling tones then a rising
        // resolve (E5 → G#4 → G#5), ~200 ms. Unmistakably the reboot cue.
        buffers[.restart] = Self.blip(
            segments: [(659.3, 0.05), (415.3, 0.05), (830.6, 0.10)], gain: 0.20, format: format)
        // launch: a long cinematic "arrival" — a C-major run climbing two octaves
        // (C4 → E4 → G4 → C5 → E5 → G5) then a sustained bell that rings out,
        // ~1.7 s. Plays under the setup finale's VibeLight wordmark reveal.
        buffers[.launch] = Self.blip(
            segments: [(261.6, 0.14), (329.6, 0.14), (392.0, 0.14),
                       (523.3, 0.14), (659.3, 0.14), (784.0, 1.0)],
            gain: 0.27, format: format)
        buffers[.quack] = Self.quack(gain: 0.28, format: format)

        if let url = Bundle.main.url(forResource: "quack", withExtension: "mp3"),
           let player = try? AVAudioPlayer(contentsOf: url) {
            player.volume = 0.85
            player.prepareToPlay()
            quackPlayer = player
        }
    }

    func play(_ effect: Effect) {
        // The quack plays the bundled recording; everything else is synth PCM.
        if effect == .quack, let quackPlayer {
            quackPlayer.currentTime = 0
            quackPlayer.play()
            return
        }
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

    /// A short buzzy comic "quack" — a descending honk (≈600→300 Hz) built from
    /// stacked harmonics (nasal, sawtooth-ish, not a pure tone) with a
    /// two-syllable "qua-ack" amplitude envelope and a little roughness. Phase is
    /// integrated so the pitch glide has no clicks.
    private static func quack(gain: Float, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let duration = 0.24
        let total = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = total
        let n = Int(total)
        var phase = 0.0
        for i in 0..<n {
            let p = Double(i) / Double(n)                 // 0…1
            let freq = 300 + 300 * (1 - p)                // 600 → 300 Hz descending honk
            phase += 2 * .pi * freq / Self.sampleRate
            var s = 0.0
            for h in 1...6 { s += sin(phase * Double(h)) / Double(h) }   // buzzy harmonics
            s /= 1.8
            let attack = min(p / 0.04, 1.0)
            let release = p > 0.75 ? max(0, 1 - (p - 0.75) / 0.25) : 1.0
            let syllables = 0.72 + 0.28 * abs(sin(.pi * 2 * p))         // "qua-ack" two humps
            let rough = 0.85 + 0.15 * sin(2 * .pi * 32 * Double(i) / Self.sampleRate)
            samples[i] = Float(s) * Float(attack * release * syllables * rough) * gain
        }
        return buffer
    }
}
