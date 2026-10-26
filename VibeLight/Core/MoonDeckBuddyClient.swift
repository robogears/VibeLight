import Foundation
import os

/// Talks to a user-installed **MoonDeckBuddy** (github.com/FrogTheFrog/moondeck-buddy)
/// over its HTTPS REST API to control the host PC — currently just RESTART.
///
/// MoonDeckBuddy is a separate app from Sunshine/Apollo: the user installs it on
/// the gaming PC and pairs VibeLight to it once (a PIN they approve on the PC).
/// After that, rebooting Windows with no on-PC dialog is one authenticated POST.
///
/// Wire protocol verified against the MoonDeck plugin's `buddyrequests.py`
/// (API version 8):
/// - `GET  /apiVersion`                → `{"version": Int}` (unauthenticated)
/// - `GET  /pairingState/<clientId>`   → `{"state": Int}` 0=paired 1=pairing 2=not
/// - `POST /pair`                      → `{"id", "hashed_id"}` (hashed = b64(id+pin))
/// - `POST /restartHost`               → body `{"delay": Int}` → `{"result": Bool}`
/// - Auth header on secure routes: `Authorization: basic <base64(clientId)>`
///
/// TLS: MoonDeckBuddy presents a self-signed cert whose hostname never matches a
/// LAN/Tailscale address, so the system trust evaluation can't pass. Instead the
/// leaf is trusted on first use and pinned once pairing succeeds — every later
/// request must present that exact cert (see `PinnedTrust` below).
final class MoonDeckBuddyClient: Sendable {
    /// The API version VibeLight was written against. We accept this OR newer,
    /// down to `minSupportedAPIVersion` — the pairing/restart endpoints have been
    /// stable across these, so a version bump shouldn't gate users out (a real
    /// install reported v7).
    static let targetAPIVersion = 8
    static let minSupportedAPIVersion = 7
    static let defaultPort = 59999
    /// The only ports a request may use. URLComponents' `port` setter raises
    /// an exception Swift can't catch on a negative value, so a "-1" typed into
    /// the port box (and saved) crashed the app on every pairing attempt.
    /// (audit NET-negative-buddy-port)
    static let validPorts = 1...65535

