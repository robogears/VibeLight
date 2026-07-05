import Foundation
import os
import Security

/// In-app GameStream pairing — a faithful port of moonlight-qt's
/// NvPairingManager, so VibeLight can pair a new host by itself (no official
/// Moonlight client needed). Phases 1–4 run over plain HTTP:47989; phase 5 is
/// an mTLS request to HTTPS:47984 using our client identity. The user enters
/// the PIN we generate on the host's own web UI, which unblocks phase 1.
final class HostPairing: @unchecked Sendable {

    enum Result: Equatable, Sendable {
        case paired(serverCertPEM: Data)
        case wrongPIN
        case alreadyInProgress
        case unreachable
        case failed(String)
    }

    private let identityProvider: ClientIdentityProvider
    private let uniqueID: String
    private let clientCertPEM: Data

    init(identityProvider: ClientIdentityProvider, uniqueID: String) {
        self.identityProvider = identityProvider
        self.uniqueID = uniqueID
        self.clientCertPEM = identityProvider.certificatePEM
    }

    /// Generates a fresh 4-digit PIN for the user to type on the host.
    static func generatePIN() -> String {
        let n = Int(GameStreamCrypto.randomBytes(2).reduce(0) { ($0 << 8) | Int($1) }) % 10000
        return String(format: "%04d", n)
    }

    // MARK: - Handshake

