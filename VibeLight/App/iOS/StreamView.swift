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
        /// Touches that began in the corner the controls are tucked into,
        /// held back (with where they began) until they are clearly a swipe
        /// left (pull the controls out) or clearly not (deliver to the game).
        private var pendingPulls: [ObjectIdentifier: CGPoint] = [:]
        /// Recognised pulls: their remaining events never reach the game.
        private var pulledTouches: Set<ObjectIdentifier> = []

        func attach(_ display: AVSampleBufferDisplayLayer) {
            // Re-add whenever the layer isn't OUR sublayer — not just when the
            // identity differs. After the external path removes the shared layer
            // (removeFromSuperlayer), `attached` still points at it; an
            // identity-only check would skip addSublayer and leave the iPad black.
            if display.superlayer !== layer {
                if let attached, attached.superlayer === layer {
                    attached.removeFromSuperlayer()
                }
                layer.addSublayer(display)
                attached = display
            }
            display.frame = bounds
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // A previous stream view can still lay out during the fade after
            // the TV takes the layer. Only its current owner may resize it.
            if let attached, attached.superlayer === layer {
                attached.frame = bounds
            }
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
            // Any touch keeps the iPad companion awake. With a TV showing the
            // game, a touch on the panel (lit or black) only brings the game
            // onto the iPad: it gets no pointer id here, so neither it nor its
            // moves and release ever reach the PC.
            let newTouchesReachGame = engine.noteCompanionActivity()
            for touch in touches {
                let key = ObjectIdentifier(touch)
                let here = touch.location(in: self)
                let ends = phase == .up || phase == .cancel
                if pulledTouches.contains(key) {
                    if ends { pulledTouches.remove(key) }
                    continue
                }
                // The corner the controls are tucked into: a tap there is the
                // game's (owner: tapping by the grey line "can't do it, and
                // sometimes the menu opens"), only a swipe left pulls them out.
                if phase == .down, newTouchesReachGame, engine.streamControlsTucked,
                   Self.inPullZone(here, in: bounds.size), !isUnderKeyboard(here) {
                    pendingPulls[key] = here
                    continue
                }
                if let start = pendingPulls[key] {
                    if phase == .cancel { pendingPulls.removeValue(forKey: key); continue }
                    switch Self.pullVerdict(dx: here.x - start.x, dy: here.y - start.y) {
                    case .pull:
                        pendingPulls.removeValue(forKey: key)
                        if !ends { pulledTouches.insert(key) }
                        engine.pullStreamControls()
                        continue
                    case .undecided where !ends:
                        continue
                    case .undecided, .game:
                        // Not a pull: the game gets it from where it began.
                        pendingPulls.removeValue(forKey: key)
                        send(touch, .down, at: start, allocate: true)
                    }
                }
                let allocate = (phase == .down)
                if allocate, !newTouchesReachGame { continue }
                // Only a touch that BEGINS on the keyboard is dropped. Gating
                // here rather than per-event is what keeps a drag that started
                // on the stream working when it crosses the keyboard — and
                // guarantees its release is delivered, because a touch with no
                // pointer id never sent a press to strand.
                if allocate, isUnderKeyboard(here) { continue }
                send(touch, phase, at: here, allocate: allocate)
            }
        }

        private func send(_ touch: UITouch, _ phase: MoonlightTouchPhase, at location: CGPoint, allocate: Bool) {
            guard let engine, let id = pointerId(for: touch, allocate: allocate) else { return }
            engine.sendTouch(phase, pointerId: id, location: location, viewSize: bounds.size)
            if phase == .up || phase == .cancel {
                pointerIds.removeValue(forKey: ObjectIdentifier(touch))
            }
        }

        // MARK: Pulling the controls out

        /// Where the tucked controls' grey pill sits: the top-right corner.
        nonisolated static let pullZone = CGSize(width: 40, height: 200)
        /// How far left a touch travels before it counts as a pull.
        nonisolated static let pullDistance: CGFloat = 24

        nonisolated static func inPullZone(_ point: CGPoint, in size: CGSize) -> Bool {
            point.x >= size.width - pullZone.width && point.y <= pullZone.height
        }

        enum PullVerdict: Equatable { case undecided, pull, game }

        /// A clear swipe left is a pull; a clear move any other way is the
        /// game's; anything smaller waits (and is a tap if it lifts).
        nonisolated static func pullVerdict(dx: CGFloat, dy: CGFloat) -> PullVerdict {
            if -dx >= pullDistance, -dx > abs(dy) * 1.5 { return .pull }
            let travelled = hypot(dx, dy)
            if travelled >= 12, -dx <= abs(dy) { return .game }
            if travelled >= 40 { return .game }   // a long drag that never read as a pull
            return .undecided
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
