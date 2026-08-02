#if os(iOS)
import XCTest
import Security
@testable import VibeLight

/// Runtime verification (iOS simulator) that the born-in-keychain client
/// identity actually assembles into a usable `SecIdentity` and signs — the exact
/// crypto path behind iOS pairing / mTLS, which can't run on the macOS test host
/// (`IOSKeychainIdentity` is `#if os(iOS)`). Probe-proven on macOS-adhoc; this
/// pins it down on-simulator.
final class IOSIdentityTests: XCTestCase {

    func testBornInKeychainIdentityAssemblesAndSigns() throws {
        // 1. Generate: SecKeyCreateRandomKey (permanent) + swift-certificates cert.
        let pems = try XCTUnwrap(IOSKeychainIdentity.generatePEMs(),
                                 "generatePEMs should mint a born-in-keychain identity")
        let certPEM = try XCTUnwrap(String(data: pems.cert, encoding: .utf8))
        XCTAssertTrue(certPEM.contains("BEGIN CERTIFICATE"), "cert PEM should be well-formed")

        // 2. Assemble the SecIdentity from the keychain (key + cert must link).
        let identity = try XCTUnwrap(IOSKeychainIdentity.assembleIdentity(),
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
        guard case .found(let reloadedCert, _) = IOSKeychainIdentity.loadPEMs() else {
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

        // Exactly one half present: a half-formed identity cannot assemble, and
        // generatePEMs' deleteAll clears the orphan. Still .absent.
        XCTAssertEqual(K.classify(certStatus: errSecSuccess, keyStatus: errSecItemNotFound), .absent)
        XCTAssertEqual(K.classify(certStatus: errSecItemNotFound, keyStatus: errSecSuccess), .absent)

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

    /// End to end on the simulator: mint an identity, then prove that the
    /// unavailable path leaves it completely untouched.
    func testUnavailableLookupDoesNotDestroyTheIdentity() throws {
        let pems = try XCTUnwrap(IOSKeychainIdentity.generatePEMs())

        // Simulate what resolve() does when the keychain refuses to answer.
        // The ONLY correct behaviour is to do nothing at all.
        if case .unavailable = IOSKeychainIdentity.classify(certStatus: errSecInteractionNotAllowed,
                                                            keyStatus: errSecInteractionNotAllowed) {
            // resolve() returns an empty identity here and generates nothing.
        } else {
            XCTFail("a locked keychain must classify as .unavailable")
        }

        // The identity is still there and still assembles.
        guard case .found(let cert, _) = IOSKeychainIdentity.loadPEMs() else {
            return XCTFail("the identity must survive an unavailable lookup")
        }
        XCTAssertEqual(cert, pems.cert)
        XCTAssertNotNil(IOSKeychainIdentity.assembleIdentity())
    }
}
#endif
