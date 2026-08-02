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
        if ! codesign --verify --deep --strict "$DEST"; then echo "verify failed"; restore; rm -f "$0"; exit 1; fi

        # By here the copy is complete, re-signed and VERIFIED — it is a good
        # install. A failing `open` at this point is a LaunchServices hiccup (it
        # hasn't noticed the freshly written bundle yet), not a bad bundle, so
        # retry rather than roll back. Deleting a verified install because the
        # launcher was slow would silently downgrade the user — or, on a first
        # relocation where there is no backup, throw the good copy away
        # entirely. The updater's relauncher takes the same retry approach.
        if open "$DEST" || { sleep 1; open "$DEST"; }; then
          # The new copy launched: NOW it is safe to drop the backup, and only
          # then the original.
          [ -n "$BAK" ] && rm -rf "$BAK"
          if [ "$REMOVE_SRC" = "1" ] && [ "$SRC" != "$DEST" ]; then rm -rf "$SRC"; fi
        else
          # Still not launching. KEEP the verified copy in place — the user can
          # start it from Finder — and just put the old one back beside it if we
          # have one, then fall back to opening the source so they aren't left
          # staring at nothing.
          echo "installed copy verified but would not launch; leaving it in place"
          if [ -n "$BAK" ]; then
            rm -rf "$DEST.previous" && mv "$BAK" "$DEST.previous" 2>/dev/null || rm -rf "$BAK"
          fi
          open "$SRC" 2>/dev/null || open "$DEST" 2>/dev/null
        fi
        rm -f "$0"
        """
        try UpdateService.launchDetachedScript(script, prefix: "vibelight-relocate", args: [
            String(ProcessInfo.processInfo.processIdentifier),
            src.path, dest.path, removeSrc ? "1" : "0",
        ])
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
