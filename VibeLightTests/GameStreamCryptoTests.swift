import XCTest
@testable import VibeLight

/// The pairing crypto gates whether we can talk to a host at all — verify the
/// primitives against known vectors before trusting the handshake.
final class GameStreamCryptoTests: XCTestCase {

    // MARK: Hex

    func testHexRoundTrip() {
        let data = Data([0x00, 0x1f, 0xab, 0xff, 0x10])
        XCTAssertEqual(data.lowercaseHex, "001fabff10")
        XCTAssertEqual(Data(hex: "001fabff10"), data)
        XCTAssertNil(Data(hex: "abc"))   // odd length
        XCTAssertNil(Data(hex: "zz"))    // non-hex
    }

    // MARK: AES-128-ECB (NIST FIPS-197 appendix test vector)

    func testAES128ECBKnownVector() {
        // FIPS-197 example: key 000102…0f, plaintext 00112233…ff →
        // ciphertext 69c4e0d86a7b0430d8cdb78070b4c55a.
        let key = Data(hex: "000102030405060708090a0b0c0d0e0f")!
        let plaintext = Data(hex: "00112233445566778899aabbccddeeff")!
        let expected = Data(hex: "69c4e0d86a7b0430d8cdb78070b4c55a")!

        let ct = GameStreamCrypto.aesEcbEncrypt(plaintext, key: key)
        XCTAssertEqual(ct, expected)
        // And it round-trips (no padding).
        XCTAssertEqual(GameStreamCrypto.aesEcbDecrypt(ct!, key: key), plaintext)
    }

    func testAESHandlesMultiBlock() {
        let key = GameStreamCrypto.randomBytes(16)
        let plaintext = GameStreamCrypto.randomBytes(48)  // 3 blocks, as in pairing
        let ct = GameStreamCrypto.aesEcbEncrypt(plaintext, key: key)
        XCTAssertEqual(ct?.count, 48)
        XCTAssertEqual(GameStreamCrypto.aesEcbDecrypt(ct!, key: key), plaintext)
    }

    // MARK: SHA-256 (NIST FIPS 180-2 published vectors)

    /// Fixed published digests, not CryptoKit's answer for the same input:
    /// `sha256` IS CryptoKit today, so comparing the two could never fail. A
    /// fixed value catches a swap to a truncated or hand-rolled hash, which
    /// would silently break the PIN-derived pairing key.
    /// (audit QUA-sha256-test-tautology)
    func testSHA256MatchesPublishedVectors() {
        XCTAssertEqual(GameStreamCrypto.sha256(Data("abc".utf8)).lowercaseHex,
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(GameStreamCrypto.sha256(Data()).lowercaseHex,
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // Two blocks: catches an implementation that only gets one block right.
        XCTAssertEqual(
            GameStreamCrypto.sha256(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)).lowercaseHex,
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    // MARK: X.509 signature extraction

    func testExtractSignatureFromSelfSignedCert() throws {
        // A self-signed RSA-SHA256 cert (generated once for this test).
        let pem = Self.sampleCertPEM.data(using: .utf8)!
        let sig = GameStreamCrypto.x509SignatureBytes(pem: pem)
        XCTAssertNotNil(sig)
        // An RSA-2048 signature is exactly 256 bytes.
        XCTAssertEqual(sig?.count, 256)
    }

    func testExtractSignatureRejectsGarbage() {
        XCTAssertNil(GameStreamCrypto.x509SignatureBytes(pem: Data("not a cert".utf8)))
    }

    // A throwaway self-signed RSA-2048 cert, CN=Test Cert (openssl req -x509).
    static let sampleCertPEM = """
-----BEGIN CERTIFICATE-----
MIICpDCCAYwCCQCvKSPgHK8SlDANBgkqhkiG9w0BAQsFADAUMRIwEAYDVQQDDAlU
ZXN0IENlcnQwHhcNMjYwNzA0MTU1NDM2WhcNNDYwNjI5MTU1NDM2WjAUMRIwEAYD
VQQDDAlUZXN0IENlcnQwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDi
2K3v09mWS7jCJt8KxLURHa4Db/ro/Ck15mJ1Ej/OMO52UvcEfgZz9/Df9qE9aFAT
2u4JAVusCOr1U0kdHdiPFZelhqVUxar26jGapsQRGEhJO/l+FA86uzkv3w2koXgC
QVZjAiSK03tpZywh2nbLdU/bhXspLe/3gKx5/2kyXpmMuCKc32w+xfhoIiYkPXeZ
QYY3kv+xH+PZi1kStqTU0SEGpi7+NmlhlF1cMC4VICzQpiwlCK8+SwNrzCPr0j+p
qGt8Cgt0L1/7/EGCdicXz/bM6p3e6QFkM7Np1wTnPcVLKCXIFWOEIfGvLzP88BWZ
SmbXa0ZO//wQzxakGWuJAgMBAAEwDQYJKoZIhvcNAQELBQADggEBANESsAPHXZjP
SqZhWuuY8HWqmpy0koVJbW/l9EqtsD9eGQFUUC5xwHdWmIB81av4bsHlRQP2PXhS
Er9QJFzwbQFFXskzKh9s21UqI1aBZh4LHH352i9TdWMbZiG04attZDi3YWt4hH9K
RKFbR7g86IDgmH9XoPLVQqnnomTQfMnSNwrg/0KNvGZpZNqBD8GF8XB73iAVoBI5
4A322dIhh+qQFD6bYV1WQf2pCqKWFDJ+KLozjO7EkE6RylgM+6TE5+bpQW6l3RVs
36bCdGZvzRlhu6sF/WwN9Enh+/zI/v5gFLmHZZpn0u/+v/CkIyVfjIKn5YuPjsK8
ibtNfthpNAQ=
-----END CERTIFICATE-----
"""
}
