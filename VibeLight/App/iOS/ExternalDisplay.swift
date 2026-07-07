#if os(iOS)
import UIKit
import AVFoundation
import Observation

/// Drives a connected TV / external monitor as a proper second screen:
///   • idle  → the full VibeLight launcher UI (same `AppState`, so it mirrors)
///   • stream → the game video at the display's NATIVE resolution, fullscreen
/// The iPad keeps the controls and doubles as a trackpad.
///
/// iOS surfaces an external display as a non-interactive `UIWindowScene` (only
/// when the app opts into multiple scenes — `UIApplicationSceneManifest` in the
/// Info.plist). We host one window there and swap its root view controller
/// between the launcher and the raw stream layer. A plain `UIWindow` via the
/// legacy `window.screen=` API no longer renders on modern iOS — it must come
/// from the scene.
@MainActor
@Observable
final class ExternalDisplay {
    static let shared = ExternalDisplay()

    /// True while a TV / monitor is connected.
    private(set) var isConnected = false
    /// Name for the iPad placeholder.
    private(set) var name = "the display"
    /// The external display's native pixel size — what the stream targets.
    private(set) var pixelSize: CGSize?
    /// Human-readable geometry the OS reports for the display (pixels, points,
    /// scale) — shown on the companion screen so the exact numbers are visible.
    private(set) var geometrySummary: String?

    @ObservationIgnored private var window: UIWindow?
    @ObservationIgnored private var streamHost: DisplayHostView?
    @ObservationIgnored private var streamVC: UIViewController?
    @ObservationIgnored private weak var streamLayer: AVSampleBufferDisplayLayer?
    /// Latest perf-HUD text mirrored from the engine, so a TV plugged in
    /// mid-stream (fresh `DisplayHostView`) shows the numbers immediately.
    @ObservationIgnored private var latestPerf: String?
    /// Builds the launcher view controller (a `UIHostingController` bound to the
    /// app's `AppState`); set once by the app after `AppState` exists. Receives
    /// the super-sample render scale (see `launcherRenderScale`) so the builder
    /// can force the launcher to rasterize at ≥2× on low-DPI panels.
    @ObservationIgnored private var makeLauncher: ((CGFloat) -> UIViewController)?
    @ObservationIgnored private var launcherVC: UIViewController?

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { note in
            let scene = note.object as? UIWindowScene
            MainActor.assumeIsolated { if let scene { self.sceneConnected(scene) } }
        }
        nc.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { note in
            let scene = note.object as? UIWindowScene
            MainActor.assumeIsolated { if let scene { self.sceneDisconnected(scene) } }
        }
        for scene in UIApplication.shared.connectedScenes {
            if let ws = scene as? UIWindowScene { sceneConnected(ws) }
        }
    }

    /// Called once by the app (in the scene `.task`) so the TV can render the
    /// launcher. If a display is already up and idle, swaps it in immediately.
    func setLauncherBuilder(_ builder: @escaping (CGFloat) -> UIViewController) {
        makeLauncher = builder
        launcherVC = nil
        if window != nil, streamLayer == nil { showLauncher() }
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
        let streamVC = UIViewController()
        streamVC.view = host

        self.window = window
        self.streamHost = host
        self.streamVC = streamVC
        let scale = ws.traitCollection.displayScale
        let px = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        self.pixelSize = px
        self.name = "the display"
        self.isConnected = true
        // The launcher super-samples to ≥2× (see `launcherRenderScale`); surface
        // that as a distinct fact so the panel's honest @1× and the render scale
        // both read clearly on the companion screen.
        let renderScale = max(2, scale)
        self.geometrySummary =
            "\(Int(px.width))×\(Int(px.height)) px  ·  \(Int(bounds.width))×\(Int(bounds.height)) pt @\(scale.clean)×"
            + (renderScale != scale ? "  ·  UI \(renderScale.clean)×" : "")
        NSLog("[VibeLight] external display connected: \(self.geometrySummary!)")

        // Mid-stream connect → show the video; otherwise the launcher.
        if let layer = streamLayer {
            host.attach(layer)
            host.setPerf(latestPerf)   // restore the HUD on the fresh host
            window.rootViewController = streamVC
        } else {
            showLauncher()
        }
        window.isHidden = false
    }

    private func sceneDisconnected(_ ws: UIWindowScene) {
        guard ws === window?.windowScene else { return }
        streamLayer?.removeFromSuperlayer()
        window?.isHidden = true
        window = nil
        streamHost = nil
        streamVC = nil
        launcherVC = nil
        pixelSize = nil
        geometrySummary = nil
        isConnected = false
    }

    // MARK: - Engine hand-off

    /// Stream starting (or mid-stream connect): show the video on the TV.
    func present(_ layer: AVSampleBufferDisplayLayer) {
        streamLayer = layer
        guard let host = streamHost else { return }
        host.attach(layer)
        window?.rootViewController = streamVC
    }

    /// Mirror the iPad's perf HUD onto the TV (nil hides it). Cached so a TV
    /// plugged in mid-stream can restore it (see `sceneConnected`).
    func setPerfHUD(_ text: String?) {
        latestPerf = text
        streamHost?.setPerf(text)
    }

    /// Stream ending: clear the last frame (no frozen image) and return the TV
    /// to the launcher UI.
    func dismiss() {
        latestPerf = nil
        streamHost?.setPerf(nil)
        streamLayer?.removeFromSuperlayer()
        streamLayer?.flushAndRemoveImage()   // kill the frozen final frame
        streamLayer = nil
        if window != nil { showLauncher() }
    }

    private func showLauncher() {
        if launcherVC == nil, let make = makeLauncher {
            let vc = make(launcherRenderScale)
            // Belt for the trait override: force the CALayer backing-store scale
            // directly too, in case the over-native `displayScale` trait alone
            // doesn't enlarge the composited buffer on a 1× external scene.
            vc.view.layer.contentsScale = launcherRenderScale
            launcherVC = vc
        }
        window?.rootViewController = launcherVC ?? blackViewController()
    }

    /// The launcher's render (super-sample) scale. Old 1080p TVs report
    /// `displayScale` 1.0, so the launcher UI would rasterize at 1× and then
    /// upscale to the panel → blur. Forcing ≥2× makes it rasterize at 2× and
    /// DOWNSAMPLE to the panel (super-sampling) → crisp. Never downgrades a
    /// genuine @2×/@3× panel. Only the launcher UI is affected; the stream video
    /// path requests the panel's true pixel res and is untouched.
    private var launcherRenderScale: CGFloat {
        max(2, window?.windowScene?.traitCollection.displayScale ?? 1)
    }

    private func blackViewController() -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .black
        return vc
    }
}

