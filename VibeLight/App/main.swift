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
        state.windowCoordinator = windowCoordinator
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
        appMenu.addItem(withTitle: "Hide VibeLight",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit VibeLight",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }
}

// Manual AppKit entry point (no @main attribute type — we boot NSApplication
// ourselves so the delegate is ours from the first event).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
