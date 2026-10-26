#if os(iOS)
import XCTest
import SwiftUI
@testable import VibeLight

/// The iPad stream's input rules (audit fix group G6A): which screen edges hold
/// back iOS's own swipes, and which route each typed key takes to the PC.
@MainActor
final class StreamInputRulesTests: XCTestCase {

    // MARK: - Edge swipes (UX-stream-edge-gestures-not-deferred)

    /// A live stream defers every edge, so one stray drag from the bottom can't
    /// go Home and (by default) close the game on the PC.
    func testEveryEdgeIsDeferredWhileStreaming() {
        XCTAssertEqual(RootView.deferredSystemEdges(streaming: true), .all)
    }

    /// The launcher keeps the normal one-swipe Home and Control Center.
    func testNoEdgeIsDeferredInTheLauncher() {
        XCTAssertEqual(RootView.deferredSystemEdges(streaming: false), [])
    }

    // MARK: - One route per key (QUA-hardware-keyboard-double-typing)

    private typealias Receiver = StreamKeyboard.KeyReceiver

    /// With a hardware keyboard forwarded raw to the PC, its keys must not
    /// ALSO become typed text, or each keystroke reaches the PC twice.
    func testForwardedHardwareKeysSkipTheTextRoute() {
        XCTAssertFalse(Receiver.textInputTakes(hardwareKey: true, hardwareKeyboardForwarded: true))
    }

    /// No hardware keyboard being forwarded → a hardware key's text is the
    /// only way it can reach the PC, so it keeps the text route.
    func testUnforwardedHardwareKeysKeepTheTextRoute() {
        XCTAssertTrue(Receiver.textInputTakes(hardwareKey: true, hardwareKeyboardForwarded: false))
    }

    /// Presses that aren't keyboard keys always pass through untouched.
    func testNonKeyPressesAlwaysPassThrough() {
        XCTAssertTrue(Receiver.textInputTakes(hardwareKey: false, hardwareKeyboardForwarded: true))
        XCTAssertTrue(Receiver.textInputTakes(hardwareKey: false, hardwareKeyboardForwarded: false))
    }
}
#endif
