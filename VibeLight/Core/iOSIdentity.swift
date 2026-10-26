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

    /// The keychain identifiers one identity lives under.
    ///
    /// The app only ever uses `.production`. Tests pass their own namespace so
    /// they mint, read and delete only their own items: the test bundle runs
    /// INSIDE the real app on the simulator, and the destructive calls used to
    /// hit the production tag and label, wiping that simulator's paired
    /// identity. (audit DAT-simulator-identity-reset)
    struct Namespace: Equatable, Sendable {
        let keyTag: Data
        let certLabel: String

        /// Stable identifiers so the identity is found + reused across
        /// launches. NEVER change these: every installed copy's identity is
        /// filed under them, so a new value reads as "no identity" and unpairs
        /// every computer. Pinned by IOSIdentityTests.
        static let production = Namespace(
            keyTag: Data("com.vibelight.client.identity.key".utf8),
            certLabel: "VibeLight Client Identity")
    }

    // MARK: - Public

    /// What a keychain lookup actually told us.
    ///
    /// The distinction is load-bearing: `generatePEMs()` starts by deleting
    /// everything, so treating "the keychain could not answer right now" the
    /// same as "there is no identity" DESTROYS a working, host-trusted identity
    /// and silently unpairs every computer. Only `absent` may lead to
    /// generation.
    enum Lookup: Equatable {
        /// Both items came back. Safe to use.
        case found(cert: Data, key: Data)
        /// The keychain positively reported "no such item". Safe to generate.
        case absent
        /// The keychain refused to answer — locked device, missing entitlement,
        /// authentication failure. The identity may well still be there.
        /// NEVER generate on this; retry later instead.
        case unavailable(OSStatus)
    }

    /// The cert PEM if our identity already lives in the keychain (both the
    /// permanent key and the cert must be present to assemble an identity).
    /// The private-key PEM is intentionally empty: on iOS the key never leaves
    /// the keychain — signing goes through the assembled `SecIdentity`.
    static func loadPEMs(in ns: Namespace = .production) -> Lookup {
        var certRef: CFTypeRef?
        let certStatus = SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: ns.certLabel,
            kSecReturnRef: true,
        ] as CFDictionary, &certRef)

        var keyRef: CFTypeRef?
        let keyStatus = SecItemCopyMatching([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: ns.keyTag,
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecReturnRef: true,
        ] as CFDictionary, &keyRef)

        switch classify(certStatus: certStatus, keyStatus: keyStatus) {
        case .unavailable(let status):
            return .unavailable(status)
        case .absent:
            return .absent
        case .found:
            // classify only reports .found when both statuses were success, so
            // both refs are present. Belt and braces: if a ref is somehow nil,
            // report unavailable rather than absent — never destroy on a
            // surprise.
            guard let certRef, keyRef != nil else { return .unavailable(errSecInternalError) }
            let cert = certRef as! SecCertificate
            migrateAccessibilityIfNeeded(ns)
            let der = SecCertificateCopyData(cert) as Data
            return .found(cert: Data(pem(fromCertDER: der).utf8), key: Data())
        }
    }

    /// Pure decision table over the two lookup statuses — the whole safety
    /// property of this file lives here, so it is separated out and tested.
    ///
    /// The rule is deliberately asymmetric: **only** an explicit
    /// `errSecItemNotFound` from both queries counts as "there is no identity".
    /// Every other status — `errSecInteractionNotAllowed` (device locked, and
    /// with it the classic case of launching before the first unlock after a
    /// reboot), `errSecMissingEntitlement`, `errSecAuthFailed`,
    /// `errSecNotAvailable`, anything unforeseen — is treated as "cannot tell",
    /// because guessing wrong in that direction is unrecoverable for the user
    /// and guessing wrong the other way costs one relaunch.
    static func classify(certStatus: OSStatus, keyStatus: OSStatus,
                         deviceUnlocked: @autoclosure () -> Bool = isDeviceUnlocked()) -> Lookup {
        if certStatus == errSecSuccess && keyStatus == errSecSuccess {
            return .found(cert: Data(), key: Data())   // placeholder — loadPEMs builds the real .found from the refs
        }
        // A non-success status that is NOT "not found" means the keychain could
        // not answer. Report the first such status.
        for status in [certStatus, keyStatus] where status != errSecSuccess && status != errSecItemNotFound {
            return .unavailable(status)
        }
        // Both halves say not-found: genuinely nothing here. Safe to generate.
        if certStatus == errSecItemNotFound && keyStatus == errSecItemNotFound { return .absent }

        // ONE half answered and the other said not-found — NOT proof of absence:
        // the keychain OMITS items whose protection class is currently
        // unavailable instead of returning errSecInteractionNotAllowed, so a
        // real item can read as not-found (the pre-fix cert/key accessibility
        // mismatch — see addCertificate — produced exactly this shape, and
        // calling it .absent ran deleteAll on a live, host-trusted key). Only a
        // device the probe below proves unlocked lets not-found mean a genuine
        // orphan (a crash between creating the key and adding the cert).
        return deviceUnlocked() ? .absent : .unavailable(errSecInteractionNotAllowed)
    }

    /// Round-trips a throwaway `WhenUnlocked` item to prove the device is
    /// unlocked *right now*.
    ///
    /// `WhenUnlocked` is the strictest ordinary class, so if an item written
    /// under it can be read back, nothing in our keychain is being hidden by the
    /// lock state — which makes an `errSecItemNotFound` for the cert or key
    /// trustworthy. Cheap (two keychain calls) and only reached on the rare
    /// half-answered path.
    static func isDeviceUnlocked() -> Bool {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                     kSecAttrAccount: "vibelight.unlock.probe",
                                     kSecAttrService: "com.vibelight.probe"]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData] = Data("probe".utf8)
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
        defer { SecItemDelete(base as CFDictionary) }
        var read = base
        read[kSecReturnData] = true
        var out: CFTypeRef?
        return SecItemCopyMatching(read as CFDictionary, &out) == errSecSuccess
    }

    /// Generate a fresh born-in-keychain identity and return its cert PEM.
    ///
    /// Destructive by design — call ONLY after `loadPEMs()` returned `.absent`.
    /// The namespace has no default on purpose: a destructive call must say
    /// whose items it replaces.
    static func generatePEMs(in ns: Namespace) -> (cert: Data, key: Data)? {
        deleteAll(in: ns)  // never leave a half-formed identity behind
        guard let key = createPermanentKey(ns),
              let der = buildSelfSignedCertDER(for: key),
              let cert = SecCertificateCreateWithData(nil, der as CFData),
              addCertificate(cert, ns),
              assembleIdentity(in: ns) != nil    // prove it actually assembles
        else {
            deleteAll(in: ns)
            return nil
        }
        // Serialize the PEM the SAME way loadPEMs does (from the cert DER), so
        // the identity's cert PEM is byte-stable across generate → relaunch.
        return (Data(pem(fromCertDER: der).utf8), Data())
    }

    /// The mTLS `SecIdentity`, assembled from the keychain key + cert.
    static func assembleIdentity(in ns: Namespace = .production) -> SecIdentity? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: ns.certLabel,
            kSecReturnRef: true,
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let out else { return nil }
        return (out as! SecIdentity)
    }

    // MARK: - Keychain items

    private static func createPermanentKey(_ ns: Namespace) -> SecKey? {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: ns.keyTag,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ],
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateRandomKey(attrs as CFDictionary, &error)
    }

    private static func addCertificate(_ cert: SecCertificate, _ ns: Namespace) -> Bool {
        let status = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: cert,
            kSecAttrLabel: ns.certLabel,
            // Match the private key's accessibility (createPermanentKey). Left
            // unset, a keychain item defaults to kSecAttrAccessibleWhenUnlocked
            // — STRICTER than the key — so on a locked device the cert lookup
            // failed while the key succeeded. That mismatch both broke identity
            // assembly whenever the screen was locked and produced the
            // half-answered lookup that used to trigger regeneration.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ] as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    /// One-time repair for identities created before the cert carried an
    /// explicit accessibility (they got the stricter `WhenUnlocked` default).
    /// Runs on the success path only, so it can never widen access to an item
    /// we failed to read.
    private static func migrateAccessibilityIfNeeded(_ ns: Namespace) {
        // Production only: the latch below lives in the app's own defaults, so
        // a test namespace setting it would skip the real identity's repair.
        guard ns == .production else { return }
        let flag = "vibelight.ios.certAccessibilityMigrated"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let status = SecItemUpdate(
            [kSecClass: kSecClassCertificate, kSecAttrLabel: ns.certLabel] as CFDictionary,
            [kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock] as CFDictionary)
        // Only latch on success: a failed migration should be retried next launch.
        if status == errSecSuccess { UserDefaults.standard.set(true, forKey: flag) }
    }

    /// Removes one namespace's key and certificate. Internal (not private) only
    /// so tests can clean up their own namespace; no default, like generatePEMs.
    static func deleteAll(in ns: Namespace) {
        SecItemDelete([kSecClass: kSecClassKey,
                       kSecAttrApplicationTag: ns.keyTag] as CFDictionary)
        SecItemDelete([kSecClass: kSecClassCertificate,
                       kSecAttrLabel: ns.certLabel] as CFDictionary)
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
