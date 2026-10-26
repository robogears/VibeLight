import XCTest
@testable import VibeLight

/// The one security property that holds VibeLight's whole host-trust model up:
/// **a pinned session is never replaced by an unpinned one.**
///
/// Apple's transport security is fully disabled (GameStream certificates are
/// self-signed by design), so byte-pinning the server certificate on every
/// request IS the boundary. `session(for:)` caches one session per host keyed by
/// the pin, and rebuilds when the pin changes — which is correct for a re-pair,
/// but was also reachable with a *stale* host snapshot: a caller that captured a
/// `StreamHost` before pairing finished (a refresh that started pre-pair and
/// resumed after its first `await`) still carries `serverCertPEM == nil`, and
/// feeding that back in rebuilt the entry as trust-on-first-use and stored it.
///
/// Nothing in the app ever clears a pin back to nil — `savePairedHost` only ever
/// adds or replaces one — so an incoming nil against a stored pin can only mean
/// the caller is stale, and is now ignored.
final class PinDurabilityTests: XCTestCase {

    private var identityDir: URL!

    override func setUp() {
        identityDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vl-pin-identity-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let identityDir { try? FileManager.default.removeItem(at: identityDir) }
    }

    /// A throwaway identity, never the owner's real one. (audit
    /// QUA-macos-tests-boot-real-app)
    private func client() throws -> HostAPIClient {
        try TestHostAPIClient.make(in: identityDir)
    }

    /// A self-signed PEM to stand in for a real pinned host certificate.
    private func certPEM() throws -> Data {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vl-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cert = dir.appendingPathComponent("c.pem"), key = dir.appendingPathComponent("k.pem")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes",
                       "-keyout", key.path, "-out", cert.path,
                       "-days", "1", "-subj", "/CN=pin-test"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return try Data(contentsOf: cert)
    }

    private func host(id: String, pin: Data?) -> StreamHost {
        StreamHost(id: id, name: "Pin Test", localAddress: nil, localPort: 47989,
                   remoteAddress: nil, remotePort: 47989,
                   manualAddress: "127.0.0.1", manualPort: 47989,
                   macAddress: nil, serverCertPEM: pin, apps: [])
    }

    // MARK: - The property

    func testAStaleUnpinnedSnapshotCannotUnpinALiveSession() throws {
        let api = try client()
        let pem = try certPEM()

        // A paired host builds a PINNED session.
        let pinned = try api.warmSession(for: host(id: "h1", pin: pem))
        XCTAssertEqual(api.isSessionPinned(hostID: "h1"), true, "a paired host must build a pinned session")

        // Now a caller arrives holding the PRE-pairing copy of the same host.
        let afterStale = try api.warmSession(for: host(id: "h1", pin: nil))
        XCTAssertEqual(api.isSessionPinned(hostID: "h1"), true,
                       "a stale unpinned snapshot must NOT replace the pinned session")
        XCTAssertTrue(afterStale === pinned, "the stale caller must be handed the existing pinned session")
    }

    func testAnUnpairedHostStillGetsItsTrustOnFirstUseSession() throws {
        // The guard must not break the legitimate never-paired case: a host with
        // no pin has nothing to protect, and needs a session to reach the XML
        // 401 that prompts pairing in the first place.
        let api = try client()
        _ = try? api.warmSession(for: host(id: "h2", pin: nil))
        XCTAssertEqual(api.isSessionPinned(hostID: "h2"), false,
                       "a never-paired host still needs its unpinned session")
    }

    func testRePairingWithADifferentCertificateStillRebuilds() throws {
        // The guard blocks nil-over-pin only. A genuinely NEW pin (re-pair after
        // the host's streaming software was reinstalled) must still replace the
        // old session, or the app would keep rejecting a host it just re-paired.
        let api = try client()
        let first = try certPEM(), second = try certPEM()
        XCTAssertNotEqual(first, second, "fixture sanity: two distinct certs")

        let original = try api.warmSession(for: host(id: "h3", pin: first))
        XCTAssertTrue(try api.warmSession(for: host(id: "h3", pin: first)) === original,
                      "fixture sanity: the same pin reuses the cached session")
        // Compare the sessions themselves: "pinned before and after" also holds
        // when the old session — trusting the OLD certificate — is wrongly kept,
        // so it could not catch the regression this test is named after.
        // (audit QUA-pin-rebuild-test-cannot-fail)
        let rePaired = try api.warmSession(for: host(id: "h3", pin: second))
        XCTAssertFalse(rePaired === original,
                       "a re-pair with a new certificate must replace the session that trusts the old one")
        XCTAssertEqual(api.isSessionPinned(hostID: "h3"), true,
                       "a re-pair must still produce a pinned session")
    }

    func testAnUnparseablePinFailsClosed() throws {
        // A stored pin that isn't valid PEM must throw, never silently downgrade
        // to accept-anything.
        let api = try client()
        XCTAssertThrowsError(try api.warmSession(for: host(id: "h4", pin: Data("not a pem".utf8)))) { error in
            XCTAssertTrue("\(error)".contains("not valid PEM"), "unexpected error: \(error)")
        }
        XCTAssertNil(api.isSessionPinned(hostID: "h4"), "a failed build must not cache anything")
    }
}
