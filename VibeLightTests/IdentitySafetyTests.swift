import XCTest
@testable import VibeLight

/// The client identity (key + certificate) is what every paired PC trusts, so
/// losing it unpairs every computer. These pin the rule that a read which merely
/// FAILS is never treated as "no identity", and that pairing settles the
/// certificate before the PC asks for a PIN.
///
/// Every test works in its own temporary folder or with an in-memory identity —
/// never the app's real Application Support identity.
final class IdentitySafetyTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vl-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Restore permissions first, or the folder can't be removed.
        if let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for name in items {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: dir.appendingPathComponent(name).path)
            }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    private var certURL: URL { dir.appendingPathComponent("client.pem") }
    private var keyURL: URL { dir.appendingPathComponent("client.key") }

    // MARK: - The pure rule (audit FS-identity-read-loss)

    func testOnlyTwoAbsentFilesMayGenerate() {
        typealias S = IdentityStore
        let c = Data("CERT".utf8), k = Data("KEY".utf8)

        XCTAssertEqual(S.plan(cert: .contents(c), key: .contents(k)), .use(cert: c, key: k))

        // Nothing there on either side (zero bytes holds nothing): generate.
        XCTAssertEqual(S.plan(cert: .missing, key: .missing), .generate)
        XCTAssertEqual(S.plan(cert: .missing, key: .empty), .generate,
                       "old builds left an empty client.key after a failed first launch")
        XCTAssertEqual(S.plan(cert: .empty, key: .missing), .generate)
        XCTAssertEqual(S.plan(cert: .empty, key: .empty), .generate)

        // Anything that might be a real identity is refused, never replaced.
        let refusals: [(IdentityStore.OwnIdentityFile, IdentityStore.OwnIdentityFile)] = [
            (.unreadable("client.pem: no permission"), .contents(k)),
            (.contents(c), .unreadable("client.key: I/O error")),
            (.unreadable("a"), .missing),
            (.missing, .unreadable("b")),
            (.unreadable("a"), .unreadable("b")),
            (.missing, .contents(k)),      // the key every PC trusts, cert lost
            (.contents(c), .missing),
            (.empty, .contents(k)),
            (.contents(c), .empty),
        ]
        for (cert, key) in refusals {
            guard case .refuse(let message) = S.plan(cert: cert, key: key) else {
                return XCTFail("\(cert) + \(key) must be refused, not replaced")
            }
            XCTAssertTrue(message.contains("reopen VibeLight"), "the message must say how to recover")
        }
    }

    func testAFileReadErrorIsNotAMissingFile() throws {
        XCTAssertEqual(IdentityStore.readIdentityFile(at: certURL), .missing)

        try Data().write(to: certURL)
        XCTAssertEqual(IdentityStore.readIdentityFile(at: certURL), .empty)

        try Data("PEM".utf8).write(to: certURL)
        XCTAssertEqual(IdentityStore.readIdentityFile(at: certURL), .contents(Data("PEM".utf8)))

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: certURL.path)
        guard case .unreadable(let why) = IdentityStore.readIdentityFile(at: certURL) else {
            return XCTFail("a file that exists but can't be read must not read as missing")
        }
        XCTAssertTrue(why.contains("client.pem"))

        // A folder where the file should be is not "missing" either.
        let folder = dir.appendingPathComponent("client.key", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        guard case .unreadable = IdentityStore.readIdentityFile(at: folder) else {
            return XCTFail("an unreadable path must not read as missing")
        }
    }

    // MARK: - The store never destroys an identity it couldn't read

    func testAnUnreadableCertificateLeavesTheKeyAndCertificateUntouched() throws {
        let key = Data("-----BEGIN PRIVATE KEY-----\nthe key every PC trusts\n".utf8)
        let cert = Data("-----BEGIN CERTIFICATE-----\nreal\n".utf8)
        try key.write(to: keyURL)
        try cert.write(to: certURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: certURL.path)

        guard case .problem(let message) = IdentityStore.loadOrCreateOwn(in: dir) else {
            return XCTFail("an unreadable certificate must be reported, not replaced")
        }
        XCTAssertTrue(message.contains("client.pem"), message)

        // Both files are exactly as they were.
        XCTAssertEqual(try Data(contentsOf: keyURL), key, "the private key must survive")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: certURL.path)
        XCTAssertEqual(try Data(contentsOf: certURL), cert, "the certificate must survive")
    }

    func testAKeyWithoutItsCertificateIsKeptAndReported() throws {
        let key = Data("-----BEGIN PRIVATE KEY-----\nlone key\n".utf8)
        try key.write(to: keyURL)

        guard case .problem = IdentityStore.loadOrCreateOwn(in: dir) else {
            return XCTFail("half an identity must be reported, not regenerated")
        }
        XCTAssertEqual(try Data(contentsOf: keyURL), key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: certURL.path),
                       "no certificate may be minted beside a key it doesn't belong to")
    }

    // MARK: - Creation is all-or-nothing

    func testAFailedCreationLeavesNoFilesBehind() throws {
        // /usr/bin/false stands in for an openssl that fails.
        guard case .problem = IdentityStore.loadOrCreateOwn(
            in: dir, openssl: URL(fileURLWithPath: "/usr/bin/false")) else {
            return XCTFail("a failed creation must be reported")
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(left, [], "a failed creation must leave neither half (nor its staging folder)")
    }

    func testCreationInstallsAMatchingPairWithAPrivateKey() throws {
        // The empty client.key an older build left behind is replaced.
        FileManager.default.createFile(atPath: keyURL.path, contents: nil)

        guard case .ready(let cert, let key) = IdentityStore.loadOrCreateOwn(in: dir) else {
            return XCTFail("a fresh folder must get an identity")
        }
        XCTAssertEqual(try Data(contentsOf: certURL), cert)
        XCTAssertEqual(try Data(contentsOf: keyURL), key)
        let mode = try FileManager.default.attributesOfItem(atPath: keyURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "the private key must never be group/other readable")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       ["client.key", "client.pem"], "no staging folder may be left behind")

        // And the next launch simply uses it.
        XCTAssertEqual(IdentityStore.loadOrCreateOwn(in: dir), .ready(cert: cert, key: key))
    }

    // MARK: - Interrupted creation (audit FS-identity-read-loss review)

    /// A real matching pair made by the production code in a throwaway folder.
    private func makePair() throws -> (cert: Data, key: Data) {
        let source = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vl-identity-src-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: source) }
        guard case .ready(let cert, let key) = IdentityStore.loadOrCreateOwn(in: source) else {
            throw XCTSkip("openssl could not create a test identity")
        }
        return (cert, key)
    }

    private func stagingFolder() throws -> URL {
        let folder = dir.appendingPathComponent(".new-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    /// Killed between moving the key and moving the certificate: the next
    /// launch finishes the move instead of refusing forever.
    func testACreationCutOffBetweenTheTwoMovesIsFinished() throws {
        let pair = try makePair()
        try pair.key.write(to: keyURL)
        try pair.cert.write(to: try stagingFolder().appendingPathComponent("client.pem"))

        XCTAssertEqual(IdentityStore.loadOrCreateOwn(in: dir), .ready(cert: pair.cert, key: pair.key))
        XCTAssertEqual(try Data(contentsOf: certURL), pair.cert)
        XCTAssertEqual(try Data(contentsOf: keyURL), pair.key)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       ["client.key", "client.pem"])
    }

    /// A staged certificate that belongs to a different key is never put
    /// beside the real one: still refused, nothing changed or removed.
    func testAStagedCertificateForAnotherKeyIsNotUsed() throws {
        let real = try makePair(), other = try makePair()
        try real.key.write(to: keyURL)
        let folder = try stagingFolder()
        try other.cert.write(to: folder.appendingPathComponent("client.pem"))

        guard case .problem = IdentityStore.loadOrCreateOwn(in: dir) else {
            return XCTFail("a certificate for another key must not complete the identity")
        }
        XCTAssertEqual(try Data(contentsOf: keyURL), real.key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: certURL.path))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("client.pem")), other.cert,
                       "nothing is cleaned up while the identity is incomplete")
    }

    /// Killed while openssl ran: the staging folder (with an unused private
    /// key) is removed once an identity is in place; folders this code didn't
    /// make are left alone.
    func testLeftoverStagingFoldersAreRemovedOnceTheIdentityIsComplete() throws {
        let orphan = try stagingFolder()
        try Data("unused private key".utf8).write(to: orphan.appendingPathComponent("client.key"))
        let notOurs = dir.appendingPathComponent(".new-notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notOurs, withIntermediateDirectories: false)

        guard case .ready = IdentityStore.loadOrCreateOwn(in: dir) else {
            return XCTFail("a fresh folder must get an identity")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       [".new-notes", "client.key", "client.pem"])
    }

    // MARK: - What the person is told

    /// The refusal names the file once, gives a short reason rather than
    /// Foundation's own sentence, and spells out the hidden folder in full.
    /// (audit FS-identity-read-loss review: refusal copy)
    func testARefusalSaysWhichFileWhyAndWhereInPlainWords() throws {
        try Data("CERT".utf8).write(to: certURL)
        try FileManager.default.createDirectory(at: keyURL, withIntermediateDirectories: false)

        guard case .problem(let message) = IdentityStore.loadOrCreateOwn(in: dir) else {
            return XCTFail("a folder where the key should be must be refused")
        }
        XCTAssertTrue(message.contains("~/Library/Application Support/VibeLight/identity"), message)
        XCTAssertEqual(message.components(separatedBy: "client.key").count - 1, 1, message)
        XCTAssertTrue(message.contains("folder, not a file"), message)
        XCTAssertFalse(message.contains(".)"), message)

        guard case .refuse(let lost) = IdentityStore.plan(cert: .missing, key: .contents(Data("K".utf8))) else {
            return XCTFail("half an identity must be refused")
        }
        XCTAssertTrue(lost.contains("client.pem is missing"), lost)
        XCTAssertTrue(lost.contains("~/Library/Application Support/VibeLight/identity"), lost)
    }

    #if os(macOS)
    func testConnectionsReportTheLaunchProblemInsteadOfAnOpensslError() {
        let provider = ClientIdentityProvider(
            identity: ClientIdentity(certificatePEM: Data(), privateKeyPEM: Data(), uniqueID: "test"),
            identityProblem: "VibeLight can't read its identity file (x).")
        XCTAssertThrowsError(try provider.secIdentity()) { error in
            XCTAssertEqual(error.localizedDescription, "VibeLight can't read its identity file (x).")
        }
    }
    #endif

    // MARK: - Pairing reads the certificate when it starts (audit ERR-ios-pairing-empty-cert-snapshot)

    private final class Calls: @unchecked Sendable { var count = 0 }

    private func emptyProvider(_ reload: @escaping @Sendable () throws -> Data) -> ClientIdentityProvider {
        ClientIdentityProvider(
            identity: ClientIdentity(certificatePEM: Data(), privateKeyPEM: Data(), uniqueID: "test"),
            supportDirectory: dir, identityProblem: nil, reloadCertificate: reload)
    }

    /// iOS: launched before the first unlock, the identity came back empty. The
    /// first pairing (still locked) must say so; once the keychain answers, the
    /// next pairing must get the real certificate without a relaunch — and keep
    /// it, rather than asking the keychain again every time.
    func testAnEmptyLaunchCertificateIsReReadWhenPairingStarts() throws {
        let calls = Calls()
        let cert = Data("-----BEGIN CERTIFICATE-----\nreal\n".utf8)
        let provider = emptyProvider {
            calls.count += 1
            if calls.count == 1 { throw ClientIdentityProvider.IdentityError.unavailable("locked") }
            return cert
        }

        XCTAssertThrowsError(try provider.pairingCertificatePEM()) { error in
            XCTAssertEqual(error.localizedDescription, "locked")
        }
        XCTAssertEqual(try provider.pairingCertificatePEM(), cert, "an unlock must be picked up without a relaunch")
        XCTAssertEqual(try provider.pairingCertificatePEM(), cert)
        XCTAssertEqual(calls.count, 2, "a certificate once found is kept")

        // A re-read that comes back empty is still "no certificate", never sent.
        XCTAssertThrowsError(try emptyProvider { Data() }.pairingCertificatePEM())
    }

    func testALaunchCertificateIsUsedAsIs() throws {
        let calls = Calls()
        let cert = Data("CERT".utf8)
        let provider = ClientIdentityProvider(
            identity: ClientIdentity(certificatePEM: cert, privateKeyPEM: Data("KEY".utf8), uniqueID: "test"),
            supportDirectory: dir, reloadCertificate: { calls.count += 1; return Data() })
        XCTAssertEqual(try provider.pairingCertificatePEM(), cert)
        XCTAssertEqual(calls.count, 0)
    }

    #if os(macOS)
    func testMacPairingWithoutAnIdentityReportsTheLaunchProblem() {
        let provider = ClientIdentityProvider(
            identity: ClientIdentity(certificatePEM: Data(), privateKeyPEM: Data(), uniqueID: "test"),
            supportDirectory: dir, identityProblem: "VibeLight can't read its identity file (x).")
        XCTAssertThrowsError(try provider.pairingCertificatePEM()) { error in
            XCTAssertEqual(error.localizedDescription, "VibeLight can't read its identity file (x).")
        }
    }
    #endif

    /// Without a certificate, pairing stops BEFORE phase 1 — the request that
    /// makes the PC ask for a PIN. The address is deliberately not a valid host
    /// name: any network attempt fails instantly as `.unreachable`, so getting
    /// the identity message back proves nothing was sent.
    func testPairingWithoutACertificateStopsBeforeThePCAsksForAPIN() async {
        let provider = emptyProvider {
            throw ClientIdentityProvider.IdentityError.unavailable("Unlock it, then try pairing again.")
        }
        let result = await HostPairing(identityProvider: provider, uniqueID: "test")
            .pair(address: "not a host", pin: "1234")
        XCTAssertEqual(result, .failed("Unlock it, then try pairing again."))
    }
}
