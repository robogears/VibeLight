import Foundation
import Security

/// Talks to **VibeLight Helper**, the small tray app on the gaming PC
/// (`WindowsHelper/` in this repo; wire contract in its `Protocol.cs`). It
/// does what the stream can't: Match TV (the PC's display and the game take
/// the stream's size), Quit Game, and Restart PC (MoonDeckBuddy's way — the
/// helper replaced MoonDeckBuddy).
///
/// - HTTPS on `port`, JSON, one request per connection.
/// - No pairing of its own (owner: "it should just work"). The TLS handshake
///   presents VibeLight's GameStream client identity, and the helper lets it
///   in only if the PC's streaming host has paired that same certificate with
///   permission to launch apps. A device that can stream from the PC can use
///   its helper; nothing else on the network can.
/// - The helper's certificate is self-signed: trusted the first time, then
///   pinned per host (AppState keeps the pins). A different one later is
///   refused (`certChanged`) until the person trusts it in Settings ▸ Windows
///   Helper — the same rule as MoonDeckBuddy.
final class WindowsHelperClient: Sendable {
    static let port = 47333

    enum HelperError: Error, LocalizedError, Equatable {
        case notRunning        // nothing answered on the port
        case certChanged       // a different helper certificate than the pinned one
        case notAllowed        // 401: this device isn't paired with the PC's host
        case http(Int)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .notRunning:
                "VibeLight Helper isn't running on the PC."
            case .certChanged:
                "VibeLight Helper's certificate changed on the PC. Trust it again in Settings ▸ Windows Helper."
            case .notAllowed:
                "VibeLight Helper doesn't know this device. Pair it with the PC's streaming host first."
            case .http(let code):
                "VibeLight Helper answered with HTTP \(code)."
            case .badResponse:
                "VibeLight Helper sent a reply VibeLight couldn't read."
            }
        }
    }

    struct Info: Decodable, Sendable, Equatable {
        let name: String
        let version: String
        let hostName: String
    }
    struct Display: Decodable, Sendable, Equatable {
        let device: String
        let width: Int
        let height: Int
        let refreshHz: Int
    }
    /// The game in front on the PC — only a window with evidence of being a
    /// game (a store's game folder, started by a launcher, on Windows' game
    /// list, exclusive fullscreen), never just any big window. `pid` is what
    /// Quit asks to close; `evidence` says why it counts. (Optional: helper
    /// 0.1.1 sent neither.)
    struct Game: Decodable, Sendable, Equatable {
        let title: String
        let process: String
        let pid: Int?
        let exclusiveFullscreen: Bool
        let evidence: String?
    }
    struct Status: Decodable, Sendable, Equatable {
        let display: Display?
        let game: Game?
        let matched: Bool
    }
    /// What /match and /restore did; `message` is a short line to show as is.
    struct MatchResult: Decodable, Sendable, Equatable {
        let ok: Bool
        let display: Display?
        let game: Game?
        let gameFitted: Bool
        let message: String
    }
    struct QuitResult: Decodable, Sendable, Equatable {
        let ok: Bool
        let title: String?
        let forced: Bool
        let message: String
    }
    struct RestartResult: Decodable, Sendable, Equatable {
        let ok: Bool
        let message: String
    }

    /// What a check of one PC found.
    enum Probe: Equatable, Sendable {
        /// Running and this device may use it. `certificate` is the helper's,
        /// to pin when nothing is pinned yet.
        case ready(pcName: String, certificate: Data)
        /// Running, but the PC's host hasn't paired this device.
        case notAllowed(pcName: String)
        case notRunning
        case certChanged
    }

    private let identityProvider: ClientIdentityProvider

    /// Every reply is a small JSON object.
    private static let replyByteCap = 64 * 1024

    init(identityProvider: ClientIdentityProvider) {
        self.identityProvider = identityProvider
    }

    // MARK: - API

    /// Is the helper on this PC, and may this device use it?
    func probe(at address: String, pinned: Data?) async -> Probe {
        do {
            let (data, certificate) = try await send("GET", "/info", at: address, pinned: pinned, timeout: 4)
            guard let info = try? JSONDecoder().decode(Info.self, from: data) else { return .notRunning }
            do {
                // /info is open to anyone; /status says whether WE get in.
                _ = try await send("GET", "/status", at: address, pinned: certificate, timeout: 4)
                return .ready(pcName: info.hostName, certificate: certificate)
            } catch HelperError.notAllowed {
                return .notAllowed(pcName: info.hostName)
            }
        } catch HelperError.certChanged {
            return .certChanged
        } catch {
            return .notRunning
        }
    }

    /// The PC's display and the game in front (nil when nothing counts as one).
    func status(at address: String, pinned: Data) async throws -> Status {
        try await decode(Status.self, send("GET", "/status", at: address, pinned: pinned, timeout: 4).0)
    }

    /// The PC's display to `width`×`height`, the game fitted to it,
    /// borderless. The refresh rate stays the display's own unless
    /// `refreshHz` asks for one (a TV preset's frame rate; helper 0.1.3+ —
    /// older helpers ignore it).
    func match(width: Int, height: Int, refreshHz: Int? = nil,
               at address: String, pinned: Data) async throws -> MatchResult {
        var body = ["width": width, "height": height]
        if let refreshHz { body["refreshHz"] = refreshHz }
        return try await decode(MatchResult.self, send("POST", "/match", at: address, pinned: pinned,
                                                       body: body, timeout: 10).0)
    }

    /// Puts back whatever `match` changed.
    func restore(at address: String, pinned: Data) async throws -> MatchResult {
        try await decode(MatchResult.self, send("POST", "/restore", at: address, pinned: pinned, timeout: 10).0)
    }

    /// Closes the game in front on the PC: politely, then by force after
    /// `graceSeconds` (1…30). `pid`: the game VibeLight showed — if another
    /// one is in front now, the helper closes nothing.
    func quitGame(graceSeconds: Int, pid: Int?, at address: String, pinned: Data) async throws -> QuitResult {
        let grace = min(max(graceSeconds, 1), 30)
        var body = ["graceSeconds": grace]
        if let pid { body["pid"] = pid }
        // The helper answers once the game is gone: allow the grace and then some.
        return try await decode(QuitResult.self, send("POST", "/quit-game", at: address, pinned: pinned,
                                                      body: body, timeout: TimeInterval(grace + 10)).0)
    }

    /// Restarts the PC no matter what's running, MoonDeckBuddy's way: the
    /// helper answers at once and restarts after `delaySeconds` (1…30, its
    /// range), with apps forced closed.
    func restart(delaySeconds: Int, at address: String, pinned: Data) async throws -> RestartResult {
        let delay = min(max(delaySeconds, 1), 30)
        return try await decode(RestartResult.self, send("POST", "/restart", at: address, pinned: pinned,
                                                         body: ["delaySeconds": delay], timeout: 8).0)
    }

    // MARK: - HTTP

    static func requestURL(address: String, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = address
        components.port = port
        components.path = path
        return components.url
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw HelperError.badResponse }
    }

    /// The reply body and the helper's certificate as seen in this handshake.
    private func send(_ method: String, _ path: String, at address: String, pinned: Data?,
                      body: [String: Int]? = nil, timeout: TimeInterval) async throws -> (Data, Data) {
        guard let url = Self.requestURL(address: address, path: path) else { throw HelperError.notRunning }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("close", forHTTPHeaderField: "Connection")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        // No identity yet (a keychain that can't answer): /info still works,
        // everything else comes back 401.
        let identity = try? identityProvider.secIdentity()
        let tls = HelperTLS(identity: identity, pinned: pinned)
        // Per request, like pairing: the pin and the identity live in the delegate.
        let session = URLSession(configuration: .ephemeral, delegate: tls, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await tls.read(session, request, cap: Self.replyByteCap)
        } catch is CappedResponseReader.TooLarge {
            throw HelperError.badResponse
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // Only a rejection by the pin itself means "changed" — an ordinary
            // cancellation must not read as one, or a forced re-trust could follow.
            if tls.rejectedPin { throw HelperError.certChanged }
            throw HelperError.notRunning
        }
        guard let certificate = tls.observedCertificate else { throw HelperError.badResponse }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return (data, certificate)
        case 401: throw HelperError.notAllowed
        case let code: throw HelperError.http(code)
        }
    }
}

