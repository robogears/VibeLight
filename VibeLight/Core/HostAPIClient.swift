import Foundation
import Security
import os

/// GameStream protocol client for Sunshine-family hosts (Vibepollo).
///
/// All calls go to HTTPS <base port − 5> (47984 for the default 47989) with
/// mTLS using the client certificate Moonlight established at pairing. There
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
    private let defaults: UserDefaults
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

    init(identityProvider: ClientIdentityProvider, defaults: UserDefaults = .standard) {
        self.identityProvider = identityProvider
        self.defaults = defaults
        self.uniqueID = Self.persistentUniqueID(in: defaults)
    }

    // MARK: - HostAPIProviding

    func serverInfo(for host: StreamHost) async throws -> (info: ServerInfo, address: String) {
        let candidates = host.candidateAddresses
        guard !candidates.isEmpty else { throw HostAPIError.unreachable(host.name) }
        let session = try session(for: host)

        var sawPinRejection = false
        for candidate in candidates {
            let data: Data
            do {
                let request = try makeRequest(
                    address: candidate.host, port: candidate.port - httpsPortOffset, path: "/serverinfo")
                data = try await boundedData(session, request).0
            } catch let error as URLError {
                // Task cancellation surfaces as URLError.cancelled too (and so
                // does our own pin-mismatch rejection) — only genuine Swift
                // cancellation should escape here.
                if Task.isCancelled { throw CancellationError() }
                // A non-task .cancelled means OUR delegate rejected the TLS
                // handshake (pin mismatch) — the host is alive but presenting
                // a different cert than we paired with. Remember it: "re-pair"
                // is actionable, "offline" is a lie.
                if error.code == .cancelled { sawPinRejection = true }
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
        if sawPinRejection { throw HostAPIError.notAuthorized }
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
        } catch is URLError {
            if Task.isCancelled { throw CancellationError() }
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
            address: address, port: httpsPort(for: host, at: address), path: path, extraQuery: items)
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
        } catch is URLError {
            if Task.isCancelled { throw CancellationError() }
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

    /// Byte-capped replacement for `session.data(for:)`: rejects an honestly
    /// oversized Content-Length up front, then caps the actual stream in case
    /// the host lies or omits it.
    private func boundedData(_ session: URLSession, _ request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(Self.responseByteCap) {
            throw HostAPIError.malformedResponse("response too large (\(response.expectedContentLength) bytes)")
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), Self.responseByteCap))
        }
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.responseByteCap {
                throw HostAPIError.malformedResponse("response exceeded \(Self.responseByteCap) bytes")
            }
        }
        return (data, response)
    }

    private func makeRequest(
        address: String, port: Int, path: String, extraQuery: [URLQueryItem] = []
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
            timeoutInterval: 5
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
        } catch is URLError {
            if Task.isCancelled { throw CancellationError() }
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
        if let entry = sessions[host.id], entry.pinnedCertDER == pinnedDER {
            return entry.session
        }
        sessions[host.id]?.session.invalidateAndCancel()

        let identity: SecIdentity
        do {
            identity = try identityProvider.secIdentity()
        } catch {
            throw HostAPIError.identityUnavailable(error.localizedDescription)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
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
    /// - ClientCertificate → the reused Moonlight pairing identity (this is
    ///   the entire authentication mechanism).
    /// - ServerTrust → byte-exact pin against the cert captured at pairing
    ///   (moonlight-qt behavior); the host's cert is self-signed, so system
    ///   trust evaluation can never pass and must not be consulted.
    ///
    /// URLSession invokes these callbacks nonisolated on its own queue, so
    /// everything held here is immutable; SecIdentity is a thread-safe CF
    /// type, hence @unchecked rather than checked Sendable (NSObject parent).
    private final class MTLSDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let identity: SecIdentity
        private let pinnedCertDER: Data?
        private let hostLabel: String
        private let logger: Logger

        init(identity: SecIdentity, pinnedCertDER: Data?, hostLabel: String, logger: Logger) {
            self.identity = identity
            self.pinnedCertDER = pinnedCertDER
            self.hostLabel = hostLabel
            self.logger = logger
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
                    // No pinned cert stored (host saved but never paired).
                    // Accept the self-signed cert so the XML 401 can surface
                    // and tell the user to pair — but leave a trace.
                    logger.notice("No pinned certificate for \(self.hostLabel, privacy: .public); accepting presented TLS certificate unverified.")
                    completionHandler(.useCredential, URLCredential(trust: trust))
                    return
                }
                if SecCertificateCopyData(leaf) as Data == pinnedCertDER {
                    completionHandler(.useCredential, URLCredential(trust: trust))
                } else {
                    logger.error("TLS certificate for \(self.hostLabel, privacy: .public) does not match the pinned pairing certificate; rejecting connection.")
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

    private static func parseServerInfo(from root: XMLNode) -> ServerInfo {
        func text(_ name: String) -> String? { root.child(name)?.text.trimmed }
        return ServerInfo(
            hostname: text("hostname") ?? "",
            state: .init(rawState: text("state") ?? ""),
            currentGameID: text("currentgame").flatMap(Int.init) ?? 0,
            currentGameUUID: text("currentgameuuid").flatMap { $0.isEmpty ? nil : $0 },
            pairStatus: text("PairStatus") == "1",
            serverCodecModeSupport: text("ServerCodecModeSupport").flatMap(Int.init) ?? 0,
            httpsPort: text("HttpsPort").flatMap(Int.init) ?? 47984,
            appVersion: text("appversion") ?? "",
            permissionMask: text("Permission").flatMap(UInt32.init),
            virtualDisplayCapable: text("VirtualDisplayCapable").map { $0 == "true" || $0 == "1" },
            macAddress: parseMAC(text("mac"))
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

    /// Stable 16-hex-char uniqueid, synthesized once and persisted. Sunshine
    /// doesn't authorize by it, so it needn't match Moonlight's — it only has
    /// to be present and consistent.
    private static func persistentUniqueID(in defaults: UserDefaults) -> String {
        let key = "vibelight.uniqueid"
        if let existing = defaults.string(forKey: key), existing.count == 16 {
            return existing
        }
        let fresh = String(format: "%016llx", UInt64.random(in: UInt64.min...UInt64.max))
        defaults.set(fresh, forKey: key)
        return fresh
    }

    /// PEM → DER for byte-exact pinning. The pinned cert is stored exactly as
    /// pairing captured it (PEM text); the TLS layer hands us DER.
    private static func derCertificate(fromPEM pem: Data) -> Data? {
        guard let text = String(data: pem, encoding: .utf8),
              let begin = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----"),
              begin.upperBound <= end.lowerBound else { return nil }
        let base64 = String(text[begin.upperBound..<end.lowerBound])
        return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
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
