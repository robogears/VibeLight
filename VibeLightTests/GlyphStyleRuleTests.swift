import XCTest
@testable import VibeLight

/// The hint-bar glyph family follows the device that drove last
/// (QOL-keyboard-hints-show-pad-glyphs): a keyboard press shows keyboard
/// hints even while a pad is attached, and the next pad press switches back.
final class GlyphStyleRuleTests: XCTestCase {

    func testPadDroveLastShowsThatPadsGlyphs() {
        XCTAssertEqual(
            ControllerManager.effectiveGlyphStyle(lastSource: .pad, controllerStyle: .xbox),
            .xbox)
        XCTAssertEqual(
            ControllerManager.effectiveGlyphStyle(lastSource: .pad, controllerStyle: .playStation),
            .playStation)
    }

    func testKeyboardDroveLastShowsKeyboardGlyphsEvenWithPadAttached() {
        XCTAssertEqual(
            ControllerManager.effectiveGlyphStyle(lastSource: .keyboard, controllerStyle: .xbox),
            .keyboard)
    }

    func testNoControllerAttachedShowsKeyboardGlyphs() {
        XCTAssertEqual(
            ControllerManager.effectiveGlyphStyle(lastSource: .pad, controllerStyle: nil),
            .keyboard)
        XCTAssertEqual(
            ControllerManager.effectiveGlyphStyle(lastSource: .keyboard, controllerStyle: nil),
            .keyboard)
    }
}
