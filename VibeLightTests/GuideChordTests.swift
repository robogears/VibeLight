import XCTest
@testable import VibeLight

/// Select + Start → one Guide press while streaming on iPad (the pad's own
/// PS button needs two presses there). The chord shares both buttons with
/// normal play and with the leave-stream hold, so every path is pinned.
final class GuideChordTests: XCTestCase {
    private let start = GuideChord.start, back = GuideChord.back, guide = GuideChord.guide
    private let lb: Int32 = 0x0100, rb: Int32 = 0x0200, a: Int32 = 0x1000
    private let t0 = ContinuousClock.now
    private func at(_ ms: Int) -> ContinuousClock.Instant { t0.advanced(by: .milliseconds(ms)) }

    /// Both down, both up → exactly one Guide tap; the game never sees
    /// Start or Select.
    func testChordTapsGuideOnRelease() {
        var c = GuideChord()
        XCTAssertEqual(c.process(start, now: at(0)).flags, 0)
        XCTAssertEqual(c.process(start | back, now: at(20)).flags, 0)
        XCTAssertEqual(c.process(back, now: at(200)), .init(flags: 0))        // releasing
        XCTAssertEqual(c.process(0, now: at(220)), .init(flags: 0, pulse: guide))
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(c.process(0, now: at(400)), .init(flags: 0))           // no second tap
    }

    func testBothInOneEventArmsImmediately() {
        var c = GuideChord()
        XCTAssertEqual(c.process(start | back, now: at(0)).flags, 0)
        XCTAssertEqual(c.phase, .armed)
    }

    /// The leave-stream hold (Start + Select + L1 + R1) still sees its whole
    /// combo, however the buttons were pressed.
    func testShouldersAbandonTheChordForTheLeaveHold() {
        var c = GuideChord()
        _ = c.process(start | back, now: at(0))
        XCTAssertEqual(c.process(start | back | lb, now: at(50)).flags, start | back | lb)
        XCTAssertEqual(c.process(start | back | lb | rb, now: at(60)).flags, start | back | lb | rb)
        XCTAssertEqual(c.process(0, now: at(2000)), .init(flags: 0))          // no Guide afterwards
    }

    func testShouldersFirstNeverEngage() {
        var c = GuideChord()
        XCTAssertEqual(c.process(lb | rb, now: at(0)).flags, lb | rb)
        XCTAssertEqual(c.process(lb | rb | start | back, now: at(10)).flags, lb | rb | start | back)
    }

    /// Start alone is held back only for the window, then delivered.
    func testLoneStartHeldPastTheWindowIsDelivered() {
        var c = GuideChord()
        let first = c.process(start, now: at(0))
        XCTAssertEqual(first.flags, 0)
        XCTAssertEqual(first.recheckAt, at(60))
        XCTAssertEqual(c.process(start, now: at(30)), .init(flags: 0, recheckAt: at(60)))
        XCTAssertEqual(c.process(start, now: at(60)).flags, start)
        // Select joining late is no chord — Start was already the game's.
        XCTAssertEqual(c.process(start | back, now: at(300)).flags, start | back)
        XCTAssertEqual(c.process(0, now: at(500)), .init(flags: 0))
    }

    /// A quick lone tap released inside the window still reaches the game.
    func testQuickLoneTapIsDeliveredAsAPulse() {
        var c = GuideChord()
        _ = c.process(back, now: at(0))
        XCTAssertEqual(c.process(0, now: at(40)), .init(flags: 0, pulse: back))
        XCTAssertEqual(c.phase, .idle)
    }

    /// Another button joining a held-back Start makes it ordinary input.
    func testOtherButtonJoiningPassesThrough() {
        var c = GuideChord()
        _ = c.process(start, now: at(0))
        XCTAssertEqual(c.process(start | a, now: at(10)).flags, start | a)
        XCTAssertEqual(c.phase, .passing)
    }

    /// Start pressed while already holding another button is never delayed.
    func testStartWithOtherButtonsHeldIsNotDelayed() {
        var c = GuideChord()
        XCTAssertEqual(c.process(a | start, now: at(0)), .init(flags: a | start))
    }
}
