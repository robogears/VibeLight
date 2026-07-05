#if os(iOS)
import SwiftUI
import UIKit

/// Locks the app to landscape. The Info.plist orientation keys +
/// `UIRequiresFullScreen` are no longer honored on modern iOS/iPadOS (Apple
/// deprecated them), so a real device still rotates to portrait — where the
/// landscape big-picture layout collapses (title squished up top, the bottom
/// command bar buried). `supportedInterfaceOrientationsFor` IS authoritative and
/// forces landscape on both iPhone and iPad.
final class VibeLightAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .landscape
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
                .task { state.chrome = chrome }
                .onChange(of: scenePhase) { _, phase in
                    // Runaway-repeat guard: controller button releases are
                    // dropped while backgrounded, so reset transient input state
                    // on foreground — the iOS analogue of the macOS
                    // didBecomeActive reset in ControllerManager.
                    if phase == .active { state.controller.handleAppBecameActive() }
                }
        }
    }
}
#endif
