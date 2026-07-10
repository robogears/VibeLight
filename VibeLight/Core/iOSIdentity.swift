#if os(iOS)
import Foundation
import Security
import X509
import SwiftASN1

/// iOS client-identity generation, entirely in Security.framework +
/// apple/swift-certificates — no `/usr/bin/openssl`, no `Foundation.Process`
/// (both forbidden on iOS).
///
/// iOS has no desktop-Moonlight plist to import, so the identity is always
/// self-generated and the **keychain is the source of truth**: the RSA key is
/// born *in* the keychain (`SecKeyCreateRandomKey` + `kSecAttrIsPermanent`), the
/// self-signed cert is added beside it, and `SecItemCopyMatching(kSecClassIdentity)`
/// then assembles the `SecIdentity` used for mTLS against the host (port 47984).
///
/// This born-in-keychain pattern is the one approach proven to assemble an
/// identity on an ad-hoc-signed, sandbox-free build (importing an external key
/// by `kSecValueRef` does not reliably form an identity there). On iOS it is
/// also the standard path. Mirrors moonlight-qt's IdentityManager cert shape:
/// CN="NVIDIA GameStream Client", 20-year validity, SHA-256, RSA-2048.
enum IOSKeychainIdentity {

    /// Stable identifiers so the identity is found + reused across launches.
    private static let keyTag = Data("com.vibelight.client.identity.key".utf8)
    private static let certLabel = "VibeLight Client Identity"

    // MARK: - Public

    /// The cert PEM if our identity already lives in the keychain (both the
    /// permanent key and the cert must be present to assemble an identity).
    /// The private-key PEM is intentionally empty: on iOS the key never leaves
    /// the keychain — signing goes through the assembled `SecIdentity`.
    static func loadPEMs() -> (cert: Data, key: Data)? {
        guard let cert = copyCertificate(), copyKey() != nil else { return nil }
        let der = SecCertificateCopyData(cert) as Data
        return (Data(pem(fromCertDER: der).utf8), Data())
    }

    /// Generate a fresh born-in-keychain identity and return its cert PEM.
    static func generatePEMs() -> (cert: Data, key: Data)? {
        deleteAll()  // never leave a half-formed identity behind
        guard let key = createPermanentKey(),
              let der = buildSelfSignedCertDER(for: key),
              let cert = SecCertificateCreateWithData(nil, der as CFData),
              addCertificate(cert),
              assembleIdentity() != nil          // prove it actually assembles
        else {
            deleteAll()
            return nil
        }
        // Serialize the PEM the SAME way loadPEMs does (from the cert DER), so
        // the identity's cert PEM is byte-stable across generate → relaunch.
        return (Data(pem(fromCertDER: der).utf8), Data())
    }

    /// The mTLS `SecIdentity`, assembled from the keychain key + cert.
    static func assembleIdentity() -> SecIdentity? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: certLabel,
            kSecReturnRef: true,
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let out else { return nil }
        return (out as! SecIdentity)
    }

    // MARK: - Keychain items

    private static func createPermanentKey() -> SecKey? {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ],
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateRandomKey(attrs as CFDictionary, &error)
    }

    private static func addCertificate(_ cert: SecCertificate) -> Bool {
        let status = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: cert,
            kSecAttrLabel: certLabel,
        ] as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    private static func copyCertificate() -> SecCertificate? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: certLabel,
            kSecReturnRef: true,
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let out else { return nil }
        return (out as! SecCertificate)
    }

    private static func copyKey() -> SecKey? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: keyTag,
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecReturnRef: true,
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let out else { return nil }
        return (out as! SecKey)
    }

    private static func deleteAll() {
        SecItemDelete([kSecClass: kSecClassKey,
                       kSecAttrApplicationTag: keyTag] as CFDictionary)
        SecItemDelete([kSecClass: kSecClassCertificate,
                       kSecAttrLabel: certLabel] as CFDictionary)
    }

    // MARK: - Cert construction (swift-certificates)

    /// Returns the DER of a 20-year self-signed cert over `key`'s public key.
    private static func buildSelfSignedCertDER(for key: SecKey) -> Data? {
        do {
            let privateKey = try Certificate.PrivateKey(key)
            let name = try DistinguishedName { CommonName("NVIDIA GameStream Client") }
            let now = Date()
            var serial = [UInt8](repeating: 0, count: 16)
            // Fail cert generation on an RNG failure rather than emit a fixed
            // near-zero serial — matches GameStreamCrypto.randomBytes's precondition.
            // (audit QUA-cert-serial-rng-status-ignored)
            guard SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial) == errSecSuccess else { return nil }
            serial[0] = (serial[0] & 0x7f) | 0x01   // positive, non-zero leading byte
            let cert = try Certificate(
                version: .v3,
                serialNumber: Certificate.SerialNumber(bytes: serial),
                publicKey: privateKey.publicKey,
                notValidBefore: now.addingTimeInterval(-3600),
                notValidAfter: now.addingTimeInterval(20 * 365 * 24 * 60 * 60),
                issuer: name,
                subject: name,
                signatureAlgorithm: .sha256WithRSAEncryption,
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                    KeyUsage(digitalSignature: true, keyCertSign: true)
                },
                issuerPrivateKey: privateKey
            )
            return Data(try cert.serializeAsPEM().derBytes)
        } catch {
            return nil
        }
    }

    // MARK: - PEM

    private static func pem(fromCertDER der: Data) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(b64)\n-----END CERTIFICATE-----\n"
    }
}
#endif
