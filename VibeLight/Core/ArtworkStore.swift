import CryptoKit
import Foundation
import ImageIO

/// Box-art pipeline: alias routing → disk cache → gated `/appasset` fetch →
/// placeholder detection. See docs/research/artwork.md.
///
/// This is an actor (not a @MainActor class) because everything heavy here —
/// SHA-256 hashing, ImageIO header parsing, synchronous file I/O — belongs off
/// the main thread, and the coalescing/gating state needs isolation anyway.
/// Nothing in this type touches AppKit.
///
/// Offline behavior (`address == nil`): aliased utility apps get their bespoke
/// tile as always (they never need the network); apps with cached art get the
/// cached file (background revalidation is skipped — there is nothing to
/// revalidate against); everything else resolves to `.bespoke(.generic)`.
/// `.pending` is deliberately never returned by this implementation: it means
/// "a fetch is in flight, a better answer is coming", and with no address no
/// fetch will ever start, so a pending tile would spin forever. When the host
/// wakes, the UI re-requests with a real address and tiles upgrade naturally.
actor ArtworkStore: ArtworkProviding {

    // MARK: - Constants

    /// sha256 of the stock `box.png` the host serves — with 200 OK! — when an
    /// app has no configured artwork. The host lies; we hash-detect the lie.
    private static let placeholderSHA256 =
        "d9164ebd069b5f735eb8efc557801778498da37f572ef70e3d35604739e6c613"

    /// The stock placeholder's exact dimensions (every real stock asset is
    /// 600×800+). Checked as a backstop in case a host build ever re-encodes
    /// box.png — new bytes, same image, hash check alone would miss it.
    private static let placeholderWidth = 130
    private static let placeholderHeight = 180

    /// moonlight-qt caps box-art fetches at 4 concurrent to avoid crushing
    /// the host (its BoxArtManager thread pool); we inherit that number.
    private static let maxConcurrentFetches = 4

    // MARK: - State

    /// Cache identity: prefer the Vibepollo/Apollo UUID (stable across
    /// artwork changes) over the numeric ID (CRC32 of name+image on legacy
    /// hosts, so it churns when the image does — which self-invalidates).
    private struct Key: Hashable, Sendable {
        let hostID: String
        let appKey: String

        init(host: StreamHost, app: StreamApp) {
            hostID = host.id
            appKey = app.uuid ?? String(app.id)
        }
    }

    private let api: any HostAPIProviding

    /// Cached files older than this are served instantly but refetched in the
    /// background: Vibepollo can swap art under a stable appid (Playnite
    /// cover sync), and `/appasset` ships zero HTTP cache validators.
    private let revalidationInterval: TimeInterval

    /// After a fetch error, don't re-hit the host for this app until the
    /// backoff elapses — the UI re-requests tiles on every scroll pass.
    private let failureBackoff: TimeInterval

    /// Duplicate-request coalescing: N visible tiles for one app share one fetch.
    private var inFlight: [Key: Task<TileArtwork, Never>] = [:]
    /// Identity tokens for in-flight fetches so late completions of cancelled
    /// tasks can't evict their replacement's entry (see clearInFlight).
    private var inFlightTokens: [Key: UUID] = [:]

    /// Removes the coalescing entry only if it still belongs to the finishing
    /// task — identified by token, since Task itself isn't Equatable.
    private func clearInFlight(key: Key, ifToken token: UUID) {
        guard inFlightTokens[key] == token else { return }
        inFlight[key] = nil
        inFlightTokens[key] = nil
    }

    /// Apps the host said "no art" about (placeholder detected), with when we
    /// learned it. In-memory only: placeholders are never written to disk as
    /// art, and this map is what stops a refetch on every scroll. Entries
    /// expire after `revalidationInterval` because art can *appear* later
    /// under the same appid.
    private var knownPlaceholders: [Key: Date] = [:]

    private var recentFailures: [Key: Date] = [:]

    /// Keys with a background revalidation already running (dedupe guard).
    private var revalidating: Set<Key> = []

    /// Counting-semaphore state for the 4-fetch gate. Implemented with
    /// continuations inside the actor rather than DispatchSemaphore, which
    /// would block a cooperative-pool thread.
    private var activeFetchCount = 0
    private var fetchWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        api: any HostAPIProviding,
        revalidationInterval: TimeInterval = 24 * 60 * 60,
        failureBackoff: TimeInterval = 5 * 60
    ) {
        self.api = api
        self.revalidationInterval = revalidationInterval
        self.failureBackoff = failureBackoff
    }

    // MARK: - ArtworkProviding

    func artwork(for app: StreamApp, host: StreamHost, address: String?) async -> TileArtwork {
        // Alias table runs BEFORE any cache or network work: known utility
        // apps ship generic stock art (desktop.png, steam.png, …) or none at
        // all, and hand-designed tiles beat both. They never hit the network.
        if let tile = Self.aliasedTile(for: app) {
            return .bespoke(tile)
        }

        let key = Key(host: host, app: app)
        let fileURL = Self.cacheFileURL(for: key)

        // Known placeholder: skip the network until the memory expires
        // (art can be added host-side under the same appid).
        if let seenAt = knownPlaceholders[key] {
            if Date().timeIntervalSince(seenAt) < revalidationInterval {
                return .bespoke(.generic)
            }
            knownPlaceholders[key] = nil
        }

        if let cachedAt = Self.modificationDate(of: fileURL) {
            // Serve cached art instantly — tiles must never block on the
            // network — and refresh stale files behind the user's back.
            if let address, Date().timeIntervalSince(cachedAt) > revalidationInterval {
                scheduleRevalidation(app: app, host: host, address: address, key: key, fileURL: fileURL)
            }
            return .image(fileURL)
        }

        guard let address else {
            // Host offline, nothing cached: see the type-level doc comment.
            return .bespoke(.generic)
        }

        if let failedAt = recentFailures[key], Date().timeIntervalSince(failedAt) < failureBackoff {
            return .bespoke(.generic)
        }

        if let existing = inFlight[key] {
            return await existing.value
        }
        let token = UUID()
        let fetch = Task {
            let result = await self.performFetch(app: app, host: host, address: address, key: key, fileURL: fileURL)
            // Identity-guarded removal: a cancelled stale fetch finishing late
            // (after invalidate() started a fresh one) must not evict the
            // NEWER task's coalescing entry.
            self.clearInFlight(key: key, ifToken: token)
            return result
        }
        inFlight[key] = fetch
        inFlightTokens[key] = token
        return await fetch.value
    }

    // MARK: - Manual refresh

    /// Drops everything known about a host's artwork: in-flight fetches,
    /// placeholder/failure memory, and the on-disk cache directory. The next
    /// tile request refetches from scratch — the manual-refresh primitive
    /// (and the cleanup hook for when a host is deleted).
    func invalidate(hostUUID: String) {
        for (key, task) in inFlight where key.hostID == hostUUID {
            task.cancel()
            inFlight[key] = nil
            inFlightTokens[key] = nil
        }
        knownPlaceholders = knownPlaceholders.filter { $0.key.hostID != hostUUID }
        recentFailures = recentFailures.filter { $0.key.hostID != hostUUID }
        revalidating = revalidating.filter { $0.hostID != hostUUID }
        // Route the host ID through the SAME traversal guard the write path
        // uses (cacheFileURL, safeComponent): host.id comes from the host, so a
        // hostile "../../.." value would otherwise escape the boxart cache and
        // recursively delete an attacker-chosen directory.
        try? FileManager.default.removeItem(
            at: Self.cacheRootURL().appendingPathComponent(Self.safeComponent(hostUUID), isDirectory: true))
    }

    // MARK: - Alias table

    /// Maps known utility/launcher apps to designed tiles, matched on the
    /// zero-width-stripped, lowercased name. Prefix rules cover Vibepollo's
    /// dynamic "Terminate <app>" entries and Playnite mode variants like
    /// "Playnite (Fullscreen)".
    nonisolated static func aliasedTile(for app: StreamApp) -> TileArtwork.BespokeTile? {
        // StreamApp.name already strips zero-width ordering prefixes and trims.
        let name = app.name.lowercased()
        switch name {
        case "desktop", "virtual desktop": return .desktop
        case "steam", "steam big picture": return .steam
        case "moondeckstream": return .moonDeck
        case "virtual display": return .virtualDisplay
        case "input only", "terminate": return .generic
        default: break
        }
        if name.hasPrefix("playnite") { return .playnite }
        if name.hasPrefix("terminate ") { return .generic }
        return nil
    }

    // MARK: - Fetch pipeline

    private func performFetch(
        app: StreamApp, host: StreamHost, address: String, key: Key, fileURL: URL
    ) async -> TileArtwork {
        await acquireFetchSlot()
        defer { releaseFetchSlot() }

        let data: Data
        do {
            data = try await api.appAsset(for: host, at: address, appID: app.id)
        } catch {
            // Cancellation means invalidate() raced us — don't poison the
            // freshly cleared failure memory.
            if !Task.isCancelled {
                recentFailures[key] = Date()
            }
            return fallback(for: fileURL)
        }
        guard !Task.isCancelled else { return fallback(for: fileURL) }
        recentFailures[key] = nil

        if Self.isPlaceholder(data) {
            // NEVER cache the placeholder as art; remember it in-memory and
            // drop any previously cached real art (revalidation path — the
            // host-side image was removed).
            knownPlaceholders[key] = Date()
            try? FileManager.default.removeItem(at: fileURL)
            return .bespoke(.generic)
        }

        // Undecodable bytes (truncated transfer, host bug): treat as a
        // transient failure rather than caching garbage the UI can't render.
        guard Self.pixelSize(of: data) != nil else {
            recentFailures[key] = Date()
            return fallback(for: fileURL)
        }

        do {
            try Self.write(data, to: fileURL)
            return .image(fileURL)
        } catch {
            // Disk write failed (full volume, Caches purge race). The art
            // exists but .image needs a file URL — degrade gracefully.
            recentFailures[key] = Date()
            return .bespoke(.generic)
        }
    }

    /// What to show when a fetch can't produce fresh art: keep any cached
    /// file (stale beats blank), else the generic bespoke tile.
    private func fallback(for fileURL: URL) -> TileArtwork {
        Self.modificationDate(of: fileURL) != nil ? .image(fileURL) : .bespoke(.generic)
    }

    /// Kicks off a background refetch of a stale cached file. The caller has
    /// already been served the cached art; this only affects future requests
    /// (overwrite on change, delete + placeholder-memo on art removal).
    private func scheduleRevalidation(
        app: StreamApp, host: StreamHost, address: String, key: Key, fileURL: URL
    ) {
        guard !revalidating.contains(key), inFlight[key] == nil else { return }
        if let failedAt = recentFailures[key], Date().timeIntervalSince(failedAt) < failureBackoff {
            return
        }
        revalidating.insert(key)
        Task {
            _ = await self.performFetch(app: app, host: host, address: address, key: key, fileURL: fileURL)
            self.revalidating.remove(key)
        }
    }

    // MARK: - Fetch gate (max 4 in flight)

    private func acquireFetchSlot() async {
        if activeFetchCount < Self.maxConcurrentFetches {
            activeFetchCount += 1
            return
        }
        await withCheckedContinuation { fetchWaiters.append($0) }
    }

    private func releaseFetchSlot() {
        if fetchWaiters.isEmpty {
            activeFetchCount -= 1
        } else {
            // Hand the slot directly to the next waiter; the count stays.
            fetchWaiters.removeFirst().resume()
        }
    }

    // MARK: - Placeholder detection

    private nonisolated static func isPlaceholder(_ data: Data) -> Bool {
        if sha256Hex(of: data) == placeholderSHA256 { return true }
        if let size = pixelSize(of: data),
           size.width == placeholderWidth, size.height == placeholderHeight {
            return true
        }
        return false
    }

    private nonisolated static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads pixel dimensions from the image header via ImageIO. NSImage is
    /// deliberately avoided: it's AppKit and has no business on this actor's
    /// cooperative-pool threads; CGImageSource parses the header without
    /// decoding pixels.
    private nonisolated static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    // MARK: - Disk layout

    /// ~/Library/Caches/<bundleID>/boxart/ — Caches because every byte here
    /// is regenerable from the host; the system may purge it at will. The
    /// bundle-ID fallback only matters outside a bundled app (unit tests).
    private nonisolated static func cacheRootURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.vibelight.app"
        return caches
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("boxart", isDirectory: true)
    }

    private nonisolated static func cacheFileURL(for key: Key) -> URL {
        cacheRootURL()
            .appendingPathComponent(Self.safeComponent(key.hostID), isDirectory: true)
            .appendingPathComponent(Self.safeComponent(key.appKey) + ".png", isDirectory: false)
    }

    /// hostID and appKey come from the host (host.id, app.uuid from /applist XML)
    /// and are used as filesystem path components. A hostile value like
    /// "../../../../tmp/evil" would escape the cache dir and let a malicious host
    /// write/delete/read arbitrary .png files. Only a strict token is used
    /// verbatim; anything else (contains "/" "\\", is "." / "..", non-ASCII, or
    /// over-long) is replaced with a deterministic SHA-256 hash — stable for
    /// caching, and guaranteed to contain no path separators.
    ///
    /// `internal` (not `private`) only so the traversal guard can be unit-tested.
    nonisolated static func safeComponent(_ raw: String) -> String {
        let isSafe = !raw.isEmpty && raw.count <= 128
            && raw != "." && raw != ".."
            && raw.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
        if isSafe { return raw }
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private nonisolated static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
