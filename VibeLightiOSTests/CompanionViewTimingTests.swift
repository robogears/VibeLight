#if os(iOS)
import XCTest
@testable import VibeLight

/// The iPad companion while a TV shows the game (owner's spec): the "Playing
/// on X" panel goes black after 5 s; a tap shows the game on the iPad; 15 s
/// without a touch puts the panel back (which then dims after 5 s again).
final class CompanionViewTimingTests: XCTestCase {
    private typealias Engine = InProcessStreamEngine

    func testPanelDimsAfterFiveSeconds() {
        XCTAssertNil(Engine.companionNext(.panel, idle: .milliseconds(4900), keyboardUp: false))
        XCTAssertEqual(Engine.companionNext(.panel, idle: .seconds(5), keyboardUp: false), .dimmed)
    }

    /// Typing on the iPad keyboard never touches the stream view, so it would
    /// read as idle — the panel stays up while the keyboard is.
    func testKeyboardHoldsThePanelUp() {
        XCTAssertNil(Engine.companionNext(.panel, idle: .seconds(60), keyboardUp: true))
    }

    func testGameOnIPadReturnsToThePanelAfterFifteenSeconds() {
        XCTAssertNil(Engine.companionNext(.stream, idle: .milliseconds(14900), keyboardUp: false))
        XCTAssertEqual(Engine.companionNext(.stream, idle: .seconds(15), keyboardUp: false), .panel)
    }

    /// Black stays black until a touch — no timer wakes it.
    func testDimmedStaysDimmed() {
        XCTAssertNil(Engine.companionNext(.dimmed, idle: .seconds(3600), keyboardUp: false))
    }
}
/// Rejoin (owner's pick from "the next five", plus: swiping up by accident
/// shouldn't cost the game).
final class RejoinRulesTests: XCTestCase {
    private typealias Engine = InProcessStreamEngine

    /// A failed connection is rejoined; the PC ending the game, our own quit,
    /// and the PC's own capture problems are not.
    func testWhichDropsAreRejoined() {
        XCTAssertTrue(Engine.shouldRejoin(error: -100, remoteQuitRequested: false))
        XCTAssertTrue(Engine.shouldRejoin(error: -101, remoteQuitRequested: false))
        XCTAssertTrue(Engine.shouldRejoin(error: 5, remoteQuitRequested: false))
        XCTAssertFalse(Engine.shouldRejoin(error: 0, remoteQuitRequested: false))
        XCTAssertFalse(Engine.shouldRejoin(error: -100, remoteQuitRequested: true))
        XCTAssertFalse(Engine.shouldRejoin(error: -103, remoteQuitRequested: false))
        XCTAssertFalse(Engine.shouldRejoin(error: -104, remoteQuitRequested: false))
    }

    func testThreeTriesAtTwoFiveAndTenSeconds() {
        XCTAssertEqual(Engine.rejoinDelays, [.seconds(2), .seconds(5), .seconds(10)])
    }

    /// A host that answers "no" to /bitrate ends governing for the stream; one
    /// that couldn't be reached is tried again later.
    func testWhichBitrateErrorsEndGoverning() {
        XCTAssertTrue(Engine.hostRefusesBitrate(HostAPIError.xmlStatus(code: 404, message: "")))
        XCTAssertTrue(Engine.hostRefusesBitrate(HostAPIError.notAuthorized))
        XCTAssertFalse(Engine.hostRefusesBitrate(HostAPIError.unreachable("PC")))
        XCTAssertFalse(Engine.hostRefusesBitrate(HostAPIError.notResponding("PC")))
    }

    /// The game waits for VibeLight as long as iOS lets it run in the
    /// background, minus room for the /cancel to land, at most 25 s.
    func testAppExitGrace() {
        XCTAssertEqual(AppState.appExitGrace(backgroundTimeRemaining: 30), .seconds(25))
        XCTAssertEqual(AppState.appExitGrace(backgroundTimeRemaining: 20), .seconds(15))
        XCTAssertEqual(AppState.appExitGrace(backgroundTimeRemaining: 3), .zero)
        XCTAssertEqual(AppState.appExitGrace(backgroundTimeRemaining: .infinity), .seconds(25))
    }

    /// After a kill, a relaunch inside 30 s offers Rejoin first.
    func testRelaunchWindow() {
        XCTAssertTrue(AppState.appExitWindowOpen(age: 20))
        XCTAssertFalse(AppState.appExitWindowOpen(age: 45))
    }
}

/// The tucked controls' corner (owner: tapping by the grey line "can't do it,
/// and sometimes the menu opens"): a tap there is the game's; only a swipe
/// left pulls the controls out.
final class StreamControlsPullTests: XCTestCase {
    private typealias Surface = StreamView.DisplayLayerView

    func testOnlyASwipeLeftPulls() {
        XCTAssertEqual(Surface.pullVerdict(dx: -30, dy: 3), .pull)
        XCTAssertEqual(Surface.pullVerdict(dx: -10, dy: 0), .undecided)   // a tap that lifts here is the game's
        XCTAssertEqual(Surface.pullVerdict(dx: 0, dy: 20), .game)
        XCTAssertEqual(Surface.pullVerdict(dx: 15, dy: 0), .game)
        XCTAssertEqual(Surface.pullVerdict(dx: -20, dy: -20), .game)
        XCTAssertEqual(Surface.pullVerdict(dx: -30, dy: 30), .game)
    }

