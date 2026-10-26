#if os(iOS)
import SwiftUI
import UIKit
import GameController

/// Raises the iPad's own keyboard over the stream and forwards what you type to
/// the host, so the PC behaves as though a keyboard were plugged into it.
///
/// Deliberately the SYSTEM keyboard rather than a drawn one: you get the real
/// iPadOS typing feel, every symbol page, dictation, and the layout the user
/// already knows — none of which is worth re-implementing badly.
///
/// It hosts an invisible, zero-size `UIKeyInput` view rather than a `UITextField`
/// because there is no text here to edit. Nothing is stored, nothing is shown;
/// each keystroke is converted and sent, and the "document" is always empty.
/// That also means no autocorrect substituting words into a game chat box, and
/// no text buffer to fall out of sync with the host.
struct StreamKeyboard: UIViewRepresentable {

    /// Bound to the button that raises/lowers the keyboard. Two-way: iOS can
    /// lower the keyboard itself (an interactive dismiss), and this flips back
    /// to false when it does.
    @Binding var isUp: Bool
    let onCharacter: (Character) -> Void
    let onBackspace: () -> Void

    func makeUIView(context: Context) -> KeyReceiver {
        let view = KeyReceiver()
        view.onCharacter = onCharacter
        view.onBackspace = onBackspace
        view.onDismiss = { isUp = false }
        return view
    }

    func updateUIView(_ view: KeyReceiver, context: Context) {
        // Closures capture the CURRENT engine each update — a stale one would
        // type into a session that has already ended.
        view.onCharacter = onCharacter
        view.onBackspace = onBackspace
        view.onDismiss = { isUp = false }
        if isUp, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !isUp, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    /// The invisible first responder. Accepts text, keeps none.
    final class KeyReceiver: UIView, UIKeyInput {
        var onCharacter: ((Character) -> Void)?
        var onBackspace: (() -> Void)?
        var onDismiss: (() -> Void)?

        override var canBecomeFirstResponder: Bool { true }

        // MARK: UIKeyInput

        /// Always true. With `hasText == false` iOS suppresses delete entirely,
        /// so backspace would never reach the host — and backspace is the whole
        /// point in a game's chat box or a password field.
        var hasText: Bool { true }

        func insertText(_ text: String) {
            for character in text { onCharacter?(character) }
        }

        func deleteBackward() {
            onBackspace?()
        }

        // MARK: Hardware keys — one route per key

        /// Whether a press reaches the text-input route (`insertText` /
        /// `deleteBackward` → `typeCharacter`). A hardware key already reaches
        /// the PC as a raw key down/up through the GameController keyboard
        /// handler the stream installs; iPadOS ALSO turns it into typed text
        /// for this first responder, so with the on-screen keyboard raised
        /// every hardware keystroke arrived twice. A hardware key therefore
        /// goes to text input only when no hardware keyboard is being
        /// forwarded; on-screen key taps are not presses and always type.
        /// (QUA-hardware-keyboard-double-typing)
        ///
        /// Only keys the raw route actually SENDS are held back: it drops any
        /// key `KeyboardMap.virtualKey` can't map (the numpad, the ISO key left
        /// of Z, international keys), so for those the typed text is still the
        /// one way they reach the PC. `hardwareKey` is nil for a press that
        /// isn't a keyboard key.
        static func textInputTakes(hardwareKey: GCKeyCode?, hardwareKeyboardForwarded: Bool) -> Bool {
            guard let hardwareKey, hardwareKeyboardForwarded else { return true }
            return KeyboardMap.virtualKey(for: hardwareKey) == nil
        }

        /// Not calling super for a press is what keeps UIKit from turning it
        /// into `insertText` (the same interception moonlight-ios uses).
        private func passedToTextInput(_ presses: Set<UIPress>) -> Set<UIPress> {
            let forwarded = GCKeyboard.coalesced != nil
            return presses.filter {
                // UIKey.keyCode and GCKeyCode are both USB-HID usages.
                let code = $0.key.map { GCKeyCode(rawValue: $0.keyCode.rawValue) }
                return Self.textInputTakes(hardwareKey: code, hardwareKeyboardForwarded: forwarded)
            }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let rest = passedToTextInput(presses)
            if !rest.isEmpty { super.pressesBegan(rest, with: event) }
        }

        override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let rest = passedToTextInput(presses)
            if !rest.isEmpty { super.pressesChanged(rest, with: event) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let rest = passedToTextInput(presses)
            if !rest.isEmpty { super.pressesEnded(rest, with: event) }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let rest = passedToTextInput(presses)
            if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
        }

        // MARK: Traits — everything "helpful" turned off

        /// Autocorrect, capitalisation and smart punctuation all rewrite what the
        /// user typed. In a chat box that is annoying; bound to a game's key
        /// bindings it is wrong — "w" must arrive as "w", never as "We".
        /// (These come from `UITextInputTraits`, which `UIKeyInput` inherits —
        /// they are protocol requirements, not `UIView` properties to override.)
        var autocorrectionType: UITextAutocorrectionType = .no
        var autocapitalizationType: UITextAutocapitalizationType = .none
        var spellCheckingType: UITextSpellCheckingType = .no
        var smartQuotesType: UITextSmartQuotesType = .no
        var smartDashesType: UITextSmartDashesType = .no
        var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
        /// No return-key "Go/Send" affordance — this types into a game, not a form.
        var returnKeyType: UIReturnKeyType = .default

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            // Covers the dismissals SwiftUI never told us about, such as the
            // interactive swipe-down. Without this the button stays lit with
            // no keyboard. (A hardware keyboard connecting usually does NOT
            // resign this view; iPadOS just hides the software keys, which is
            // why hardware presses are filtered above.)
            if resigned { onDismiss?() }
            return resigned
        }
    }
}
#endif
