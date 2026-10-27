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
#endif