    /// The setup card's port field: blank means the default port; anything
    /// else must be a whole number in `validPorts`, or nil.
    static func port(fromField text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return defaultPort }
        guard let port = Int(trimmed), validPorts.contains(port) else { return nil }
        return port
    }

    /// The request URL, or nil for a port outside `validPorts` — checked here
    /// too so a bad port saved by an older build can't reach the setter.
    static func requestURL(host: String, port: Int, path: String) -> URL? {
        guard validPorts.contains(port) else { return nil }
        var comps = URLComponents()
        comps.scheme = "https"; comps.host = host; comps.port = port; comps.path = path
        return comps.url
    }

    /// Pairing state as reported by `GET /pairingState`.
    enum PairState: Int, Sendable { case paired = 0, pairing = 1, notPaired = 2 }

    enum MDError: Error, LocalizedError, Equatable {
        case offline                     // couldn't reach MoonDeckBuddy at all
        case certChanged                 // TLS pin mismatch — Buddy reinstalled (or MITM)
        case apiVersionTooOld(Int)       // buddy older than we support
        case unauthorized                // 401 — this client isn't paired
        case http(Int)                   // other non-2xx
        case badResponse(String)         // unparseable / unexpected JSON (detail = endpoint + body)
        case restartRejected             // {"result": false}

        var errorDescription: String? {
            switch self {
            case .offline:
                return "Couldn't reach MoonDeckBuddy. Make sure it's installed and running on the PC, and the PC is awake."
            case .certChanged:
                return "MoonDeckBuddy's security certificate changed — it was probably reinstalled or updated on the PC. Pair it again to continue."
            case .apiVersionTooOld(let v):
                return "MoonDeckBuddy is too old (API v\(v)); VibeLight needs v\(MoonDeckBuddyClient.minSupportedAPIVersion) or newer. Update MoonDeckBuddy on the PC."
            case .unauthorized:
                return "VibeLight isn't paired with MoonDeckBuddy on this PC yet."
            case .http(let code):
                return "MoonDeckBuddy returned HTTP \(code)."
            case .badResponse(let detail):
                return "MoonDeckBuddy sent an unexpected response (\(detail))."
            case .restartRejected:
                return "MoonDeckBuddy declined the restart."
            }
        }
    }

    private let session: URLSession
    private let trust = PinnedTrust()

    /// Every reply this client reads is a tiny JSON object; 256 KB is already
    /// three orders of magnitude of headroom. Enforced mid-transfer — see
    /// `CappedResponseReader` for why a post-hoc size check bounds nothing.
    private static let replyByteCap = 256 * 1024

    /// `configuration` is injectable so tests can intercept requests with a
    /// custom URLProtocol; production passes nil for the pinned-trust session.
    init(configuration: URLSessionConfiguration? = nil) {
        let cfg = configuration ?? {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 6
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            c.urlCache = nil
            return c
        }()
        session = URLSession(configuration: cfg,
                             delegate: trust, delegateQueue: nil)
    }

    // MARK: - TLS pinning (trust-on-first-use)

    /// Require `der` as the server's leaf cert for `host` on subsequent
    /// connections (blocks an active MITM after the cert is first captured).
    /// Pass nil to accept-and-record the next cert (first pairing).
    func setExpectedCert(_ der: Data?, forHost host: String) { trust.setExpected(der, host: host) }

    /// The leaf cert seen on the most recent connection to `host` — store this
    /// after a successful first pair so it can be pinned from then on.
    func observedCert(forHost host: String) -> Data? { trust.observedCert(host: host) }

    // MARK: - Wire encoding (pure — unit-tested)

    /// `Authorization: basic <base64(clientId)>` — the base64 payload is the raw
    /// client-id string, NOT `user:pass`.
    static func authorizationHeader(clientID: String) -> String {
        "basic \(Data(clientID.utf8).base64EncodedString())"
    }

    /// The `hashed_id` a client sends with `/pair`: base64(clientId + pin). The
    /// host recomputes it from the PIN the user types to prove human approval.
    static func pairingHash(clientID: String, pin: String) -> String {
        Data((clientID + pin).utf8).base64EncodedString()
    }

    // MARK: - API

    /// Liveness + protocol check. Throws `.offline` if unreachable,
    /// `.apiVersionMismatch` if the buddy speaks a different version.
    func checkReachable(host: String, port: Int) async throws {
        let version = try await apiVersion(host: host, port: port)
        guard version >= Self.minSupportedAPIVersion else {
            throw MDError.apiVersionTooOld(version)
        }
    }

    func apiVersion(host: String, port: Int) async throws -> Int {
        let data = try await send("GET", host: host, port: port, path: "/apiVersion")
        // `version` is an Int in current builds; tolerate a stringified number too.
        if let obj = Self.json(data) {
            if let v = obj["version"] as? Int { return v }
            if let s = obj["version"] as? String, let v = Int(s) { return v }
        }
        throw MDError.badResponse("apiVersion: \(Self.snippet(data))")
    }

    func pairState(host: String, port: Int, clientID: String) async throws -> PairState {
        let data = try await send("GET", host: host, port: port, path: "/pairingState/\(clientID)")
        guard let obj = Self.json(data), let raw = obj["state"] else {
            throw MDError.badResponse("pairingState: \(Self.snippet(data))")
        }
        // `state` is 0/1/2 in current builds; older/other builds may send a
        // string enum ("Paired"/"Pairing"/"NotPaired"). Accept both.
        if let i = raw as? Int, let s = PairState(rawValue: i) { return s }
        if let str = (raw as? String)?.lowercased().replacingOccurrences(of: "_", with: "") {
            switch str {
            case "paired":    return .paired
            case "pairing":   return .pairing
            case "notpaired": return .notPaired
            default: break
            }
        }
        throw MDError.badResponse("pairingState state=\(raw)")
    }

    /// Begin pairing: the PC pops a PIN dialog the user fills in. `hashed_id`
    /// proves this client knows the PIN it displayed.
    func startPairing(host: String, port: Int, clientID: String, pin: String) async throws {
        _ = try await send("POST", host: host, port: port, path: "/pair",
                           body: ["id": clientID, "hashed_id": Self.pairingHash(clientID: clientID, pin: pin)])
    }

    /// Restart the host PC (no on-PC confirmation dialog). `delaySeconds` is
    /// 1…30 per the buddy's validation.
    ///
    /// Current buddy builds route this as `POST /restartHost`; older builds
    /// (the same vintage that reports string pairing states) used a different
    /// route name, answering 404 here. Fall back through the legacy names —
    /// a wrong guess is a harmless 404 — and if none exist, surface the
    /// buddy's actual API version so the fix ("update MoonDeckBuddy") is
    /// obvious rather than a bare HTTP 404.
    func restart(host: String, port: Int, clientID: String, delaySeconds: Int = 5) async throws {
        let delay = min(max(delaySeconds, 1), 30)
        for (i, path) in ["/restartHost", "/restartPc", "/restartPC"].enumerated() {
            do {
                let data = try await send("POST", host: host, port: port, path: path,
                                          body: ["delay": delay], authClientID: clientID)
                // {"result": Bool} — false means the buddy declined.
                if let obj = Self.json(data), let ok = obj["result"] as? Bool, !ok {
                    throw MDError.restartRejected
                }
                return
            } catch MDError.http(404) where i < 2 {
                continue   // try the next candidate route
            } catch MDError.http(404) {
                let v = (try? await apiVersion(host: host, port: port)).map { "v\($0)" } ?? "unknown version"
                throw MDError.badResponse(
                    "no restart route — buddy API \(v). Update MoonDeckBuddy on the PC")
            }
        }
    }

    // MARK: - HTTP

    private func send(_ method: String, host: String, port: Int, path: String,
                      body: [String: Any]? = nil, authClientID: String? = nil) async throws -> Data {
        guard Self.validPorts.contains(port) else { throw MDError.badResponse("port \(port) is not a valid port") }
        guard let url = Self.requestURL(host: host, port: port, path: path) else { throw MDError.badResponse("bad url") }

        var req = URLRequest(url: url)
        req.httpMethod = method
        if let authClientID {
            req.setValue(Self.authorizationHeader(clientID: authClientID), forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        // Snapshot before the request so a rejection during THIS request is
        // distinguishable from one during a concurrent one.
        let rejectionsBefore = trust.pinRejectionCount
        let data: Data, response: URLResponse
        do {
            // Replies here are tiny JSON objects ({"version":8}); the only
            // other bound is an INACTIVITY timeout, which never cuts off a
            // server that keeps sending. The cap is enforced by the reader as
            // bytes arrive — the previous version checked `data.count` after
            // the whole body was already buffered, which bounds nothing, and
            // threw from inside this `do` where the catch below relabelled it
            // "offline" so it could never even be reported.
            (data, response) = try await trust.read(session, req, cap: Self.replyByteCap)
        } catch let tooLarge as CappedResponseReader.TooLarge {
            throw MDError.badResponse("reply too large (\(tooLarge.bytes) bytes)")
        } catch {
            // Report .certChanged only when the pin ACTUALLY rejected a
            // certificate during this request. URLError.cancelled alone is not
            // proof — ordinary cancellation produces it too, and the caller's
            // response is to discard the stored pin, which would let an on-path
            // attacker turn any cancellation into a fresh trust-on-first-use
            // capture of its own certificate.
            if let urlError = error as? URLError, urlError.code == .cancelled,
               trust.pinRejectionCount > rejectionsBefore {
                throw MDError.certChanged
            }
            throw MDError.offline
        }
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401: throw MDError.unauthorized
            default: throw MDError.http(http.statusCode)
            }
        }
        return data
    }

    private static func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// A short, log-safe preview of a response body for diagnostics.
    private static func snippet(_ data: Data) -> String {
        let s = String(decoding: data.prefix(160), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "empty body" : s
    }
}

