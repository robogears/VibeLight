import Foundation

/// Select + Start pressed together sends ONE PS / Xbox / Guide press to the PC.
///
/// Why it exists: on iPadOS the controller's own Home button can't do it in
/// one press. The system's Game Overlay takes the first press and only the
/// second reaches the app — there is no opt-out (see the long note above
/// `setSystemGestures` in InProcessStreamEngine). The owner picked this chord
/// as the one-press way to open Steam / the PC's overlay.
///
/// The rules, per pad, on moonlight button flags:
/// - Start + Select down with nothing else, then both up → one Guide tap.
///   Neither Start nor Select reaches the game.
/// - L1 / R1 (or any other button) joining abandons the chord and everything
///   passes through unchanged — so the leave-stream hold (Start + Select +
///   L1 + R1) still sees its full combo.
/// - Start or Select ALONE is held back at most `window` in case its partner
///   follows, then delivered. A quick lone tap released inside the window is
///   still delivered, as a tap (`pulse`).
///
/// Pure — no GameController, no clock reads — so the rules are unit-tested.
struct GuideChord {
    static let start: Int32 = 0x0010
    static let back: Int32 = 0x0020
    static let guide: Int32 = 0x0400
    static let pair: Int32 = start | back
    /// How long a lone Start / Select waits for its partner. Two thumbs never
    /// land on the same millisecond; 60 ms covers a deliberate "both at once"
    /// and is far below anything a menu button needs.
    static let window: Duration = .milliseconds(60)

    enum Phase: Equatable {
        case idle
        /// One of the pair is down alone and held back since `since`.
        case waiting(since: ContinuousClock.Instant, held: Int32)
        /// Both are down with nothing else: the chord is live.
        case armed
        /// Not a chord — pass everything through until the pair is released.
        case passing
    }

    struct Output: Equatable {
        /// The flags to send now.
        var flags: Int32
        /// Buttons to TAP on top of `flags`: sent pressed now, released by the
        /// caller's follow-up send (~100 ms later).
        var pulse: Int32 = 0
        /// Re-run `process` with the pad's state at this instant, even if the
        /// pad reports nothing new — a held-back lone button must not wait
        /// for the next stick wiggle.
        var recheckAt: ContinuousClock.Instant? = nil
    }

    private(set) var phase: Phase = .idle

    mutating func process(_ flags: Int32, now: ContinuousClock.Instant) -> Output {
        let pairBits = flags & Self.pair
        let rest = flags & ~Self.pair      // every button that isn't Start / Select

        switch phase {
        case .idle:
            guard rest == 0, pairBits != 0 else { return Output(flags: flags) }
            if pairBits == Self.pair {
                phase = .armed
                return Output(flags: rest)
            }
            phase = .waiting(since: now, held: pairBits)
            return Output(flags: rest, recheckAt: now.advanced(by: Self.window))

        case .waiting(let since, let held):
            if rest == 0, pairBits == Self.pair {
                phase = .armed
                return Output(flags: rest)
            }
            if rest == 0, pairBits == held {
                let deadline = since.advanced(by: Self.window)
                if now < deadline { return Output(flags: rest, recheckAt: deadline) }
                phase = .passing            // no partner came: it's a plain press
                return Output(flags: flags)
            }
            if pairBits == 0 {
                // Released inside the window: a quick lone tap. Deliver it.
                phase = .idle
                return Output(flags: flags, pulse: held)
            }
            phase = .passing                // another button joined: not a chord
            return Output(flags: flags)

        case .armed:
            if rest != 0 {
                // L1/R1 (the leave-stream hold) or anything else: not ours.
                phase = .passing
                return Output(flags: flags)
            }
            if pairBits != 0 { return Output(flags: rest) }   // still releasing
            phase = .idle
            return Output(flags: flags, pulse: Self.guide)

        case .passing:
            if pairBits == 0 { phase = .idle }
            return Output(flags: flags)
        }
    }
}
