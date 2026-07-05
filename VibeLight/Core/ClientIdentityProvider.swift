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
        let p12URL = try ensureP12()
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
        #endif
    }

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

    private func ensureP12() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let p12URL = supportDirectory.appendingPathComponent("client-\(pemFingerprint.prefix(16)).p12")
        if fm.fileExists(atPath: p12URL.path) { return p12URL }

        // Stale bundles from prior pairings are useless — clear them.
        if let stale = try? fm.contentsOfDirectory(at: supportDirectory, includingPropertiesForKeys: nil) {
            for url in stale where url.pathExtension == "p12" {
                try? fm.removeItem(at: url)
            }
        }

        let certURL = supportDirectory.appendingPathComponent("tmp-cert.pem")
        let keyURL = supportDirectory.appendingPathComponent("tmp-key.pem")
        try identity.certificatePEM.write(to: certURL)
        try identity.privateKeyPEM.write(to: keyURL)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        defer {
            try? fm.removeItem(at: certURL)
            try? fm.removeItem(at: keyURL)
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
        guard process.terminationStatus == 0, fm.fileExists(atPath: p12URL.path) else {
            let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw IdentityError.opensslFailed(err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12URL.path)
        return p12URL
    }
    #endif
}
