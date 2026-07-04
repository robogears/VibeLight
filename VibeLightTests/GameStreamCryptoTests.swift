import XCTest
import CryptoKit
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

    // MARK: SHA-256

    func testSHA256MatchesCryptoKit() {
        let data = Data("moonlight".utf8)
        XCTAssertEqual(GameStreamCrypto.sha256(data), Data(SHA256.hash(data: data)))
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
