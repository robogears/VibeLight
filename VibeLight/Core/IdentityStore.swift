import Foundation

/// Resolves VibeLight's OWN client identity — never Moonlight's (v0.2.0 removed
/// that import; see `resolve`):
/// - macOS: the cert/key in Application Support, generated on first launch
///   (RSA-2048 self-signed, mirroring moonlight-qt's IdentityManager:
///   CN="NVIDIA GameStream Client", 20-year validity), then copied over the
///   stream helper's identity in its own preferences domain.
/// - iOS: an identity born in the keychain (see iOSIdentity).
/// Every computer is paired with it in-app, by PIN.
enum IdentityStore {

    static func resolve(moonlightIdentity: ClientIdentity?) -> ClientIdentity {
        #if os(iOS)
        // iOS never has a desktop-Moonlight plist to import, and /usr/bin/openssl
        // + Process are forbidden. The keychain is the source of truth: a fresh
        // user always self-generates (SecKeyCreateRandomKey + swift-certificates),
        // and the identity lives in the keychain across launches. See iOSIdentity.
        return resolveFromKeychain(
            uniqueID: uniqueID(),
            lookup: { IOSKeychainIdentity.loadPEMs(in: .production) },
            generate: { IOSKeychainIdentity.generatePEMs(in: .production) })
        #else
        // VibeLight is SEPARATE from Moonlight. It used to prefer the identity
        // out of Moonlight's plist ("zero setup" for existing Moonlight users),
        // which quietly entangled the two apps: VibeLight's pairings lived in
        // someone else's file, and installing/resetting/removing Moonlight
        // changed them underneath us. VibeLight now always uses its OWN
        // identity — generated on first launch, stored under Application
        // Support, mirrored only into VibeLight's own helper domain.
        //
        // `moonlightIdentity` is DEAD: every caller passes nil and it is
        // ignored. Never wire it back up (see the paragraph above); remove it
        // here and at its one app call site, AppState.init, together.
        // (audit QUA-moonlight-import-dead-code) A user coming from Moonlight
        // pairs their hosts once, in-app, via PIN — no Moonlight required.
        _ = moonlightIdentity
        switch loadOrCreateOwn(in: directory) {
        case .ready(let cert, let key):
            let identity = ClientIdentity(certificatePEM: cert, privateKeyPEM: key, uniqueID: uniqueID())
            syncHelperIdentity(identity)
            return identity
        case .problem(let message):
            // Left exactly as found on disk. The empty identity makes every host
            // request and pairing attempt fail with this message instead.
            identityProblem = message
            return ClientIdentity(
                certificatePEM: Data(), privateKeyPEM: Data(), uniqueID: uniqueID())
        }
        #endif
    }

    #if os(iOS)
    /// The iOS decision, with the keychain calls passed in so a test can prove
    /// the `.unavailable` branch never generates — `generatePEMs` deletes the
    /// existing identity first, so generating there unpairs every computer.
    /// (audit QUA-ios-unavailable-test-cannot-fail)
    static func resolveFromKeychain(
        uniqueID id: String,
        lookup: () -> IOSKeychainIdentity.Lookup,
        generate: () -> (cert: Data, key: Data)?
    ) -> ClientIdentity {
        switch lookup() {
        case .found(let cert, let key):
            return ClientIdentity(certificatePEM: cert, privateKeyPEM: key, uniqueID: id)

        case .absent:
            // Genuinely nothing in the keychain — first run, or a half-formed
            // identity that cannot assemble either way. Safe to generate.
            if let pems = generate() {
                return ClientIdentity(certificatePEM: pems.cert, privateKeyPEM: pems.key, uniqueID: id)
            }
            return ClientIdentity(certificatePEM: Data(), privateKeyPEM: Data(), uniqueID: id)

        case .unavailable:
            // The keychain could not answer — classically a launch before the
            // first unlock after a reboot. The identity is probably sitting
            // right there. Generating would call deleteAll() and destroy it,
            // unpairing every computer with no way back except re-pairing each
            // one by PIN. Returning an empty identity instead costs nothing:
            // ClientIdentityProvider.secIdentity() re-queries the keychain
            // lazily and caches only on success, and pairingCertificatePEM()
            // re-reads the certificate when pairing starts, so the app recovers
            // on its own once the device is unlocked.
            return ClientIdentity(certificatePEM: Data(), privateKeyPEM: Data(), uniqueID: id)
        }
    }
    #endif

