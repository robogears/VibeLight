#if os(iOS)
import UIKit
import AVFoundation
import Observation

/// Streams to a connected TV / external monitor at that display's NATIVE
/// resolution, rendering fullscreen THERE instead of iOS's default (mirror the
/// iPad panel, letterboxed). The iPad screen keeps the controls and doubles as
/// a trackpad.
///
/// iOS surfaces an external display as a non-interactive `UIWindowScene`
/// (only when the app opts into multiple scenes — see `UIApplicationSceneManifest`
/// in the Info.plist). We host ONE window on that scene containing just the
/// stream's `AVSampleBufferDisplayLayer`. A plain `UIWindow` with the legacy
/// `window.screen =` API no longer renders on modern iOS — it must be created
/// from the scene.
///
/// The engine reads `pixelSize` at launch to request the stream at the TV's
/// resolution, and calls `present`/`dismiss` to move its display layer here.
@MainActor
@Observable
final class ExternalDisplay {
    static let shared = ExternalDisplay()

    /// True while a TV / monitor is connected.
    private(set) var isConnected = false
    /// Name for the placeholder ("the TV").
    private(set) var name = "the display"
    /// The external display's native pixel size — what the stream targets.
    private(set) var pixelSize: CGSize?

    @ObservationIgnored private var window: UIWindow?
    @ObservationIgnored private var hostView: DisplayHostView?
    @ObservationIgnored private weak var streamLayer: AVSampleBufferDisplayLayer?

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { note in
            // Grab the Sendable scene before the actor hop (Notification isn't Sendable).
            let scene = note.object as? UIWindowScene
            MainActor.assumeIsolated { if let scene { self.sceneConnected(scene) } }
        }
        nc.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { note in
            let scene = note.object as? UIWindowScene
            MainActor.assumeIsolated { if let scene { self.sceneDisconnected(scene) } }
        }
        // A display attached before the app launched → its scene is already up.
        for scene in UIApplication.shared.connectedScenes {
            if let ws = scene as? UIWindowScene { sceneConnected(ws) }
        }
    }

    // MARK: - External scene lifecycle

    private func sceneConnected(_ ws: UIWindowScene) {
        guard ws.session.role == .windowExternalDisplayNonInteractive, window == nil else { return }

        let bounds = ws.coordinateSpace.bounds
        let window = UIWindow(windowScene: ws)
        window.frame = bounds
        window.backgroundColor = .black

        let host = DisplayHostView(frame: bounds)
        host.backgroundColor = .black
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let vc = UIViewController()
        vc.view = host
        window.rootViewController = vc
        window.isHidden = false

        self.window = window
        self.hostView = host
        let scale = ws.traitCollection.displayScale
        self.pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        self.name = "the display"
        self.isConnected = true
        NSLog("[VibeLight] external display connected: \(Int(bounds.width))×\(Int(bounds.height)) pt @\(scale)x")

        // A stream is already running → move its video onto the TV now.
        if let layer = streamLayer { host.attach(layer) }
    }

    private func sceneDisconnected(_ ws: UIWindowScene) {
        guard ws === window?.windowScene else { return }
        streamLayer?.removeFromSuperlayer()   // RootView re-parents to the iPad
        window?.isHidden = true
        window = nil
        hostView = nil
        pixelSize = nil
        isConnected = false
    }

    // MARK: - Engine hand-off

    /// Called when a stream starts (and on mid-stream connect). Moves the layer
    /// onto the TV if one is attached; otherwise it stays on the iPad.
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
        if attached === display { display.frame = bounds; return }
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
