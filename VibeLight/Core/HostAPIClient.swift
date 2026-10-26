import Foundation
import Security
import os

/// GameStream protocol client for Sunshine-family hosts (Vibepollo).
///
/// All calls go to HTTPS <base port − 5> (47984 for the default 47989) with
/// mTLS using VibeLight's own client certificate, paired in-app. There
/// is no token/cookie/header auth: possession of the certificate IS the
/// authorization. Crucially, a rejected certificate still completes the TLS
/// handshake — the server answers every request with XML
/// `<root status_code="401">` instead of aborting the connection. Every parse
/// therefore starts from the `status_code` attribute, never the HTTP status
/// line or TLS success alone.
final class HostAPIClient: HostAPIProviding, @unchecked Sendable {
    // @unchecked: mutable state is only the per-host session cache, guarded
    // by `lock`; everything else is immutable and Sendable.

    private let identityProvider: ClientIdentityProvider
    private let logger = Logger(subsystem: "com.vibelight.VibeLight", category: "HostAPIClient")

    /// Sent as `uniqueid` on every request. Sunshine never authorizes by it,
    /// but its *presence* is what flips `PairStatus` to 1 in /serverinfo, so
    /// it must always be there — and stable, so the host's client bookkeeping
    /// sees one device instead of many.
    private let uniqueID: String

    /// One URLSession per host: the pinned server cert differs per host and
    /// URLSession delegates are fixed at creation. Keyed by host UUID; the
    /// entry is rebuilt if the pinned cert changes (re-pair).
    private var sessions: [String: SessionEntry] = [:]
    private let lock = NSLock()

    private struct SessionEntry {
        let pinnedCertDER: Data?
        let session: URLSession
    }

    /// Whether the cached session for this host is currently pinned. Test seam
    /// for the stale-snapshot guard in `session(for:)` — the security property
    /// is "a pinned session is never replaced by an unpinned one", and that is
    /// only checkable from outside if the pin state is observable.
    func isSessionPinned(hostID: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = sessions[hostID] else { return nil }
        return entry.pinnedCertDER != nil
    }

    /// Builds (or returns) this host's session without issuing a request — the
    /// other half of the test seam above, so the pin-durability property can be
    /// exercised without a live host.
    @discardableResult
    func warmSession(for host: StreamHost) throws -> URLSession {
        try session(for: host)
    }

    /// `uniqueID` is supplied by the caller — the same value `IdentityStore`
    /// already owns and `HostPairing` already receives. It used to be
    /// regenerated here from a SECOND reader of the same UserDefaults key with a
    /// stricter validity rule (exactly 16 characters), so a value IdentityStore
    /// happily accepted was silently overwritten by this class, changing the id
    /// the host uses for its per-client bookkeeping mid-life.
    init(identityProvider: ClientIdentityProvider, uniqueID: String? = nil) {
        self.identityProvider = identityProvider
        self.uniqueID = uniqueID ?? IdentityStore.uniqueID()
    }

    // MARK: - HostAPIProviding

