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
/// LAN/Tailscale address, so the system trust evaluation can't pass. We accept
/// the presented cert for the user-specified host:port — this is a private-network
/// control channel and the clientId credential only controls that one host.
/// (Pinning the shared `moondeck_cert.pem` is a possible future hardening.)
final class MoonDeckBuddyClient: Sendable {
    /// The API version VibeLight was written against. We accept this OR newer,
    /// down to `minSupportedAPIVersion` — the pairing/restart endpoints have been
    /// stable across these, so a version bump shouldn't gate users out (a real
    /// install reported v7).
    static let targetAPIVersion = 8
    static let minSupportedAPIVersion = 7
    static let defaultPort = 59999

    /// Pairing state as reported by `GET /pairingState`.
    enum PairState: Int, Sendable { case paired = 0, pairing = 1, notPaired = 2 }

    enum MDError: Error, LocalizedError, Equatable {
        case offline                     // couldn't reach MoonDeckBuddy at all
        case apiVersionTooOld(Int)       // buddy older than we support
        case unauthorized                // 401 — this client isn't paired
        case http(Int)                   // other non-2xx
        case badResponse                 // unparseable / unexpected JSON
        case restartRejected             // {"result": false}

        var errorDescription: String? {
            switch self {
            case .offline:
                return "Couldn't reach MoonDeckBuddy. Make sure it's installed and running on the PC, and the PC is awake."
            case .apiVersionTooOld(let v):
                return "MoonDeckBuddy is too old (API v\(v)); VibeLight needs v\(MoonDeckBuddyClient.minSupportedAPIVersion) or newer. Update MoonDeckBuddy on the PC."
            case .unauthorized:
                return "VibeLight isn't paired with MoonDeckBuddy on this PC yet."
            case .http(let code):
                return "MoonDeckBuddy returned HTTP \(code)."
            case .badResponse:
                return "MoonDeckBuddy sent an unexpected response."
            case .restartRejected:
                return "MoonDeckBuddy declined the restart."
            }
        }
    }

    private let session: URLSession
    private let trust = PinnedTrust()

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
        guard let obj = Self.json(data), let v = obj["version"] as? Int else { throw MDError.badResponse }
        return v
    }

    func pairState(host: String, port: Int, clientID: String) async throws -> PairState {
        let data = try await send("GET", host: host, port: port, path: "/pairingState/\(clientID)")
        guard let obj = Self.json(data), let raw = obj["state"] as? Int,
              let state = PairState(rawValue: raw) else { throw MDError.badResponse }
        return state
    }

    /// Begin pairing: the PC pops a PIN dialog the user fills in. `hashed_id`
    /// proves this client knows the PIN it displayed.
    func startPairing(host: String, port: Int, clientID: String, pin: String) async throws {
        _ = try await send("POST", host: host, port: port, path: "/pair",
                           body: ["id": clientID, "hashed_id": Self.pairingHash(clientID: clientID, pin: pin)])
    }

    /// Restart the host PC (no on-PC confirmation dialog). `delaySeconds` is
    /// 1…30 per the buddy's validation.
    func restart(host: String, port: Int, clientID: String, delaySeconds: Int = 5) async throws {
        let data = try await send("POST", host: host, port: port, path: "/restartHost",
                                  body: ["delay": min(max(delaySeconds, 1), 30)],
                                  authClientID: clientID)
        // {"result": Bool} — false means the buddy declined.
        if let obj = Self.json(data), let ok = obj["result"] as? Bool, !ok {
            throw MDError.restartRejected
        }
    }

    // MARK: - HTTP

    private func send(_ method: String, host: String, port: Int, path: String,
                      body: [String: Any]? = nil, authClientID: String? = nil) async throws -> Data {
        var comps = URLComponents()
        comps.scheme = "https"; comps.host = host; comps.port = port; comps.path = path
        guard let url = comps.url else { throw MDError.badResponse }

        var req = URLRequest(url: url)
        req.httpMethod = method
        if let authClientID {
            req.setValue(Self.authorizationHeader(clientID: authClientID), forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
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
}

/// TLS trust for MoonDeckBuddy's self-signed cert (whose hostname never matches a
/// LAN/Tailscale address, so system evaluation always fails). Per host:
/// - an *expected* leaf cert registered → the presented cert MUST match it, else
///   the connection is rejected (blocks an active MITM after the first pairing);
/// - no expected cert yet → accept the presented cert and RECORD it, so it can be
///   pinned once pairing succeeds (trust-on-first-use).
/// Thread-safe: URLSession invokes the delegate on its own queue.
private final class PinnedTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var expected: [String: Data] = [:]     // host -> required leaf DER
    private var observedCerts: [String: Data] = [:] // host -> last-seen leaf DER

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
            completionHandler(.cancelAuthenticationChallenge, nil)  // cert changed — reject
        } else {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        }
    }
}
