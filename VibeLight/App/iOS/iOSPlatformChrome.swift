#if os(iOS)
import UIKit

/// iOS conformer for `PlatformChrome`. iOS apps are inherently one full-screen
/// scene, so almost all of the macOS `WindowCoordinator` collapses to nothing:
/// no window to make key, no Dock/menu bar to hide, no activation handoff to a
/// subprocess (streaming is in-process — or, in Phase 1, disabled). The only
/// real duty is keeping the display awake during a session.
@MainActor
final class iOSPlatformChrome: PlatformChrome {

    /// The root scene could observe this to present/dismiss a stream layer once
    /// in-process streaming lands. In Phase 1 nothing sets it true.
    private(set) var isStreaming = false

    func preventSleep(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on
    }

    /// No system cursor to hide on touch iOS (iPadOS trackpad pointer is managed
    /// by the OS itself).
    func hidePointer() {}

    func beginStreamPresentation(helperPID: pid_t?) {
        isStreaming = true
        preventSleep(true)
    }

    func endStreamPresentation() {
        isStreaming = false
        preventSleep(false)
    }

    func endStreamPresentationIfActive() {
        guard isStreaming else { return }
        endStreamPresentation()
    }

    /// Apple HIG forbids programmatic termination; the quit-app chord is a no-op.
    func quitApp() {}
}
#endif
