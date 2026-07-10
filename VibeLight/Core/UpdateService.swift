#if os(macOS)
import AppKit
import CryptoKit
import Foundation
import Observation

/// In-app self-updater for VibeLight, modeled on the Electron/GitHub-Releases
/// pattern but native: it polls the repo's latest *published* release, and —
/// because VibeLight is ad-hoc signed and un-notarized — trusts the download
/// solely on TLS to GitHub, then swaps the running bundle and relaunches.
///
/// Security posture (mirrors the electron-github-updater trust model):
/// - The SOLE authenticity boundary is TLS to GitHub + the host pin
///   (github.com / *.githubusercontent.com, re-checked on every redirect).
/// - `codesign --verify` on the extracted bundle is an INTEGRITY check only
///   (catches a corrupt download); it does NOT establish authenticity — any
///   internally-consistent bundle passes, and we re-sign ad-hoc anyway. Do not
///   relax the TLS/host pin believing codesign backstops it.
/// - The relauncher re-signs ad-hoc after install (moving a bundle + stripping
///   quarantine invalidates the seal, and an unsigned bundle is "damaged"), and
///   ROLLS BACK to the `.bak` copy if the re-sign, verify, or swap fails — the
///   backup is deleted only after the new bundle verifies. Never leave no app.
@MainActor
@Observable
final class UpdateService {

    struct Release: Equatable, Sendable {
        var version: String       // e.g. "0.1.2" (leading v stripped)
        var notes: String
        var releaseURL: URL
        var assetURL: URL
        var assetSize: Int64
        var sha256URL: URL?       // published "<asset>.sha256" sidecar, if any
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading(Double)  // 0…1
        case installing           // verifying the downloaded bundle
        case readyToInstall       // downloaded + verified; waiting for "Restart"
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var available: Release?
    /// The unpacked, verified new bundle waiting to be swapped in on Restart.
    @ObservationIgnored private var stagedApp: URL?

    nonisolated private static let owner = "robogears"
    nonisolated private static let repo = "VibeLight"

    /// Shared session for the updater's small control-plane fetches (the release
    /// JSON and the `.sha256` sidecar). `URLSession.shared` follows redirects
    /// blind; this one refuses any hop that leaves GitHub, matching the payload
    /// Downloader's per-hop re-validation so the class doc's "re-checked on every
    /// redirect" claim holds everywhere. (audit NET-checksum-fetch-no-redirect-revalidation)
    nonisolated private static let githubSession: URLSession = {
        URLSession(configuration: .ephemeral, delegate: GitHubRedirectGuard(), delegateQueue: nil)
    }()

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Where the new version gets installed. Update the running bundle in place
    /// when it's a normal writable location; when we're running from a
    /// read-only App-Translocation copy (the Gatekeeper quarantine dance) or a
    /// non-writable spot, install to /Applications — the canonical location —
    /// and relaunch from there instead.
    var installDestination: URL {
        let fm = FileManager.default
        let bundle = Bundle.main.bundleURL
        let translocated = bundle.path.contains("/AppTranslocation/")
        if !translocated, fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path) {
            return bundle
        }
        let applications = URL(fileURLWithPath: "/Applications/VibeLight.app")
        if fm.isWritableFile(atPath: "/Applications") { return applications }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/VibeLight.app")
    }

    /// We can self-install whenever the destination's parent directory is
    /// writable — which, thanks to the /Applications → ~/Applications fallback,
    /// is effectively always true for a real install (dev builds excepted).
    var canSelfInstall: Bool {
        #if DEBUG
        return false
        #else
        return FileManager.default.isWritableFile(atPath: installDestination.deletingLastPathComponent().path)
        #endif
    }

    // MARK: - Check

    /// Silent launch checks swallow errors (offline is normal); an explicit
    /// "Check for Updates" surfaces them.
    func check(silent: Bool) async {
        switch phase {
        case .downloading, .installing: return
        default: break
        }
        phase = .checking
        do {
            if let release = try await Self.fetchLatest(),
               Self.isNewer(release.version, than: currentVersion) {
                available = release
                phase = .available
            } else {
                available = nil
                phase = .upToDate
            }
        } catch {
            available = nil
            phase = silent ? .idle : .failed(Self.message(for: error))
        }
    }

    // MARK: - Download + install

