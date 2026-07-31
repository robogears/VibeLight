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
        // VibeLight is SEPARATE from Moonlight. It used to prefer the identity
        // out of Moonlight's plist ("zero setup" for existing Moonlight users),
        // which quietly entangled the two apps: VibeLight's pairings lived in
        // someone else's file, and installing/resetting/removing Moonlight
        // changed them underneath us. VibeLight now always uses its OWN
        // identity — generated on first launch, stored under Application
        // Support, mirrored only into VibeLight's own helper domain.
        //
        // `moonlightIdentity` is ignored on purpose; the parameter stays so the
        // iOS/macOS call sites keep one shape. A user coming from Moonlight
        // pairs their hosts once, in-app, via PIN — no Moonlight required.
        _ = moonlightIdentity
        if let existing = loadOwn() {
            syncHelperIdentity(existing)
            return existing
        }
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
    /// The preferences domain the stream helper reads its client identity from.
    /// The helper is our moonlight-qt fork; it used to share Moonlight's own
    /// domain (com.moonlight-stream.Moonlight), which is exactly what entangled
    /// the two apps. The fork now sets organizationDomain "vibelight.com" /
    /// applicationName "StreamHelper", and Qt reverses that to the domain below —
    /// ours alone.
    ///
    /// VERIFIED EMPIRICALLY, not derived: Qt does NOT simply reverse every
    /// domain. "vibelight.app" came out as the junk domain
    /// `com.vibelight-app.StreamHelper` (dot mangled to a hyphen, `com.`
    /// prepended), which would have left this constant pointing at a plist the
    /// helper never reads — a silent identity mismatch, i.e. the ON-1
    /// "host says not paired" bug. MUST stay in lockstep with app/main.cpp.
    static let helperDefaultsSuite = "com.vibelight.StreamHelper"

    private static func syncHelperIdentity(_ identity: ClientIdentity) {
        guard let defaults = UserDefaults(suiteName: helperDefaultsSuite) else { return }
        // VibeLight is the SOURCE OF TRUTH for the client identity; the helper
        // must present the same certificate or the host sees two different
        // clients and rejects the streaming one as unpaired — while the launcher,
        // using its own good cert, still shows the host as paired. That split
        // brain is the ON-1 bug.
        //
        // This used to bail out whenever the helper already had a cert. That was
        // right while Moonlight's identity was authoritative (we adopted it, so
        // they matched by construction) and is WRONG now: the helper mints its
        // own identity the first time it runs for any reason, and that stale cert
        // would then win forever with no way to correct it. Mirror ours over the
        // top whenever they differ (compared first, so the common case is a
        // no-op write).
        guard defaults.data(forKey: "certificate") != identity.certificatePEM else { return }
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
