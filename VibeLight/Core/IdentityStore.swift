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
        #if os(iOS)
        // iOS never has a desktop-Moonlight plist to import, and /usr/bin/openssl
        // + Process are forbidden. The keychain is the source of truth: a fresh
        // user always self-generates (SecKeyCreateRandomKey + swift-certificates),
        // and the identity lives in the keychain across launches. See iOSIdentity.
        let id = uniqueID()
        if let pems = IOSKeychainIdentity.loadPEMs() ?? IOSKeychainIdentity.generatePEMs() {
            usingGeneratedIdentity = true
            return ClientIdentity(certificatePEM: pems.cert, privateKeyPEM: pems.key, uniqueID: id)
        }
        return ClientIdentity(certificatePEM: Data(), privateKeyPEM: Data(), uniqueID: id)
        #else
        if let moonlightIdentity, !moonlightIdentity.certificatePEM.isEmpty,
           !moonlightIdentity.privateKeyPEM.isEmpty {
            // Reusing Moonlight's identity is the zero-setup story — but until
            // now we reused it WITHOUT keeping a copy, so VibeLight's pairings
            // lived entirely in someone else's file. Reset or uninstall Moonlight
            // and we'd mint a brand-new cert and every host would say "not
            // paired" until re-paired by hand. Adopt it into our own store on
            // first sight: same bytes, same pairings, now durable. Never
            // overwrites an identity we already own.
            adoptAsOwn(moonlightIdentity)
            return moonlightIdentity
        }
        if let existing = loadOwn() {
            syncHelperIdentity(existing)
            return existing
        }
        // (the Moonlight-import branch above adopts a copy via adoptAsOwn)
        if let generated = generateAndPersist() {
            syncHelperIdentity(generated)
            return generated
        }
        return ClientIdentity(
            certificatePEM: Data(), privateKeyPEM: Data(), uniqueID: uniqueID())
        #endif
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

    #if os(macOS)
    /// The stream helper (our moonlight-qt fork) deliberately reads its client
    /// identity from Moonlight's preferences domain — that reuse is the whole
    /// zero-setup story for existing Moonlight users. But on a Mac that never
    /// had Moonlight, the domain is empty: VibeLight pairs with its OWN
    /// generated cert while the helper mints a different one on first stream,
    /// so the host answers "not paired" and streaming dead-ends (the standalone
    /// pairing bug). Fix: whenever VibeLight runs on its own identity, mirror
    /// the cert/key into the Moonlight domain so launcher + helper present one
    /// identity. A real Moonlight install later reads this same plist, so
    /// pairings keep working. Never overwrites an existing identity.
    /// Persists an identity we adopted from Moonlight into VibeLight's own store,
    /// so it survives Moonlight being reset, uninstalled, or its plist cleared.
    /// No-op when we already own one — the on-disk copy is the source of truth
    /// and must never be silently replaced (that WOULD force a re-pair, the exact
    /// failure this exists to prevent).
    private static func adoptAsOwn(_ identity: ClientIdentity) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: certURL.path) else { return }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Same 0600-before-write ordering as generateAndPersist: create the key
        // file with the right mode FIRST, because writing to an existing file
        // keeps its permissions and a post-hoc chmod leaves a readable window.
        try? fm.removeItem(at: keyURL)
        fm.createFile(atPath: keyURL.path, contents: nil,
                      attributes: [.posixPermissions: 0o600])
        do {
            try identity.certificatePEM.write(to: certURL)
            try identity.privateKeyPEM.write(to: keyURL)
        } catch {
            // Best-effort: failing to cache it just leaves us on the old
            // reuse-only behaviour, which still works while Moonlight's plist
            // is intact. Never fail startup over this.
            try? fm.removeItem(at: certURL)
            try? fm.removeItem(at: keyURL)
        }
    }

    private static func syncHelperIdentity(_ identity: ClientIdentity) {
        guard let defaults = UserDefaults(suiteName: "com.moonlight-stream.Moonlight") else { return }
        if let cert = defaults.data(forKey: "certificate"), !cert.isEmpty { return }
        defaults.set(identity.certificatePEM, forKey: "certificate")
        defaults.set(identity.privateKeyPEM, forKey: "key")
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
        // Pre-create the key file 0600 so openssl truncate-writes into it
        // (O_CREAT only applies perms on *creation*) instead of creating it
        // under the umask (0644) — closes the window where the RSA private key
        // was group/other-readable before the post-hoc chmod below.
        try? fm.removeItem(at: keyURL)
        fm.createFile(atPath: keyURL.path, contents: nil, attributes: [.posixPermissions: 0o600])

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
    #endif
}