    func testTheZoneIsTheTopRightCorner() {
        let screen = CGSize(width: 1376, height: 1032)
        XCTAssertTrue(Surface.inPullZone(CGPoint(x: 1360, y: 40), in: screen))
        XCTAssertFalse(Surface.inPullZone(CGPoint(x: 1300, y: 40), in: screen))
        XCTAssertFalse(Surface.inPullZone(CGPoint(x: 1360, y: 400), in: screen))
    }
}

/// The owner got stuck on "Open VibeLight on your iPad" on the iPad itself.
/// A screen only counts as another screen when one exists, it is a
/// different object AND a different size from the built-in panel.
final class ExternalPlacementTests: XCTestCase {
    private let iPad = CGSize(width: 2752, height: 2064)
    private let tv = CGSize(width: 3840, height: 2160)

    func testTheIPadsOwnScreenIsNeverExternal() {
        XCTAssertFalse(ExternalScenePlacement.isOtherScreen(screenCount: 1, sameObject: false,
                                                            nativeSize: tv, builtInNativeSize: iPad))
        XCTAssertFalse(ExternalScenePlacement.isOtherScreen(screenCount: 2, sameObject: false,
                                                            nativeSize: iPad, builtInNativeSize: iPad))
        XCTAssertFalse(ExternalScenePlacement.isOtherScreen(screenCount: 2, sameObject: true,
                                                            nativeSize: tv, builtInNativeSize: iPad))
    }

    func testAWindowOnTheTVIs() {
        XCTAssertTrue(ExternalScenePlacement.isOtherScreen(screenCount: 2, sameObject: false,
                                                           nativeSize: tv, builtInNativeSize: iPad))
    }
}

/// Leaving the stream (Frame Trace's fire): the frame closes in to black, a
/// diamond grows out of the centre over the game while the game dims, and it
/// ENDS black, so the stream only stops under black (owner). Pure, so the
/// shape is tested.
final class ExitFireTests: XCTestCase {
    private let screen = CGSize(width: 1376, height: 1032)
    private func window(_ f: Double) -> CGRect? {
        StreamExitOverlay.fireWindow(f: f, in: screen, inset: 10)?.boundingRect
    }

    func testStartsAsTheWholeFrame() throws {
        let w = try XCTUnwrap(window(0))
        XCTAssertEqual(w, CGRect(x: 10, y: 10, width: 1356, height: 1012))
    }

    func testClosesToBlackBeforeTheDiamond() {
        XCTAssertNil(window(0.29))
        XCTAssertNil(window(0.33))
    }

    /// One closing, then the diamond only GROWS (it once opened and closed
    /// again, which read as the ring closing twice).
    func testDiamondGrowsFromAPointPastTheCorners() throws {
        let sizes = try [0.38, 0.45, 0.55, 0.65, 0.75, 0.85].map { try XCTUnwrap(window($0)).width }
        XCTAssertLessThan(sizes[0], 0.05 * screen.width)            // starts as a point
        XCTAssertEqual(sizes, sizes.sorted())
        let late = try XCTUnwrap(StreamExitOverlay.fireWindow(f: 0.80, in: screen, inset: 10))
        XCTAssertTrue(late.contains(CGPoint(x: 1, y: 1)))            // the whole game shows
    }

    func testDiamondIsTallerThanWideAndCentred() throws {
        let d = try XCTUnwrap(window(0.55))
        XCTAssertEqual(d.width / d.height, (0.6 * screen.width) / (0.9 * screen.height), accuracy: 0.01)
        XCTAssertEqual(d.midX, screen.width / 2, accuracy: 0.5)
        XCTAssertEqual(d.midY, screen.height / 2, accuracy: 0.5)
    }

    /// The game stays bright while the diamond grows, then fades to black.
    func testGameDimsToBlackAfterTheDiamondGrows() {
        XCTAssertEqual(StreamExitOverlay.fireDim(f: 0.6), 0)
        XCTAssertGreaterThan(StreamExitOverlay.fireDim(f: 0.8), StreamExitOverlay.fireDim(f: 0.7))
        XCTAssertEqual(StreamExitOverlay.fireDim(f: 0.92), 1, accuracy: 0.0001)
    }

    /// Clear when the hold starts, closing in faster and faster (exponential),
    /// full when it fires; silent before the fire's black ends.
    func testLeaveAudioCurve() {
        let hold = InProcessStreamEngine.leaveHoldSeconds
        XCTAssertEqual(InProcessStreamEngine.leaveMuffle(elapsed: 0), 0, accuracy: 0.001)
        XCTAssertLessThan(InProcessStreamEngine.leaveMuffle(elapsed: hold / 2), 0.25)   // gentle first half
        XCTAssertEqual(InProcessStreamEngine.leaveMuffle(elapsed: hold), 1, accuracy: 0.001)
        XCTAssertLessThan(InProcessStreamEngine.leaveAudioFade, 0.92 * 1.2)   // the fire is black from 92 % of 1.2 s
    }

    /// The whole last stretch is solid black — the engine waits past it.
    func testEndsBlack() {
        XCTAssertEqual(StreamExitOverlay.fireDuration, .milliseconds(1200))
        for f in stride(from: 0.92, through: 1.0, by: 0.01) {
            XCTAssertNil(window(f), "f = \(f)")
            XCTAssertEqual(StreamExitOverlay.fireDim(f: f), 1, accuracy: 0.0001)
        }
    }
}

#endif
