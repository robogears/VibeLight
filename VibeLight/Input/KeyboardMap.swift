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
}
#endif