    /// "Update Now": download + verify the new build, then stop at
    /// `.readyToInstall` so the user chooses when to restart.
    func downloadAndInstall() async {
        // Reentrancy guard: a double-fire must not start two downloads.
        switch phase {
        case .downloading, .installing, .readyToInstall: return
        default: break
        }
        guard let release = available else { return }
        // No self-install (dev build only, in practice): open the release page.
        guard canSelfInstall else {
            NSWorkspace.shared.open(release.releaseURL)
            return
        }
        phase = .downloading(0)
        do {
            let zipURL = try await Downloader.download(release.assetURL, expectedSize: release.assetSize) { [weak self] fraction in
                if case .downloading = self?.phase { self?.phase = .downloading(fraction) }
            }
            phase = .installing  // "verifying"
            try await Self.verifyChecksum(zipURL: zipURL, sha256URL: release.sha256URL)
            stagedApp = try Self.unpackAndValidate(zipURL: zipURL, expectedVersion: release.version)
            phase = .readyToInstall
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// "Restart Now": swap the staged bundle into place and relaunch it. The
    /// relauncher waits for us to exit first, so we quit right after handing off.
    func installStagedUpdate() {
        guard let newApp = stagedApp else { return }
        phase = .installing
        do {
            try Self.stageRelaunch(replacing: installDestination, with: newApp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.terminate(nil)
            }
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    func openReleasePage() {
        if let release = available { NSWorkspace.shared.open(release.releaseURL) }
    }

    // MARK: - GitHub API

    private static func fetchLatest() async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("VibeLight-Updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, response) = try await githubSession.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.network }
        if http.statusCode == 404 { return nil }  // no published (non-draft) release yet
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }
        return try parseRelease(data)
    }

    /// Pure parse — unit-tested against fixture JSON.
    nonisolated static func parseRelease(_ data: Data) throws -> Release {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]] else {
            throw UpdateError.malformed
        }
        // Require the arm64 asset BY NAME — VibeLight is Apple-Silicon-only and the
        // ship process always publishes "…-arm64.zip". A generic ".zip" fallback
        // could select a wrong-arch or mis-named (but TLS-valid) asset that still
        // passes identity/version/codesign checks. (audit QOL-any-zip-arch-fallback)
        let asset = assets.first { ($0["name"] as? String)?.contains("-arm64.zip") == true }
        guard let asset,
              let urlString = asset["browser_download_url"] as? String,
              let assetURL = validatedAssetURL(urlString) else {
            throw UpdateError.noAsset
        }
        let size = (asset["size"] as? Int64) ?? (asset["size"] as? Int).map(Int64.init) ?? 0
        let releaseURL = (obj["html_url"] as? String).flatMap(URL.init)
            ?? URL(string: "https://github.com/\(owner)/\(repo)/releases")!
        // Match the "<asset>.sha256" sidecar the ship process publishes next to
        // the zip (asset-name contract). Optional: older releases predate it.
        let sha256URL: URL? = (asset["name"] as? String).flatMap { name in
            assets.first { ($0["name"] as? String) == name + ".sha256" }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap { validatedAssetURL($0) }
        }
        return Release(
            version: normalize(tag),
            notes: (obj["body"] as? String) ?? "",
            releaseURL: releaseURL,
            assetURL: assetURL,
            assetSize: size,
            sha256URL: sha256URL
        )
    }

    /// Pin downloads to GitHub — refuse anything else even if the API is somehow
    /// tampered with. (Redirects to *.githubusercontent.com are followed by
    /// URLSession and are also GitHub-owned.)
    nonisolated static func validatedAssetURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https",
              let host = url.host?.lowercased(),
              host == "github.com" || host.hasSuffix(".githubusercontent.com") else { return nil }
        return url
    }

    // MARK: - Version compare (pure, tested)

    nonisolated static func normalize(_ tag: String) -> String {
        tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
    }

    /// Numeric left-to-right compare of dotted versions (missing segments = 0).
    /// Never string-compares ("10" < "9").
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            normalize(s).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Checksum verification

    /// Verifies the downloaded zip against its published `.sha256` sidecar before
    /// we trust it enough to unpack. This is an INTEGRITY check (catches a
    /// corrupted or truncated download) layered on the TLS-to-GitHub authenticity
    /// boundary — NOT a replacement for it. A missing or unreadable sidecar warns
    /// and proceeds (older releases predate the sidecar contract; the zip already
    /// arrived over pinned TLS) — the house "warn, don't block" pattern. Only a
    /// definitive hash MISMATCH hard-fails.
    private static func verifyChecksum(zipURL: URL, sha256URL: URL?) async throws {
        guard let sha256URL else {
            NSLog("[VibeLight] update: no .sha256 sidecar published; skipping checksum verification")
            return
        }
        let (data, response) = try await githubSession.data(from: sha256URL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8),
              let expected = sidecarExpectedHash(from: text) else {
            NSLog("[VibeLight] update: unreadable .sha256 sidecar; skipping checksum verification")
            return
        }
        let actual = try sha256Hex(ofFileAt: zipURL)
        guard actual == expected else {
            throw UpdateError.badPackage("The download's checksum didn't match the published value.")
        }
    }

