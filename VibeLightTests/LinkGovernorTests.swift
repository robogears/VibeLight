import XCTest
@testable import VibeLight

/// Link Governor (owner's pick from "the next five"): the bitrate follows the
/// connection — three bad seconds step it down a quarter, a calm minute steps
/// it back toward the preset's number, which is the ceiling.
final class LinkGovernorTests: XCTestCase {
    private let calm = LinkGovernor.Sample(framesReceived: 120, framesDropped: 0, assemblyMs: 2)
    private let lossy = LinkGovernor.Sample(framesReceived: 113, framesDropped: 7, assemblyMs: 3)

    private func feed(_ g: inout LinkGovernor, _ s: LinkGovernor.Sample, _ n: Int) -> [LinkGovernor.Step] {
        (0..<n).compactMap { _ in g.observe(s) }
    }

    func testStartsAtThePresetWithAFloor() {
        let g = LinkGovernor(ceilingKbps: 60_000, fps: 120)
        XCTAssertEqual(g.currentKbps, 60_000)
        XCTAssertEqual(g.floorKbps, 24_000)
        // A small preset never floors below 2 Mbps, nor above itself.
        XCTAssertEqual(LinkGovernor(ceilingKbps: 3_000, fps: 60).floorKbps, 2_000)
        XCTAssertEqual(LinkGovernor(ceilingKbps: 1_500, fps: 60).floorKbps, 1_500)
    }

    func testThreeBadSecondsStepDownAQuarter() {
        var g = LinkGovernor(ceilingKbps: 60_000, fps: 120)
        XCTAssertTrue(feed(&g, lossy, 2).isEmpty)
        XCTAssertEqual(g.observe(lossy), .down(from: 60_000, to: 45_000, lostPercent: 6))
        XCTAssertEqual(g.currentKbps, 45_000)
    }

    /// A good second in between resets the count: only a sustained problem acts.
    func testABlipDoesNothing() {
        var g = LinkGovernor(ceilingKbps: 60_000, fps: 120)
        XCTAssertTrue(feed(&g, lossy, 2).isEmpty)
        XCTAssertNil(g.observe(calm))
        XCTAssertTrue(feed(&g, lossy, 2).isEmpty)
    }

    /// Frames taking a whole frame interval to arrive count too (the link
    /// falling behind before it loses them); a still screen (no frames) doesn't.
    func testLateFramesAreBadAndStillScreensAreNot() {
        XCTAssertTrue(LinkGovernor.isBad(.init(framesReceived: 120, framesDropped: 0, assemblyMs: 9),
                                         frameIntervalMs: 1000 / 120))
        XCTAssertFalse(LinkGovernor.isBad(.init(framesReceived: 0, framesDropped: 0, assemblyMs: 0),
                                          frameIntervalMs: 1000 / 120))
    }

    func testNeverBelowTheFloorAndWaitsBetweenSteps() {
        var g = LinkGovernor(ceilingKbps: 60_000, fps: 120)
        let steps = feed(&g, lossy, 60)
        XCTAssertEqual(steps.first, .down(from: 60_000, to: 45_000, lostPercent: 6))
        XCTAssertEqual(g.currentKbps, g.floorKbps)
        // Cooldown: no two steps closer than five seconds.
        XCTAssertLessThanOrEqual(steps.count, 60 / LinkGovernor.cooldownSeconds)
    }

    func testACalmMinuteStepsBackUpToThePreset() {
        var g = LinkGovernor(ceilingKbps: 60_000, fps: 120)
        _ = feed(&g, lossy, 3)                       // 45 Mbps
        XCTAssertTrue(feed(&g, calm, 59).isEmpty)
        XCTAssertEqual(g.observe(calm), .up(from: 45_000, to: 51_750))
        _ = feed(&g, calm, 240)
        XCTAssertEqual(g.currentKbps, 60_000, "back at the preset, never above it")
    }

    /// The host clamps (its own ceiling) or refuses; the governor records what
    /// it really runs at.
    func testSettleRecordsWhatTheHostApplied() {
        var g = LinkGovernor(ceilingKbps: 60_000, fps: 120)
        _ = feed(&g, lossy, 3)
        g.settle(at: 40_000)
        XCTAssertEqual(g.currentKbps, 40_000)
    }

    func testThePillSaysWhatHappened() {
        XCTAssertEqual(LinkGovernor.notice(for: .down(from: 60_000, to: 45_000, lostPercent: 6), ceilingKbps: 60_000).title,
                       "Connection busy · 60 → 45 Mbps")
        XCTAssertEqual(LinkGovernor.notice(for: .down(from: 60_000, to: 45_000, lostPercent: 6), ceilingKbps: 60_000).detail,
                       "6% of frames lost")
        XCTAssertEqual(LinkGovernor.notice(for: .up(from: 52_000, to: 60_000), ceilingKbps: 60_000).title,
                       "Back to 60 Mbps")
        XCTAssertEqual(LinkGovernor.mbps(7_500), "7.5")
    }
}
