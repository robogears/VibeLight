import AppKit
import SwiftUI

/// Screen-filling window that CAN take keyboard focus. It's a titled window
/// (not native fullscreen — that would push us into a Space and cause the slow
/// swipe animation on every stream handoff), sized to the whole screen with a
/// transparent, hidden title bar. The traffic-light buttons are invisible until
/// the mouse reaches the top-left, so it feels like an immersive fullscreen app
/// but stays escapable (close / minimize) without Cmd-Tab.
final class BigPictureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the big-picture window lifecycle and the immersive chrome
/// (hidden menu bar/dock, sleep prevention, stream handoff).
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private(set) var window: BigPictureWindow?
    private var sleepActivity: NSObjectProtocol?
    private var buttonRevealMonitor: Any?
    private var buttonsRevealed = false

    /// True between beginStreamHandoff and endStreamHandoff. Failure paths
    /// use this to restore the chrome exactly when a handoff is outstanding —
    /// a launch can fail long after the previous session's handoff began.
    private(set) var isHandoffActive = false

    func showBigPicture<Content: View>(_ content: Content) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let win = BigPictureWindow(
            contentRect: screen.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.level = .normal
        win.backgroundColor = NSColor(Theme.background)
        win.isOpaque = true
        // Escapable-but-immersive: fill the screen, no visible chrome, but the
        // traffic lights are reachable at the top-left on hover.
        win.collectionBehavior = [.fullScreenNone]
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = false
        win.contentView = NSHostingView(rootView: content)
        win.delegate = self
        // Input-mode switching + button reveal need mouseMoved events.
        win.acceptsMouseMovedEvents = true
        win.setFrame(screen.frame, display: true)
        win.makeKeyAndOrderFront(nil)
        window = win

        installButtonReveal()
        enterImmersiveChrome()
        preventDisplaySleep()
        NSApp.activate()
        // Big-picture opens in console mode: no cursor until the mouse moves.
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    // MARK: - Hover-revealed window buttons

    private static let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    private func installButtonReveal() {
        setButtons(alpha: 0)
        buttonRevealMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.updateButtonReveal() }
            return event
        }
    }

    /// Reveal the traffic lights when the cursor is in the top-left corner.
    private func updateButtonReveal() {
        guard let window, window.isKeyWindow else { return }
        let p = window.mouseLocationOutsideOfEventStream  // window coords, bottom-left origin
        let inCorner = p.y >= window.frame.height - 56 && p.y <= window.frame.height
            && p.x >= 0 && p.x < 220
        guard inCorner != buttonsRevealed else { return }
        buttonsRevealed = inCorner
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            for type in Self.buttonTypes {
                window.standardWindowButton(type)?.animator().alphaValue = inCorner ? 1 : 0
            }
        }
    }

    private func setButtons(alpha: CGFloat) {
        for type in Self.buttonTypes {
            window?.standardWindowButton(type)?.alphaValue = alpha
        }
    }

    // MARK: - Immersive chrome

    /// hideMenuBar REQUIRES hideDock or AppKit throws NSInvalidArgumentException.
    func enterImmersiveChrome() {
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
    }

    /// Clear immersive chrome while Moonlight owns the screen — its own
    /// fullscreen handling must not fight our presentation options.
    func exitImmersiveChrome() {
        NSApp.presentationOptions = []
    }

    // MARK: - Minimize / restore (reveal the Dock so a minimized window is reachable)

    func windowWillMiniaturize(_ notification: Notification) {
        exitImmersiveChrome()  // a hidden Dock would hide the minimized window
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        enterImmersiveChrome()
        NSApp.activate()
    }

    // MARK: - Stream handoff

    /// Called when the stream window is coming up. We deliberately do NOT hide
    /// or order our own window back — keeping VibeLight's fullscreen window up
    /// means the desktop never flashes through while the stream window appears.
    /// The stream window opens on top of us, and we force it frontmost + focused
    /// by activating the helper process we launched (the sanctioned way for an
    /// active app to hand focus to a subprocess under macOS 14+ cooperative
    /// activation — a plain launch would leave it unfocused).
    func beginStreamHandoff(helperPID: pid_t?) {
        isHandoffActive = true
        // Do NOT un-hide the Dock/menu bar here: there's a ~1s gap between the
        // connection starting (when this fires) and the fullscreen stream window
        // actually covering the screen, and un-hiding immediately makes the Dock
        // flash in that gap. Our presentation options simply lapse when the
        // helper takes frontmost, and its fullscreen-desktop window then covers
        // everything — so keeping the Dock hidden through the handoff is cleaner.
        if let helperPID, let helperApp = NSRunningApplication(processIdentifier: helperPID) {
            helperApp.activate()
        } else {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: "com.moonlight-stream.Moonlight")
        }
    }

    /// Called when the stream process exited: reclaim the screen.
    func endStreamHandoff() {
        isHandoffActive = false
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        enterImmersiveChrome()
    }

    /// Restores the chrome only if a handoff is actually outstanding — safe to
    /// call from any failure path without stealing activation spuriously.
    func endStreamHandoffIfActive() {
        guard isHandoffActive else { return }
        endStreamHandoff()
    }

    // MARK: - Sleep

    /// A couch launcher must never let the display sleep mid-browse.
    private func preventDisplaySleep() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled],
            reason: "VibeLight big-picture session"
        )
    }
}