/// TLS for one helper request: presents VibeLight's client identity when the
/// helper asks for it, and holds the helper to its pinned certificate (or
/// records the one it shows, for the first check).
private final class HelperTLS: CappedResponseReader {
    private let identity: SecIdentity?
    private let pinned: Data?
    private let lock = NSLock()
    private var observed: Data?
    private var rejected = false

    init(identity: SecIdentity?, pinned: Data?) {
        self.identity = identity
        self.pinned = pinned
    }

    var observedCertificate: Data? { lock.lock(); defer { lock.unlock() }; return observed }
    var rejectedPin: Bool { lock.lock(); defer { lock.unlock() }; return rejected }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            if let identity {
                completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust,
                  let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let der = SecCertificateCopyData(leaf) as Data
            lock.lock()
            observed = der
            let mismatch = pinned != nil && pinned != der
            if mismatch { rejected = true }
            lock.unlock()
            if mismatch {
                completionHandler(.cancelAuthenticationChallenge, nil)
            } else {
                completionHandler(.useCredential, URLCredential(trust: trust))
            }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// How big the stream gets on a TV with Match TV on (Settings ▸ Windows
/// Helper ▸ TV Resolution). The owner's words: Full is the TV's own
/// resolution, Half is "4K > 1440p", Quarter is "4K > 1080p" (the default).
/// Per side that is ×1, ×2/3 and ×1/2. The frame rate never changes.
enum TVMatchScale: String, CaseIterable, Codable, Sendable {
    case quarter, half, full

    var title: String {
        switch self {
        case .quarter: "Quarter"
        case .half: "Half"
        case .full: "Full"
        }
    }

    /// Never below 720p: a quarter of a 1080p TV (540p) looks worse than the
    /// TV deserves.
    static let minimumHeight = 720

    /// The stream size for a TV of `tv` pixels: the scale, rounded down to even
    /// numbers (encoders want them), raised to 720p if it fell below.
    static func streamSize(tv: (width: Int, height: Int), scale: TVMatchScale) -> (width: Int, height: Int)? {
        guard tv.width >= 2, tv.height >= 2 else { return nil }
        let (num, den): (Int, Int) = switch scale {
        case .full: (1, 1)
        case .half: (2, 3)
        case .quarter: (1, 2)
        }
        var height = tv.height * num / den
        if height < minimumHeight { height = min(minimumHeight, tv.height) }
        let width = tv.width * height / tv.height
        return (width / 2 * 2, height / 2 * 2)
    }

    /// The row's value: "Quarter · 1920×1080" for a TV that's attached,
    /// "Quarter · 4K → 1080p" when none is.
    func label(tv: (width: Int, height: Int)?) -> String {
        if let tv, let size = Self.streamSize(tv: tv, scale: self) {
            return "\(title) · \(size.width)×\(size.height)"
        }
        let example: String = switch self {
        case .quarter: "4K → 1080p"
        case .half: "4K → 1440p"
        case .full: "4K → 4K"
        }
        return "\(title) · \(example)"
    }
}
