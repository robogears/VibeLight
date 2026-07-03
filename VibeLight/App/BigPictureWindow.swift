import AppKit
import SwiftUI

/// Borderless screen-sized window that CAN take keyboard focus.
///
/// Why not native fullscreen: `.fullScreenPrimary` moves the app into its own
/// Space, so every stream launch/return triggers the slow Space-swipe
/// animation. A borderless window on the normal Space hands off to the
/// Moonlight window instantly. Borderless windows refuse key status unless
/// these overrides exist — without them the keyboard is silently dead.
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
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = .normal
        win.backgroundColor = NSColor(Theme.background)
        win.isOpaque = true
        win.collectionBehavior = [.fullScreenNone]
        win.contentView = NSHostingView(rootView: content)
        win.delegate = self
        win.setFrame(screen.frame, display: true)
        win.makeKeyAndOrderFront(nil)
        window = win

        enterImmersiveChrome()
        preventDisplaySleep()
        NSApp.activate()
    }

    /// hideMenuBar REQUIRES hideDock or AppKit throws NSInvalidArgumentException.
    func enterImmersiveChrome() {
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
    }

    /// Clear immersive chrome while Moonlight owns the screen — its own
    /// fullscreen handling must not fight our presentation options.
    func exitImmersiveChrome() {
        NSApp.presentationOptions = []
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
        exitImmersiveChrome()
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
