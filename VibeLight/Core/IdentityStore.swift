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
        switch IOSKeychainIdentity.loadPEMs() {
        case .found(let cert, let key):
            usingGeneratedIdentity = true
            return ClientIdentity(certificatePEM: cert, privateKeyPEM: key, uniqueID: id)

        case .absent:
            // Genuinely nothing in the keychain — first run, or a half-formed
            // identity that cannot assemble either way. Safe to generate.
            if let pems = IOSKeychainIdentity.generatePEMs() {
                usingGeneratedIdentity = true
                return ClientIdentity(certificatePEM: pems.cert, privateKeyPEM: pems.key, uniqueID: id)
            }
            return ClientIdentity(certificatePEM: Data(), privateKeyPEM: Data(), uniqueID: id)

        case .unavailable:
            // The keychain could not answer — classically a launch before the
            // first unlock after a reboot. The identity is probably sitting
            // right there. Generating would call deleteAll() and destroy it,
            // unpairing every computer with no way back except re-pairing each
            // one by PIN. Returning an empty identity instead costs the user a
            // relaunch and nothing else: ClientIdentityProvider.secIdentity()
            // re-queries the keychain lazily and caches only on success, so the
            // app recovers on its own once the device is unlocked.
            return ClientIdentity(certificatePEM: Data(), privateKeyPEM: Data(), uniqueID: id)
        }
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

    /// The client's `uniqueid`, generated once and persisted. THE single owner
    /// of this key — HostAPIClient used to be a second reader/writer with a
    /// stricter validity rule, so a value accepted here was silently rotated
    /// there, changing the id the host uses for its per-client bookkeeping.
    static func uniqueID() -> String {
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

    /// Projects VibeLight's known hosts into the helper's preferences domain.
    ///
    /// The helper needs each host's PINNED SERVER CERT (`srvcert`) to speak
    /// HTTPS on 47984 at all. Without it, moonlight-qt falls back to plain HTTP
    /// on 47989 — where no client certificate is presented, so the host answers
    /// `PairStatus 0` no matter how well-paired you actually are. The visible
    /// symptom is "Computer X has not been paired" while VibeLight itself shows
    /// the host as paired and lists its apps, because VibeLight talks 47984
    /// directly. Verified on a live host: 47989 → PairStatus 0 / Permission 0;
    /// 47984 with the cert → PairStatus 1 / Permission 119480064.
    ///
    /// Before the Moonlight split the helper inherited these records from
    /// Moonlight's plist; now VibeLight owns them and must hand them over. Key
    /// names mirror NvComputer's SER_* constants in the fork
    /// (app/backend/nvcomputer.cpp) — QSettings arrays are 1-based.
    static func syncHelperHosts(_ hosts: [StreamHost]) {
        guard let defaults = UserDefaults(suiteName: helperDefaultsSuite) else { return }
        // Only hosts we actually hold a pinned cert for are useful to the helper;
        // an entry without one would put it right back on the HTTP fallback.
        let usable = hosts.filter { ($0.serverCertPEM?.isEmpty == false) }

        // Clear the previous array wholesale (including any record the helper
        // wrote for itself) so removals propagate instead of lingering.
        let previous = defaults.integer(forKey: "hosts.size")
        if previous > 0 {
            for i in 1...previous {
                for key in ["hostname", "uuid", "customname", "mac", "srvcert", "nvidiasw",
                            "localaddress", "localport", "remoteaddress", "remoteport",
                            "manualaddress", "manualport", "ipv6address", "ipv6port"] {
                    defaults.removeObject(forKey: "hosts.\(i).\(key)")
                }
            }
        }

        for (offset, host) in usable.enumerated() {
            let p = "hosts.\(offset + 1)."
            defaults.set(host.name, forKey: p + "hostname")
            defaults.set(host.id, forKey: p + "uuid")
            defaults.set(host.serverCertPEM, forKey: p + "srvcert")
            if let mac = host.macAddress { defaults.set(mac, forKey: p + "mac") }
            if let a = host.localAddress {
                defaults.set(a, forKey: p + "localaddress"); defaults.set(host.localPort, forKey: p + "localport")
            }
            if let a = host.remoteAddress {
                defaults.set(a, forKey: p + "remoteaddress"); defaults.set(host.remotePort, forKey: p + "remoteport")
            }
            if let a = host.manualAddress {
                defaults.set(a, forKey: p + "manualaddress"); defaults.set(host.manualPort, forKey: p + "manualport")
            }
        }
        defaults.set(usable.count, forKey: "hosts.size")
    }

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
        // The uniqueid matters as much as the certificate. Sunshine/Vibepollo
        // tracks paired clients by it, so a helper querying with its OWN id gets
        // PairStatus 0 — "Computer X has not been paired" — even while holding
        // the correct certificate and reaching the host fine. The helper mints
        // one on first run ("Loaded unique ID from settings"), so it must be
        // overwritten too, not just the key material.
        let certMatches = defaults.data(forKey: "certificate") == identity.certificatePEM
        let idMatches = defaults.string(forKey: "uniqueid") == identity.uniqueID
        guard !certMatches || !idMatches else { return }
        defaults.set(identity.certificatePEM, forKey: "certificate")
        defaults.set(identity.privateKeyPEM, forKey: "key")
        defaults.set(identity.uniqueID, forKey: "uniqueid")
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
        // nullDevice, NOT Pipe(): nothing ever read these, so openssl blocked
        // forever the moment it filled the 64 KB pipe buffer — and this runs
        // synchronously on the MAIN ACTOR during first-launch startup, so the
        // hang would be a permanently beachballed app with no window.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
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
