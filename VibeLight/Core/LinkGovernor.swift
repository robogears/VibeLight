import Foundation

/// Link Governor (owner's pick from "the next five", Oct 2026): the stream's
/// bitrate follows the connection instead of being chosen for the worst
/// minute of the night. Three bad seconds in a row step it down a quarter
/// (never below the floor); a calm minute steps it back up toward the preset's
/// number, which is the ceiling and is never edited. Each step is applied
/// live with the host's runtime `/bitrate` (Vibepollo retunes the encoder in
/// place on NVENC and rebuilds it in-session elsewhere), so the game never
/// stops.
///
/// Pure: the engine feeds it one sample a second from the counters it already
/// reads for the perf HUD, so the rules are tested here.
struct LinkGovernor: Equatable, Sendable {
    /// One second of the stream.
    struct Sample: Equatable, Sendable {
        var framesReceived: Int
        var framesDropped: Int
        /// How long the average frame took to arrive in full, in ms.
        var assemblyMs: Double
    }

    enum Step: Equatable, Sendable {
        case down(from: Int, to: Int, lostPercent: Int)
        case up(from: Int, to: Int)

        var to: Int {
            switch self {
            case .down(_, let to, _), .up(_, let to): to
            }
        }
        var from: Int {
            switch self {
            case .down(let from, _, _), .up(let from, _): from
            }
        }
    }

    static let badSecondsToStep = 3
    static let calmSecondsToStep = 60
    /// No two changes closer than this: the encoder needs a moment to settle.
    static let cooldownSeconds = 5
    /// Frames lost in a second, in percent, that make it a bad second.
    static let lossThreshold = 2.0
    static let downFactor = 0.75
    static let upFactor = 1.15
    static let floorFraction = 0.4
    /// Below this the picture stops being worth having; the floor never goes lower.
    static let floorMinimumKbps = 2_000

    let ceilingKbps: Int
    let floorKbps: Int
    /// The time between frames at the stream's rate, in ms.
    let frameIntervalMs: Double
    private(set) var currentKbps: Int
    private var badSeconds = 0
    private var calmSeconds = 0
    private var cooldown = 0
    private var worstLoss = 0.0

    init(ceilingKbps: Int, fps: Int) {
        let ceiling = max(ceilingKbps, 1)
        self.ceilingKbps = ceiling
        self.floorKbps = min(ceiling, max(Int((Double(ceiling) * Self.floorFraction).rounded()),
                                          Self.floorMinimumKbps))
        self.frameIntervalMs = 1000 / Double(max(fps, 1))
        self.currentKbps = ceiling
    }

    static func lossPercent(_ s: Sample) -> Double {
        let total = s.framesReceived + s.framesDropped
        return total > 0 ? Double(s.framesDropped) * 100 / Double(total) : 0
    }

    /// Frames being lost, or taking a whole frame interval to arrive (the
    /// connection falling behind before it starts losing them). A second with
    /// no frames at all (a still screen) is not bad.
    static func isBad(_ s: Sample, frameIntervalMs: Double) -> Bool {
        lossPercent(s) >= lossThreshold || (s.framesReceived > 0 && s.assemblyMs >= frameIntervalMs)
    }

    /// Feeds one second; returns the step to apply now, if any. The step is
    /// taken as current straight away; `settle(at:)` records what the host
    /// actually applied (it clamps to its own ceiling) or puts it back.
    mutating func observe(_ s: Sample) -> Step? {
        if cooldown > 0 { cooldown -= 1 }
        if Self.isBad(s, frameIntervalMs: frameIntervalMs) {
            badSeconds += 1
            calmSeconds = 0
            worstLoss = max(worstLoss, Self.lossPercent(s))
        } else {
            badSeconds = 0
            worstLoss = 0
            calmSeconds += 1
        }
        guard cooldown == 0 else { return nil }
        if badSeconds >= Self.badSecondsToStep, currentKbps > floorKbps {
            let to = max(floorKbps, Int((Double(currentKbps) * Self.downFactor).rounded()))
            let step = Step.down(from: currentKbps, to: to, lostPercent: Int(worstLoss.rounded()))
            currentKbps = to
            badSeconds = 0
            worstLoss = 0
            cooldown = Self.cooldownSeconds
            return step
        }
        if calmSeconds >= Self.calmSecondsToStep, currentKbps < ceilingKbps {
            let to = min(ceilingKbps, Int((Double(currentKbps) * Self.upFactor).rounded()))
            let step = Step.up(from: currentKbps, to: to)
            currentKbps = to
            calmSeconds = 0
            cooldown = Self.cooldownSeconds
            return step
        }
        return nil
    }

    mutating func settle(at kbps: Int) {
        currentKbps = kbps
    }

    /// "60", "45", "7.5" — Mbps as the pill and HUD say it.
    static func mbps(_ kbps: Int) -> String {
        let value = Double(kbps) / 1000
        return value >= 10 ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }

    /// The pill's two lines for a step that the host has applied.
    static func notice(for step: Step, ceilingKbps: Int) -> (title: String, detail: String) {
        switch step {
        case .down(let from, let to, let lost):
            return ("Connection busy · \(mbps(from)) → \(mbps(to)) Mbps",
                    lost > 0 ? "\(lost)% of frames lost" : "frames arriving late")
        case .up(_, let to) where to >= ceilingKbps:
            return ("Back to \(mbps(to)) Mbps", "your preset")
        case .up(_, let to):
            return ("Raising to \(mbps(to)) Mbps", "connection calm")
        }
    }
}
