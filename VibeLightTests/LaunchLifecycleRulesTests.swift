import XCTest
@testable import VibeLight

/// Pure lifecycle rules for the Mac launcher: when the launch-time update card
/// may open, and when the window holds the display awake.
final class LaunchLifecycleRulesTests: XCTestCase {

    // MARK: QUA-launch-update-card-no-stream-gate

    private func decide(available: Bool = true, idle: Bool = true, overlayOpen: Bool = false,
                        onHome: Bool = true, onboarding: Bool = false) -> AppState.LaunchUpdateCardDecision {
        AppState.launchUpdateCardDecision(updateAvailable: available, sessionIdle: idle,
                                          overlayOpen: overlayOpen, onHome: onHome, onboarding: onboarding)
    }

    func testUpdateFoundWhileAStreamIsLiveWaitsInsteadOfOpeningBehindIt() {
        // The Mac clears the card slot when the stream goes live, so "no card
        // open" alone used to let the update card open under the game.
        XCTAssertEqual(decide(idle: false, overlayOpen: false), .waitForStreamEnd)
        XCTAssertEqual(decide(idle: false, overlayOpen: true), .waitForStreamEnd)
    }

    func testUpdateCardShowsOnAQuietHomeScreen() {
        XCTAssertEqual(decide(), .show)
    }

    func testUpdateCardIsSkippedWhenSomethingElseHasTheScreen() {
        XCTAssertEqual(decide(overlayOpen: true), .skip)
        XCTAssertEqual(decide(onHome: false), .skip)
        XCTAssertEqual(decide(onboarding: true), .skip)
        XCTAssertEqual(decide(available: false), .skip)
        XCTAssertEqual(decide(available: false, idle: false), .skip)
    }

    // MARK: LIF-display-sleep-held-hidden

    private func hold(windowOpen: Bool = true, minimized: Bool = false, hidden: Bool = false,
                      active: Bool = true, handoff: Bool = false) -> Bool {
        WindowCoordinator.shouldHoldDisplayAwake(windowOpen: windowOpen, minimized: minimized,
                                                 appHidden: hidden, appActive: active, handoffActive: handoff)
    }

    func testDisplayIsHeldAwakeOnlyWhileTheLauncherIsInFront() {
        XCTAssertTrue(hold())
        XCTAssertFalse(hold(hidden: true), "Hide VibeLight must let the display sleep")
        XCTAssertFalse(hold(active: false), "switching to another app must let the display sleep")
        XCTAssertFalse(hold(minimized: true))
        XCTAssertFalse(hold(windowOpen: false))
    }

    func testStreamHandoffKeepsTheHoldAsBefore() {
        // VibeLight is in the background by design while the helper streams.
        XCTAssertTrue(hold(active: false, handoff: true))
        XCTAssertTrue(hold(hidden: true, active: false, handoff: true))
        XCTAssertFalse(hold(minimized: true, active: false, handoff: true))
    }
}
