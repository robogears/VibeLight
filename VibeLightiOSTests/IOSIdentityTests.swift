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
        let reloaded = try XCTUnwrap(IOSKeychainIdentity.loadPEMs(),
                                     "loadPEMs should find the identity created above")
        XCTAssertEqual(reloaded.cert, pems.cert, "the cached identity should be stable")
    }
}
#endif
