#if os(iOS)
import SwiftUI
import UIKit

/// Locks the app to landscape. On modern iOS/iPadOS (esp. the iOS 26 betas)
/// neither the Info.plist orientation keys, `UIRequiresFullScreen`, NOR the
/// `supportedInterfaceOrientationsFor` delegate mask reliably prevent a rotate
/// to portrait — where the landscape big-picture layout collapses. So we ALSO
/// actively re-assert landscape via `requestGeometryUpdate` whenever the device
/// rotates: the delegate mask defines the ALLOWED set, and the geometry request
/// snaps the interface back into it. Belt (mask) + suspenders (geometry).
final class VibeLightAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .landscape
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { _ in Self.forceLandscape() }
        return true
    }

    /// Re-assert landscape on the active window scene (no-op if already landscape).
    static func forceLandscape() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

/// iOS / iPadOS entry point. Unlike macOS (which boots `NSApplication` manually
/// in App/main.swift to get a borderless big-picture key window), iOS is
/// inherently a single full-screen scene, so a plain SwiftUI `App` + WindowGroup
/// IS the big-picture surface — no menu bar, no activation policy, no window
/// coordinator. This mirrors the macOS AppDelegate's composition: one AppState,
/// host `RootView`, inject via `.environment`, force dark mode.
@main
struct VibeLightApp: App {
    /// Owns the landscape orientation lock (see VibeLightAppDelegate).
    @UIApplicationDelegateAdaptor(VibeLightAppDelegate.self) private var appDelegate
    /// One AppState for the app's lifetime (same single-owner model as macOS,
    /// where the AppDelegate holds the sole instance).
    @State private var state = AppState()
    /// The iOS chrome conformer. Held here (strongly) because `AppState.chrome`
    /// is a weak reference — the scene owns its lifetime.
    @State private var chrome = iOSPlatformChrome()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .task {
                    state.chrome = chrome
                    // A connected TV renders the launcher UI (bound to this same
                    // AppState) when not streaming — so the external display is
                    // never a dead/frozen screen.
                    ExternalDisplay.shared.setLauncherBuilder {
                        let vc = UIHostingController(
                            rootView: ExternalDisplayContent()
                                .environment(state)
                                .preferredColorScheme(.dark))
                        vc.view.backgroundColor = .black
                        return vc
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Runaway-repeat guard: controller button releases are
                    // dropped while backgrounded, so reset transient input state
                    // on foreground — the iOS analogue of the macOS
                    // didBecomeActive reset in ControllerManager.
                    if phase == .active {
                        state.controller.handleAppBecameActive()
                        VibeLightAppDelegate.forceLandscape()   // re-lock after any rotation while away
                    }
                    // "Quit Game on App Exit" (and general stream teardown):
                    // backgrounding suspends our sockets, so the stream dies
                    // regardless — end it deliberately, /cancel-ing the remote
                    // game when the setting is on.
                    if phase == .background { state.handleAppDidEnterBackground() }
                }
        }
    }
}
#endif
