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

    /// Stop any running stream helper so it isn't orphaned when VibeLight quits
    /// (macOS doesn't kill children on parent exit). SIGTERM ends only the LOCAL
    /// client — the remote game keeps running (invariant 6), the correct quit
    /// semantics. (SEV-03)
    func applicationWillTerminate(_ notification: Notification) {
        state?.session.disconnect()
    }

    /// Minimal main menu so ⌘Q / ⌘H / ⌘M work — a borderless app still needs
    /// standard app-level shortcuts.
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