    /// Why resolve() returned an empty identity, in words the person can act
    /// on, when it knows (macOS: identity files present but unreadable, or
    /// creation failed). Set once during resolve() on the main actor at startup;
    /// ClientIdentityProvider shows it instead of a bare openssl error.
    nonisolated(unsafe) static var identityProblem: String?

    // MARK: - Storage

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeLight/identity", isDirectory: true)
    }
    private static let certFileName = "client.pem"
    private static let keyFileName = "client.key"
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

    // MARK: - Own identity files (macOS)
    //
    // audit FS-identity-read-loss: loadOwn used `try?`, so "couldn't read the
    // file" looked exactly like "no file", and generation then deleted the
    // existing private key before openssl even ran — one transient read error
    // (permissions, I/O, an external home folder) silently unpaired every
    // computer. Generation also wrote both files in place, so a failure between
    // the key and the certificate could leave a new key beside an old cert,
    // which fails on every later launch. Now: generate ONLY when both files are
    // genuinely absent, never delete what is there, and build a new pair in a
    // staging folder that is moved into place only once it is complete.

    /// What one identity file on disk turned out to be.
    enum OwnIdentityFile: Equatable {
        /// No such file (ENOENT).
        case missing
        /// Zero bytes: holds no key material, so there is nothing to lose.
        case empty
        case contents(Data)
        /// Exists (or might) but could not be read. Never means "absent".
        case unreadable(String)
    }

    enum OwnIdentityPlan: Equatable {
        case use(cert: Data, key: Data)
        case generate
        /// Leave the files alone and show this message.
        case refuse(String)
    }

    enum OwnIdentityOutcome: Equatable {
        case ready(cert: Data, key: Data)
        case problem(String)
    }

    static func readIdentityFile(at url: URL) -> OwnIdentityFile {
        do {
            let data = try Data(contentsOf: url)
            return data.isEmpty ? .empty : .contents(data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            return .unreadable("\(url.lastPathComponent) (no permission to read it)")
        } catch {
            return .unreadable("\(url.lastPathComponent) (\(unreadableReason(url: url, error: error)))")
        }
    }

    /// A short reason for the refusal message. Foundation's localizedDescription
    /// is a whole sentence that repeats the file name ("The file “client.key”
    /// couldn’t be opened."), which read badly nested inside ours.
    /// (audit FS-identity-read-loss review: refusal copy)
    private static func unreadableReason(url: URL, error: Error) -> String {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            return "it's a folder, not a file"
        }
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        if let underlying, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code))).lowercased()
        }
        return "an unexpected read error, code \((error as NSError).code)"
    }

    /// Spelled out in full: "Application Support" alone is the hidden one
    /// inside the Library folder, which a person can't find from the name.
    static let identityFolderForPeople = "~/Library/Application Support/VibeLight/identity"

    /// The pure rule. Only "nothing there" on BOTH sides may generate. A
    /// zero-byte file counts as nothing: builds before this fix pre-created an
    /// empty client.key before openssl ran, so a failed first launch left
    /// exactly that, and refusing there would strand someone who never had an
    /// identity. Any unreadable file, or one real file without its partner,
    /// is refused — the real half may be the key every computer trusts.
    static func plan(cert: OwnIdentityFile, key: OwnIdentityFile) -> OwnIdentityPlan {
        switch (cert, key) {
        case (.contents(let c), .contents(let k)):
            return .use(cert: c, key: k)
        case (.missing, .missing), (.missing, .empty), (.empty, .missing), (.empty, .empty):
            return .generate
        case (.unreadable(let why), _), (_, .unreadable(let why)):
            return .refuse("VibeLight can't read its identity file \(why), so it changed nothing. "
                + "In Finder, choose Go ▸ Go to Folder…, open \(identityFolderForPeople), "
                + "and check that file: select it, choose File ▸ Get Info, and make sure it's an "
                + "ordinary file you can read (see Sharing & Permissions). Then reopen VibeLight.")
        default:
            let lost = (key == .missing || key == .empty) ? keyFileName : certFileName
            return .refuse("VibeLight's identity file \(lost) is missing or empty. "
                + "Put it back in \(identityFolderForPeople) and reopen VibeLight, "
                + "or move that identity folder to the Trash to start over (every computer then needs pairing again).")
        }
    }

    /// Loads the identity in `directory`, creating one only when none exists.
    /// `openssl` is injectable so a test can make generation fail.
    static func loadOrCreateOwn(
        in directory: URL,
        openssl: URL = URL(fileURLWithPath: "/usr/bin/openssl")
    ) -> OwnIdentityOutcome {
        let certURL = directory.appendingPathComponent(certFileName)
        let keyURL = directory.appendingPathComponent(keyFileName)
        let certFile = readIdentityFile(at: certURL), keyFile = readIdentityFile(at: keyURL)
        switch plan(cert: certFile, key: keyFile) {
        case .use(let cert, let key):
            removeStagingFolders(in: directory)
            return .ready(cert: cert, key: key)
        case .refuse(let message):
            if let pair = finishInterruptedCreation(in: directory, cert: certFile, key: keyFile, openssl: openssl) {
                removeStagingFolders(in: directory)
                return .ready(cert: pair.cert, key: pair.key)
            }
            return .problem(message)
        case .generate:
            if let pair = generateAndPersist(in: directory, openssl: openssl) {
                removeStagingFolders(in: directory)
                return .ready(cert: pair.cert, key: pair.key)
            }
            return .problem("VibeLight couldn't create its client identity. Quit and reopen VibeLight to try again.")
        }
    }

    // audit FS-identity-read-loss review (staging leftovers): `defer` doesn't
    // run when the app is killed or the power fails, so an interrupted
    // creation left its `.new-<UUID>` folder behind — with an unused private
    // key inside if openssl had got that far — and nothing ever removed it. A
    // kill between the two renames also left the new key in place without its
    // certificate (still in the staging folder), which the rule above refuses
    // on every launch.

    private static let stagingPrefix = ".new-"

    /// Only folders this code made: `.new-` followed by a UUID.
    private static func stagingFolders(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter {
            $0.hasPrefix(stagingPrefix) && UUID(uuidString: String($0.dropFirst(stagingPrefix.count))) != nil
        }.map { directory.appendingPathComponent($0, isDirectory: true) }
    }

    /// Called only once the identity in place is complete: from then on no
    /// staging folder can hold anything that is needed, and a creation still
    /// running elsewhere would find the files present and give up anyway.
    private static func removeStagingFolders(in directory: URL) {
        for folder in stagingFolders(in: directory) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Completes a creation that was cut off after the key was moved into
    /// place: the certificate is still alone in its staging folder. It is moved
    /// in only when its public key matches the key in place, so a certificate
    /// that belongs to some other key is never put beside the real one.
    private static func finishInterruptedCreation(
        in directory: URL, cert: OwnIdentityFile, key: OwnIdentityFile, openssl: URL
    ) -> (cert: Data, key: Data)? {
        guard cert == .missing || cert == .empty, case .contents(let keyData) = key else { return nil }
        let finalKey = directory.appendingPathComponent(keyFileName)
        let finalCert = directory.appendingPathComponent(certFileName)
        let candidates = stagingFolders(in: directory).filter {
            if case .contents = readIdentityFile(at: $0.appendingPathComponent(certFileName)),
               readIdentityFile(at: $0.appendingPathComponent(keyFileName)) == .missing {
                return true
            }
            return false
        }
        guard !candidates.isEmpty,
              let keyPub = runOpenSSL(openssl, ["pkey", "-pubout", "-in", finalKey.path]),
              !keyPub.isEmpty else { return nil }
        for folder in candidates {
            let stagedCert = folder.appendingPathComponent(certFileName)
            guard case .contents(let certData) = readIdentityFile(at: stagedCert),
                  runOpenSSL(openssl, ["x509", "-noout", "-pubkey", "-in", stagedCert.path]) == keyPub
            else { continue }
            guard holdsNothing(finalCert), rename(stagedCert.path, finalCert.path) == 0 else { return nil }
            return (certData, keyData)
        }
        return nil
    }

    private static func generateAndPersist(
        in directory: URL, openssl: URL
    ) -> (cert: Data, key: Data)? {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // A fresh staging folder beside the real files (same volume, so the
        // final rename is atomic per file). Anything that goes wrong is thrown
        // away with it; the real location is never written until both halves
        // exist and match.
        let staging = directory.appendingPathComponent("\(stagingPrefix)\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: staging, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        defer { try? fm.removeItem(at: staging) }
        let newCert = staging.appendingPathComponent(certFileName)
        let newKey = staging.appendingPathComponent(keyFileName)
        // Pre-create the key file 0600 so openssl truncate-writes into it
        // (O_CREAT only applies perms on *creation*) instead of creating it
        // under the umask (0644) — the RSA private key is never readable by
        // group/other, and the rename below keeps the mode.
        guard fm.createFile(atPath: newKey.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { return nil }

        guard runOpenSSL(openssl, [
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", newKey.path, "-out", newCert.path,
            "-days", "7300", "-nodes", "-sha256",
            "-subj", "/CN=NVIDIA GameStream Client",
        ]) != nil,
              case .contents(let cert) = readIdentityFile(at: newCert),
              case .contents(let key) = readIdentityFile(at: newKey),
              // openssl does not check the final flush of its output, so a full
              // disk can leave a truncated cert behind a zero exit. Both halves
              // must yield the same public key before they go anywhere.
              let certPub = runOpenSSL(openssl, ["x509", "-noout", "-pubkey", "-in", newCert.path]),
              let keyPub = runOpenSSL(openssl, ["pkey", "-pubout", "-in", newKey.path]),
              !certPub.isEmpty, certPub == keyPub
        else { return nil }

        // Move into place, key first. Each destination must still be empty
        // (missing or zero bytes) right now — if anything real appeared since
        // the read, leave it and give up rather than overwrite it.
        let finalKey = directory.appendingPathComponent(keyFileName)
        let finalCert = directory.appendingPathComponent(certFileName)
        guard holdsNothing(finalKey), holdsNothing(finalCert),
              rename(newKey.path, finalKey.path) == 0 else { return nil }
        guard holdsNothing(finalCert), rename(newCert.path, finalCert.path) == 0 else {
            // The key we just placed was never used by anything; take it back
            // so the folder is left as we found it rather than half-filled.
            if case .contents(let placed) = readIdentityFile(at: finalKey), placed == key {
                try? fm.removeItem(at: finalKey)
            }
            return nil
        }
        return (cert, key)
    }

    private static func holdsNothing(_ url: URL) -> Bool {
        switch readIdentityFile(at: url) {
        case .missing, .empty: return true
        case .contents, .unreadable: return false
        }
    }

    /// Runs openssl and returns its stdout, or nil on a launch failure or a
    /// non-zero exit. Output here is a few hundred bytes (a public key), far
    /// below the pipe buffer, so reading after exit cannot deadlock. stderr is
    /// nullDevice, NOT Pipe(): nothing reads it, and an unread pipe blocks the
    /// child once full — this runs synchronously on the MAIN ACTOR during
    /// first-launch startup, so that hang would be a permanently beachballed
    /// app with no window.
    private static func runOpenSSL(_ openssl: URL, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = openssl
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
    #endif
}
