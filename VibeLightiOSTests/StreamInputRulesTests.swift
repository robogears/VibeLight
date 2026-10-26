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

    // MARK: - Characters with no US key (QUA-onscreen-keyboard-assumes-us-pc-layout)

    /// Accented letters, CJK and emoji used to be dropped silently; they now
    /// reach the PC as typed text, which its keyboard layout can't change.
    func testCharactersWithNoUSKeyAreSentAsText() {
        for character: Character in ["é", "ß", "中", "🙂", "👍🏽", "👩‍💻"] {
            XCTAssertEqual(KeyboardMap.route(for: character), .text(String(character)),
                           "\(character) must arrive as text, not be dropped")
        }
    }

    /// Characters a US key types stay real key presses: games bind keys, and
    /// text can't trigger a binding.
    func testCharactersWithAUSKeyStayKeyPresses() {
        XCTAssertEqual(KeyboardMap.route(for: "w"), .key(vk: 0x57, shift: false))
        XCTAssertEqual(KeyboardMap.route(for: "W"), .key(vk: 0x57, shift: true))
        XCTAssertEqual(KeyboardMap.route(for: "@"), .key(vk: 0x32, shift: true))
        XCTAssertEqual(KeyboardMap.route(for: " "), .key(vk: 0x20, shift: false))
        XCTAssertEqual(KeyboardMap.route(for: "\n"), .key(vk: 0x0D, shift: false))
    }

    /// Invisible control and format characters are not something to type.
    func testInvisibleCharactersAreDropped() {
        for character: Character in ["\u{200B}", "\u{FEFF}", "\u{07}"] {
            XCTAssertNil(KeyboardMap.route(for: character))
        }
    }

    // MARK: - Keyboard frame after "will hide" (QUA-keyboard-hide-clears-undocked-frame)

    private let screen = CGRect(x: 0, y: 0, width: 1194, height: 834)
    private let docked = CGRect(x: 0, y: 434, width: 1194, height: 400)

    /// A real dismissal ends just below the screen: the frame clears, so no
    /// strip of the stream stays blocked.
    func testHideEndingOffScreenClearsTheFrame() {
        let parked = CGRect(x: 0, y: 834, width: 1194, height: 400)
        XCTAssertEqual(InProcessStreamEngine.keyboardFrame(afterHideEndingAt: parked,
                                                           current: docked, screen: screen), .zero)
    }

    /// A split, undocked or floating keyboard is reported as a "hide" while
    /// still on screen: the last known frame stays, so taps in the split gap
    /// don't reach the game.
    func testHideEndingOnScreenKeepsTheKnownFrame() {
        let undocked = CGRect(x: 0, y: 200, width: 1194, height: 300)
        XCTAssertEqual(InProcessStreamEngine.keyboardFrame(afterHideEndingAt: undocked,
                                                           current: docked, screen: screen), docked)
    }

    /// With no frame known yet, an on-screen hide's own end frame is used.
    func testHideEndingOnScreenWithNoKnownFrameUsesTheEndFrame() {
        let floating = CGRect(x: 600, y: 300, width: 320, height: 260)
        XCTAssertEqual(InProcessStreamEngine.keyboardFrame(afterHideEndingAt: floating,
                                                           current: .zero, screen: screen), floating)
    }

    /// Missing information falls back to the old behaviour: clear.
    func testHideWithoutAFrameOrScreenClears() {
        XCTAssertEqual(InProcessStreamEngine.keyboardFrame(afterHideEndingAt: nil,
                                                           current: docked, screen: screen), .zero)
        XCTAssertEqual(InProcessStreamEngine.keyboardFrame(afterHideEndingAt: docked,
                                                           current: docked, screen: nil), .zero)
    }
}
#endif
