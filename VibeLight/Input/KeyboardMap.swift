#if os(iOS)
import GameController

/// Maps a hardware-keyboard key (GameController `GCKeyCode`, i.e. a USB-HID usage)
/// to a Windows virtual-key code for `LiSendKeyboardEvent`, plus the MODIFIER_*
/// bit for modifier keys. The host (Sunshine/Apollo) speaks Windows VK codes.
enum KeyboardMap {
    // MODIFIER_* mask bits (Limelight.h).
    static let modShift: UInt8 = 0x01
    static let modCtrl:  UInt8 = 0x02
    static let modAlt:   UInt8 = 0x04
    static let modMeta:  UInt8 = 0x08

    /// The MODIFIER_* bit for a modifier key, or nil if `code` isn't a modifier.
    static func modifierBit(for code: GCKeyCode) -> UInt8? {
        switch code {
        case .leftShift, .rightShift:     return modShift
        case .leftControl, .rightControl: return modCtrl
        case .leftAlt, .rightAlt:         return modAlt
        case .leftGUI, .rightGUI:         return modMeta
        default:                          return nil
        }
    }

    /// The Windows virtual-key code for `code`, or nil if unmapped.
    static func virtualKey(for code: GCKeyCode) -> Int16? {
        let raw = code.rawValue
        // Letters A–Z: HID 0x04–0x1D → VK 0x41–0x5A (both contiguous).
        if raw >= GCKeyCode.keyA.rawValue, raw <= GCKeyCode.keyZ.rawValue {
            return Int16(0x41 + (raw - GCKeyCode.keyA.rawValue))
        }
        // Digits 1–9: HID 0x1E–0x26 → VK 0x31–0x39 (both contiguous). 0 is separate.
        if raw >= GCKeyCode.one.rawValue, raw <= GCKeyCode.nine.rawValue {
            return Int16(0x31 + (raw - GCKeyCode.one.rawValue))
        }
        switch code {
        case .zero:                 return 0x30
        case .returnOrEnter:        return 0x0D   // VK_RETURN
        case .escape:               return 0x1B   // VK_ESCAPE
        case .deleteOrBackspace:    return 0x08   // VK_BACK
        case .tab:                  return 0x09   // VK_TAB
        case .spacebar:             return 0x20   // VK_SPACE
        case .hyphen:               return 0xBD   // VK_OEM_MINUS
        case .equalSign:            return 0xBB   // VK_OEM_PLUS
        case .openBracket:          return 0xDB   // VK_OEM_4
        case .closeBracket:         return 0xDD   // VK_OEM_6
        case .backslash:            return 0xDC   // VK_OEM_5
        case .semicolon:            return 0xBA   // VK_OEM_1
        case .quote:                return 0xDE   // VK_OEM_7
        case .graveAccentAndTilde:  return 0xC0   // VK_OEM_3
        case .comma:                return 0xBC   // VK_OEM_COMMA
        case .period:               return 0xBE   // VK_OEM_PERIOD
        case .slash:                return 0xBF   // VK_OEM_2
        case .capsLock:             return 0x14   // VK_CAPITAL
        // Function keys F1–F12 → VK 0x70–0x7B.
        case .F1:  return 0x70
        case .F2:  return 0x71
        case .F3:  return 0x72
        case .F4:  return 0x73
        case .F5:  return 0x74
        case .F6:  return 0x75
        case .F7:  return 0x76
        case .F8:  return 0x77
        case .F9:  return 0x78
        case .F10: return 0x79
        case .F11: return 0x7A
        case .F12: return 0x7B
        // Navigation cluster.
        case .insert:        return 0x2D   // VK_INSERT
        case .home:          return 0x24   // VK_HOME
        case .pageUp:        return 0x21   // VK_PRIOR
        case .deleteForward: return 0x2E   // VK_DELETE
        case .end:           return 0x23   // VK_END
        case .pageDown:      return 0x22   // VK_NEXT
        case .rightArrow:    return 0x27   // VK_RIGHT
        case .leftArrow:     return 0x25   // VK_LEFT
        case .downArrow:     return 0x28   // VK_DOWN
        case .upArrow:       return 0x26   // VK_UP
        // Modifier keys are forwarded as their own key events too.
        case .leftControl:   return 0xA2   // VK_LCONTROL
        case .leftShift:     return 0xA0   // VK_LSHIFT
        case .leftAlt:       return 0xA4   // VK_LMENU
        case .leftGUI:       return 0x5B   // VK_LWIN
        case .rightControl:  return 0xA3   // VK_RCONTROL
        case .rightShift:    return 0xA1   // VK_RSHIFT
        case .rightAlt:      return 0xA5   // VK_RMENU
        case .rightGUI:      return 0x5C   // VK_RWIN
        default:             return nil
        }
    }

    // MARK: - On-screen keyboard (characters, not HID codes)