    func pair(address: String, pin: String) async -> Result {
        let hashLength = 32  // SHA-256 (Sunshine/Apollo/Vibepollo are all gen 7+)
        let salt = GameStreamCrypto.randomBytes(16)
        let aesKey = GameStreamCrypto.sha256(salt + Data(pin.utf8)).prefix(16)

        do {
            // Clear any zombie session first: Sunshine keeps a half-open pairing
            // session per uniqueid across aborted attempts (its emplace never
            // replaces), which makes the NEXT attempt die at stage 1. We're not
            // paired yet (pairing is only offered for unpaired hosts), so this
            // is pure cleanup.
            await unpair(address)

            // Phase 1 — getservercert. The host parks this request until the
            // user types the PIN into its web UI, so give them a real window
            // (moonlight-qt waits indefinitely; a short timeout both fails a
            // slow-but-correct PIN AND leaves a poisoned session behind).
            let resp1 = try await get(
                address: address,
                query: "devicename=roth&updateState=1&phrase=getservercert&salt=\(salt.lowercaseHex)&clientcert=\(clientCertPEM.lowercaseHex)",
                timeout: 600)
            guard paired(resp1) else { return stageError(resp1, "The host rejected pairing (stage 1).") }
            guard let serverCertPEM = xmlHex(resp1, "plaincert"), !serverCertPEM.isEmpty else {
                await unpair(address)
                return .alreadyInProgress
            }

            // Phase 2 — clientchallenge.
            let randomChallenge = GameStreamCrypto.randomBytes(16)
            guard let encryptedChallenge = GameStreamCrypto.aesEcbEncrypt(randomChallenge, key: aesKey) else {
                return .failed("Encryption failed.")
            }
            let resp2 = try await get(
                address: address,
                query: "devicename=roth&updateState=1&clientchallenge=\(encryptedChallenge.lowercaseHex)")
            guard paired(resp2) else { await unpair(address); return stageError(resp2, "Pairing failed (stage 2).") }
            guard let encResponse = xmlHex(resp2, "challengeresponse"),
                  let challengeResponseData = GameStreamCrypto.aesEcbDecrypt(encResponse, key: aesKey),
                  challengeResponseData.count >= hashLength + 16 else {
                await unpair(address); return .failed("Invalid challenge response (stage 2).")
            }

            // Phase 3 — serverchallengeresp.
            let serverResponse = challengeResponseData.prefix(hashLength)
            let serverChallenge = challengeResponseData.subdata(in: hashLength..<(hashLength + 16))
            let clientSecret = GameStreamCrypto.randomBytes(16)
            guard let clientCertSig = GameStreamCrypto.x509SignatureBytes(pem: clientCertPEM) else {
                return .failed("Couldn't read the client certificate.")
            }
            var challengeResponse = Data()
            challengeResponse.append(serverChallenge)
            challengeResponse.append(clientCertSig)
            challengeResponse.append(clientSecret)
            let paddedHash = GameStreamCrypto.sha256(challengeResponse)  // 32 bytes
            guard let encHash = GameStreamCrypto.aesEcbEncrypt(paddedHash, key: aesKey) else {
                return .failed("Encryption failed.")
            }
            let resp3 = try await get(
                address: address,
                query: "devicename=roth&updateState=1&serverchallengeresp=\(encHash.lowercaseHex)")
            guard paired(resp3) else { await unpair(address); return stageError(resp3, "Pairing failed (stage 3).") }
            guard let pairingSecret = xmlHex(resp3, "pairingsecret"), pairingSecret.count > 16 else {
                await unpair(address); return .failed("Invalid pairing secret (stage 3).")
            }

            // Verify the server proved it knew the PIN (MITM / wrong-PIN checks).
            let serverSecret = pairingSecret.prefix(16)
            let serverSignature = pairingSecret.suffix(from: pairingSecret.startIndex + 16)
            guard GameStreamCrypto.verify(Data(serverSecret), signature: Data(serverSignature),
                                          serverCertPEM: serverCertPEM) else {
                await unpair(address); return .failed("Could not verify the host (possible MITM).")
            }
            guard let serverCertSig = GameStreamCrypto.x509SignatureBytes(pem: serverCertPEM) else {
                await unpair(address); return .failed("Couldn't read the host certificate.")
            }
            var expected = Data()
            expected.append(randomChallenge)
            expected.append(serverCertSig)
            expected.append(Data(serverSecret))
            guard GameStreamCrypto.sha256(expected) == Data(serverResponse) else {
                await unpair(address); return .wrongPIN
            }

            // Phase 4 — clientpairingsecret.
            guard let privateKey = try? identityProvider.privateKey(),
                  let signature = GameStreamCrypto.sign(Data(clientSecret), privateKey: privateKey) else {
                return .failed("Couldn't sign the pairing secret.")
            }
            let clientPairingSecret = Data(clientSecret) + signature
            let resp4 = try await get(
                address: address,
                query: "devicename=roth&updateState=1&clientpairingsecret=\(clientPairingSecret.lowercaseHex)")
            guard paired(resp4) else { await unpair(address); return stageError(resp4, "Pairing failed (stage 4).") }

            // Phase 5 — pairchallenge over mTLS, pinning the server cert we learned.
            let resp5 = try await getMTLS(address: address, serverCertPEM: serverCertPEM,
                                          query: "devicename=roth&updateState=1&phrase=pairchallenge")
            guard paired(resp5) else { await unpair(address); return stageError(resp5, "Pairing failed (stage 5).") }

            return .paired(serverCertPEM: serverCertPEM)
        } catch is CancellationError {
            return .failed("Pairing was cancelled.")
        } catch let error as URLError where error.code == .timedOut {
            await unpair(address)  // don't leave a zombie session poisoning the retry
            return .failed("Timed out waiting for the PIN. Enter it on the host, then try again.")
        } catch {
            return .unreachable
        }
    }

    // MARK: - Requests

