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
final class WindowCoordinator: NSObject, NSWindowDelegate, PlatformChrome {
    private(set) var window: BigPictureWindow?
    private var sleepActivity: NSObjectProtocol?
    private var buttonRevealMonitor: Any?
    private var buttonsRevealed = false
    private var activationBounceObserver: (any NSObjectProtocol)?
    /// The embedded helper we handed the screen to (nil when the stock-Moonlight
    /// fallback was used — that app has its own Cmd-Tab identity).
    private var handoffHelperPID: pid_t?
    /// True while the window does NOT fill its screen (the user resized it into a
    /// window). Drives the chrome: filling → immersive (menu bar/dock hidden,
    /// traffic lights hover-revealed); windowed → normal (menu bar/dock reachable,
    /// traffic lights always visible). VibeLight starts filling, so this is false.
    private var isWindowed = false

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
        installActivationBounce()
        enterImmersiveChrome()
        preventDisplaySleep()
        NSApp.activate()
        // Big-picture opens in console mode: no cursor until the mouse moves.
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    // MARK: - Cmd-Tab back to the stream

    /// The embedded helper is an LSUIElement agent — it never appears in the
    /// Cmd-Tab switcher, so while a stream owns the screen VibeLight IS the
    /// stream's Cmd-Tab identity. Without this bounce, Cmd-Tabbing "back" raises
    /// the launcher window over the live stream and the stream becomes
    /// unreachable (the user has to relaunch to see it again).
    private func installActivationBounce() {
        activationBounceObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in self?.bounceToStreamIfHandoffActive() }
        }
    }

    private func bounceToStreamIfHandoffActive() {
        guard isHandoffActive, let pid = handoffHelperPID,
              let helper = NSRunningApplication(processIdentifier: pid),
              !helper.isTerminated else { return }
        helper.activate()
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

    /// Reveal the traffic lights when the cursor is in the top-left corner —
    /// except in windowed mode, where they stay visible so the window is
    /// obviously grabbable / closable.
    private func updateButtonReveal() {
        guard let window, window.isKeyWindow else { return }
        let shouldReveal: Bool
        if isWindowed {
            shouldReveal = true
        } else {
            let p = window.mouseLocationOutsideOfEventStream  // window coords, bottom-left origin
            shouldReveal = p.y >= window.frame.height - 56 && p.y <= window.frame.height
                && p.x >= 0 && p.x < 220
        }
        guard shouldReveal != buttonsRevealed else { return }
        buttonsRevealed = shouldReveal
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            for type in Self.buttonTypes {
                window.standardWindowButton(type)?.animator().alphaValue = shouldReveal ? 1 : 0
            }
        }
    }

    // MARK: - Windowed ↔ immersive (resize-driven)

    /// Whether the window currently fills its screen (within a few points).
    private static func frameFillsScreen(_ window: NSWindow) -> Bool {
        guard let screen = window.screen ?? NSScreen.main else { return false }
        let f = window.frame, s = screen.frame
        return abs(f.width - s.width) < 4 && abs(f.height - s.height) < 4
            && abs(f.minX - s.minX) < 4 && abs(f.minY - s.minY) < 4
    }

    /// Re-evaluate chrome whenever the window frame changes: filling the screen
    /// is immersive (menu bar/dock hidden); anything smaller is a normal window
    /// (menu bar/dock reachable — the whole point of "make it windowed").
    private func syncChromeToWindowState() {
        guard let window else { return }
        let filling = Self.frameFillsScreen(window)
        isWindowed = !filling
        if filling { enterImmersiveChrome() } else { exitImmersiveChrome() }
        buttonsRevealed = false            // force updateButtonReveal to re-apply
        updateButtonReveal()
    }

    func windowDidResize(_ notification: Notification) { syncChromeToWindowState() }
    func windowDidMove(_ notification: Notification) { syncChromeToWindowState() }

    /// Green "zoom" button toggles between filling the screen (immersive) and a
    /// comfortable centered window — an easy way in and out of fullscreen.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        guard let screen = window.screen ?? NSScreen.main else { return defaultFrame }
        if Self.frameFillsScreen(window) {
            let vf = screen.visibleFrame
            let w = vf.width * 0.72, h = vf.height * 0.82
            return NSRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h)
        }
        return screen.frame   // windowed → zoom back to immersive fill
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
        syncChromeToWindowState()   // immersive only if it's back to filling the screen
        NSApp.activate()
    }

    /// Release the mouse-moved monitor when the window goes away, mirroring
    /// ControllerManager.stop(). Benign today (window close terminates the app)
    /// but prevents a dangling monitor if the window is ever recreated. (SEV-09)
    func windowWillClose(_ notification: Notification) {
        if let buttonRevealMonitor {
            NSEvent.removeMonitor(buttonRevealMonitor)
            self.buttonRevealMonitor = nil
        }
        if let activationBounceObserver {
            NotificationCenter.default.removeObserver(activationBounceObserver)
            self.activationBounceObserver = nil
        }
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
        handoffHelperPID = helperPID
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
        isHandoffActive = false   // before activate(): didBecomeActive must not bounce
        handoffHelperPID = nil
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        syncChromeToWindowState()   // restore whichever mode the user was in
    }

    /// Restores the chrome only if a handoff is actually outstanding — safe to
    /// call from any failure path without stealing activation spuriously.
    func endStreamHandoffIfActive() {
        guard isHandoffActive else { return }
        endStreamHandoff()
    }

    // MARK: - PlatformChrome

    /// Toggle the display-sleep assertion. `preventDisplaySleep()` is idempotent
    /// (its `guard sleepActivity == nil` no-ops a double-arm).
    func preventSleep(_ on: Bool) {
        if on {
            preventDisplaySleep()
        } else if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    /// Console/directed mode: cursor vanishes until the mouse moves again.
    func hidePointer() {
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func beginStreamPresentation(helperPID: pid_t?) { beginStreamHandoff(helperPID: helperPID) }
    func endStreamPresentation() { endStreamHandoff() }
    func endStreamPresentationIfActive() { endStreamHandoffIfActive() }
    func quitApp() { NSApplication.shared.terminate(nil) }

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
