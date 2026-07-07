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
            guard attached !== display else { return }
            attached?.removeFromSuperlayer()
            attached = display
            display.frame = bounds
            layer.addSublayer(display)
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

        private func forward(_ touches: Set<UITouch>, phase: MoonlightTouchPhase) {
            guard let engine else { return }
            for touch in touches {
                let allocate = (phase == .down)
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
