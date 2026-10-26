#if os(iOS)
import XCTest
import Security
@testable import VibeLight

/// Runtime verification (iOS simulator) that the born-in-keychain client
/// identity actually assembles into a usable `SecIdentity` and signs — the exact
/// crypto path behind iOS pairing / mTLS, which can't run on the macOS test host
/// (`IOSKeychainIdentity` is `#if os(iOS)`). Probe-proven on macOS-adhoc; this
/// pins it down on-simulator.
///
/// The test bundle runs INSIDE the real app on the simulator, so every keychain
/// call here uses a test-only namespace, unique per test and deleted in
/// tearDown — never `.production`, which holds the simulator's real paired
/// identity. (audit DAT-simulator-identity-reset)
final class IOSIdentityTests: XCTestCase {

    private var ns: IOSKeychainIdentity.Namespace!

    override func setUp() {
        let id = UUID().uuidString
        ns = .init(keyTag: Data("com.vibelight.tests.identity.key.\(id)".utf8),
                   certLabel: "VibeLight Test Identity \(id)")
        XCTAssertNotEqual(ns, .production)
    }

    override func tearDown() {
        IOSKeychainIdentity.deleteAll(in: ns)
    }

    /// Every installed copy's identity is filed under these; a changed value
    /// reads as "no identity" and unpairs every computer.
    func testProductionNamespaceIsUnchanged() {
        XCTAssertEqual(IOSKeychainIdentity.Namespace.production.keyTag,
                       Data("com.vibelight.client.identity.key".utf8))
        XCTAssertEqual(IOSKeychainIdentity.Namespace.production.certLabel, "VibeLight Client Identity")
    }

    func testBornInKeychainIdentityAssemblesAndSigns() throws {
        // 1. Generate: SecKeyCreateRandomKey (permanent) + swift-certificates cert.
        let pems = try XCTUnwrap(IOSKeychainIdentity.generatePEMs(in: ns),
                                 "generatePEMs should mint a born-in-keychain identity")
        let certPEM = try XCTUnwrap(String(data: pems.cert, encoding: .utf8))
        XCTAssertTrue(certPEM.contains("BEGIN CERTIFICATE"), "cert PEM should be well-formed")

        // 2. Assemble the SecIdentity from the keychain (key + cert must link).
        let identity = try XCTUnwrap(IOSKeychainIdentity.assembleIdentity(in: ns),
                                     "SecIdentity should assemble from the born-in-keychain key + cert")

        // 3. The private key signs (this is what HostPairing does over mTLS).
        var key: SecKey?
        XCTAssertEqual(SecIdentityCopyPrivateKey(identity, &key), errSecSuccess)
        let privateKey = try XCTUnwrap(key)
        var error: Unmanaged<CFError>?
        let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                              Data("vibelight".utf8) as CFData, &error)
        let sig = try XCTUnwrap(signature as Data?, "RSA signing should succeed")
        XCTAssertEqual(sig.count, 256, "an RSA-2048 signature is 256 bytes")

        // 4. The cert parses via Security.framework with the expected identity.
        let der = try XCTUnwrap(Data(base64Encoded:
            certPEM.split(separator: "\n").filter { !$0.contains("-----") }.joined()))
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        var cn: CFString?
        SecCertificateCopyCommonName(cert, &cn)
        XCTAssertEqual(cn as String?, "NVIDIA GameStream Client")