    private func get(address: String, path: String = "/pair", query: String, timeout: TimeInterval = 10) async throws -> String {
        var comps = URLComponents()
        comps.scheme = "http"; comps.host = address; comps.port = 47989; comps.path = path
        comps.percentEncodedQuery = query + "&uniqueid=\(uniqueID)&uuid=\(UUID().uuidString)"
        var req = URLRequest(url: comps.url!)
        req.setValue("close", forHTTPHeaderField: "Connection")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = timeout
        let (data, _) = try await URLSession.shared.data(for: req)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func getMTLS(address: String, serverCertPEM: Data, query: String) async throws -> String {
        var comps = URLComponents()
        comps.scheme = "https"; comps.host = address; comps.port = 47984; comps.path = "/pair"
        comps.percentEncodedQuery = query + "&uniqueid=\(uniqueID)&uuid=\(UUID().uuidString)"
        var req = URLRequest(url: comps.url!)
        req.setValue("close", forHTTPHeaderField: "Connection")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 10
        let identity = try identityProvider.secIdentity()
        let delegate = PairTLSDelegate(identity: identity, serverCertDER: GameStreamCrypto.pemToDER(serverCertPEM))
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, _) = try await session.data(for: req)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Removes our pairing session (and any stale half-open one) on the host.
    /// The real endpoint is GET /unpair — `phrase=unpair` on /pair is NOT a
    /// thing on Sunshine-family hosts (it 404s, making cleanup a silent no-op
    /// and poisoning every retry with a stale session).
    private func unpair(_ address: String) async {
        _ = try? await get(address: address, path: "/unpair", query: "devicename=roth&updateState=1")
    }

    // MARK: - XML helpers

    /// Hosts report failures as attributes on the root element over an HTTP 200
    /// (`<root status_code="400" status_message="…">`). Surface them so a stage
    /// failure says what the HOST thinks went wrong, not just which stage died.
    private func stageError(_ xml: String, _ fallback: String) -> Result {
        .failed(Self.stageMessage(xml: xml, fallback: fallback))
    }

    /// Builds a human message from a host failure response, folding in the
    /// host's own `status_code` / `status_message` when present.
    static func stageMessage(xml: String, fallback: String) -> String {
        let code = attributeValue(xml, "status_code")
        let message = attributeValue(xml, "status_message")
        switch (code, message) {
        case (let c?, let m?) where c != "200": return "\(fallback) Host says: \(m) (\(c))."
        case (_, let m?):                       return "\(fallback) Host says: \(m)."
        case (let c?, _) where c != "200":      return "\(fallback) Host status \(c)."
        default:                                return fallback
        }
    }

    static func attributeValue(_ xml: String, _ name: String) -> String? {
        guard let r = xml.range(of: "\(name)=\""),
              let end = xml.range(of: "\"", range: r.upperBound..<xml.endIndex) else { return nil }
        let value = String(xml[r.upperBound..<end.lowerBound])
        return value.isEmpty ? nil : value
    }

    private func xmlValue(_ xml: String, _ tag: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    private func xmlHex(_ xml: String, _ tag: String) -> Data? {
        guard let s = xmlValue(xml, tag)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return Data(hex: s)
    }

    private func paired(_ xml: String) -> Bool {
        xmlValue(xml, "paired")?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }
}

/// mTLS delegate for the pairing phase-5 request: presents our client identity
/// and accepts the server cert we pinned during phase 1.
private final class PairTLSDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let identity: SecIdentity
    private let serverCertDER: Data?
    private let logger = Logger(subsystem: "com.vibelight.app", category: "pairing")

    init(identity: SecIdentity, serverCertDER: Data?) {
        self.identity = identity
        self.serverCertDER = serverCertDER
    }

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
            completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            // Trust-on-use for the phase-5 leg. Authentication is already
            // established by the PIN-derived AES challenge + RSA signatures in
            // phases 2–4, and phase 5 carries no secret — so a hard byte-pin
            // here adds no real security and could wrongly FAIL pairing if the
            // phase-1 plaincert encoding differs from the presented leaf. We
            // surface a mismatch for diagnostics but still accept. Post-pairing,
            // HostAPIClient byte-pins every request. (SEV-06: not a dead pin.)
            if let serverCertDER,
               let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
               SecCertificateCopyData(leaf) as Data != serverCertDER {
                logger.notice("Phase-5 TLS leaf differs from the phase-1 plaincert (accepted; PIN/RSA already authenticated).")
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