    /// The on-screen keyboard hands us finished TEXT, not key codes: iOS gives
    /// `insertText("A")`, never "shift down, a, shift up". So a character has to
    /// be turned back into the key press that would have produced it —
    /// `("A")` → VK 0x41 **with shift**, `("@")` → VK 0x32 **with shift**.
    ///
    /// US layout, deliberately: moonlight-common-c declares these codes as key
    /// POSITIONS on a US English keyboard, and the host then types whatever its
    /// own layout puts at that position. Anything unmapped (accented letters,
    /// emoji, CJK) returns nil here rather than being guessed at — a wrong
    /// keystroke in a game is worse than a missing one — and `route(for:)`
    /// sends it as text instead.
    ///
    /// Known limit, shared with Moonlight (QUA-onscreen-keyboard-assumes-us-pc-layout):
    /// on a PC set to a non-US layout (UK, German, French…), symbols and some
    /// letters land as whatever that layout has at the US key's position (UK:
    /// "@" arrives as a double quote; German: y and z swap), and with Caps Lock
    /// on at the PC, shifted letters arrive lowercase. Sending everything as
    /// text would avoid that but stops games that read raw keys from seeing
    /// W/A/S/D, so it stays a Recommendation (an optional "type as text"
    /// setting), not the default.
    static func keyStroke(for character: Character) -> (vk: Int16, shift: Bool)? {
        // Letters: same VK either way; case is carried by shift.
        if let ascii = character.asciiValue {
            switch ascii {
            case 0x61...0x7A:                                    // a–z
                return (Int16(ascii - 0x61 + 0x41), false)
            case 0x41...0x5A:                                    // A–Z
                return (Int16(ascii), true)
            case 0x30...0x39:                                    // 0–9
                return (Int16(ascii), false)
            default: break
            }
        }
        switch character {
        // Whitespace and editing. "\n" arrives from the keyboard's return key.
        case " ":  return (0x20, false)   // VK_SPACE
        case "\n", "\r": return (0x0D, false)   // VK_RETURN
        case "\t": return (0x09, false)   // VK_TAB
        // Unshifted punctuation.
        case "-":  return (0xBD, false)   // VK_OEM_MINUS
        case "=":  return (0xBB, false)   // VK_OEM_PLUS
        case "[":  return (0xDB, false)   // VK_OEM_4
        case "]":  return (0xDD, false)   // VK_OEM_6
        case "\\": return (0xDC, false)   // VK_OEM_5
        case ";":  return (0xBA, false)   // VK_OEM_1
        case "'":  return (0xDE, false)   // VK_OEM_7
        case "`":  return (0xC0, false)   // VK_OEM_3
        case ",":  return (0xBC, false)   // VK_OEM_COMMA
        case ".":  return (0xBE, false)   // VK_OEM_PERIOD
        case "/":  return (0xBF, false)   // VK_OEM_2
        // Shifted digits.
        case "!":  return (0x31, true)
        case "@":  return (0x32, true)
        case "#":  return (0x33, true)
        case "$":  return (0x34, true)
        case "%":  return (0x35, true)
        case "^":  return (0x36, true)
        case "&":  return (0x37, true)
        case "*":  return (0x38, true)
        case "(":  return (0x39, true)
        case ")":  return (0x30, true)
        // Shifted punctuation.
        case "_":  return (0xBD, true)
        case "+":  return (0xBB, true)
        case "{":  return (0xDB, true)
        case "}":  return (0xDD, true)
        case "|":  return (0xDC, true)
        case ":":  return (0xBA, true)
        case "\"": return (0xDE, true)
        case "~":  return (0xC0, true)
        case "<":  return (0xBC, true)
        case ">":  return (0xBE, true)
        case "?":  return (0xBF, true)
        // The iOS keyboard's "smart" substitutions reach us as real curly
        // characters even with smart quotes/dashes off in some contexts —
        // fold them back to the plain key that produced them.
        case "\u{2018}", "\u{2019}": return (0xDE, false)   // ' '  → '
        case "\u{201C}", "\u{201D}": return (0xDE, true)    // " "  → "
        case "\u{2013}", "\u{2014}": return (0xBD, false)   // – —  → -
        default:   return nil
        }
    }

    /// How one on-screen-keyboard character reaches the host.
    enum TypedRoute: Equatable {
        /// A real key press (with Shift around it when needed): games bind keys.
        case key(vk: Int16, shift: Bool)
        /// Typed text, for characters no US key produces. Text can't trigger a
        /// game's key binding, so it is never a wrong keystroke.
        case text(String)
    }

    /// The route for `character`: a key press when a US key types it, text
    /// otherwise (é, ß, CJK, emoji), and nothing for invisible control or
    /// format characters (a zero-width space is not something to type).
    /// Before, unmapped characters were silently dropped.
    /// (QUA-onscreen-keyboard-assumes-us-pc-layout, non-drastic part)
    static func route(for character: Character) -> TypedRoute? {
        if let stroke = keyStroke(for: character) {
            return .key(vk: stroke.vk, shift: stroke.shift)
        }
        let invisible = character.unicodeScalars.allSatisfy {
            $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
        }
        return invisible ? nil : .text(String(character))
    }

    /// VK_BACK — the on-screen keyboard's delete key.
    static let backspaceVK: Int16 = 0x08
}
#endif