        // 5. Idempotency: a second load finds the SAME identity (stable across launches).
        guard case .found(let reloadedCert, _) = IOSKeychainIdentity.loadPEMs(in: ns) else {
            return XCTFail("loadPEMs should report .found for the identity created above")
        }
        XCTAssertEqual(reloadedCert, pems.cert, "the cached identity should be stable")
    }

    // MARK: - The destroy-guard

    /// The safety property: a keychain that cannot answer must never be read as
    /// "there is no identity", because the caller's response to `.absent` is
    /// `generatePEMs()`, which begins with `deleteAll()`. Getting this backwards
    /// wipes a working, host-trusted identity and unpairs every computer.
    func testOnlyAnExplicitNotFoundIsTreatedAsAbsent() {
        typealias K = IOSKeychainIdentity

        // Both halves present -> use it.
        XCTAssertEqual(K.classify(certStatus: errSecSuccess, keyStatus: errSecSuccess),
                       .found(cert: Data(), key: Data()))

        // Both halves positively absent -> first run, safe to generate.
        XCTAssertEqual(K.classify(certStatus: errSecItemNotFound, keyStatus: errSecItemNotFound),
                       .absent)

        // ONE half answered, the other said not-found. This is the subtle one:
        // the keychain OMITS items whose protection class is unavailable from a
        // search rather than reporting errSecInteractionNotAllowed, so on a
        // locked device a perfectly real item reads as "not found". Before the
        // accessibility fix the cert was WhenUnlocked while the key was
        // AfterFirstUnlock, which produces exactly this shape — and treating it
        // as absent would deleteAll a live, host-trusted key.
        //
        // So a half-answer is only "absent" on a device we can PROVE is
        // unlocked; otherwise it must be unavailable.
        XCTAssertEqual(K.classify(certStatus: errSecSuccess, keyStatus: errSecItemNotFound,
                                  deviceUnlocked: true), .absent)
        XCTAssertEqual(K.classify(certStatus: errSecItemNotFound, keyStatus: errSecSuccess,
                                  deviceUnlocked: true), .absent)
        XCTAssertEqual(K.classify(certStatus: errSecSuccess, keyStatus: errSecItemNotFound,
                                  deviceUnlocked: false), .unavailable(errSecInteractionNotAllowed))
        XCTAssertEqual(K.classify(certStatus: errSecItemNotFound, keyStatus: errSecSuccess,
                                  deviceUnlocked: false), .unavailable(errSecInteractionNotAllowed))

        // Both-not-found stays absent regardless of lock state: there is nothing
        // to protect, so a first run on a locked device still gets an identity.
        XCTAssertEqual(K.classify(certStatus: errSecItemNotFound, keyStatus: errSecItemNotFound,
                                  deviceUnlocked: false), .absent)

        // The probe itself must work on a real (unlocked) device/simulator,
        // otherwise the half-answer path would never resolve to .absent.
        XCTAssertTrue(K.isDeviceUnlocked(),
                      "a running simulator/device is unlocked; the probe must say so")

        // Anything the keychain says OTHER than not-found must be unavailable.
        // errSecInteractionNotAllowed is the one that bit us: a launch before
        // the first unlock after a reboot.
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable,
                       errSecMissingEntitlement, errSecInvalidKeychain, OSStatus(-99999)] {
            XCTAssertEqual(K.classify(certStatus: status, keyStatus: errSecSuccess),
                           .unavailable(status), "cert status \(status) must not read as absent")
            XCTAssertEqual(K.classify(certStatus: errSecSuccess, keyStatus: status),
                           .unavailable(status), "key status \(status) must not read as absent")
            // Even mixed with a genuine not-found, "cannot tell" wins.
            XCTAssertEqual(K.classify(certStatus: errSecItemNotFound, keyStatus: status),
                           .unavailable(status), "not-found + \(status) must not read as absent")
        }
    }

    /// End to end on the simulator: mint an identity, then drive the code that
    /// decides whether to generate — `IdentityStore.resolveFromKeychain` — with
    /// a keychain that answers "unavailable". Its generate step is the REAL
    /// destructive generator (in this test's namespace), so if resolve ever
    /// generated on `.unavailable`, the identity would be replaced and this
    /// fails. (audit QUA-ios-unavailable-test-cannot-fail)
    func testUnavailableLookupDoesNotDestroyTheIdentity() throws {
        let pems = try XCTUnwrap(IOSKeychainIdentity.generatePEMs(in: ns))
        let ns = self.ns!
        var generateCalls = 0

        let resolved = IdentityStore.resolveFromKeychain(
            uniqueID: "test",
            lookup: { .unavailable(errSecInteractionNotAllowed) },
            generate: { generateCalls += 1; return IOSKeychainIdentity.generatePEMs(in: ns) })

        XCTAssertEqual(generateCalls, 0, "a keychain that can't answer must never lead to generation")
        XCTAssertTrue(resolved.certificatePEM.isEmpty, "unavailable resolves to an empty identity")

        // The identity is still there, byte for byte, and still assembles.
        guard case .found(let cert, _) = IOSKeychainIdentity.loadPEMs(in: ns) else {
            return XCTFail("the identity must survive an unavailable lookup")
        }
        XCTAssertEqual(cert, pems.cert)
        XCTAssertNotNil(IOSKeychainIdentity.assembleIdentity(in: ns))
    }

    /// The other two branches, so the test above can't pass by resolve simply
    /// never generating at all.
    func testResolveGeneratesOnlyWhenAbsentAndUsesWhatItFinds() {
        var generateCalls = 0
        let minted = (cert: Data("NEW".utf8), key: Data())

        let fresh = IdentityStore.resolveFromKeychain(
            uniqueID: "test", lookup: { .absent },
            generate: { generateCalls += 1; return minted })
        XCTAssertEqual(generateCalls, 1)
        XCTAssertEqual(fresh.certificatePEM, minted.cert)

        let existing = IdentityStore.resolveFromKeychain(
            uniqueID: "test", lookup: { .found(cert: Data("OLD".utf8), key: Data()) },
            generate: { generateCalls += 1; return minted })
        XCTAssertEqual(generateCalls, 1, "a found identity is used, never regenerated")
        XCTAssertEqual(existing.certificatePEM, Data("OLD".utf8))
    }
}
#endif
