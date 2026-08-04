#if os(iOS)
import XCTest
@testable import VibeLight

/// The on-screen keyboard hands the app finished TEXT ("A"), never the key press
/// that produced it (shift + a). `KeyboardMap.keyStroke(for:)` reverses that, and
/// a wrong entry here is not a crash — it is the host quietly typing the wrong
/// character, or a game action firing that the user never asked for. Hence a
/// table test rather than spot checks.
final class KeyboardCharacterMapTests: XCTestCase {

    private func stroke(_ character: Character) -> (vk: Int16, shift: Bool)? {
        KeyboardMap.keyStroke(for: character)
    }

    // MARK: - Letters

    func testLowercaseLettersMapToTheirVKWithoutShift() {
        XCTAssertEqual(stroke("a")?.vk, 0x41)
        XCTAssertEqual(stroke("a")?.shift, false)
        XCTAssertEqual(stroke("z")?.vk, 0x5A)
        XCTAssertEqual(stroke("m")?.vk, 0x4D)
        for character in "abcdefghijklmnopqrstuvwxyz" {
            XCTAssertEqual(stroke(character)?.shift, false, "\(character) must not be shifted")
        }
    }

    /// Case is carried by shift, not by a different key: "A" and "a" are the same
    /// physical key. Getting this wrong sends an unmapped VK and types nothing.
    func testUppercaseLettersShareTheVKAndAddShift() {
        for (lower, upper) in zip("abcdefghijklmnopqrstuvwxyz", "ABCDEFGHIJKLMNOPQRSTUVWXYZ") {
            XCTAssertEqual(stroke(upper)?.vk, stroke(lower)?.vk, "\(upper) and \(lower) are one key")
            XCTAssertEqual(stroke(upper)?.shift, true, "\(upper) must be shifted")
        }
    }

    // MARK: - Digits and their shifted symbols

    func testDigitsMapUnshifted() {
        XCTAssertEqual(stroke("0")?.vk, 0x30)
        XCTAssertEqual(stroke("9")?.vk, 0x39)
        for character in "0123456789" {
            XCTAssertEqual(stroke(character)?.shift, false)
        }
    }

    /// ")" is shift+0, not shift+9 — the US row wraps, and an off-by-one here
    /// types the neighbouring symbol.
    func testShiftedDigitRowMapsToTheCorrectDigitKey() {
        let pairs: [(Character, Character)] = [("!", "1"), ("@", "2"), ("#", "3"), ("$", "4"),
                                               ("%", "5"), ("^", "6"), ("&", "7"), ("*", "8"),
                                               ("(", "9"), (")", "0")]
        for (symbol, digit) in pairs {
            XCTAssertEqual(stroke(symbol)?.vk, stroke(digit)?.vk, "\(symbol) is shift+\(digit)")
            XCTAssertEqual(stroke(symbol)?.shift, true, "\(symbol) must be shifted")
        }
    }

    // MARK: - Punctuation

    func testUnshiftedPunctuation() {
        XCTAssertEqual(stroke("-")?.vk, 0xBD)
        XCTAssertEqual(stroke("=")?.vk, 0xBB)
        XCTAssertEqual(stroke("/")?.vk, 0xBF)
        XCTAssertEqual(stroke(";")?.vk, 0xBA)
        for character in "-=[]\\;'`,./" {
            XCTAssertEqual(stroke(character)?.shift, false, "\(character) must not be shifted")
        }
    }

    func testShiftedPunctuationSharesItsUnshiftedKey() {
        let pairs: [(Character, Character)] = [("_", "-"), ("+", "="), ("{", "["), ("}", "]"),
                                               ("|", "\\"), (":", ";"), ("\"", "'"), ("~", "`"),
                                               ("<", ","), (">", "."), ("?", "/")]
        for (shifted, plain) in pairs {
            XCTAssertEqual(stroke(shifted)?.vk, stroke(plain)?.vk, "\(shifted) is shift+\(plain)")
            XCTAssertEqual(stroke(shifted)?.shift, true, "\(shifted) must be shifted")
        }
    }

    // MARK: - Whitespace

    func testWhitespaceAndReturn() {
        XCTAssertEqual(stroke(" ")?.vk, 0x20)     // VK_SPACE
        XCTAssertEqual(stroke("\n")?.vk, 0x0D)    // VK_RETURN
        XCTAssertEqual(stroke("\r")?.vk, 0x0D)    // the keyboard can send either
        XCTAssertEqual(stroke("\t")?.vk, 0x09)    // VK_TAB
    }

    // MARK: - iOS's own substitutions

    /// Smart punctuation is switched off, but curly characters still arrive via
    /// paste, dictation, and predictive text. They must fold back to the plain
    /// key rather than vanishing mid-sentence.
    func testCurlySubstitutionsFoldBackToPlainKeys() {
        XCTAssertEqual(stroke("\u{2019}")?.vk, stroke("'")?.vk)   // ’ → '
        XCTAssertEqual(stroke("\u{2019}")?.shift, false)
        XCTAssertEqual(stroke("\u{201C}")?.vk, stroke("'")?.vk)   // “ → shift+'
        XCTAssertEqual(stroke("\u{201C}")?.shift, true)
        XCTAssertEqual(stroke("\u{2014}")?.vk, stroke("-")?.vk)   // — → -
    }

    // MARK: - What must NOT be guessed at

    /// A character with no US-layout key is dropped, not approximated. Sending a
    /// plausible-looking wrong VK into a game fires whatever that key is bound
    /// to, which is worse than the character simply not arriving.
    func testUnmappableCharactersAreDroppedRatherThanGuessed() {
        for character: Character in ["é", "ß", "中", "🙂", "\u{200B}"] {
            XCTAssertNil(stroke(character), "\(character) has no US key and must not be invented")
        }
    }

    func testBackspaceConstantIsVKBack() {
        XCTAssertEqual(KeyboardMap.backspaceVK, 0x08)
    }
}
#endif