    func serverInfo(for host: StreamHost) async throws -> (info: ServerInfo, address: String) {
        let candidates = host.candidateAddresses
        guard !candidates.isEmpty else { throw HostAPIError.unreachable(host.name) }
        let session = try session(for: host)

        var sawPinRejection = false
        // A timeout means the host ACCEPTED our connection and then went silent —
        // a stuck service, not a sleeping PC. Tracked separately so the UI can say
        // so instead of lying with "asleep" (and offering a pointless wake).
        var sawTimeout = false
        let delegate = session.delegate as? MTLSDelegate
        for candidate in candidates {
            let data: Data
            let pinRejectionsBefore = delegate?.pinRejectionCount ?? 0
            do {
                let request = try makeRequest(
                    address: candidate.host, port: candidate.port - httpsPortOffset, path: "/serverinfo")
                data = try await boundedData(session, request).0
            } catch {
                // Per-ADDRESS failures advance to the next candidate; verdicts
                // ABOUT THE HOST do not. This clause used to catch only
                // URLError, so a malformed address (makeRequest throws
                // .unreachable) abandoned the remaining candidates — but
                // widening it naively is worse, because it also swallows the
                // byte-cap rejection, which means the host DID answer and is a
                // definitive answer about it.
                if Task.isCancelled { throw CancellationError() }
                if let apiError = error as? HostAPIError {
                    switch apiError {
                    case .unreachable:
                        // This address is no good; try the next one.
                        logger.debug("serverinfo via \(candidate.host, privacy: .public) failed: \(apiError.localizedDescription, privacy: .public)")
                        continue
                    default:
                        // .malformedResponse (over-cap body, unusable session)
                        // and friends are about the host, not the route.
                        throw apiError
                    }
                }
                guard let error = error as? URLError else {
                    logger.debug("serverinfo via \(candidate.host, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    continue
                }
                // Ask the delegate whether IT rejected the handshake on the
                // pin, rather than reading that into URLError.cancelled — which
                // also covers a session invalidated mid-request and other
                // internal cancellations, and turned those into a spurious
                // "certificate changed — pair it again".
                if let delegate, delegate.pinRejectionCount > pinRejectionsBefore {
                    sawPinRejection = true
                }
                // .timedOut = the socket opened but no reply arrived. Anything
                // else (cannotConnectToHost, cannotFindHost, notConnectedToInternet)
                // is a genuine "nothing there", i.e. asleep/offline/wrong network.
                if error.code == .timedOut { sawTimeout = true }
                // Network-level failure: this address may just be the wrong
                // network (LAN address while on VPN, or host asleep). Next.
                logger.debug("serverinfo via \(candidate.host, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
            // The host answered — any XML error (401 unpaired, etc.) is a
            // definitive verdict, not an address problem: stop iterating.
            let root = try Self.verifiedRoot(in: data, context: "serverinfo")
            return (Self.parseServerInfo(from: root), candidate.host)
        }
        // Pin rejection != unpaired: the host answered with a cert that isn't the
        // one we pinned, which is a different situation (and a different remedy)
        // from our own cert being absent from its paired pool.
        if sawPinRejection { throw HostAPIError.hostIdentityChanged(host.name) }
        // Order matters: a pin rejection is the more actionable verdict, but a
        // timeout beats "unreachable" — the host demonstrably answered at the
        // socket level, so calling it offline would send the user to Wake-on-LAN
        // for a machine that is already on.
        if sawTimeout { throw HostAPIError.notResponding(host.name) }
        throw HostAPIError.unreachable(host.name)
    }

    func appList(for host: StreamHost, at address: String) async throws -> [StreamApp] {
        let root = try await xmlRoot(for: host, at: address, path: "/applist", context: "applist")
        var apps: [StreamApp] = []
        for node in root.children where node.name == "App" {
            guard let id = node.child("ID").flatMap({ Int($0.text.trimmed) }) else { continue }
            apps.append(StreamApp(
                id: id,
                // VERBATIM, including zero-width ordering prefixes and empty
                // <AppTitle/> — the launch CLI needs the exact padded string,
                // and pad width shifts whenever the app count crosses a power
                // of two. Display-stripping happens in StreamApp.name.
                rawName: node.child("AppTitle")?.text ?? "",
                uuid: node.child("UUID").map(\.text.trimmed).flatMap { $0.isEmpty ? nil : $0 },
                idx: node.child("IDX").flatMap { Int($0.text.trimmed) },
                isHDRSupported: node.child("IsHdrSupported")?.text.trimmed == "1",
                isHidden: false
            ))
        }
        // No filtering here: pseudo-apps (permission-denied placeholder,
        // Terminate entries) are the integrator's concern.
        return apps
    }

    func appAsset(for host: StreamHost, at address: String, appID: Int) async throws -> Data {
        let session = try session(for: host)
        let request = try makeRequest(
            address: address, port: httpsPort(for: host, at: address), path: "/appasset",
            extraQuery: [
                URLQueryItem(name: "appid", value: String(appID)),
                URLQueryItem(name: "AssetType", value: "2"),
                URLQueryItem(name: "AssetIdx", value: "0"),
            ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await boundedData(session, request)
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            // A timeout means the host took our request and went silent — it may
            // well have ACTED on it (a /launch that times out still starts the
            // session). Saying "unreachable" there sends the user to Wake-on-LAN
            // for a machine that is very much awake.
            if error.code == .timedOut { throw HostAPIError.notResponding(host.name) }
            throw HostAPIError.unreachable(host.name)
        }

        // Success is raw PNG, but errors still arrive as XML — sniff before
        // handing bytes to an image decoder.
        if data.first == UInt8(ascii: "<") {
            _ = try Self.verifiedRoot(in: data, context: "appasset")
            throw HostAPIError.malformedResponse("appasset returned XML instead of image data")
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw HostAPIError.malformedResponse("appasset returned HTTP \(http.statusCode)")
        }
        return data
    }

    func cancel(for host: StreamHost, at address: String) async throws {
        let root = try await xmlRoot(for: host, at: address, path: "/cancel", context: "cancel")
        // Sunshine always sends <cancel>1</cancel> alongside status 200, but
        // treat an explicit 0 as failure if a host ever produces one.
        if let cancelled = root.child("cancel")?.text.trimmed, cancelled != "1" {
            throw HostAPIError.malformedResponse("cancel reported failure (<cancel>\(cancelled)</cancel>)")
        }
    }

    /// Starts a game on the host over mTLS 47984 and returns its RTSP session URL
    /// (`<sessionUrl0>`) for `LiStartConnection`. `rikeyHex`/`rikeyId` are the
    /// remote-input AES key/iv the caller also feeds to the stream engine;
    /// `extraLaunchParams` is moonlight-common-c's `LiGetLaunchUrlQueryParameters`
    /// output appended verbatim. Query shape mirrors moonlight-qt's launchApp().
    func launch(app: StreamApp, on host: StreamHost, at address: String, settings: StreamSettings,
                rikeyHex: String, rikeyId: Int, extraLaunchParams: String) async throws -> String? {
        try await launchOrResume(path: "/launch", app: app, on: host, at: address, settings: settings,
                                 rikeyHex: rikeyHex, rikeyId: rikeyId, extraLaunchParams: extraLaunchParams)
    }

    /// `/resume` — required (not optional) when the host is already streaming
    /// this app: Sunshine rejects `/launch` while any session is active. Same
    /// query contract as `/launch` (Limelight.h mandates the
    /// LiGetLaunchUrlQueryParameters fragment on both).
    func resume(app: StreamApp, on host: StreamHost, at address: String, settings: StreamSettings,
                rikeyHex: String, rikeyId: Int, extraLaunchParams: String) async throws -> String? {
        try await launchOrResume(path: "/resume", app: app, on: host, at: address, settings: settings,
                                 rikeyHex: rikeyHex, rikeyId: rikeyId, extraLaunchParams: extraLaunchParams)
    }

    private func launchOrResume(path: String, app: StreamApp, on host: StreamHost, at address: String,
                                settings: StreamSettings, rikeyHex: String, rikeyId: Int,
                                extraLaunchParams: String) async throws -> String? {
        // surroundAudioInfo = channelCount | (channelMask << 16); stereo = 2 | (0x3<<16).
        let surround = 2 | (0x3 << 16)
        var items = [
            URLQueryItem(name: "appid", value: String(app.id)),
            URLQueryItem(name: "mode", value: "\(settings.width)x\(settings.height)x\(settings.fps)"),
            URLQueryItem(name: "additionalStates", value: "1"),
            URLQueryItem(name: "sops", value: settings.gameOptimizations ? "1" : "0"),
            URLQueryItem(name: "rikey", value: rikeyHex),
            URLQueryItem(name: "rikeyid", value: String(rikeyId)),
            URLQueryItem(name: "localAudioPlayMode", value: settings.muteHostSpeakers ? "0" : "1"),
            URLQueryItem(name: "surroundAudioInfo", value: String(surround)),
            URLQueryItem(name: "remoteControllersBitmap", value: "1"),
            URLQueryItem(name: "gcmap", value: "1"),
            URLQueryItem(name: "gcpersist", value: "0"),
        ]
        if settings.hdr {
            items.append(URLQueryItem(name: "hdrMode", value: "1"))
            items.append(URLQueryItem(name: "clientHdrCapVersion", value: "0"))
        }
        var request = try makeRequest(
            address: address, port: httpsPort(for: host, at: address), path: path, extraQuery: items,
            timeout: Self.launchTimeout)
        // LiGetLaunchUrlQueryParameters() is a raw pre-formed query fragment.
        // Merge it into the URL's percent-encoded query via URLComponents (same
        // encoding path as every other query item) rather than concatenating
        // onto the absolute string — string surgery + URL(string:) would null
        // the request URL on any parse hiccup. On failure keep the original URL.
        if !extraLaunchParams.isEmpty, let url = request.url,
           var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let existing = comps.percentEncodedQuery ?? ""
            comps.percentEncodedQuery = existing.isEmpty ? extraLaunchParams
                                                         : existing + "&" + extraLaunchParams
            if let merged = comps.url { request.url = merged }
        }
        let session = try session(for: host)
        let data: Data
        do {
            data = try await boundedData(session, request).0
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            // A timeout means the host took our request and went silent — it may
            // well have ACTED on it (a /launch that times out still starts the
            // session). Saying "unreachable" there sends the user to Wake-on-LAN
            // for a machine that is very much awake.
            if error.code == .timedOut { throw HostAPIError.notResponding(host.name) }
            throw HostAPIError.unreachable(host.name)
        }
        let root = try Self.verifiedRoot(in: data, context: path)   // throws on status_code != 200
        return root.child("sessionUrl0")?.text.trimmed
    }

    // MARK: - Request plumbing

    /// Sunshine-family port map: HTTPS API sits at base − 5 (47989 → 47984).
    private let httpsPortOffset = 5

    /// The `at address:` contract carries only the host string (it comes from
    /// a prior serverInfo call), so recover the matching stored port here.
    private func httpsPort(for host: StreamHost, at address: String) -> Int {
        if let match = host.candidateAddresses.first(where: { $0.host == address }) {
            return match.port - httpsPortOffset
        }
        return 47989 - httpsPortOffset
    }

    /// Hard byte ceiling for a host response. A MITM'd or compromised host
    /// could otherwise stream unbounded bytes into memory (and the box-art path
    /// writes them to disk) — the 5 s timeout is per-chunk, so a slow trickle
    /// never trips it. Mirrors the updater's byteCap. XML replies are a few KB
    /// and box art well under a megabyte; 16 MB is far above any legit response.
    private static let responseByteCap = 16 * 1024 * 1024

    /// Byte-capped replacement for `session.data(for:)`, enforced *during* the
    /// transfer: the delegate checks the cap on the declared Content-Length and
    /// on every received chunk, cancelling the task the moment it's exceeded.
    /// Both simpler shapes had a hole — `data(for:)` + a post-hoc size check
    /// buffers a lying/omitted-length body whole (hundreds of MB in memory),
    /// and a per-byte `bytes(for:)` drain was ~an order of magnitude slower on
    /// the box-art path. Chunk granularity keeps the buffered read's speed
    /// while actually bounding memory.
    private func boundedData(_ session: URLSession, _ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let delegate = session.delegate as? MTLSDelegate else {
            // Unreachable: session(for:) installs an MTLSDelegate on every
            // session this class builds. Fail closed rather than fall back to
            // a read that buffers the whole body before checking the cap.
            throw HostAPIError.malformedResponse("internal error: session has no MTLSDelegate")
        }
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                delegate.begin(task: task, cap: Self.responseByteCap, continuation: continuation)
                // resume() BEFORE handing the task to the holder. A task
                // cancelled while still suspended is not guaranteed to deliver
                // didCompleteWithError, and that delegate callback is the only
                // thing that resumes the continuation — so cancelling an
                // un-resumed task could hang this await forever. Starting it
                // first means every cancel lands on a running task, which always
                // completes. `begin` precedes both so no callback can arrive
                // before its continuation is registered.
                task.resume()
                holder.store(task)
            }
        } onCancel: {
            // Swift-level cancellation (the caller's Task went away) must tear
            // the transfer down too, not merely stop awaiting it — otherwise the
            // download keeps running and keeps filling the buffer.
            holder.cancel()
        }
    }

    /// Bridges Swift task cancellation to a URLSessionTask that may not exist
    /// yet at the moment cancellation arrives.
    private final class TaskHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false

        func store(_ task: URLSessionTask) {
            lock.lock()
            let alreadyCancelled = cancelled
            self.task = task
            lock.unlock()
            // Cancellation beat us to it. boundedData calls resume() before
            // store, so this cancel lands on a running task and
            // didCompleteWithError resolves the await — the same guarantee
            // cancel() below relies on. The catch sites normalize the resulting
            // URLError.cancelled into CancellationError via Task.isCancelled,
            // which is true here by construction.
            if alreadyCancelled { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    /// Cheap, read-only endpoints (serverinfo, applist, appasset, cancel) answer
    /// in milliseconds on a healthy host — a short timeout keeps the UI snappy.
    static let quickTimeout: TimeInterval = 5
    /// `/launch` and `/resume` are NOT cheap: the host spins up an encoder and,
    /// on a virtual-display setup, creates/switches a display mode before it
    /// replies. 5 s is short enough that a normal-but-slow start looks like a
    /// failure — and worse, the host proceeds anyway, leaving a session running
    /// that the client already gave up on. Give them real room.
    static let launchTimeout: TimeInterval = 20

    private func makeRequest(
        address: String, port: Int, path: String, extraQuery: [URLQueryItem] = [],
        timeout: TimeInterval = HostAPIClient.quickTimeout
    ) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = address
        components.port = port
        components.path = path
        // uniqueid: stable (PairStatus depends on it). uuid: fresh per request
        // — moonlight-qt sends it as a cache-buster and some proxies key on it.
        components.queryItems = [
            URLQueryItem(name: "uniqueid", value: uniqueID),
            URLQueryItem(name: "uuid", value: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()),
        ] + extraQuery
        guard let url = components.url else {
            throw HostAPIError.unreachable(address)
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        // The server closes after every response (close_connection_after_response);
        // announce it so URLSession doesn't try to reuse the connection.
        request.setValue("close", forHTTPHeaderField: "Connection")
        return request
    }

    /// GET an XML endpoint at a known-good address and return the verified
    /// `<root>` (status_code already checked).
    private func xmlRoot(
        for host: StreamHost, at address: String, path: String,
        extraQuery: [URLQueryItem] = [], context: String
    ) async throws -> XMLNode {
        let session = try session(for: host)
        let request = try makeRequest(
            address: address, port: httpsPort(for: host, at: address), path: path, extraQuery: extraQuery)
        let data: Data
        do {
            data = try await boundedData(session, request).0
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            // A timeout means the host took our request and went silent — it may
            // well have ACTED on it (a /launch that times out still starts the
            // session). Saying "unreachable" there sends the user to Wake-on-LAN
            // for a machine that is very much awake.
            if error.code == .timedOut { throw HostAPIError.notResponding(host.name) }
            throw HostAPIError.unreachable(host.name)
        }
        return try Self.verifiedRoot(in: data, context: context)
    }

    // MARK: - Session cache

    private func session(for host: StreamHost) throws -> URLSession {
        let pinnedDER: Data?
        if let pem = host.serverCertPEM, !pem.isEmpty {
            guard let der = Self.derCertificate(fromPEM: pem) else {
                // Fail closed: a present-but-unparseable pin must not silently
                // downgrade to accept-anything.
                throw HostAPIError.malformedResponse("stored server certificate for \(host.name) is not valid PEM")
            }
            pinnedDER = der
        } else {
            pinnedDER = nil
        }

        lock.lock()
        defer { lock.unlock() }
        if let entry = sessions[host.id] {
            if entry.pinnedCertDER == pinnedDER { return entry.session }
            // A pin is only ever ADDED (savePairedHost) or REPLACED by a
            // re-pair — nothing in the app ever clears one back to nil. So an
            // incoming nil against a stored pin cannot mean "this host was
            // unpaired"; it means the CALLER is holding a StreamHost value it
            // captured before pairing finished (e.g. a refresh that started
            // pre-pair and resumed after its first await). Rebuilding from that
            // stale copy would swap the pinned session for a trust-on-first-use
            // one and store it — silently unpinning the host until a current
            // copy happens to come through. Keep the pinned session instead.
            if pinnedDER == nil {
                logger.notice("ignoring a stale unpinned snapshot of \(host.name, privacy: .public); keeping the pinned session")
                return entry.session
            }
        }
        sessions[host.id]?.session.invalidateAndCancel()

        let identity: SecIdentity
        do {
            identity = try identityProvider.secIdentity()
        } catch {
            throw HostAPIError.identityUnavailable(error.localizedDescription)
        }

        let configuration = URLSessionConfiguration.ephemeral
        // Session-level ceiling only. Each request sets its OWN timeoutInterval
        // (quickTimeout for reads, launchTimeout for /launch + /resume) and that
        // is what actually bounds it — this must be >= the largest of them or it
        // would clamp the long launch back down to the short value.
        configuration.timeoutIntervalForRequest = HostAPIClient.launchTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldUsePipelining = false
        // One connection per request is the protocol contract anyway.
        configuration.httpMaximumConnectionsPerHost = 1

        let delegate = MTLSDelegate(
            identity: identity, pinnedCertDER: pinnedDER, hostLabel: host.name, logger: logger)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        sessions[host.id] = SessionEntry(pinnedCertDER: pinnedDER, session: session)
        return session
    }

    // MARK: - TLS delegate

    /// Answers both halves of the GameStream TLS dance:
    /// - ClientCertificate → VibeLight's own pairing identity (this is
    ///   the entire authentication mechanism).
    /// - ServerTrust → byte-exact pin against the cert captured at pairing
    ///   (moonlight-qt behavior); the host's cert is self-signed, so system
    ///   trust evaluation can never pass and must not be consulted.
    ///
    /// URLSession invokes these callbacks nonisolated on its own queue, so
    /// everything held here is immutable; SecIdentity is a thread-safe CF
    /// type, hence @unchecked rather than checked Sendable (NSObject parent).
    private final class MTLSDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate,
                                      @unchecked Sendable {
        private let identity: SecIdentity
        private let pinnedCertDER: Data?
        private let hostLabel: String
        private let logger: Logger
        /// Trust-on-first-use record for the UNPAIRED path only. Written/read on
        /// the URLSession delegate's serial queue (challenges are delivered
        /// serially), so a plain var is safe under @unchecked Sendable.
        private var firstSeenLeafDER: Data?

        init(identity: SecIdentity, pinnedCertDER: Data?, hostLabel: String, logger: Logger) {
            self.identity = identity
            self.pinnedCertDER = pinnedCertDER
            self.hostLabel = hostLabel
            self.logger = logger
        }

        // MARK: - Byte-capped body accumulation

        /// One in-flight request. `begin` is called from the caller's thread
        /// while the delegate callbacks arrive on the session's serial queue, so
        /// this registry gets its own lock rather than relying on that queue.
        private struct Pending {
            let cap: Int
            var buffer = Data()
            var response: URLResponse?
            let continuation: CheckedContinuation<(Data, URLResponse), any Error>
        }
        private let pendingLock = NSLock()
        private var pending: [ObjectIdentifier: Pending] = [:]

        /// How many server certs THIS delegate has rejected for failing the pin
        /// — the ground truth callers consult instead of inferring a rejection
        /// from `URLError.cancelled` (which also covers ordinary internal
        /// cancellations; see serverInfo).
        ///
        /// A monotonic counter, not a read-and-clear or sticky flag: the session
        /// is shared by concurrent requests (box art alongside /serverinfo), so
        /// callers snapshot before and compare after to see exactly the
        /// rejections during their own attempt. Per-session, not per-task —
        /// URLSession's challenge callback gives no per-task attribution, so a
        /// concurrent request's rejection is (acceptably) blamed on whichever
        /// attempt is in flight; that is only wrong for a host record whose
        /// addresses point at different machines.
        private var pinRejections = 0

        var pinRejectionCount: Int {
            pendingLock.lock(); defer { pendingLock.unlock() }
            return pinRejections
        }

        private func notePinRejection() {
            pendingLock.lock(); pinRejections += 1; pendingLock.unlock()
        }

        func begin(task: URLSessionTask, cap: Int,
                   continuation: CheckedContinuation<(Data, URLResponse), any Error>) {
            pendingLock.lock()
            pending[ObjectIdentifier(task)] = Pending(cap: cap, continuation: continuation)
            pendingLock.unlock()
        }

        /// Resumes the continuation at most once and forgets the task.
        private func finish(_ task: URLSessionTask, _ result: Result<(Data, URLResponse), any Error>) {
            pendingLock.lock()
            let entry = pending.removeValue(forKey: ObjectIdentifier(task))
            pendingLock.unlock()
            entry?.continuation.resume(with: result)
        }

        private func tooLarge(_ bytes: Int) -> any Error {
            HostAPIError.malformedResponse("host response too large (\(bytes) bytes)")
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            let id = ObjectIdentifier(dataTask)
            pendingLock.lock()
            let cap = pending[id]?.cap
            pending[id]?.response = response
            // New response headers mean a new body. URLSession follows
            // redirects on this task, and a 3xx that carried a body would
            // otherwise leave those bytes prepended to the real one.
            pending[id]?.buffer.removeAll(keepingCapacity: true)
            pendingLock.unlock()

            // An honestly-declared oversize is rejected before a single body
            // byte is read.
            if let cap, response.expectedContentLength > Int64(cap) {
                completionHandler(.cancel)
                finish(dataTask, .failure(tooLarge(Int(clamping: response.expectedContentLength))))
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let id = ObjectIdentifier(dataTask)
            pendingLock.lock()
            guard let cap = pending[id]?.cap else { pendingLock.unlock(); return }
            // Append through the subscript's modify accessor — in place, no
            // CoW copy of the accumulated body on every chunk (copy-out /
            // append / copy-back memcpy'd the whole buffer so far each time:
            // O(n²) bytes over a transfer).
            pending[id]?.buffer.append(data)
            let total = pending[id]?.buffer.count ?? 0
            pendingLock.unlock()

            // A host that lied about (or omitted) Content-Length is caught here,
            // one chunk past the cap — not after the whole body is in memory.
            if total > cap {
                dataTask.cancel()
                finish(dataTask, .failure(tooLarge(total)))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            pendingLock.lock()
            let entry = pending[ObjectIdentifier(task)]
            pendingLock.unlock()
            guard let entry else { return }   // already finished (cap breach)

            if let error {
                finish(task, .failure(error))
            } else if let response = entry.response ?? task.response {
                finish(task, .success((entry.buffer, response)))
            } else {
                finish(task, .failure(HostAPIError.malformedResponse("no response from host")))
            }
        }

        // Both the session-level and task-level variants funnel to one
        // handler: ServerTrust and ClientCertificate are connection-level
        // challenges, but which callback URLSession picks depends on which
        // methods the delegate implements — cover both.
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            handle(challenge, completionHandler: completionHandler)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            handle(challenge, completionHandler: completionHandler)
        }

        private func handle(
            _ challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            switch challenge.protectionSpace.authenticationMethod {
            case NSURLAuthenticationMethodClientCertificate:
                completionHandler(
                    .useCredential,
                    URLCredential(identity: identity, certificates: nil, persistence: .forSession))

            case NSURLAuthenticationMethodServerTrust:
                guard let trust = challenge.protectionSpace.serverTrust,
                      let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                      let leaf = chain.first else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
                guard let pinnedCertDER else {
                    // Host saved but never paired: accept the self-signed cert so
                    // the XML 401 can surface and prompt pairing. We deliberately
                    // do NOT hard-pin here (a legitimate cert rotation before
                    // pairing must still work), but we trust-on-first-use record
                    // the leaf and WARN if it later changes — making a silent swap
                    // on the unpaired path observable instead of invisible.
                    // (audit NET-unpaired-host-accepts-any-cert)
                    let leafDER = SecCertificateCopyData(leaf) as Data
                    if let seen = firstSeenLeafDER, seen != leafDER {
                        logger.warning("TLS certificate for \(self.hostLabel, privacy: .public) CHANGED since first contact while still unpaired — possible cert rotation or a different machine on this address. Accepting to allow pairing.")
                    } else if firstSeenLeafDER == nil {
                        firstSeenLeafDER = leafDER
                        logger.notice("No pinned certificate for \(self.hostLabel, privacy: .public); recording presented cert (trust-on-first-use) and accepting so pairing can proceed.")
                    }
                    completionHandler(.useCredential, URLCredential(trust: trust))
                    return
                }
                if SecCertificateCopyData(leaf) as Data == pinnedCertDER {
                    completionHandler(.useCredential, URLCredential(trust: trust))
                } else {
                    logger.error("TLS certificate for \(self.hostLabel, privacy: .public) does not match the pinned pairing certificate; rejecting connection.")
                    notePinRejection()
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }

            default:
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    // MARK: - XML

    /// Parses a GameStream XML body and enforces the `status_code` attribute
    /// of `<root>` — the protocol's real status channel (HTTP status and TLS
    /// success mean nothing on their own).
    private static func verifiedRoot(in data: Data, context: String) throws -> XMLNode {
        guard let root = XMLNode.parse(data) else {
            throw HostAPIError.malformedResponse("\(context): response is not parseable XML")
        }
        guard root.name == "root" else {
            throw HostAPIError.malformedResponse("\(context): unexpected root element <\(root.name)>")
        }
        guard let code = root.attributes["status_code"].flatMap(Int.init) else {
            throw HostAPIError.malformedResponse("\(context): <root> has no status_code attribute")
        }
        guard code == 200 else {
            if code == 401 { throw HostAPIError.notAuthorized }
            throw HostAPIError.xmlStatus(code: code, message: root.attributes["status_message"] ?? "")
        }
        return root
    }

    /// Parses a raw `/serverinfo` body. Every field below is host-controlled,
    /// so this is a trust boundary and gets direct test coverage — this
    /// entry point exists for that, keeping `XMLNode` file-private.
    static func parseServerInfo(fromXML data: Data) -> ServerInfo? {
        XMLNode.parse(data).map(parseServerInfo(from:))
    }

    private static func parseServerInfo(from root: XMLNode) -> ServerInfo {
        func text(_ name: String) -> String? { root.child(name)?.text.trimmed }
        return ServerInfo(
            hostname: text("hostname") ?? "",
            state: .init(rawState: text("state") ?? ""),
            currentGameID: text("currentgame").flatMap(Int.init) ?? 0,
            currentGameUUID: text("currentgameuuid").flatMap { $0.isEmpty ? nil : $0 },
            pairStatus: text("PairStatus") == "1",
            // Parsed as Int32, not Int: this reaches moonlight-common-c as an
            // int32_t, and `Int32(someInt)` TRAPS on anything past 2^31-1. The
            // host controls this field, so a value like 9999999999 would kill
            // the app on launch. Int32's failable init rejects it here instead,
            // and 0 — "no special codec modes" — is the right reading of a
            // value that cannot be a valid mask anyway.
            serverCodecModeSupport: text("ServerCodecModeSupport").flatMap(Int32.init).map(Int.init) ?? 0,
            // Same shape of problem, different consequence: an out-of-range port
            // would be nonsense, so fall back to the well-known one.
            httpsPort: text("HttpsPort").flatMap(Int.init).flatMap { (1...65535).contains($0) ? $0 : nil } ?? 47984,
            appVersion: text("appversion") ?? "",
            permissionMask: text("Permission").flatMap(UInt32.init),
            virtualDisplayCapable: text("VirtualDisplayCapable").map { $0 == "true" || $0 == "1" },
            macAddress: parseMAC(text("mac")),
            hostUUID: text("uniqueid").flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// "aa:bb:cc:dd:ee:ff" → 6 raw bytes. All-zeros is Sunshine's "unknown" → nil.
    private static func parseMAC(_ s: String?) -> Data? {
        guard let s, !s.isEmpty else { return nil }
        let parts = s.split(separator: ":")
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard let b = UInt8(part, radix: 16) else { return nil }
            bytes.append(b)
        }
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return Data(bytes)
    }

    // MARK: - Identity helpers

    /// PEM → DER for byte-exact pinning. The pinned cert is stored exactly as
    /// pairing captured it (PEM text); the TLS layer hands us DER.
    /// Defers to the ONE PEM parser. Pairing and pinning read the same stored
    /// `serverCertPEM`, and having two parsers meant they could disagree on what
    /// it contained (this one took the first block; the other concatenated every
    /// block in the file).
    private static func derCertificate(fromPEM pem: Data) -> Data? {
        GameStreamCrypto.pemToDER(pem)
    }
}

// MARK: - Minimal XML DOM (Foundation XMLParser)

/// Tiny element tree for the handful of flat XML shapes GameStream returns.
/// Text is accumulated verbatim — zero-width characters in <AppTitle> are
/// load-bearing and must survive parsing untouched.
private final class XMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func child(_ name: String) -> XMLNode? {
        children.first { $0.name == name }
    }

    static func parse(_ data: Data) -> XMLNode? {
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        // parse() runs synchronously on this thread; a failed parse with a
        // recovered root still counts as failure — GameStream XML is tiny and
        // either whole or garbage.
        return parser.parse() ? collector.root : nil
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var root: XMLNode?
        private var stack: [XMLNode] = []

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            let node = XMLNode(name: elementName, attributes: attributeDict)
            if let parent = stack.last {
                parent.children.append(node)
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?
        ) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let string = String(data: CDATABlock, encoding: .utf8) {
                stack.last?.text += string
            }
        }
    }
}

private extension String {
    /// Whitespace/newline trim for XML scalar fields. NOT for <AppTitle>:
    /// zero-width padding is category Cf, untouched by this — but titles are
    /// kept fully verbatim anyway.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