/// TLS trust for MoonDeckBuddy's self-signed cert (whose hostname never matches a
/// LAN/Tailscale address, so system evaluation always fails). Per host:
/// - an *expected* leaf cert registered → the presented cert MUST match it, else
///   the connection is rejected (blocks an active MITM after the first pairing);
/// - no expected cert yet → accept the presented cert and RECORD it, so it can be
///   pinned once pairing succeeds (trust-on-first-use).
/// Thread-safe: URLSession invokes the delegate on its own queue.
private final class PinnedTrust: CappedResponseReader {
    private let lock = NSLock()
    private var expected: [String: Data] = [:]     // host -> required leaf DER
    private var observedCerts: [String: Data] = [:] // host -> last-seen leaf DER
    /// How many certificates THIS delegate has rejected for failing the pin —
    /// the ground truth callers consult instead of inferring a rejection from
    /// `URLError.cancelled`, which also covers ordinary cancellation. Monotonic:
    /// callers snapshot before a request and compare after.
    private var rejections = 0

    var pinRejectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return rejections
    }

    func setExpected(_ der: Data?, host: String) {
        lock.lock(); defer { lock.unlock() }
        if let der { expected[host] = der } else { expected.removeValue(forKey: host) }
    }
    func observedCert(host: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return observedCerts[host]
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host
        let leafDER = SecCertificateCopyData(leaf) as Data
        lock.lock()
        observedCerts[host] = leafDER
        let pinned = expected[host]
        lock.unlock()

        if let pinned, pinned != leafDER {
            lock.lock(); rejections += 1; lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)  // cert changed — reject
        } else {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        }
    }
}
