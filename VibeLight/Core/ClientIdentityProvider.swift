import Foundation
import Security
import CryptoKit

/// Turns the PEM cert/key pair imported from Moonlight into a `SecIdentity`
/// usable for mTLS against the host's HTTPS API (port 47984).
///
/// Strategy (verified on this machine): PEM → PKCS#12 via the system openssl
/// (cached in Application Support, chmod 600), then `SecPKCS12Import` with
/// `kSecImportToMemoryOnly` — yields an in-memory identity with no keychain
/// interaction and no user prompts.
final class ClientIdentityProvider: @unchecked Sendable {
    enum IdentityError: Error, LocalizedError {
        case opensslFailed(String)
        case importFailed(OSStatus)
        case noIdentityInBundle

        var errorDescription: String? {
            switch self {
            case .opensslFailed(let msg): "Could not build client identity bundle: \(msg)"
            case .importFailed(let status): "Identity import failed (OSStatus \(status))."
            case .noIdentityInBundle: "Identity bundle contained no usable identity."
            }
        }
    }

    private let identity: ClientIdentity
    private let supportDirectory: URL
    private var cached: SecIdentity?
    private let lock = NSLock()

    init(identity: ClientIdentity, supportDirectory: URL? = nil) {
        self.identity = identity
        self.supportDirectory = supportDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeLight", isDirectory: true)
    }

    /// The mTLS identity, building + caching it on first use.
    func secIdentity() throws -> SecIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        #if os(iOS)
        // iOS: the identity was born in the keychain (SecKeyCreateRandomKey +
        // swift-certificates cert, see iOSIdentity). Query it back — no openssl,
        // no P12, no on-disk key material.
        guard let identity = IOSKeychainIdentity.assembleIdentity() else {
            throw IdentityError.importFailed(errSecItemNotFound)
        }
        cached = identity
        return identity
        #else
        // A cached bundle that no longer imports is not a permanent verdict —
        // it is a corrupt file. openssl killed mid-write (log out, crash, disk
        // full) leaves a short or truncated .p12 that `fileExists` happily
        // accepts, and every host request then fails with "Client identity
        // unavailable" forever, because the file being there is what stops it
        // being rebuilt. Rebuild once from the PEMs before giving up.
        do {
            return try importIdentity(from: try ensureP12())
        } catch {
            return try importIdentity(from: try ensureP12(force: true))
        }
        #endif
    }

    #if os(macOS)
    private func importIdentity(from p12URL: URL) throws -> SecIdentity {
        let p12Data = try Data(contentsOf: p12URL)

        var items: CFArray?
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: p12Passphrase,
            kSecImportToMemoryOnly as String: kCFBooleanTrue!,
        ]
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw IdentityError.importFailed(status) }
        guard let array = items as? [[String: Any]],
              let first = array.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            throw IdentityError.noIdentityInBundle
        }
        let secIdentity = identityRef as! SecIdentity
        cached = secIdentity
        return secIdentity
    }
    #endif

    /// The client's private key, for signing during pairing.
    func privateKey() throws -> SecKey {
        var key: SecKey?
        let status = SecIdentityCopyPrivateKey(try secIdentity(), &key)
        guard status == errSecSuccess, let key else { throw IdentityError.importFailed(status) }
        return key
    }

    /// The client certificate PEM (for the pairing handshake wire format).
    var certificatePEM: Data { identity.certificatePEM }

    #if os(macOS)
    // MARK: - P12 cache (macOS)

    /// Passphrase derived from the key material itself — stable across launches,
    /// unique per pairing, never stored separately. The P12 sits beside a
    /// plaintext-PEM Moonlight plist anyway; this is parity, not new exposure.
    private var p12Passphrase: String {
        let digest = SHA256.hash(data: identity.privateKeyPEM + identity.certificatePEM)
        return digest.map { String(format: "%02x", $0) }.prefix(4).joined()
            + digest.suffix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Fingerprint of the PEM inputs; a changed pairing invalidates the cache.
    private var pemFingerprint: String {
        SHA256.hash(data: identity.certificatePEM + identity.privateKeyPEM)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Where the cached bundle for the CURRENT pairing lives.
    private var p12CacheURL: URL {
        supportDirectory.appendingPathComponent("client-\(pemFingerprint.prefix(16)).p12")
    }

    /// Below this a file cannot possibly hold a cert + key (a real RSA-2048
    /// PKCS#12 is ~2.5 KB) — shared by the cache check and openssl verification.
    private static let minPlausibleP12Bytes = 256

    private func ensureP12(force: Bool = false) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let p12URL = p12CacheURL
        // `fileExists` is not "is usable": a truncated bundle from an
        // interrupted openssl run passes it. Require a plausible size too —
        // anything under `minPlausibleP12Bytes` cannot hold a cert and a key.
        // The caller additionally forces a rebuild when an existing file fails
        // to import.
        if !force, let size = try? fm.attributesOfItem(atPath: p12URL.path)[.size] as? Int,
           size >= Self.minPlausibleP12Bytes {
            return p12URL
        }
        try? fm.removeItem(at: p12URL)

        // Stale bundles from prior pairings are useless — clear them.
        if let stale = try? fm.contentsOfDirectory(at: supportDirectory, includingPropertiesForKeys: nil) {
            for url in stale where url.pathExtension == "p12" {
                try? fm.removeItem(at: url)
            }
        }

        let certURL = supportDirectory.appendingPathComponent("tmp-cert.pem")
        let keyURL = supportDirectory.appendingPathComponent("tmp-key.pem")
        try identity.certificatePEM.write(to: certURL)
        // Create the plaintext private-key temp file 0600 from birth rather than
        // write-then-chmod, which leaves a brief world-readable window. (SEV-04)
        guard fm.createFile(atPath: keyURL.path, contents: identity.privateKeyPEM,
                            attributes: [.posixPermissions: 0o600]) else {
            throw IdentityError.opensslFailed("Could not write client key material.")
        }
        defer {
            try? fm.removeItem(at: certURL)
            try? fm.removeItem(at: keyURL)
        }

        // Pre-create the output 0600 so openssl inherits those permissions
        // instead of the ambient umask. openssl opens -out with O_TRUNC, which
        // keeps an existing file's mode, so the bundle is never briefly
        // world-readable. This is the same race the key file above was hardened
        // against in SEV-04 — the .p12 holds the same private key and had been
        // left on write-then-chmod.
        guard fm.createFile(atPath: p12URL.path, contents: nil,
                            attributes: [.posixPermissions: 0o600]) else {
            throw IdentityError.opensslFailed("Could not create the client identity bundle.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "pkcs12", "-export",
            "-in", certURL.path,
            "-inkey", keyURL.path,
            "-out", p12URL.path,
            "-passout", "pass:\(p12Passphrase)",
            "-name", "VibeLight Client",
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        // The output now always EXISTS (we pre-created it), so existence proves
        // nothing — check that openssl actually filled it, and clean up the
        // empty/short husk on failure so the next attempt starts fresh instead
        // of finding a "cached" bundle that can never import.
        let written = (try? fm.attributesOfItem(atPath: p12URL.path)[.size]) as? Int ?? 0
        guard process.terminationStatus == 0, written >= Self.minPlausibleP12Bytes else {
            try? fm.removeItem(at: p12URL)
            let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw IdentityError.opensslFailed(err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12URL.path)
        return p12URL
    }
    #endif
}
