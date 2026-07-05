#if os(iOS)
import SwiftUI
import AVFoundation

/// Full-screen host for the stream's `AVSampleBufferDisplayLayer` (decoded video
/// is enqueued onto it by `MoonlightSession`). A UIView whose backing layer IS
/// the display layer, so it resizes with the view automatically.
struct StreamView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> DisplayLayerView {
        let view = DisplayLayerView()
        view.backgroundColor = .black
        view.attach(layer)
        return view
    }

    func updateUIView(_ view: DisplayLayerView, context: Context) {
        view.attach(layer)
    }

    final class DisplayLayerView: UIView {
        private weak var attached: AVSampleBufferDisplayLayer?

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
    }
}
#endif
