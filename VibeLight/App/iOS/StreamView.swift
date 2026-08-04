#if os(iOS)
import SwiftUI
import AVFoundation

/// Full-screen host for the stream's `AVSampleBufferDisplayLayer` (decoded video
/// is enqueued onto it by `MoonlightSession`). A UIView whose backing layer IS
/// the display layer, so it resizes with the view automatically.
///
/// Also the touch surface: multi-touch is forwarded to the engine (which maps
/// into the aspect-fit video rect and sends native touch / mouse fallback).
/// SwiftUI overlays (the X button, HUD) sit above and win hit-testing, so
/// stream touches never fight the controls.
struct StreamView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    /// The engine to forward touches to; nil disables touch control entirely.
    weak var engine: InProcessStreamEngine?
    /// False when a TV owns the video (ExternalDisplay) — then this view must NOT
    /// touch the layer (a layer has one superlayer; re-attaching here would yank
    /// it off the TV). Touch forwarding stays live so the iPad is still a trackpad.
    var hostsLayer = true

    func makeUIView(context: Context) -> DisplayLayerView {
        let view = DisplayLayerView()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
        view.engine = engine
        if hostsLayer { view.attach(layer) }
        return view
    }

    func updateUIView(_ view: DisplayLayerView, context: Context) {
        view.engine = engine
        if hostsLayer { view.attach(layer) }
        // When !hostsLayer the external display owns the layer — leave it alone.
    }

    final class DisplayLayerView: UIView {
        weak var engine: InProcessStreamEngine?
        private weak var attached: AVSampleBufferDisplayLayer?

        /// UITouch → stable pointer id (0…9) for the host. Slot 0 is the
        /// primary pointer (the one the mouse fallback follows).
        private var pointerIds: [ObjectIdentifier: UInt32] = [:]

        func attach(_ display: AVSampleBufferDisplayLayer) {
            // Re-add whenever the layer isn't OUR sublayer — not just when the
            // identity differs. After the external path removes the shared layer
            // (removeFromSuperlayer), `attached` still points at it; an
            // identity-only check would skip addSublayer and leave the iPad black.
            if display.superlayer !== layer {
                attached?.removeFromSuperlayer()
                layer.addSublayer(display)
                attached = display
            }
            display.frame = bounds
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attached?.frame = bounds
        }

        // MARK: Touch forwarding

        private func pointerId(for touch: UITouch, allocate: Bool) -> UInt32? {
            let key = ObjectIdentifier(touch)
            if let id = pointerIds[key] { return id }
            guard allocate else { return nil }
            let used = Set(pointerIds.values)
            guard let free = (0..<10).map(UInt32.init).first(where: { !used.contains($0) }) else { return nil }
            pointerIds[key] = free
            return free
        }

        /// True when `point` (this view's coordinates) is under the on-screen
        /// keyboard. Everything outside it stays live, so you can still tap a
        /// text field in the game and then type into it.
        ///
        /// The keyboard usually swallows its own touches — it lives in a window
        /// above this one. This exists for the cases where it does not: the gap
        /// between the halves of a SPLIT keyboard, the area around a FLOATING
        /// one, and the strip beneath an undocked keyboard. Those all report as
        /// part of the keyboard's frame, and a tap there is aiming at a key, not
        /// at the game.
        private func isUnderKeyboard(_ point: CGPoint) -> Bool {
            guard let engine, engine.onScreenKeyboardUp else { return false }
            let keyboard = engine.keyboardFrameInScreen
            guard !keyboard.isNull, !keyboard.isEmpty, let screen = window?.screen else { return false }
            // Screen → this view. Not `convert(_:from: nil)`, which means window
            // base coordinates — the same thing only when the app owns the whole
            // screen, and wrong under Stage Manager or a split view.
            return screen.coordinateSpace.convert(keyboard, to: self).contains(point)
        }

        private func forward(_ touches: Set<UITouch>, phase: MoonlightTouchPhase) {
            guard let engine else { return }
            engine.noteCompanionActivity()   // any touch wakes the iPad companion
            for touch in touches {
                let allocate = (phase == .down)
                // Only a touch that BEGINS on the keyboard is dropped. Gating
                // here rather than per-event is what keeps a drag that started
                // on the stream working when it crosses the keyboard — and
                // guarantees its release is delivered, because a touch with no
                // pointer id never sent a press to strand.
                if allocate, isUnderKeyboard(touch.location(in: self)) { continue }
                guard let id = pointerId(for: touch, allocate: allocate) else { continue }
                engine.sendTouch(phase, pointerId: id,
                                 location: touch.location(in: self), viewSize: bounds.size)
                if phase == .up || phase == .cancel {
                    pointerIds.removeValue(forKey: ObjectIdentifier(touch))
                }
            }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            forward(touches, phase: .down)
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            forward(touches, phase: .move)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            forward(touches, phase: .up)
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            forward(touches, phase: .cancel)
        }
    }
}
#endif
