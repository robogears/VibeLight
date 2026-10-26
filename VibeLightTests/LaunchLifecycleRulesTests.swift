import XCTest
@testable import VibeLight

/// Pure lifecycle rules for the Mac launcher: when the launch-time update card
/// may open.
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
}
