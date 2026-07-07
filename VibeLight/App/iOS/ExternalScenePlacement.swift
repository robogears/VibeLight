#if os(iOS)
import SwiftUI
import UIKit

/// Detects the ONE accidental configuration where iPadOS puts the app's primary
/// interactive `WindowGroup` scene on an EXTERNAL screen — Stage Manager extended
/// display, app launched from the TV's own dock/Spotlight. In that case the real
/// external-display feature never engages (there is no
/// `.windowExternalDisplayNonInteractive` scene), and the iPad launcher would
/// render — deformed — on the TV. When this is detected, `RootView` shows a
/// "open on your iPad" card instead.
///
/// SAFE-BY-DEFAULT. `isOnExternalScreen` starts false and flips true ONLY when
/// every guard below positively confirms the accidental case. Every nil /
/// ambiguous / transient read maps to false → the normal iPad UI. A false
/// positive would cover the real UI and is unacceptable; a false negative just
/// falls back to today's behavior and is fine. The load-bearing guard isn't the
/// (deprecated) screen-identity check — it's that the loved flow ALWAYS has a
/// non-interactive external scene and the accidental case NEVER does, which makes
/// a loved-flow false positive structurally impossible.
@MainActor
@Observable
final class ExternalScenePlacement {
    private(set) var isOnExternalScreen = false

    /// The window hosting `RootView`, captured on each probe read so the debounce
    /// re-check doesn't have to capture a non-Sendable `UIWindow` across a hop.
    @ObservationIgnored private weak var lastWindow: UIWindow?
    /// Guards against a stale async confirmation clobbering a newer read.
    @ObservationIgnored private var epoch = 0

    /// Evaluate against the window that actually hosts `RootView` (per-window,
    /// never a global scene scan — so the loved flow's separate TV window can
    /// never be mistaken for this one).
    func evaluate(for window: UIWindow?) {
        lastWindow = window
        let candidate = Self.isCertainlyExternal(window)
        // Super-sample the redirect card the instant we're on an external screen
        // (idempotent; removed when back on the iPad) so its text is crisp — the
        // main window renders at the panel's native scale otherwise, which looks
        // softer than the @2× iPad. Same lever as the launcher supersample.
        Self.setSupersample(window, on: candidate)
        // Bias to safe: any non-external verdict is applied immediately.
        guard candidate else {
            if isOnExternalScreen { isOnExternalScreen = false }
            return
        }
        guard !isOnExternalScreen else { return }   // already showing → nothing to do
        // A `true` verdict must SURVIVE a later runloop turn before we flip the
        // UI — kills any one-frame flash during launch / attach / a cross-display
        // move / built-in `UIScreen` re-instantiation on TV connect.
        epoch &+= 1
        let token = epoch
        Task { @MainActor [weak self] in
            guard let self, self.epoch == token else { return }        // superseded → drop
            guard Self.isCertainlyExternal(self.lastWindow),           // still external?
                  !self.isOnExternalScreen else { return }
            self.isOnExternalScreen = true
        }
    }

    /// True ONLY when all guards positively confirm the accidental case.
    private static func isCertainlyExternal(_ window: UIWindow?) -> Bool {
        // 1 — read THIS window's own scene (never a global scan).
        guard let scene = window?.windowScene else { return false }
        // 2 — only the primary interactive scene. Rejects the TV's own
        //     `.windowExternalDisplayNonInteractive` window; matches only the
        //     mis-placed `.windowApplication`.
        guard scene.session.role == .windowApplication else { return false }
        // 3 — LOAD-BEARING. The loved flow ALWAYS has a non-interactive external
        //     scene; the accidental case NEVER does. If one exists, the primary
        //     scene is definitionally on the iPad → not external. This makes a
        //     loved-flow false positive impossible regardless of screen identity.
        guard !hasNonInteractiveExternalScene() else { return false }
        // 4 — this scene's screen is NOT the built-in panel. Both sides are real
        //     objects here; a mismatch is positive, not "failed to match". This
        //     also subsumes the single-screen cases (iPad-only,
        //     Stage-Manager-multiwindow-on-iPad): there `scene.screen` IS the
        //     built-in → equal → false. (Mirroring likewise stays on the
        //     built-in → equal → false.)
        guard let builtIn = builtInScreen() else { return false }
        return scene.screen !== builtIn
    }

    private static func hasNonInteractiveExternalScene() -> Bool {
        UIApplication.shared.connectedScenes.contains {
            ($0 as? UIWindowScene)?.session.role == .windowExternalDisplayNonInteractive
        }
    }

    /// Force the host window to render at 3× while on the external display so the
    /// redirect card's text is crystal-clear (the panel's native scale otherwise
    /// rasterizes it softer than the @2× iPad); cleanly removed when back on the
    /// iPad. Idempotent, and a no-op on the iPad (no override present → skipped),
    /// so the normal UI is never touched. Only the redirect card is on screen in
    /// this state, so the extra backing store is transient and not during a stream.
    private static func setSupersample(_ window: UIWindow?, on: Bool) {
        guard let window else { return }
        // The `traitOverrides.displayScale` GETTER asserts when no override is
        // present ("Can't return value for trait DisplayScale that has no
        // override"), so gate every read behind `contains` (short-circuited).
        let has = window.traitOverrides.contains(UITraitDisplayScale.self)
        if on {
            guard !has || window.traitOverrides.displayScale != 3 else { return }
            window.traitOverrides.displayScale = 3
        } else if has {
            window.traitOverrides.remove(UITraitDisplayScale.self)
        }
    }

    /// The built-in device display. No non-deprecated API classifies a `UIScreen`
    /// as built-in (even iOS 26's `UIScreen.main` deprecation offers no
    /// replacement for this), so this one `UIScreen.screens` call is unavoidable;
    /// `screens.first` is documented as the built-in. Any misbehavior yields at
    /// worst a false negative (→ the safe, normal iPad UI). Isolated here so the
    /// single deprecation warning has one clearly-labelled home.
    private static func builtInScreen() -> UIScreen? { UIScreen.screens.first }
}

/// Invisible, inert probe placed inside `RootView` so it reads RootView's OWN
/// hosting window. `didMoveToWindow` covers launch-on-TV and TV-unplug (the
/// window re-homes to the iPad); `layoutSubviews` fires when a Stage Manager
/// drag moves the window between screens (its geometry changes); and every
/// SwiftUI re-render re-polls via `updateUIView` (RootView re-renders when a TV
/// connects, since it reads `ExternalDisplay.isConnected`).
struct ScenePlacementProbe: UIViewRepresentable {
    let placement: ExternalScenePlacement

    func makeUIView(context: Context) -> ProbeView { ProbeView(placement: placement) }
    func updateUIView(_ v: ProbeView, context: Context) { v.reevaluate() }

    final class ProbeView: UIView {
        private let placement: ExternalScenePlacement

        init(placement: ExternalScenePlacement) {
            self.placement = placement
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func reevaluate() { placement.evaluate(for: window) }
        override func didMoveToWindow() { super.didMoveToWindow(); reevaluate() }
        override func layoutSubviews() { super.layoutSubviews(); reevaluate() }
    }
}

/// Shown on the external display when the user accidentally opened the app there.
/// Uses the app's design tokens (SF Rounded heavy, navy-dark, single blue accent).
struct ExternalRedirectCard: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "ipad.and.arrow.forward")
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Open VibeLight on your iPad")
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("It streams here automatically once it's running on your iPad.")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
            .multilineTextAlignment(.center)
            .padding(56)
        }
    }
}
#endif
