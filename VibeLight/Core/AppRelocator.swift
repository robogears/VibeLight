#if os(macOS)
import AppKit
import Foundation

/// Offers to move VibeLight into /Applications on first launch when it's
/// running from Downloads or a read-only App-Translocation copy. Living in
/// /Applications is what makes the self-updater's in-place install work and
/// keeps macOS from quarantine-translocating the app on every launch.
///
/// Shares the re-sign-and-relaunch approach with the updater (moving a bundle
/// + stripping quarantine invalidates the ad-hoc seal, so we re-sign in place).
enum AppRelocator {

    static var applicationsURL: URL { URL(fileURLWithPath: "/Applications/VibeLight.app") }

    private static var userApplicationsPath: String {
        NSHomeDirectory() + "/Applications/VibeLight.app"
    }

    /// Whether the running bundle is already in an Applications folder (and not
    /// a translocated read-only copy of it).
    static func isInApplications() -> Bool {
        let path = Bundle.main.bundleURL.path
        if path.contains("/AppTranslocation/") { return false }
        return path == applicationsURL.path || path == userApplicationsPath
    }

    /// True when we should offer to relocate (Release builds only — a dev build
    /// living in DerivedData must never try to move itself).
    static func shouldOfferRelocation() -> Bool {
        #if DEBUG
        return false
        #else
        guard !isInApplications() else { return false }
        // Only worthwhile if we can actually write /Applications.
        return FileManager.default.isWritableFile(atPath: "/Applications")
        #endif
    }

    /// Copies the running bundle to /Applications (de-quarantined + re-signed)
    /// and relaunches from there, then quits. `true` if the mover started.
    @MainActor
    static func moveToApplications() -> Bool {
        let src = Bundle.main.bundleURL     // readable even when translocated
        let dest = applicationsURL
        // A plain (non-translocated) source we own can be removed after the
        // copy, making it a true move; a translocated copy is ephemeral.
        let removeSrc = !src.path.contains("/AppTranslocation/")
            && FileManager.default.isWritableFile(atPath: src.path)
        do {
            try stageMove(src: src, dest: dest, removeSrc: removeSrc)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.terminate(nil)
            }
            return true
        } catch {
            return false
        }
    }

    private static func stageMove(src: URL, dest: URL, removeSrc: Bool) throws {
        let script = """
        #!/bin/bash
        # VibeLight relocate-to-Applications. Args: <pid> <src> <dest> <removeSrc>.
        trap '' HUP TERM
        OLD_PID="$1"; SRC="$2"; DEST="$3"; REMOVE_SRC="$4"
        LOGDIR="$HOME/Library/Logs/VibeLight"; mkdir -p "$LOGDIR"
        exec >> "$LOGDIR/update.log" 2>&1
        echo "=== $(date) relocate src=$SRC dest=$DEST ==="
        for i in $(seq 1 150); do kill -0 "$OLD_PID" 2>/dev/null || break; sleep 0.2; done
        mkdir -p "$(dirname "$DEST")"
        [ -e "$DEST" ] && rm -rf "$DEST"
        if ! ditto "$SRC" "$DEST"; then echo "copy failed"; open "$SRC"; rm -f "$0"; exit 1; fi
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
        codesign --force --deep --sign - "$DEST" 2>/dev/null || true
        if open "$DEST"; then
          # Only delete the original once the moved copy actually launched.
          if [ "$REMOVE_SRC" = "1" ] && [ "$SRC" != "$DEST" ]; then rm -rf "$SRC"; fi
        else
          open "$SRC"
        fi
        rm -f "$0"
        """
        let fm = FileManager.default
        let scriptURL = fm.temporaryDirectory.appendingPathComponent("vibelight-relocate-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            scriptURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            src.path, dest.path, removeSrc ? "1" : "0",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
#else
import Foundation

/// iOS: there is no "/Applications" concept and apps can't relocate or re-sign
/// themselves. Stubbed so the shared `AppState` startup checks compile and
/// simply never offer relocation on iOS.
enum AppRelocator {
    static func shouldOfferRelocation() -> Bool { false }
    @MainActor static func moveToApplications() -> Bool { false }
}
#endif
