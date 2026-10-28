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
/// Leaving the stream (Frame Trace's fire): the frame closes in to black, a
/// curved diamond opens on the game and closes again, and it ENDS black, so
/// the stream only stops under black (owner). Pure, so the shape is tested.
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
        XCTAssertNil(window(0.40))
        XCTAssertNil(window(0.47))
    }

    func testDiamondPeaksTallerThanWide() throws {
        let d = try XCTUnwrap(window(0.75))
        XCTAssertEqual(d.width, 0.6 * screen.width, accuracy: 1)
        XCTAssertEqual(d.height, 0.9 * screen.height, accuracy: 1)
        XCTAssertEqual(d.midX, screen.width / 2, accuracy: 0.5)
    }

    /// The whole last stretch is solid black — the engine waits past it.
    func testEndsBlack() {
        for f in stride(from: 0.95, through: 1.0, by: 0.01) { XCTAssertNil(window(f), "f = \(f)") }
    }
}

#endif
