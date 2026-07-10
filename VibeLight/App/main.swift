import AppKit
import SwiftUI

// AppKit-driven boot: SwiftUI's WindowGroup can't give us the borderless
// screen-sized key window the big-picture experience needs (see
// BigPictureWindow for why native fullscreen is wrong here).

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private let windowCoordinator = WindowCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        installMainMenu()

        let state = AppState()
        state.chrome = windowCoordinator
        self.state = state

        windowCoordinator.showBigPicture(
            RootView()
                .environment(state)
                .preferredColorScheme(.dark)
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// "Quit Game on App Exit" (default on): when VibeLight quits with a live
    /// session, fully stop the game on the host (`/cancel`) so nothing is left
    /// streaming/running there. That's an async network call, so we defer
    /// termination until it finishes (or its watchdog fires). Also covers logout/
    /// shutdown, where macOS honors terminateLater up to its own timeout.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // isLocalStreamActive (not hasActiveRemoteSession): only /cancel a game
        // THIS device is actually streaming. A game the host reports running
        // could be another client's, or one we left running on purpose — see the
        // property doc. Mirrors the iOS background-exit narrowing.
        guard let state, state.settings.stopStreamOnExit, state.isLocalStreamActive else {
            return .terminateNow
        }
        Task { @MainActor in
            await state.stopStreamForAppExit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Belt-and-suspenders on the way out: SIGTERM any still-running stream helper
    /// so it isn't orphaned (macOS doesn't kill children on parent exit). If the
    /// exit-quit above ran, the local client is already gone and this no-ops.
    /// (SEV-03)
    func applicationWillTerminate(_ notification: Notification) {
        state?.session.disconnect()
    }

    /// Minimal main menu so ⌘Q / ⌘H / ⌘, work — a borderless app still needs
    /// standard app-level shortcuts. (⌘⇧Q, the hold-to-quit-game chord, is owned
    /// by the keyboard monitor, not the menu.)
    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About VibeLight",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        // Native ⌘, so the settings shortcut works through AppKit's menu
        // system, not just our key monitor. Target is self so it routes to
        // AppState the same way the on-screen Settings action does.
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide VibeLight",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit VibeLight",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        state?.route(.settings)
    }
}

// Manual AppKit entry point (no @main attribute type — we boot NSApplication
// ourselves so the delegate is ours from the first event).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