    /// Pulls the 64-char lowercase hex digest out of a `shasum`-style sidecar
    /// (`<hash>  <filename>` or a bare hash). Pure + testable — the security-
    /// critical parse that decides whether the download is trusted.
    nonisolated static func sidecarExpectedHash(from text: String) -> String? {
        text.lowercased()
            .split(whereSeparator: { !$0.isHexDigit })
            .first(where: { $0.count == 64 })
            .map(String.init)
    }

    /// Streaming SHA-256 of a file (the update zip is tens of MB — never slurp it
    /// whole into memory just to hash it). Internal (not private) so the checksum
    /// path can be unit-tested against a known-hash fixture.
    nonisolated static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Unpack + validate

    private static func unpackAndValidate(zipURL: URL, expectedVersion: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("vibelight-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Clean up the extraction dir on any failure; on success ownership
        // passes to the relauncher (which deletes it after installing).
        var success = false
        defer { if !success { try? fm.removeItem(at: dir) } }
        // ditto extracts the sequestered-resource zip we produce at release time.
        try runTool("/usr/bin/ditto", ["-x", "-k", zipURL.path, dir.path])
        try? fm.removeItem(at: zipURL)

        let apps = (try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "app" }
        guard let app = apps.first(where: { $0.lastPathComponent == "VibeLight.app" }) ?? apps.first else {
            throw UpdateError.badPackage("The update didn't contain VibeLight.")
        }
        // Identity gate: it must actually be VibeLight and not older than promised.
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard (info?["CFBundleIdentifier"] as? String) == "com.vibelight.app" else {
            throw UpdateError.badPackage("The update has an unexpected identity.")
        }
        if let v = info?["CFBundleShortVersionString"] as? String,
           isNewer(expectedVersion, than: v) {
            throw UpdateError.badPackage("The downloaded build is older than expected.")
        }
        // Integrity ONLY — the ad-hoc seal must be internally consistent (catches
        // a corrupt download). This is NOT an authenticity check (see class doc).
        try runTool("/usr/bin/codesign", ["--verify", "--deep", app.path])
        success = true
        return app
    }

    // MARK: - Relaunch

    /// Writes a self-contained relauncher, launches it detached, and returns.
    /// Paths are passed as argv (never string-baked) so spaces/quotes are safe.
    private static func stageRelaunch(replacing dest: URL, with newApp: URL) throws {
        let script = """
        #!/bin/bash
        # VibeLight self-updater relauncher. Args: <old-pid> <new-app> <dest>.
        trap '' HUP TERM
        OLD_PID="$1"; NEW_APP="$2"; DEST="$3"
        LOGDIR="$HOME/Library/Logs/VibeLight"; mkdir -p "$LOGDIR"
        exec >> "$LOGDIR/update.log" 2>&1
        echo "=== $(date) update pid=$OLD_PID ==="
        cleanup() { rm -f "$0"; }
        # Wait (<=30s) for the running app to exit before touching its bundle.
        for i in $(seq 1 150); do kill -0 "$OLD_PID" 2>/dev/null || break; sleep 0.2; done
        # Still alive after the wait? Abort — never swap a live bundle out.
        if kill -0 "$OLD_PID" 2>/dev/null; then
          echo "app did not exit; aborting"; open "$DEST"; cleanup; exit 1
        fi
        mkdir -p "$(dirname "$DEST")"
        # Back up an existing install; a fresh install to /Applications has none.
        BAK=""
        if [ -e "$DEST" ]; then
          BAK="${DEST}.bak"; rm -rf "$BAK"
          if ! mv "$DEST" "$BAK"; then echo "backup failed"; open "$DEST"; cleanup; exit 1; fi
        fi
        rollback() {
          echo "rolling back"; rm -rf "$DEST"
          if [ -n "$BAK" ]; then mv "$BAK" "$DEST"; open "$DEST"; fi
          cleanup; exit 1
        }
        # Copy the new bundle in.
        if ! ditto "$NEW_APP" "$DEST"; then echo "ditto failed"; rollback; fi
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
        # Re-sign is MANDATORY (moving + de-quarantining invalidated the seal).
        # If it — or the verify — fails, roll back; the backup still exists.
        if ! codesign --force --deep --sign - "$DEST"; then echo "re-sign failed"; rollback; fi
        if ! codesign --verify --strict "$DEST"; then echo "verify failed"; rollback; fi
        # Verified good: only now is it safe to drop the backup + source.
        [ -n "$BAK" ] && rm -rf "$BAK"
        rm -rf "$NEW_APP"
        echo "installed; relaunching"
        open "$DEST" || { sleep 1; open "$DEST"; }
        cleanup
        """
        let fm = FileManager.default
        let scriptURL = fm.temporaryDirectory.appendingPathComponent("vibelight-relaunch-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            scriptURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            newApp.path,
            dest.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()  // orphaned to launchd when we quit; trap keeps it alive
    }

    // MARK: - Helpers

    @discardableResult
    private static func runTool(_ path: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw UpdateError.tool("\(URL(fileURLWithPath: path).lastPathComponent) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }

    static func message(for error: any Error) -> String {
        if let e = error as? UpdateError { return e.message }
        return (error as NSError).localizedDescription
    }
}

enum UpdateError: Error {
    case network
    case http(Int)
    case malformed
    case noAsset
    case badPackage(String)
    case tool(String)

    var message: String {
        switch self {
        case .network: "Couldn't reach the update server."
        case .http(let code): "The update server returned an error (\(code))."
        case .malformed: "The update response couldn't be read."
        case .noAsset: "The latest release has no macOS download."
        case .badPackage(let why): "The update couldn't be verified: \(why)"
        case .tool(let why): "Update failed: \(why)"
        }
    }
}

/// Refuses any redirect hop that leaves GitHub, for the updater's small
/// control-plane fetches (release JSON + `.sha256` sidecar). Stateless.
private final class GitHubRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let host = request.url?.host?.lowercased(),
           host == "github.com" || host == "api.github.com"
             || host.hasSuffix(".github.com") || host.hasSuffix(".githubusercontent.com") {
            completionHandler(request)
        } else {
            completionHandler(nil)   // cancel — refuse an off-GitHub redirect
        }
    }
}

/// Streams a download to a temp file, reporting progress. Follows GitHub's
/// redirect to the CDN automatically.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: @Sendable (Double) -> Void
    private let byteCap: Int64
    private var movedFile: URL?

    private init(expectedSize: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
        // Hard ceiling so a tampered/oversized asset can't fill the disk:
        // 10% over the advertised size, or 500 MB, whichever is larger — but
        // never more than 2 GB, so a hostile advertised size (on the same channel
        // as the payload) can't inflate the cap itself. (SEV-11)
        self.byteCap = min(max(Int64(Double(expectedSize) * 1.1), 500_000_000), 2_000_000_000)
        self.onProgress = onProgress
    }

    static func download(_ url: URL, expectedSize: Int64,
                         onProgress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let delegate = Downloader(expectedSize: expectedSize, onProgress: { fraction in
            Task { @MainActor in onProgress(fraction) }
        })
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 300  // a stalled transfer fails, not hangs
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            var request = URLRequest(url: url)
            request.setValue("VibeLight-Updater", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
        }
    }

    /// Re-validate the host on EVERY redirect hop — the initial pin alone would
    /// let a github.com URL bounce off-host.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url, UpdateService.validatedAssetURL(url.absoluteString) != nil {
            completionHandler(request)
        } else {
            completionHandler(nil)  // cancel — refuse an off-GitHub redirect
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > byteCap {
            downloadTask.cancel()  // surfaces as an error via didCompleteWithError
            return
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is deleted right after this returns — move it now.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibelight-update-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            movedFile = dest
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
        } else if let movedFile {
            continuation?.resume(returning: movedFile)
        } else {
            continuation?.resume(throwing: UpdateError.network)
        }
        continuation = nil
    }
}
#else
import Foundation
import Observation

/// iOS stub: a bundle can't self-install on iOS (no writable app bundle, no
/// `open`, no `codesign`). Updates ship out-of-band (sideload / AltStore). The
/// public surface matches macOS so the shared `AppState`/`UpdateCard` compile
/// unchanged; every action is inert and `phase` stays `.upToDate`.
@MainActor
@Observable
final class UpdateService {
    struct Release: Equatable, Sendable {
        var version: String
        var notes: String
    }

    enum Phase: Equatable {
        case idle, checking, upToDate, available
        case downloading(Double), installing, readyToInstall
        case failed(String)
    }

    private(set) var phase: Phase = .upToDate
    private(set) var available: Release?
    let canSelfInstall = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func check(silent: Bool) async { phase = .upToDate }
    func downloadAndInstall() async {}
    func installStagedUpdate() {}
    func openReleasePage() {}
}
#endif
