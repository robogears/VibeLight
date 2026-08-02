import XCTest
import Security
@testable import VibeLight

/// `GameStreamCrypto.verify` is the signature check inside pairing — the step
/// that proves the host holds the private key for the certificate we are about
/// to pin, and therefore the step that decides whether an impostor on the same
/// address gets pinned as your PC. Every neighbouring primitive had coverage;
/// this one had none.
///
/// A real RSA keypair + self-signed cert is minted per run, so these exercise
/// Security.framework end to end rather than a stub.
final class GameStreamCryptoVerifyTests: XCTestCase {

    private var privateKey: SecKey!
    private var certPEM: Data!

    override func setUpWithError() throws {
        (privateKey, certPEM) = try Self.makeIdentity(commonName: "GameStream Test Host")
    }

    // MARK: - The property that matters

    func testAGenuineSignatureVerifies() throws {
        let message = Data("challenge-from-the-client".utf8)
        let signature = try XCTUnwrap(GameStreamCrypto.sign(message, privateKey: privateKey))
        XCTAssertTrue(GameStreamCrypto.verify(message, signature: signature, serverCertPEM: certPEM))
    }

    func testASignatureFromADifferentKeyIsRejected() throws {
        // The impostor case: right message, valid signature, wrong signer.
        let (_, otherCertPEM) = try Self.makeIdentity(commonName: "Someone Else")
        let message = Data("challenge-from-the-client".utf8)
        let signature = try XCTUnwrap(GameStreamCrypto.sign(message, privateKey: privateKey))
        XCTAssertFalse(GameStreamCrypto.verify(message, signature: signature,
                                               serverCertPEM: otherCertPEM),
                       "a signature must not verify against an unrelated certificate")
    }

    func testATamperedMessageIsRejected() throws {
        let signature = try XCTUnwrap(GameStreamCrypto.sign(Data("original".utf8), privateKey: privateKey))
        XCTAssertFalse(GameStreamCrypto.verify(Data("modified".utf8), signature: signature,
                                               serverCertPEM: certPEM))
    }

    func testATamperedSignatureIsRejected() throws {
        let message = Data("challenge".utf8)
        var signature = try XCTUnwrap(GameStreamCrypto.sign(message, privateKey: privateKey))
        signature[0] ^= 0xFF
        XCTAssertFalse(GameStreamCrypto.verify(message, signature: signature, serverCertPEM: certPEM))
    }

    // MARK: - Malformed input must return false, never crash

    func testGarbageInputsAreRejectedNotCrashed() throws {
        let message = Data("challenge".utf8)
        let signature = try XCTUnwrap(GameStreamCrypto.sign(message, privateKey: privateKey))

        XCTAssertFalse(GameStreamCrypto.verify(message, signature: Data(), serverCertPEM: certPEM),
                       "empty signature")
        XCTAssertFalse(GameStreamCrypto.verify(Data(), signature: signature, serverCertPEM: certPEM),
                       "empty message")
        XCTAssertFalse(GameStreamCrypto.verify(message, signature: signature, serverCertPEM: Data()),
                       "empty cert")
        XCTAssertFalse(GameStreamCrypto.verify(message, signature: signature,
                                               serverCertPEM: Data("not a pem at all".utf8)),
                       "non-PEM cert")
        XCTAssertFalse(GameStreamCrypto.verify(
            message, signature: signature,
            serverCertPEM: Data("-----BEGIN CERTIFICATE-----\nZm9v\n-----END CERTIFICATE-----\n".utf8)),
                       "well-framed PEM wrapping non-certificate bytes")
        XCTAssertFalse(GameStreamCrypto.verify(message, signature: Data(repeating: 0, count: 256),
                                               serverCertPEM: certPEM),
                       "all-zero signature of the right length")
    }

    // MARK: - Fixture

    /// Mints an RSA-2048 key and a self-signed cert over it, returning the key
    /// and the cert as PEM (the shape `verify` consumes).
    private static func makeIdentity(commonName: String) throws -> (SecKey, Data) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vl-crypto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let keyURL = dir.appendingPathComponent("key.pem")
        let certURL = dir.appendingPathComponent("cert.pem")
        let openssl = Process()
        openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        openssl.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes",
                            "-keyout", keyURL.path, "-out", certURL.path,
                            "-days", "1", "-subj", "/CN=\(commonName)"]
        openssl.standardOutput = Pipe(); openssl.standardError = Pipe()
        try openssl.run()
        openssl.waitUntilExit()

        let certPEM = try Data(contentsOf: certURL)
        let keyPEM = try String(contentsOf: keyURL, encoding: .utf8)
        let base64 = keyPEM.split(separator: "\n").filter { !$0.contains("-----") }.joined()
        let keyDER = try XCTUnwrap(Data(base64Encoded: base64))

        // openssl writes PKCS#8; SecKeyCreateWithData wants PKCS#1, so strip the
        // 26-byte PrivateKeyInfo prefix that precedes the RSAPrivateKey.
        let pkcs1 = keyDER.dropFirst(26)
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(pkcs1 as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 2048,
        ] as CFDictionary, &error)
        return (try XCTUnwrap(key, "could not load the test private key"), certPEM)
    }
}
