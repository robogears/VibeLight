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

        # Move the existing install ASIDE rather than deleting it. This used to
        # `rm -rf "$DEST"` and only then copy: a ditto that failed midway (disk
        # full, permissions, an interrupted relocate) left the user with NO app
        # at the destination and only the source to fall back on — and when the
        # source IS being removed, with nothing at all. The backup is deleted
        # only after the new copy verifies and launches.
        BAK=""
        if [ -e "$DEST" ]; then
          BAK="$DEST.vibelight-bak"
          rm -rf "$BAK"
          if ! mv "$DEST" "$BAK"; then echo "could not set aside existing install"; open "$SRC"; rm -f "$0"; exit 1; fi
        fi

        restore() {
          echo "restoring previous install"
          rm -rf "$DEST"
          [ -n "$BAK" ] && mv "$BAK" "$DEST" && open "$DEST" && return 0
          open "$SRC"
        }

        if ! ditto "$SRC" "$DEST"; then echo "copy failed"; restore; rm -f "$0"; exit 1; fi
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
        # A moved bundle's seal is invalid until re-signed, and an unsigned
        # bundle is "damaged" to Gatekeeper — so unlike the cosmetic xattr strip,
        # a re-sign failure here is fatal and must roll back, not be swallowed.
        if ! codesign --force --deep --sign - "$DEST"; then echo "re-sign failed"; restore; rm -f "$0"; exit 1; fi
        if ! codesign --verify --deep "$DEST"; then echo "verify failed"; restore; rm -f "$0"; exit 1; fi

        if open "$DEST"; then
          # The new copy launched: NOW it is safe to drop the backup, and only
          # then the original.
          [ -n "$BAK" ] && rm -rf "$BAK"
          if [ "$REMOVE_SRC" = "1" ] && [ "$SRC" != "$DEST" ]; then rm -rf "$SRC"; fi
        else
          restore
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