private extension CGFloat {
    /// "2" not "2.0", "1.5" stays "1.5" — for the @Nx scale readout.
    var clean: String {
        self == rounded() ? String(Int(self)) : String(format: "%.1f", Double(self))
    }
}

/// A plain black view that hosts (and keeps sized) the stream's display layer,
/// plus the perf HUD mirrored from the iPad so the numbers are visible on the TV.
private final class DisplayHostView: UIView {
    private weak var attached: AVSampleBufferDisplayLayer?
    private let perfLabel = PaddedLabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        perfLabel.numberOfLines = 0
        perfLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        perfLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        perfLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        perfLabel.layer.cornerRadius = 10
        perfLabel.layer.masksToBounds = true
        perfLabel.isHidden = true
        addSubview(perfLabel)   // stays a subview → always above the raw video sublayer
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(_ display: AVSampleBufferDisplayLayer) {
        // Re-add whenever the layer isn't OUR sublayer — not just when the
        // identity differs. On a stream re-launch the layer was detached by
        // `dismiss()` (removeFromSuperlayer) while `attached` still pointed at it;
        // an identity-only check skipped addSublayer and the TV stayed black.
        if display.superlayer !== layer {
            attached?.removeFromSuperlayer()
            layer.insertSublayer(display, at: 0)   // video under the perf label
            attached = display
        }
        display.frame = bounds
    }

    func setPerf(_ text: String?) {
        perfLabel.text = text
        perfLabel.isHidden = (text?.isEmpty ?? true)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attached?.frame = bounds
        let inset: CGFloat = 28
        let maxW = bounds.width - inset * 2
        let fit = perfLabel.sizeThatFits(CGSize(width: maxW, height: .greatestFiniteMagnitude))
        perfLabel.frame = CGRect(x: inset, y: inset,
                                 width: min(fit.width, maxW), height: fit.height)
    }
}

/// UILabel with text insets — for the perf HUD's padded, rounded background.
private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let inner = CGSize(width: size.width - insets.left - insets.right, height: size.height)
        let s = super.sizeThatFits(inner)
        return CGSize(width: s.width + insets.left + insets.right,
                      height: s.height + insets.top + insets.bottom)
    }
}
#endif
