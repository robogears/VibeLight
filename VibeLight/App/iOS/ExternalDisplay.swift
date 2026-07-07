#if os(iOS)
import UIKit
import AVFoundation
import Observation

/// Streams to a connected TV / external monitor at that display's NATIVE
/// resolution, instead of iOS's default behaviour (mirror the iPad panel,
/// letterboxed to the iPad's aspect ratio). When a display is attached we host
/// one window on it containing only the stream's `AVSampleBufferDisplayLayer`;
/// the iPad screen keeps the controls and doubles as a trackpad.
///
/// The engine reads `pixelSize` at launch to request the stream at the TV's
/// resolution, and calls `present`/`dismiss` to move its display layer here.
///
/// Uses the `UIScreen` external-display API (deprecated on the newest iOS but
/// still the most broadly-functional path, and — crucially — it touches no
/// scene configuration, so if the OS ever drops it the feature simply no-ops
/// and the app is unaffected).
@MainActor
@Observable
final class ExternalDisplay {
    static let shared = ExternalDisplay()

    /// True while a TV / monitor is connected. Drives the engine's resolution
    /// choice and the iPad's "playing on the TV" placeholder.
    private(set) var isConnected = false
    /// Human name of the attached display (for the placeholder), e.g. "TV".
    private(set) var name = "the TV"
    /// The external display's native pixel size — what the stream should target.
    private(set) var pixelSize: CGSize?

    @ObservationIgnored private var window: UIWindow?
    @ObservationIgnored private var hostView: DisplayHostView?
    /// The stream layer currently owned by a live session (so a mid-stream
    /// connect can grab it and a disconnect can hand it back).
    @ObservationIgnored private weak var streamLayer: AVSampleBufferDisplayLayer?

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIScreen.didConnectNotification, object: nil, queue: .main) { note in
            // Pull the Sendable screen out before the actor hop (the non-Sendable
            // Notification can't cross into the @MainActor closure under Swift 6).
            let screen = note.object as? UIScreen
            MainActor.assumeIsolated { if let screen { self.connect(screen) } }
        }
        nc.addObserver(forName: UIScreen.didDisconnectNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.disconnect() }
        }
        // A display already attached at launch (plugged in before the app opened).
        if let ext = UIScreen.screens.first(where: { $0 !== UIScreen.main }) {
            connect(ext)
        }
    }

    // MARK: - Connect / disconnect (system-driven)

    private func connect(_ screen: UIScreen) {
        guard window == nil else { return }
        screen.overscanCompensation = .none

        let window = UIWindow(frame: screen.bounds)
        window.screen = screen
        let host = DisplayHostView(frame: screen.bounds)
        host.backgroundColor = .black
        let vc = UIViewController()
        vc.view = host
        window.rootViewController = vc
        window.isHidden = false

        self.window = window
        self.hostView = host
        // nativeBounds is the physical panel size in PIXELS — exactly the stream
        // resolution we want (e.g. 3840×2160 for a 4K TV).
        let nb = screen.nativeBounds
        self.pixelSize = CGSize(width: nb.width, height: nb.height)
        self.name = "the display"
        self.isConnected = true

        // A stream is already running → move its video onto the TV now.
        if let layer = streamLayer { host.attach(layer) }
    }

    private func disconnect() {
        // Hand the layer back to whoever hosts it on the iPad (RootView re-parents
        // it via StreamView once `isConnected` flips false).
        streamLayer?.removeFromSuperlayer()
        window?.isHidden = true
        window = nil
        hostView = nil
        pixelSize = nil
        isConnected = false
    }

    // MARK: - Engine hand-off

    /// Called when a stream starts (and on mid-stream connect). Moves the layer
    /// onto the TV if one is attached; otherwise the layer stays on the iPad.
    func present(_ layer: AVSampleBufferDisplayLayer) {
        streamLayer = layer
        hostView?.attach(layer)
    }

    /// Called when the stream ends — the layer is going away.
    func dismiss() {
        streamLayer = nil
    }
}

/// A plain black view that hosts (and keeps sized) the stream's display layer.
private final class DisplayHostView: UIView {
    private weak var attached: AVSampleBufferDisplayLayer?

    func attach(_ display: AVSampleBufferDisplayLayer) {
        guard attached !== display else { display.frame = bounds; return }
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
#endif
