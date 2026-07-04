import Foundation

/// Resolves VibeLight's client identity, in priority order:
/// 1. Moonlight's existing pairing (so users who already use Moonlight keep all
///    their paired hosts working — zero setup).
/// 2. VibeLight's own generated identity (persisted in Application Support).
/// 3. A freshly generated RSA-2048 self-signed identity.
///
/// (3) is what lets a brand-new user — who has never installed Moonlight — pair
/// hosts entirely inside VibeLight. Generation mirrors moonlight-qt's
/// IdentityManager: CN="NVIDIA GameStream Client", 20-year self-signed cert.
enum IdentityStore {

    static func resolve(moonlightIdentity: ClientIdentity?) -> ClientIdentity {
        if let moonlightIdentity, !moonlightIdentity.certificatePEM.isEmpty,
           !moonlightIdentity.privateKeyPEM.isEmpty {
            return moonlightIdentity
        }
        if let existing = loadOwn() { return existing }
        return generateAndPersist() ?? ClientIdentity(
            certificatePEM: Data(), privateKeyPEM: Data(), uniqueID: uniqueID())
    }

    /// True when VibeLight is running on its own generated identity (i.e. no
    /// Moonlight was found) — used to tailor the empty state. Set once during
    /// resolve() on the main actor at startup.
    nonisolated(unsafe) static var usingGeneratedIdentity = false

    // MARK: - Storage

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeLight/identity", isDirectory: true)
    }
    private static var certURL: URL { directory.appendingPathComponent("client.pem") }
    private static var keyURL: URL { directory.appendingPathComponent("client.key") }
    private static let uniqueIDKey = "vibelight.uniqueid"

    private static func uniqueID() -> String {
        if let existing = UserDefaults.standard.string(forKey: uniqueIDKey), !existing.isEmpty {
            return existing
        }
        let id = GameStreamCrypto.randomBytes(8).lowercaseHex
        UserDefaults.standard.set(id, forKey: uniqueIDKey)
        return id
    }

    private static func loadOwn() -> ClientIdentity? {
        let fm = FileManager.default
        guard let cert = try? Data(contentsOf: certURL), !cert.isEmpty,
              let key = try? Data(contentsOf: keyURL), !key.isEmpty,
              fm.fileExists(atPath: certURL.path) else { return nil }
        usingGeneratedIdentity = true
        return ClientIdentity(certificatePEM: cert, privateKeyPEM: key, uniqueID: uniqueID())
    }

    private static func generateAndPersist() -> ClientIdentity? {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", keyURL.path, "-out", certURL.path,
            "-days", "7300", "-nodes", "-sha256",
            "-subj", "/CN=NVIDIA GameStream Client",
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let cert = try? Data(contentsOf: certURL),
              let key = try? Data(contentsOf: keyURL), !cert.isEmpty, !key.isEmpty else {
            return nil
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        usingGeneratedIdentity = true
        return ClientIdentity(certificatePEM: cert, privateKeyPEM: key, uniqueID: uniqueID())
    }
}
