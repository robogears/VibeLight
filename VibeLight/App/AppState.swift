#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import Observation

/// Which screen the big-picture UI is showing.
enum Screen: Equatable {
    case home
    case settings
}

/// Modal layers above the current screen. Exactly one at a time; they capture
/// all navigation input while visible.
enum Overlay: Equatable {
    case sessionHUD                 // reconciling / launching progress
    case sessionEnded(StreamApp)    // stream closed — resume / quit / home
    case error(String)
    case cheatSheet                 // keybind reference
    case update                     // a newer version is available
    case hosts                      // computer list + add-by-IP
    case relocate                   // offer to move into /Applications
    case customResolution           // type an arbitrary WxH
    case confirmOverridePreset(Int) // slot already taken — override it?
    case presetSlotMenu(Int)        // rename / clear a filled slot
    case renamePreset(Int)          // type a new preset name
    case moonDeckSetup(String)      // set up / pair MoonDeckBuddy for host id
    case confirmRestartPC(String)   // confirm force-restarting host id
    case confirmSwitchStream(running: String, target: StreamApp)  // host busy — switch to target?
}

/// First-run setup wizard steps (see `OnboardingFlow`). Unskippable; shown once
/// until `hasCompletedSetup`, and re-triggerable from Settings ▸ Restart Setup.
enum OnboardingStep: Int, CaseIterable, Equatable {
    case welcome, theme, quality, presets, finish
    case finale   // cinematic hand-off after "Jump in" — non-interactive
}

/// The composition root: owns every module, routes navigation events, and
/// exposes observable state the views render from. All UI decisions flow
/// through `route(_:)` so controller, keyboard, and mouse behave identically.
@MainActor
@Observable
final class AppState {
    // MARK: Modules

    @ObservationIgnored let api: HostAPIClient
    @ObservationIgnored let artwork: ArtworkStore
    @ObservationIgnored let identityProvider: ClientIdentityProvider
    @ObservationIgnored let clientUniqueID: String
    #if os(macOS)
    let session: StreamSessionManager
    #else
    let session: InProcessStreamEngine
    #endif
    let focus = FocusEngine()
    let controller = ControllerManager()
    /// The launch deal-in intro (plays once per app launch; see `LaunchIntro`).
    let intro = LaunchIntro()
    let updateService = UpdateService()
    /// Console-style menu sounds (focus tick / confirm / back).
    @ObservationIgnored let sfx = MenuSFX()
    /// OS/window chrome, injected after construction (macOS: the app delegate's
    /// `WindowCoordinator`; iOS: `iOSPlatformChrome` from the SwiftUI scene).
    @ObservationIgnored weak var chrome: (any PlatformChrome)?

    // MARK: Library state

    private(set) var hosts: [StreamHost] = []      // merged: Moonlight + user-added, capped at 4
    /// Persisted so a relaunch reopens on the PC you last used (not whichever
    /// host happens to sort first). Restored in init when the host still exists.
    private(set) var selectedHostID: String? {
        didSet {
            guard selectedHostID != oldValue else { return }
            UserDefaults.standard.set(selectedHostID, forKey: Self.selectedHostKey)
            // Also stash the host's stable address. A host's `id` changes
            // representation across launches (added:<ip> ↔ real uuid, Moonlight
            // import present vs absent, pre- vs post-pair), so an exact-id match
            // alone silently loses the selection and falls back to the first
            // host. The address survives all of those, so restore can recover.
            UserDefaults.standard.set(selectedHost?.candidateAddresses.first?.host,
                                      forKey: Self.selectedHostAddrKey)
        }
    }
    private static let selectedHostKey = "vibelight.lastSelectedHost"
    private static let selectedHostAddrKey = "vibelight.lastSelectedHostAddr"

    /// Which host to reopen on launch: the saved id if it still exists, else the
    /// host at the saved (stable) address — this is what makes the "remember my
    /// last PC" preference survive a host's id changing representation between
    /// launches — else the first host.
    nonisolated static func resolveSelectedHostID(in hosts: [StreamHost],
                                                  savedID: String?, savedAddr: String?) -> String? {
        if let savedID, let match = hosts.first(where: { $0.id == savedID }) { return match.id }
        if let savedAddr, !savedAddr.isEmpty,
           let match = hosts.first(where: { $0.candidateAddresses.contains { $0.host == savedAddr } }) {
            return match.id
        }
        return hosts.first?.id
    }
    private(set) var serverInfo: ServerInfo?
    private(set) var hostAddress: String?
    private(set) var hostError: String?
    private(set) var isRefreshing = false
    /// Apps to render: fresh from the host when online, else the plist cache.
    private(set) var apps: [StreamApp] = []

    // Host management (the top-right chip menu).
    @ObservationIgnored private var importedHosts: [StreamHost] = []
    private(set) var addedHosts: [AddedHost] = []
    static let maxHosts = 4
    var addHostIP: String = ""
    var addHostError: String?

    /// A computer the user added by IP (persisted separately from Moonlight's
    /// read-only plist). `serverCert` is filled in once we pair with it.
    struct AddedHost: Codable, Equatable, Sendable {
        var name: String
        var ip: String
        var uuid: String?
        var serverCert: Data?
    }

    /// Live pairing state for the computer manager.
    struct PairingState: Equatable, Sendable {
        var hostID: String
        var hostName: String
        var pin: String
        enum Status: Equatable, Sendable {
            case waiting, success, wrongPIN, unreachable, failed(String)
        }
        var status: Status
        var webUIURL: String
    }
    var pairing: PairingState?
    @ObservationIgnored private var pairingTask: Task<Void, Never>?

    // MARK: MoonDeckBuddy (force-restart the host PC)

    /// Per-host MoonDeckBuddy settings, keyed by the host's stable primary
    /// address. Persisted; the port defaults to MoonDeckBuddy's 59999.
    struct MoonDeckConfig: Codable, Equatable, Sendable {
        var port: Int = MoonDeckBuddyClient.defaultPort
        var paired: Bool = false
        /// Leaf TLS cert captured at first pairing; pinned on later connections
        /// so an active MITM can't hijack the restart credential.
        var pinnedCert: Data?
    }
    /// Live pairing progress shown in the MoonDeckBuddy setup overlay.
    struct MoonDeckPairing: Equatable, Sendable {
        var hostID: String
        var pin: String
        enum Status: Equatable, Sendable {
            case connecting, waiting, paired, offline, failed(String)
        }
        var status: Status
    }
    @ObservationIgnored let moonDeck = MoonDeckBuddyClient()
    /// One client identity for this VibeLight install (the whole Basic-auth
    /// credential). Generated once, reused for every host.
    private(set) var moonDeckClientID: String = ""
    private(set) var moonDeckConfigs: [String: MoonDeckConfig] = [:]
    var moonDeckPairing: MoonDeckPairing?
    /// The port field text in the setup overlay.
    var moonDeckPortText: String = String(MoonDeckBuddyClient.defaultPort)
    /// True while a restart request is in flight (locks the confirm overlay).
    private(set) var moonDeckRestarting = false
    @ObservationIgnored private var moonDeckPairingTask: Task<Void, Never>?
    private static let moonDeckClientKey = "vibelight.moondeck.clientid"
    private static let moonDeckConfigsKey = "vibelight.moondeck.configs"

    var selectedHost: StreamHost? {
        hosts.first { $0.id == selectedHostID }
    }
    var hostOnline: Bool { serverInfo != nil }

    // MARK: UI state

    var screen: Screen = .home
    var overlay: Overlay?
    var settings: StreamSettings {
        didSet { persistSettings() }
    }

    /// The launcher background style (Settings ▸ Themes). Global appearance pref,
    /// stored on its own key so it's NOT captured into per-session stream presets.
    var backgroundTheme: BackgroundTheme = .ambient {
        didSet {
            guard oldValue != backgroundTheme else { return }
            UserDefaults.standard.set(backgroundTheme.rawValue, forKey: Self.backgroundThemeKey)
        }
    }

    // MARK: First-run setup wizard

    /// The current setup-wizard step, or nil when the launcher is live. Non-nil
    /// gates ALL input into `routeOnboarding` (see `route`), so it can't be
    /// skipped or bypassed into the launcher.
    private(set) var onboardingStep: OnboardingStep?
    /// Which quality control (resolution / fps / bitrate) is focused on the
    /// quality step (0…2).
    private(set) var onboardingQualityFocus = 0
    /// Bump this to FORCE every user to redo setup on their next update (e.g.
    /// when a new setup step is added). The wizard shows whenever the user's
    /// stored completed version is below this. (Switching to this versioned key
    /// from the old boolean also re-shows setup once for everyone now.)
    static let requiredSetupVersion = 1
    /// The three quality controls the wizard asks about, in order.
    let onboardingQualityRows: [SettingsRow] = [.resolution, .fps, .bitrate]
    var isOnboarding: Bool { onboardingStep != nil }

    /// Settings rows currently adjustable via left/right (vList doesn't consume
    /// horizontal moves — that's how value adjustment works).
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// The active settings tab (L1/R1 switch between them). Grouping keeps each
    /// screen short instead of one long scroll.
    var settingsTab: SettingsTab = .video

    // MARK: Presets — six fixed slots (nil = empty)

    static let presetSlotCount = 6
    /// Exactly `presetSlotCount` entries; `nil` = an empty slot. Slot index i
    /// (0-based) is shown as "Preset i+1".
    private(set) var presets: [StreamPreset?] = Array(repeating: nil, count: presetSlotCount)
    /// Which slot's settings are currently loaded (nil once settings diverge or
    /// a slot is cleared).
    private(set) var activePresetSlot: Int?
    /// Non-nil when focus is on the home-screen preset rail (managed outside the
    /// FocusEngine so it uses left/right to enter/leave the app shelf).
    var focusedPresetSlot: Int?
    private static let presetsKey = "vibelight.presets.v2"
    private static let activePresetKey = "vibelight.activePresetSlot"

    func defaultPresetName(forSlot i: Int) -> String { "Preset \(i + 1)" }

    /// Which input device is driving right now. Controller/keyboard hides the
    /// mouse cursor and disables hover-focus (so tiles scrolling under a parked
    /// cursor can't steal focus); mouse use brings the cursor and hover back.
    private(set) var inputMode: InputMode = .directed

    /// Glyph family for on-screen hints: controller glyphs while a pad drives,
    /// keyboard/desk glyphs when the mouse took over.
    var effectiveGlyphStyle: ControllerGlyphStyle {
        inputMode == .pointer ? .keyboard : controller.glyphStyle
    }

    private static let settingsKey = "vibelight.streamSettings"
    private static let backgroundThemeKey = "vibelight.backgroundTheme"
    private static let setupVersionKey = "vibelight.setupVersion"

    // MARK: - Boot

    init() {
        let importer = MoonlightConfigImporter()
        let imported = try? importer.importAll()

        // Reuse Moonlight's identity if present; otherwise generate our own so
        // a user without Moonlight can still pair hosts in-app.
        let identity = IdentityStore.resolve(moonlightIdentity: imported?.identity)
        let identityProvider = ClientIdentityProvider(identity: identity)
        self.identityProvider = identityProvider
        self.clientUniqueID = identity.uniqueID
        let client = HostAPIClient(identityProvider: identityProvider)
        api = client
        artwork = ArtworkStore(api: client)
        #if os(macOS)
        session = StreamSessionManager(api: client)
        #else
        session = InProcessStreamEngine(api: client)
        #endif

        // Our settings: previously persisted > imported Moonlight defaults > fallback.
        var loaded: StreamSettings
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(StreamSettings.self, from: data) {
            loaded = saved
        } else {
            loaded = imported?.settings ?? .fallback
        }
        // Snap the imported bitrate (e.g. 87500) onto the clean 10 Mbps grid so
        // it reads "90 Mbps", not "87". didSet doesn't fire during init.
        let step = Self.bitrateStep
        loaded.bitrateKbps = min(max(((loaded.bitrateKbps + step / 2) / step) * step,
                                     Self.bitrateMin), Self.bitrateMax)
        settings = loaded
        if let raw = UserDefaults.standard.string(forKey: Self.backgroundThemeKey),
           let theme = BackgroundTheme(rawValue: raw) {
            backgroundTheme = theme   // didSet doesn't fire during init
        }
        // Show the setup wizard when the user hasn't completed the CURRENT
        // required version (fresh install → 0; a bump forces a redo for all).
        let completedSetup = UserDefaults.standard.integer(forKey: Self.setupVersionKey)
        if completedSetup < Self.requiredSetupVersion { onboardingStep = .welcome }

        importedHosts = (imported?.hosts ?? []).filter(\.isPaired)
        addedHosts = Self.loadAddedHosts()
        rebuildHosts()
        // Reopen on the last-used PC if it's still around (by id, or by its
        // stable address if the id's representation changed); else the first host.
        let savedHostID = UserDefaults.standard.string(forKey: Self.selectedHostKey)
        let savedHostAddr = UserDefaults.standard.string(forKey: Self.selectedHostAddrKey)
        selectedHostID = Self.resolveSelectedHostID(in: hosts, savedID: savedHostID, savedAddr: savedHostAddr)
        apps = displayApps(from: selectedHost?.apps ?? [])
        if hosts.isEmpty {
            hostError = "No computers yet — open the computer menu (top-right) to add one by IP."
        }

        presets = Self.loadPresets()
        let savedSlot = UserDefaults.standard.object(forKey: Self.activePresetKey) as? Int
        activePresetSlot = savedSlot.flatMap { (0..<Self.presetSlotCount).contains($0) ? $0 : nil }

        // MoonDeckBuddy: a stable per-install client id + saved per-host configs.
        if let existing = UserDefaults.standard.string(forKey: Self.moonDeckClientKey), !existing.isEmpty {
            moonDeckClientID = existing
        } else {
            moonDeckClientID = UUID().uuidString
            UserDefaults.standard.set(moonDeckClientID, forKey: Self.moonDeckClientKey)
        }
        if let data = UserDefaults.standard.data(forKey: Self.moonDeckConfigsKey),
           let decoded = try? JSONDecoder().decode([String: MoonDeckConfig].self, from: data) {
            moonDeckConfigs = decoded
        }

        wireCallbacks()
        rebuildFocus()
        focus.focusFirst()
        startRefreshLoop()
        runStartupChecks()
    }

    // MARK: - Presets

    private static func loadPresets() -> [StreamPreset?] {
        let empty = Array<StreamPreset?>(repeating: nil, count: presetSlotCount)
        guard let data = UserDefaults.standard.data(forKey: presetsKey),
              let arr = try? JSONDecoder().decode([StreamPreset?].self, from: data) else { return empty }
        // Normalize to exactly the slot count (tolerate an older/shorter blob).
        var slots = Array(arr.prefix(presetSlotCount))
        while slots.count < presetSlotCount { slots.append(nil) }
        return slots
    }

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.presetsKey)
        }
        UserDefaults.standard.set(activePresetSlot, forKey: Self.activePresetKey)
    }

    /// Settings-header click / select on slot `i`: snapshot the current settings
    /// into that slot. If it's already taken, confirm the override first.
    func requestSaveToSlot(_ i: Int) {
        guard presets.indices.contains(i) else { return }
        if presets[i] != nil {
            presentOverlay(.confirmOverridePreset(i))
        } else {
            performSaveToSlot(i)
        }
    }

    /// Actually writes the current settings into slot `i` (keeps the slot's
    /// existing name on override).
    func performSaveToSlot(_ i: Int) {
        guard presets.indices.contains(i) else { return }
        let name = presets[i]?.name ?? defaultPresetName(forSlot: i)
        presets[i] = StreamPreset(id: UUID().uuidString, name: name, settings: settings)
        activePresetSlot = i
        persistPresets()
        controller.focusTick()
    }

    /// Home rail: load slot `i`'s settings (no-op for an empty slot).
    func applySlot(_ i: Int) {
        guard presets.indices.contains(i), let preset = presets[i] else { return }
        settings = preset.settings
        activePresetSlot = i
        persistPresets()
    }

    func clearSlot(_ i: Int) {
        guard presets.indices.contains(i) else { return }
        presets[i] = nil
        if activePresetSlot == i { activePresetSlot = nil }
        persistPresets()
    }

    func renameSlot(_ i: Int, to name: String) {
        guard presets.indices.contains(i), presets[i] != nil else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        presets[i]?.name = trimmed.isEmpty ? defaultPresetName(forSlot: i) : trimmed
        persistPresets()
    }

    /// Parses a "presetslot:N" focus id.
    func presetSlotIndex(_ id: String?) -> Int? {
        guard let id, id.hasPrefix("presetslot:") else { return nil }
        return Int(id.dropFirst("presetslot:".count))
    }

    /// Bound to the rename overlay's text field.
    var renameText: String = ""

    /// Seeds + opens the rename overlay for slot `i`.
    func openRename(_ i: Int) {
        guard presets.indices.contains(i) else { return }
        renameText = presets[i]?.name ?? defaultPresetName(forSlot: i)
        presentOverlay(.renamePreset(i))
    }

    func applyRename(_ i: Int) {
        renameSlot(i, to: renameText)
        dismissOverlay()
    }

    // MARK: - Home preset rail navigation (all six slots always present)

    var isPresetRailActive: Bool { focusedPresetSlot != nil }

    private func enterPresetRail() {
        focusedPresetSlot = activePresetSlot ?? 0
        controller.focusTick()
    }

    private func exitPresetRail() {
        focusedPresetSlot = nil
        controller.focusTick()
    }

    private func movePresetFocus(_ delta: Int) {
        guard let i = focusedPresetSlot else { return }
        let next = min(max(i + delta, 0), Self.presetSlotCount - 1)
        guard next != i else { return }
        focusedPresetSlot = next
        controller.focusTick()
    }

    private func wireCallbacks() {
        controller.onEvent = { [weak self] event in
            self?.route(event)
        }
        controller.onInputActivity = { [weak self] mode in
            guard let self else { return }
            self.intro.skip()   // any controller/keyboard/mouse input ends the intro
            if mode == .directed {
                // Console mode: cursor vanishes until the mouse moves again
                // (the OS auto-reveals it on movement — no unhide bookkeeping).
                chrome?.hidePointer()
            }
            if inputMode != mode { inputMode = mode }
        }
        controller.quitAppChordEnabled = { [weak self] in
            guard let self else { return false }
            return screen == .home && overlay == nil
        }
        focus.onFocusChange = { [weak self] _, new in
            guard let self, let new else { return }
            self.controller.focusTick()   // haptic on every move (unchanged)
            // Sound only when LANDING on the home header (Restart PC / host chip).
            // Scrolling the app shelf, the preset rail, and settings rows is
            // silent — audio there is reserved for deliberate actions.
            if new.hasPrefix("header:") { self.sfx.play(.move) }
        }
        #if os(iOS)
        // While streaming, the in-process engine flips the controller manager
        // into stream-passthrough (pads drive the game, not the launcher).
        session.controllerSource = controller
        #endif
        // Failures arrive asynchronously (startup watchdog, child termination
        // handler) long after launch() returned — this observer is the ONLY
        // reliable way to catch them. Without it a failed launch strands the
        // user on the input-locked session HUD forever.
        session.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            refreshKeepAwake()
            if case .failed(let message) = phase {
                chrome?.endStreamPresentationIfActive()
                presentOverlay(.error(message))
            }
        }
        session.onStreamDidStart = { [weak self] helperPID in
            guard let self else { return }
            chrome?.beginStreamPresentation(helperPID: helperPID)
            overlay = nil
            rebuildFocus()
        }
        session.onStreamDidEnd = { [weak self] _ in
            guard let self else { return }
            // Only reclaim the screen if a presentation actually began. A stream
            // that ends while still .launching (STARTED never arrived) never ran
            // beginStreamPresentation, so an unconditional call here would
            // spuriously re-activate + restore immersive chrome. (SEV-07)
            chrome?.endStreamPresentationIfActive()
            if case .ending(let app) = session.phase {
                if session.remoteQuitRequested {
                    // The user explicitly quit the game — no "still running"
                    // decision card, straight back to the library.
                    session.acknowledgeEnd()
                    dismissOverlay()
                } else {
                    presentOverlay(.sessionEnded(app))
                }
            } else {
                rebuildFocus()
            }
            Task { await self.refreshSelectedHost() }
        }
    }

    // MARK: - Host refresh

    private func startRefreshLoop() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshSelectedHost()
                try? await Task.sleep(for: .seconds(12))
            }
        }
    }

    private static let skipRelocationKey = "vibelight.skipRelocation"

    /// Launch sequence: first offer to move into /Applications (if we're running
    /// from Downloads / a translocated copy), otherwise go straight to the
    /// update check. Relocation takes priority because it relaunches the app.
    private func runStartupChecks() {
        let skipped = UserDefaults.standard.bool(forKey: Self.skipRelocationKey)
        if AppRelocator.shouldOfferRelocation() && !skipped {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if overlay == nil, screen == .home { presentOverlay(.relocate) }
            }
        } else {
            checkForUpdatesOnLaunch()
        }
    }

    func moveToApplications() {
        if !AppRelocator.moveToApplications() {
            overlay = .error("Couldn't move VibeLight to Applications. Drag it there manually from Finder.")
            rebuildFocus()
            if focus.focusedItemID == nil { focus.focusFirst() }
        }
        // On success the app relaunches from /Applications and this instance quits.
    }

    /// "Not Now" — don't nag about relocation again, then resume the update check.
    func declineRelocation() {
        UserDefaults.standard.set(true, forKey: Self.skipRelocationKey)
        dismissOverlay()
        checkForUpdatesOnLaunch()
    }

    /// Silent update check a couple seconds after launch; if a newer version is
    /// published and nothing else is on screen, greet the user with the card.
    private func checkForUpdatesOnLaunch() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            await updateService.check(silent: true)
            if updateService.phase == .available, overlay == nil, screen == .home {
                presentOverlay(.update)
            }
        }
    }

    /// Settings "Check for Updates": if one's already found, jump to the card;
    /// otherwise run a visible check and surface the result.
    func checkForUpdates() {
        // Already have an update found or staged → jump back to the card.
        if updateService.phase == .available || updateService.phase == .readyToInstall {
            presentOverlay(.update)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await updateService.check(silent: false)
            // Re-check after the await: don't stomp a session HUD/error that
            // appeared while we were checking, or fire mid-stream.
            if updateService.phase == .available, overlay == nil, session.phase == .idle {
                presentOverlay(.update)
            }
        }
    }

    func startUpdate() {
        Task { await updateService.downloadAndInstall() }
    }

    // MARK: - Host management

    func openHostMenu() {
        addHostError = nil
        presentOverlay(.hosts)
    }

    private static let addedHostsKey = "vibelight.addedHosts"

    private static func loadAddedHosts() -> [AddedHost] {
        guard let data = UserDefaults.standard.data(forKey: addedHostsKey),
              let arr = try? JSONDecoder().decode([AddedHost].self, from: data) else { return [] }
        return arr
    }

    private func persistAddedHosts() {
        if let data = try? JSONEncoder().encode(addedHosts) {
            UserDefaults.standard.set(data, forKey: Self.addedHostsKey)
        }
    }

    /// Merges Moonlight's paired hosts with the user-added ones, de-duped by
    /// address/uuid and capped at `maxHosts`.
    private func rebuildHosts() {
        var merged = importedHosts
        for added in addedHosts {
            let h = Self.streamHost(from: added)
            let dupe = merged.contains {
                $0.id == h.id || $0.manualAddress == added.ip || $0.localAddress == added.ip
            }
            if !dupe { merged.append(h) }
        }
        hosts = Array(merged.prefix(Self.maxHosts))
    }

    private static func streamHost(from added: AddedHost) -> StreamHost {
        StreamHost(id: added.uuid ?? "added:\(added.ip)", name: added.name,
                   localAddress: added.ip, localPort: 47989,
                   remoteAddress: nil, remotePort: 47989,
                   manualAddress: added.ip, manualPort: 47989,
                   macAddress: nil, serverCertPEM: added.serverCert, apps: [])
    }

    // MARK: - Pairing

    /// Whether this host still needs pairing (no pinned server cert yet).
    func needsPairing(_ host: StreamHost) -> Bool { !host.isPaired }

    func beginPairing(_ host: StreamHost) {
        guard let ip = host.manualAddress ?? host.localAddress ?? host.candidateAddresses.first?.host else { return }
        pairingTask?.cancel()
        let pin = HostPairing.generatePIN()
        pairing = PairingState(hostID: host.id, hostName: host.name, pin: pin,
                               status: .waiting, webUIURL: "https://\(ip):47990")
        rebuildFocus()
        // Phase 1 blocks until the user types the PIN on the PC's web UI — which
        // means leaving this screen. On iOS, an auto-lock would suspend the app
        // and drop the pending socket, so keep the display awake until pairing
        // resolves (no-op on macOS).
        setPairingKeepAwake(true)
        pairingTask = Task { [weak self] in
            guard let self else { return }
            let manager = HostPairing(identityProvider: identityProvider, uniqueID: clientUniqueID)
            let result = await manager.pair(address: ip, pin: pin)
            guard !Task.isCancelled, pairing?.hostID == host.id else { setPairingKeepAwake(false); return }
            setPairingKeepAwake(false)
            switch result {
            case .paired(let certPEM):
                savePairedHost(ip: ip, serverCertPEM: certPEM)
                pairing?.status = .success
            case .wrongPIN: pairing?.status = .wrongPIN
            case .unreachable: pairing?.status = .unreachable
            case .alreadyInProgress:
                pairing?.status = .failed("The host is already handling a pairing request — wait a moment and retry.")
            case .failed(let m): pairing?.status = .failed(m)
            }
            rebuildFocus()
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        pairing = nil
        setPairingKeepAwake(false)
        rebuildFocus()
        if focus.focusedItemID == nil { focus.focusFirst() }
    }

    /// Hold the display awake for the duration of pairing so an iOS auto-lock
    /// can't suspend the app while phase 1 waits for the PIN. iOS only — macOS
    /// already keeps the big-picture display awake.
    private func setPairingKeepAwake(_ on: Bool) {
        pairingWantsKeepAwake = on
        refreshKeepAwake()
    }

    @ObservationIgnored private var pairingWantsKeepAwake = false

    /// iOS idle-timer ownership, in one place: the screen must not sleep while
    /// pairing (PIN is on screen, hands are on the other computer) or during a
    /// stream (controller input never resets the idle timer — the display
    /// would sleep mid-game). Streaming keep-awake honors the user's
    /// "Keep Display Awake" setting; pairing always holds it.
    private func refreshKeepAwake() {
        #if os(iOS)
        let streamActive: Bool
        switch session.phase {
        case .streaming, .launching: streamActive = true
        default: streamActive = false
        }
        UIApplication.shared.isIdleTimerDisabled =
            pairingWantsKeepAwake || (settings.keepAwake && streamActive)
        #endif
    }

    #if os(iOS)
    /// iOS "Quit Game on App Exit": backgrounding suspends our sockets, so the
    /// stream can't survive anyway — tear down locally, and when the setting is
    /// on also /cancel the remote game. Runs inside a UIKit background task so
    /// the HTTPS round-trip has time to land before suspension.
    func handleAppDidEnterBackground() {
        let live: Bool
        switch session.phase {
        case .streaming, .launching: live = true
        default: live = false
        }
        guard live else { return }
        let taskID = UIApplication.shared.beginBackgroundTask()
        Task {
            // 2.5 s budget: iOS SIGKILLs (0x8BADF00D) any app that takes ≥5 s to
            // terminate — the /cancel is best-effort, staying alive is not.
            await stopStreamForAppExit(budget: .milliseconds(2500))
            session.disconnect()           // always: never strand a dead .streaming UI
            UIApplication.shared.endBackgroundTask(taskID)
        }
    }
    #endif

    // MARK: - MoonDeckBuddy (force-restart the host PC)

    /// Stable key for per-host MoonDeckBuddy config: the host's primary address.
    private func moonDeckKey(for host: StreamHost) -> String? {
        host.candidateAddresses.first?.host
    }
    /// Address to actually connect to: the resolved address GameStream reached
    /// (works over Tailscale / when remote), falling back to the primary. Config
    /// stays keyed by the stable primary via `moonDeckKey`.
    private func moonDeckConnectAddress(for host: StreamHost) -> String? {
        if host.id == selectedHostID, let resolved = hostAddress, !resolved.isEmpty { return resolved }
        return moonDeckKey(for: host)
    }
    func moonDeckConfig(for host: StreamHost) -> MoonDeckConfig? {
        guard let key = moonDeckKey(for: host) else { return nil }
        return moonDeckConfigs[key]
    }
    func isMoonDeckPaired(_ host: StreamHost) -> Bool {
        moonDeckConfig(for: host)?.paired == true
    }
    private func updateMoonDeckConfig(for host: StreamHost, _ mutate: (inout MoonDeckConfig) -> Void) {
        guard let key = moonDeckKey(for: host) else { return }
        var cfg = moonDeckConfigs[key] ?? MoonDeckConfig()
        mutate(&cfg)
        moonDeckConfigs[key] = cfg
        if let data = try? JSONEncoder().encode(moonDeckConfigs) {
            UserDefaults.standard.set(data, forKey: Self.moonDeckConfigsKey)
        }
    }

    /// The "Restart PC" button in the header. Paired → confirm; otherwise walk
    /// the user through installing/pairing MoonDeckBuddy first.
    func requestRestartPC() {
        guard let host = selectedHost else { return }
        moonDeckRestarting = false
        if isMoonDeckPaired(host) {
            presentOverlay(.confirmRestartPC(host.id))
        } else {
            moonDeckPairing = nil
            moonDeckPortText = String(moonDeckConfig(for: host)?.port ?? MoonDeckBuddyClient.defaultPort)
            presentOverlay(.moonDeckSetup(host.id))
        }
    }

    /// Kick off MoonDeckBuddy PIN pairing from the setup overlay: reach the
    /// buddy, POST /pair, then poll until the user approves the PIN on the PC.
    func beginMoonDeckPairing() {
        guard case .moonDeckSetup(let hostID)? = overlay,
              let host = hosts.first(where: { $0.id == hostID }),
              let addr = moonDeckConnectAddress(for: host) else { return }
        let port = Int(moonDeckPortText.trimmingCharacters(in: .whitespaces)) ?? MoonDeckBuddyClient.defaultPort
        let pin = String(format: "%04d", Int.random(in: 0...9999))
        updateMoonDeckConfig(for: host) { $0.port = port }
        moonDeckPairing = MoonDeckPairing(hostID: hostID, pin: pin, status: .connecting)
        rebuildFocus()

        moonDeckPairingTask?.cancel()
        moonDeckPairingTask = Task { [weak self] in
            guard let self else { return }
            let clientID = moonDeckClientID
            // TOFU pinning: require the saved cert if we have one; otherwise accept
            // and capture this first cert so every later connection is pinned to it.
            moonDeck.setExpectedCert(moonDeckConfig(for: host)?.pinnedCert, forHost: addr)
            do {
                try await moonDeck.checkReachable(host: addr, port: port)
                if moonDeckConfig(for: host)?.pinnedCert == nil,
                   let cert = moonDeck.observedCert(forHost: addr) {
                    updateMoonDeckConfig(for: host) { $0.pinnedCert = cert }
                    moonDeck.setExpectedCert(cert, forHost: addr)
                }
                try await moonDeck.startPairing(host: addr, port: port, clientID: clientID, pin: pin)
                guard !Task.isCancelled, moonDeckPairing?.hostID == hostID else { return }
                moonDeckPairing?.status = .waiting
                rebuildFocus()
                // Poll ~2 minutes for the user to type the PIN into MoonDeckBuddy.
                for _ in 0..<60 {
                    try await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, moonDeckPairing?.hostID == hostID else { return }
                    if try await moonDeck.pairState(host: addr, port: port, clientID: clientID) == .paired {
                        updateMoonDeckConfig(for: host) { $0.paired = true; $0.port = port }
                        moonDeckPairing?.status = .paired
                        rebuildFocus()
                        return
                    }
                }
                moonDeckPairing?.status = .failed("Timed out. Enter the PIN in the MoonDeckBuddy pop-up on your PC, then try again.")
                rebuildFocus()
            } catch {
                guard !Task.isCancelled, moonDeckPairing?.hostID == hostID else { return }
                if let mdError = error as? MoonDeckBuddyClient.MDError, case .offline = mdError {
                    moonDeckPairing?.status = .offline
                } else {
                    moonDeckPairing?.status = .failed((error as? LocalizedError)?.errorDescription ?? "Pairing failed.")
                }
                rebuildFocus()
            }
        }
    }

    func cancelMoonDeckPairing() {
        moonDeckPairingTask?.cancel()
        moonDeckPairingTask = nil
        moonDeckPairing = nil
    }

    /// Still showing the restart flow for this host? Guards the async completion
    /// from clobbering whatever overlay the user moved on to.
    private func inRestartFlow(for hostID: String) -> Bool {
        switch overlay {
        case .confirmRestartPC(let id), .moonDeckSetup(let id): return id == hostID
        default: return false
        }
    }

    /// Fire the restart. Called from the confirm overlay's "Restart" and from the
    /// setup overlay's "Restart now" (right after a successful pair).
    func performRestartPC(hostID: String) {
        guard let host = hosts.first(where: { $0.id == hostID }),
              let addr = moonDeckConnectAddress(for: host),
              let cfg = moonDeckConfig(for: host) else { return }
        moonDeckRestarting = true
        rebuildFocus()
        Task { [weak self] in
            guard let self else { return }
            // Pin to the cert captured at pairing (nil → accept+capture if the
            // host was paired before pinning existed).
            moonDeck.setExpectedCert(cfg.pinnedCert, forHost: addr)
            do {
                try await moonDeck.restart(host: addr, port: cfg.port,
                                           clientID: moonDeckClientID, delaySeconds: 5)
                moonDeckRestarting = false
                guard inRestartFlow(for: hostID) else { return }
                cancelMoonDeckPairing()
                dismissOverlay()
                // The PC is rebooting; drop the live connection state so the UI
                // shows it going offline rather than a stale "online".
                serverInfo = nil
                hostError = "Restarting \(host.name)…"
            } catch {
                moonDeckRestarting = false
                guard inRestartFlow(for: hostID) else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? "Restart failed."
                cancelMoonDeckPairing()
                presentOverlay(.error(message))
            }
        }
    }

    private func savePairedHost(ip: String, serverCertPEM: Data) {
        guard let i = addedHosts.firstIndex(where: { $0.ip == ip }) else { return }
        addedHosts[i].serverCert = serverCertPEM
        persistAddedHosts()
        rebuildHosts()
        if let host = hosts.first(where: { $0.manualAddress == ip }) {
            selectHost(host.id)  // re-probe now that it's paired
        }
    }

    /// Whether a host was added by the user (removable) vs imported from Moonlight.
    func isAddedHost(_ host: StreamHost) -> Bool {
        addedHosts.contains { $0.ip == host.manualAddress || "added:\($0.ip)" == host.id }
    }

    func addHost() {
        let ip = addHostIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else { return }
        guard hosts.count < Self.maxHosts else {
            addHostError = "You can have at most \(Self.maxHosts) computers."
            return
        }
        guard Self.isValidHostAddress(ip) else {
            addHostError = "Enter a valid IP address (e.g. 192.168.1.20)."
            return
        }
        let exists = hosts.contains {
            $0.manualAddress == ip || $0.localAddress == ip || $0.remoteAddress == ip
        }
        guard !exists else { addHostError = "That computer is already in your list."; return }

        addedHosts.append(AddedHost(name: ip, ip: ip, uuid: nil))
        persistAddedHosts()
        rebuildHosts()
        addHostIP = ""
        addHostError = nil
        // Switch to it and probe (fills in its real name / online state, and
        // surfaces "not paired" if the reused cert doesn't cover it yet).
        if let added = hosts.first(where: { $0.manualAddress == ip }) {
            selectHost(added.id)
        }
        rebuildFocus()
    }

    func removeAddedHost(_ host: StreamHost) {
        addedHosts.removeAll { $0.ip == host.manualAddress || "added:\($0.ip)" == host.id }
        persistAddedHosts()
        let wasSelected = selectedHostID == host.id
        rebuildHosts()
        if wasSelected {
            selectedHostID = hosts.first?.id
            serverInfo = nil; hostAddress = nil
            apps = displayApps(from: selectedHost?.apps ?? [])
            Task { await refreshSelectedHost() }
        }
        rebuildFocus()
    }

    /// Once a probe learns an added host's real UUID/name, upgrade the stored
    /// entry so it de-dupes against Moonlight and shows a friendly name.
    private func upgradeAddedHost(ip: String, uuid: String?, name: String?) {
        guard let i = addedHosts.firstIndex(where: { $0.ip == ip }) else { return }
        var changed = false
        if let uuid, addedHosts[i].uuid != uuid { addedHosts[i].uuid = uuid; changed = true }
        if let name, !name.isEmpty, addedHosts[i].name == ip { addedHosts[i].name = name; changed = true }
        if changed {
            persistAddedHosts()
            let keepID = selectedHostID
            rebuildHosts()
            // The id may have changed (added:<ip> → uuid); re-point selection.
            if let match = hosts.first(where: { $0.manualAddress == ip }) { selectedHostID = match.id }
            else { selectedHostID = keepID }
        }
    }

    private static func isValidHostAddress(_ s: String) -> Bool {
        // Accept an IPv4 dotted quad or a plausible hostname (no spaces).
        if s.contains(" ") { return false }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ Int($0).map { $0 >= 0 && $0 <= 255 } ?? false }) {
            return true
        }
        // hostname fallback: letters/digits/dots/hyphens, has a dot
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return s.contains(".") && s.unicodeScalars.allSatisfy { ok.contains($0) }
    }

    func refreshSelectedHost() async {
        guard let host = selectedHost else { return }
        // The session manager owns host truth while a stream is active.
        guard session.phase == .idle else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let (info, address) = try await api.serverInfo(for: host)
            serverInfo = info
            hostAddress = address
            hostError = nil
            // A freshly-added host reports its real name here.
            if isAddedHost(host), let ip = host.manualAddress {
                upgradeAddedHost(ip: ip, uuid: nil, name: info.hostname)
            }
            let fresh = try await api.appList(for: host, at: address)
            apps = displayApps(from: fresh)
        } catch let error as HostAPIError {
            serverInfo = nil
            hostAddress = nil
            if case .unreachable = error {
                hostError = nil // asleep host is a normal state, not an error banner
            } else {
                hostError = error.localizedDescription
            }
            apps = displayApps(from: host.apps) // fall back to plist cache
        } catch {
            serverInfo = nil
            hostAddress = nil
        }
        rebuildFocus()
        if focus.focusedItemID == nil { focus.focusFirst() }
    }

    /// Filters host pseudo-apps out of the library (permission placeholder,
    /// terminate entries, unnamed apps) and hides Moonlight-hidden ones.
    private func displayApps(from raw: [StreamApp]) -> [StreamApp] {
        raw.filter { app in
            guard app.id != 114514, !app.isHidden else { return false }
            let name = app.name.lowercased()
            return !name.isEmpty && name != "terminate" && !name.hasPrefix("terminate ")
        }
        .sorted { ($0.idx ?? Int.max, $0.name) < ($1.idx ?? Int.max, $1.name) }
    }

    func selectHost(_ id: String) {
        guard id != selectedHostID else { return }
        selectedHostID = id
        serverInfo = nil
        hostAddress = nil
        apps = displayApps(from: selectedHost?.apps ?? [])
        rebuildFocus()
        focus.focusFirst()
        Task { await refreshSelectedHost() }
    }

    func wakeSelectedHost() {
        if let host = selectedHost { wakeHost(host) }
    }

    func wakeHost(_ host: StreamHost) {
        guard let mac = host.macAddress else { return }
        let addresses = host.candidateAddresses.map(\.host)
        try? WakeOnLAN.wake(mac: mac, unicastAddresses: addresses)
    }

    // MARK: - Focus content

    static let settingsRowIDs = SettingsRow.allCases.map(\.focusID)

    private func rebuildFocus() {
        var sections: [FocusSection] = []
        switch overlay {
        case .sessionEnded:
            sections = [FocusSection(id: "ended", kind: .vList,
                                     itemIDs: ["ended:resume", "ended:quit", "ended:home"])]
        case .error:
            sections = [FocusSection(id: "error", kind: .vList, itemIDs: ["error:ok"])]
        case .update:
            // Buttons are only focusable when there's a choice to make.
            switch updateService.phase {
            case .downloading, .installing:
                return
            default:
                sections = [FocusSection(id: "update", kind: .vList,
                                         itemIDs: ["update:now", "update:later"])]
            }
        case .hosts:
            if let pairing {
                let ids: [String]
                switch pairing.status {
                case .waiting: ids = ["pair:cancel"]
                case .success: ids = ["pair:done"]
                default: ids = ["pair:retry", "pair:cancel"]
                }
                sections = [FocusSection(id: "pair", kind: .vList, itemIDs: ids)]
            } else {
                var ids = hosts.map { "hostmenu:\($0.id)" }
                if hosts.count < Self.maxHosts { ids.append("hostmenu:add") }
                sections = [FocusSection(id: "hosts", kind: .vList, itemIDs: ids)]
            }
        case .relocate:
            sections = [FocusSection(id: "relocate", kind: .vList,
                                     itemIDs: ["relocate:move", "relocate:later"])]
        case .customResolution:
            sections = [FocusSection(id: "customres", kind: .vList,
                                     itemIDs: ["customres:set", "customres:cancel"])]
        case .confirmOverridePreset:
            sections = [FocusSection(id: "override", kind: .vList,
                                     itemIDs: ["override:yes", "override:cancel"])]
        case .presetSlotMenu:
            sections = [FocusSection(id: "slotmenu", kind: .vList,
                                     itemIDs: ["slotmenu:rename", "slotmenu:clear", "slotmenu:cancel"])]
        case .renamePreset:
            sections = [FocusSection(id: "rename", kind: .vList,
                                     itemIDs: ["rename:set", "rename:cancel"])]
        case .moonDeckSetup:
            let ids: [String]
            switch moonDeckPairing?.status {
            case .some(.connecting), .some(.waiting): ids = ["moondeck:cancel"]
            case .some(.paired):                      ids = ["moondeck:restart", "moondeck:done"]
            default:                                  ids = ["moondeck:pair", "moondeck:cancel"]
            }
            sections = [FocusSection(id: "moondeck", kind: .vList, itemIDs: ids)]
        case .confirmRestartPC:
            if moonDeckRestarting { return }   // locked while the request is in flight
            sections = [FocusSection(id: "restartpc", kind: .vList,
                                     itemIDs: ["restartpc:yes", "restartpc:cancel"])]
        case .confirmSwitchStream:
            sections = [FocusSection(id: "switchstream", kind: .vList,
                                     itemIDs: ["switchstream:yes", "switchstream:cancel"])]
        case .sessionHUD, .cheatSheet:
            // Nothing focusable in these overlays — but keep the underlying
            // sections installed. routeOverlay() gates all input anyway, and
            // preserving sections keeps the user's shelf position (and the
            // engine's per-section memory) intact for when they return.
            return
        case nil:
            switch screen {
            case .home:
                // Header row above the shelf: restart PC + host chip, reachable
                // with d-pad UP from the games. IDs only when the views render
                // (host set) — never emit focusable IDs no view draws.
                if selectedHost != nil {
                    sections.append(FocusSection(
                        id: "header", kind: .shelf,
                        itemIDs: ["header:restart", "header:host"]
                    ))
                }
                sections.append(FocusSection(
                    id: "apps", kind: .shelf,
                    itemIDs: apps.map { "app:\(appKey($0))" }
                ))
            case .settings:
                // The six preset slots sit above the rows (up from a row reaches
                // them); L1/R1 still switch tabs. Default focus is the first row
                // (openSettings/switchSettingsTab focus it explicitly).
                sections = [
                    FocusSection(id: "presetslots", kind: .shelf,
                                 itemIDs: (0..<Self.presetSlotCount).map { "presetslot:\($0)" }),
                    FocusSection(id: "settings", kind: .vList,
                                 itemIDs: settingsTab.rows.map(\.focusID)),
                ]
            }
        }
        focus.setSections(sections)
    }

    /// Single funnel for presenting an overlay: install it, rebuild the focus
    /// content, and guarantee something is focused (a card whose buttons are
    /// all gray turns Select into a lottery).
    private func presentOverlay(_ newOverlay: Overlay) {
        overlay = newOverlay
        rebuildFocus()
        if focus.focusedItemID == nil { focus.focusFirst() }
    }

    func appKey(_ app: StreamApp) -> String {
        app.uuid ?? String(app.id)
    }

    var focusedApp: StreamApp? {
        guard let id = focus.focusedItemID, id.hasPrefix("app:") else { return nil }
        let key = String(id.dropFirst(4))
        return apps.first { appKey($0) == key }
    }

    // MARK: - Event routing

    /// Mouse selection of a specific control: switch to pointer mode, focus
    /// exactly what was clicked, then activate it — so a click always hits the
    /// button under the cursor, never whatever the controller last focused.
    func pointerSelect(_ id: String) {
        intro.skip()   // a tap/click ends the launch intro too
        if inputMode != .pointer { inputMode = .pointer }
        focus.focus(itemID: id)
        route(.select)
    }

    // MARK: - Onboarding

    /// True if any preset slot is filled — used to skip the presets tutorial for
    /// users who clearly already know how to use them.
    var hasAnyPreset: Bool { presets.contains { $0 != nil } }

    /// Seed Preset 1 from the setup's chosen settings — only for a user with NO
    /// presets (the sole case the presets step is shown). Called from the step.
    func seedFirstPresetIfEmpty() {
        guard !hasAnyPreset else { return }
        performSaveToSlot(0)
    }

    /// Advance to the next wizard step, or finish on the last one. The presets
    /// tutorial is skipped for users who already have presets.
    func advanceOnboarding() {
        guard let step = onboardingStep else { return }
        sfx.play(.select)
        var raw = step.rawValue + 1
        if OnboardingStep(rawValue: raw) == .presets, hasAnyPreset { raw += 1 }
        if let next = OnboardingStep(rawValue: raw) {
            onboardingStep = next   // view layer animates the step transition
        } else {
            completeSetup()
        }
    }

    func backOnboarding() {
        guard let step = onboardingStep else { return }
        var raw = step.rawValue - 1
        if OnboardingStep(rawValue: raw) == .presets, hasAnyPreset { raw -= 1 }
        guard let prev = OnboardingStep(rawValue: raw) else { return }
        sfx.play(.back)
        onboardingStep = prev
    }

    /// Finish: persist so the wizard never shows again, and hand off to the
    /// launcher (which plays its own deal-in intro right after).
    /// Called at the END of the finale (not the moment "Jump in" is pressed):
    /// persist the completed version, drop into the launcher, and play the
    /// deal-in intro (which was skipped while setup was up).
    func completeSetup() {
        UserDefaults.standard.set(Self.requiredSetupVersion, forKey: Self.setupVersionKey)
        onboardingStep = nil
        intro.begin()
    }

    /// The setup finale's "arrival" swell (played by `FinaleStep`).
    func playLaunchCue() { sfx.play(.launch) }

    /// Settings ▸ Restart Setup — replay the wizard from the top.
    func restartSetup() {
        onboardingQualityFocus = 0
        screen = .home
        overlay = nil
        onboardingStep = .welcome
    }

    /// Touch: focus a specific quality control on the wizard's quality step.
    func focusOnboardingQuality(_ i: Int) {
        onboardingQualityFocus = min(max(i, 0), onboardingQualityRows.count - 1)
    }

    private func routeOnboarding(_ event: NavigationEvent) {
        guard let step = onboardingStep else { return }
        switch step {
        case .welcome:
            if event == .select || event == .move(.right) { advanceOnboarding() }
        case .theme:
            switch event {
            case .move(.left):  backgroundTheme = Self.cycle(backgroundTheme, forward: false); sfx.play(.move)
            case .move(.right): backgroundTheme = Self.cycle(backgroundTheme, forward: true); sfx.play(.move)
            case .select:       advanceOnboarding()
            case .back:         backOnboarding()
            default: break
            }
        case .quality:
            switch event {
            case .move(.up):    onboardingQualityFocus = max(0, onboardingQualityFocus - 1); sfx.play(.move)
            case .move(.down):  onboardingQualityFocus = min(onboardingQualityRows.count - 1, onboardingQualityFocus + 1); sfx.play(.move)
            case .move(.left):  adjust(row: onboardingQualityRows[onboardingQualityFocus], forward: false)
            case .move(.right): adjust(row: onboardingQualityRows[onboardingQualityFocus], forward: true)
            case .select:       advanceOnboarding()
            case .back:         backOnboarding()
            default: break
            }
        case .presets:
            if event == .select || event == .move(.right) { advanceOnboarding() }
            else if event == .back { backOnboarding() }
        case .finish:
            if event == .select { advanceOnboarding() }   // → the cinematic finale
            else if event == .back { backOnboarding() }
        case .finale:
            break   // non-interactive; FinaleStep auto-hands off to the launcher
        }
    }

    func route(_ event: NavigationEvent) {
        // The setup wizard owns all input until it's done — unskippable.
        if onboardingStep != nil {
            routeOnboarding(event)
            return
        }
        // Menu SFX — deliberate actions make sound, navigation mostly doesn't:
        //  • Overlays (cards) keep normal select/back — they're deliberate.
        //  • Settings screen is SILENT except an explicit value change (adjust()).
        //  • Home: select confirms; the Restart PC button gets its own reboot cue
        //    (the host chip / apps just confirm). Focus-move ticks are header-only
        //    (onFocusChange).
        switch event {
        case .select:
            if overlay != nil {
                sfx.play(.select)
            } else if screen != .settings {
                sfx.play(focus.focusedItemID == "header:restart" ? .restart : .select)
            }
        case .back:
            if overlay != nil || screen != .settings { sfx.play(.back) }
        default:
            break
        }
        // Global chord: hold Menu → quit the remote game completely.
        if event == .quitChord {
            quitRemoteGameCompletely()
            return
        }

        // Hold B/Circle on the home screen → quit VibeLight itself. Gated to
        // home-with-no-overlay so it can never fire mid-stream or from a menu.
        if event == .quitApp {
            // macOS: quit VibeLight. iOS: no-op — apps can't self-terminate (HIG);
            // the chrome's quitApp() is a no-op there.
            if screen == .home, overlay == nil {
                chrome?.quitApp()
            }
            return
        }

        if let overlay {
            routeOverlay(event, overlay: overlay)
            return
        }

        switch screen {
        case .home:
            routeHome(event)
        case .settings:
            routeSettings(event)
        }
    }

    private func routeHome(_ event: NavigationEvent) {
        // Preset rail mode: up/down move within, left leaves, select applies,
        // X (contextMenu) opens rename/clear on a filled slot.
        if isPresetRailActive {
            switch event {
            case .move(.up): movePresetFocus(-1)
            case .move(.down): movePresetFocus(+1)
            case .move(.left): exitPresetRail()
            case .move(.right): break
            case .select: if let i = focusedPresetSlot { applySlot(i) }
            case .contextMenu:
                if let i = focusedPresetSlot, presets[i] != nil { presentOverlay(.presetSlotMenu(i)) }
            case .back: exitPresetRail()
            case .settings: openSettings()
            default: break
            }
            return
        }
        switch event {
        case .select:
            if let id = focus.focusedItemID, id.hasPrefix("host:") {
                selectHost(String(id.dropFirst(5)))
            } else if focus.focusedItemID == "header:host" {
                openHostMenu()
            } else if focus.focusedItemID == "header:restart" {
                requestRestartPC()
            } else if let app = focusedApp {
                launch(app)
            }
        case .settings:
            openSettings()
        case .detail, .contextMenu:
            presentOverlay(.cheatSheet)
        case .move(.right):
            // Right off the end of the app shelf enters the preset rail (always
            // available — the six slots are always shown).
            if !focus.handle(.move(.right)) { enterPresetRail() }
        case .back:
            break // home is the root — nowhere to go back to
        default:
            _ = focus.handle(event)
        }
    }

    private func routeSettings(_ event: NavigationEvent) {
        let onSlot = presetSlotIndex(focus.focusedItemID)
        switch event {
        case .back, .settings:
            closeSettings()
        case .prevSection:
            switchSettingsTab(forward: false)
        case .nextSection:
            switchSettingsTab(forward: true)
        case .move(.left), .move(.right):
            if onSlot != nil {
                _ = focus.handle(event)  // shelf: move between the six slots
            } else if let rowID = focus.focusedItemID,
                      let row = SettingsRow.allCases.first(where: { $0.focusID == rowID }) {
                adjust(row: row, forward: event == .move(.right))
            }
        case .select:
            if let i = onSlot {
                requestSaveToSlot(i)           // save current settings into the slot
            } else if let rowID = focus.focusedItemID,
                      let row = SettingsRow.allCases.first(where: { $0.focusID == rowID }),
                      row.isAction {
                performSettingAction(row)      // Software Update / Restart Setup
            } else if focus.focusedItemID == SettingsRow.resolution.focusID {
                openCustomResolution()         // type an arbitrary WxH
            }
        case .contextMenu:
            if let i = onSlot, presets[i] != nil { presentOverlay(.presetSlotMenu(i)) }
        default:
            _ = focus.handle(event)            // up/down cross into / out of the slots
        }
    }

    /// Cycles between settings tabs (L1/R1). Clamps at the ends and re-homes
    /// focus to the first row of the new tab.
    func switchSettingsTab(forward: Bool) {
        let all = SettingsTab.allCases
        guard let i = all.firstIndex(of: settingsTab) else { return }
        let next = min(max(i + (forward ? 1 : -1), 0), all.count - 1)
        setSettingsTab(all[next])
    }

    /// Jumps straight to a tab (mouse click on the tab strip).
    func setSettingsTab(_ tab: SettingsTab) {
        guard tab != settingsTab else { return }
        inputMode = .pointer
        settingsTab = tab
        rebuildFocus()
        focusFirstSettingRow()
    }

    private func routeOverlay(_ event: NavigationEvent, overlay: Overlay) {
        switch overlay {
        case .sessionHUD:
            break // launching — input is intentionally locked
        case .cheatSheet:
            if event == .back || event == .select || event == .detail || event == .contextMenu {
                dismissOverlay()
            }
        case .error:
            if event == .back || event == .select {
                if case .failed = session.phase { session.acknowledgeEnd() }
                dismissOverlay()
            }
        case .sessionEnded(let app):
            switch event {
            case .select:
                switch focus.focusedItemID {
                case "ended:resume":
                    session.acknowledgeEnd()
                    dismissOverlay()
                    launch(app)
                case "ended:quit":
                    quitRemoteGameCompletely()
                case "ended:home", nil, .some:
                    session.acknowledgeEnd()
                    dismissOverlay()
                }
            case .back:
                session.acknowledgeEnd()
                dismissOverlay()
            default:
                _ = focus.handle(event)
            }
        case .update:
            // Input is locked during the download/install itself.
            switch updateService.phase {
            case .downloading, .installing:
                return
            default:
                break
            }
            switch event {
            case .select:
                if focus.focusedItemID == "update:now" {
                    if updateService.phase == .readyToInstall {
                        updateService.installStagedUpdate()  // Restart Now → swap + relaunch
                    } else {
                        startUpdate()                          // Update Now → download
                    }
                    rebuildFocus() // the download/install lock removes focus
                } else {
                    dismissOverlay()  // Later
                }
            case .back:
                dismissOverlay()
            default:
                _ = focus.handle(event)
            }
        case .hosts:
            if pairing != nil {
                switch event {
                case .select:
                    switch focus.focusedItemID {
                    case "pair:cancel": cancelPairing()
                    case "pair:done": pairing = nil; dismissOverlay()
                    case "pair:retry":
                        if let h = hosts.first(where: { $0.id == pairing?.hostID }) { beginPairing(h) }
                    default: break
                    }
                case .back: cancelPairing()
                default: _ = focus.handle(event)
                }
                return
            }
            switch event {
            case .select:
                if focus.focusedItemID == "hostmenu:add" {
                    addHost()
                } else if let id = focus.focusedItemID, id.hasPrefix("hostmenu:") {
                    let hostID = String(id.dropFirst("hostmenu:".count))
                    if let host = hosts.first(where: { $0.id == hostID }) {
                        // Unpaired → start pairing; paired → switch to it.
                        if needsPairing(host) { beginPairing(host) }
                        else { selectHost(hostID); dismissOverlay() }
                    }
                }
            case .back:
                dismissOverlay()
            default:
                _ = focus.handle(event)
            }
        case .relocate:
            switch event {
            case .select:
                if focus.focusedItemID == "relocate:move" {
                    moveToApplications()  // relaunches on success
                } else {
                    declineRelocation()
                }
            case .back:
                // Back = just dismiss (we'll ask again next launch); the
                // explicit "Not Now" button is what silences future prompts.
                dismissOverlay()
                checkForUpdatesOnLaunch()
            default:
                _ = focus.handle(event)
            }
        case .customResolution:
            switch event {
            case .select:
                if focus.focusedItemID == "customres:set" { applyCustomResolution() }
                else { dismissOverlay() }
            case .back:
                dismissOverlay()
            default:
                _ = focus.handle(event)
            }
        case .confirmOverridePreset(let i):
            switch event {
            case .select:
                if focus.focusedItemID == "override:yes" {
                    dismissOverlay()
                    performSaveToSlot(i)
                } else { dismissOverlay() }
            case .back:
                dismissOverlay()
            default:
                _ = focus.handle(event)
            }
        case .presetSlotMenu(let i):
            switch event {
            case .select:
                switch focus.focusedItemID {
                case "slotmenu:rename": openRename(i)   // replaces this overlay
                case "slotmenu:clear": dismissOverlay(); clearSlot(i)
                default: dismissOverlay()
                }
            case .back:
                dismissOverlay()
            default:
                _ = focus.handle(event)
            }
        case .renamePreset(let i):
            switch event {
            case .select:
                if focus.focusedItemID == "rename:set" { applyRename(i) }
                else { dismissOverlay() }
            case .back:
                dismissOverlay()
            default:
                _ = focus.handle(event)
            }
        case .moonDeckSetup(let hostID):
            if moonDeckRestarting { break }   // locked while a restart is in flight
            switch event {
            case .select:
                switch focus.focusedItemID {
                case "moondeck:pair":    beginMoonDeckPairing()
                case "moondeck:restart": performRestartPC(hostID: hostID)
                case "moondeck:done":    cancelMoonDeckPairing(); dismissOverlay()
                default:                 cancelMoonDeckPairing(); dismissOverlay()  // cancel
                }
            case .back:
                cancelMoonDeckPairing(); dismissOverlay()
            default:
                _ = focus.handle(event)
            }
        case .confirmSwitchStream(_, let target):
            switch event {
            case .select:
                if focus.focusedItemID == "switchstream:yes" {
                    dismissOverlay()
                    forceLaunch(target)
                } else {
                    dismissOverlay()
                }
            case .back:
                dismissOverlay()
            default:
                _ = focus.handle(event)
            }
        case .confirmRestartPC(let hostID):
            if moonDeckRestarting { break }   // locked while in flight
            switch event {
            case .select:
                if focus.focusedItemID == "restartpc:yes" { performRestartPC(hostID: hostID) }
                else { dismissOverlay() }
            case .back:
                dismissOverlay()
            default:
                _ = focus.handle(event)
            }
        }
    }

    private func dismissOverlay() {
        pairingTask?.cancel(); pairingTask = nil; pairing = nil
        setPairingKeepAwake(false)
        moonDeckPairingTask?.cancel(); moonDeckPairingTask = nil; moonDeckPairing = nil
        overlay = nil
        rebuildFocus()
        if focus.focusedItemID == nil { focus.focusFirst() }
    }

    func openSettings() {
        screen = .settings
        rebuildFocus()
        focusFirstSettingRow()
    }

    /// Default settings focus is the first row of the active tab (not the preset
    /// slots above it — those are reached by pressing up).
    private func focusFirstSettingRow() {
        if let first = settingsTab.rows.first?.focusID { focus.focus(itemID: first) }
        else { focus.focusFirst() }
    }

    func closeSettings() {
        screen = .home
        rebuildFocus()
        if focus.focusedItemID == nil { focus.focusFirst() }
    }

    // MARK: - Actions

    func launch(_ app: StreamApp) {
        guard selectedHost != nil else { return }
        // Host already streaming something ELSE → offer to switch instead of
        // erroring out (the engines close the running app on the way in).
        if let info = serverInfo, info.currentGameID != 0, info.currentGameID != app.id {
            let runningName = apps.first { $0.id == info.currentGameID }?.name ?? "Another app"
            presentOverlay(.confirmSwitchStream(running: runningName, target: app))
            return
        }
        forceLaunch(app)
    }

    /// The unguarded launch path: used directly by the switch-stream confirm
    /// (the user already chose to close what's running).
    private func forceLaunch(_ app: StreamApp) {
        guard let host = selectedHost else { return }
        presentOverlay(.sessionHUD)
        Task {
            await session.launch(app: app, on: host, settings: settings)
            // No post-await phase check needed: every .failed transition —
            // including the asynchronous ones from the startup watchdog and
            // the child's termination handler — lands via onPhaseChange.
        }
    }

    /// The headline feature: fully terminate the remote game, from anywhere.
    func quitRemoteGameCompletely() {
        guard let host = selectedHost else { return }
        Task {
            await session.quitCompletely(host: host)
            if case .failed = session.phase {
                // onPhaseChange already surfaced the error overlay.
            } else {
                // Quit from the ended-card: no child remains, so no
                // termination handler will fire — resolve the phase and the
                // card here. (Quit mid-stream resolves via onStreamDidEnd
                // instead, where remoteQuitRequested suppresses the card.)
                session.acknowledgeEnd()
                if case .sessionEnded = overlay { dismissOverlay() }
            }
            await refreshSelectedHost()
        }
    }

    /// A stream is active, or the host is still running a game — something the
    /// host would keep doing after VibeLight closes.
    var hasActiveRemoteSession: Bool {
        session.phase != .idle || (serverInfo?.currentGameID ?? 0) != 0
    }

    /// Called by the app delegate when VibeLight is quitting. With "Quit Game on
    /// App Exit" on (default), fully stop the remote game (`/cancel`, invariant 3)
    /// so nothing is left streaming/running on the PC after the app closes.
    /// Bounded by a watchdog so a hung/unreachable host can't block termination.
    /// `budget` bounds the remote /cancel. macOS can afford 7 s; the iOS
    /// background/termination path MUST finish well inside iOS's 5-second
    /// termination watchdog (0x8BADF00D SIGKILL otherwise — seen on-device as
    /// "random crashes" every time the app was exited while the host was slow).
    func stopStreamForAppExit(budget: Duration = .seconds(7)) async {
        guard settings.stopStreamOnExit, let host = selectedHost, hasActiveRemoteSession else { return }
        let work = Task { await session.quitCompletely(host: host) }
        let watchdog = Task { try? await Task.sleep(for: budget); work.cancel() }
        await work.value
        watchdog.cancel()
    }

    // MARK: - Settings rows

    enum SettingsRow: String, CaseIterable {
        case resolution, fps, bitrate, codec, hdr, decoder, yuv444
        case audio, muteHostSpeakers, muteOnFocusLoss
        case touchControls, externalDisplay, absoluteMouse, swapMouseButtons, reverseScrolling, captureSystemKeys, swapGamepadButtons, backgroundGamepad
        case vsync, framePacing, gameOpt, quitAppAfter, keepAwake, performanceOverlay, stopStreamOnExit
        case background
        case appVersion, checkUpdates, restartSetup

        var focusID: String { "setting:\(rawValue)" }

        /// Action/readonly rows don't adjust with left/right and render without
        /// value chevrons (they respond to select instead).
        var isAction: Bool { self == .checkUpdates || self == .restartSetup }
        var isReadonly: Bool { self == .appVersion }

        var title: String {
            switch self {
            case .resolution: "Resolution"
            case .fps: "Frame Rate"
            case .bitrate: "Bitrate"
            case .codec: "Video Codec"
            case .hdr: "HDR"
            case .decoder: "Video Decoder"
            case .yuv444: "YUV 4:4:4"
            case .audio: "Audio"
            case .muteHostSpeakers: "Mute Host Speakers"
            case .muteOnFocusLoss: "Mute When Inactive"
            case .touchControls: "Touch Control"
            case .externalDisplay: "Use TV / Monitor"
            case .absoluteMouse: "Remote Desktop Mouse"
            case .swapMouseButtons: "Swap Mouse Buttons"
            case .reverseScrolling: "Reverse Scrolling"
            case .captureSystemKeys: "Capture System Keys"
            case .swapGamepadButtons: "Swap A/B & X/Y"
            case .backgroundGamepad: "Background Gamepad"
            case .vsync: "V-Sync"
            case .framePacing: "Frame Pacing"
            case .gameOpt: "Game Optimizations"
            case .quitAppAfter: "Quit Game on Disconnect"
            case .keepAwake: "Keep Display Awake"
            case .performanceOverlay: "Performance Stats"
            case .stopStreamOnExit: "Quit Game on App Exit"
            case .background: "Background"
            case .appVersion: "Version"
            case .checkUpdates: "Software Update"
            case .restartSetup: "Restart Setup"
            }
        }
    }

    /// Settings groups, switched with L1/R1 so each screen stays short.
    enum SettingsTab: String, CaseIterable {
        case video, audio, input, advanced, themes, about
        var title: String {
            switch self {
            case .video: "Video"; case .audio: "Audio"; case .input: "Input"
            case .advanced: "Advanced"; case .themes: "Themes"; case .about: "About"
            }
        }
        var rows: [SettingsRow] {
            switch self {
            case .video:
                #if os(iOS)
                [.resolution, .fps, .bitrate, .codec, .hdr, .decoder, .yuv444, .externalDisplay]
                #else
                [.resolution, .fps, .bitrate, .codec, .hdr, .decoder, .yuv444]
                #endif
            case .audio: [.audio, .muteHostSpeakers, .muteOnFocusLoss]
            case .input:
                #if os(iOS)
                [.touchControls, .absoluteMouse, .swapMouseButtons, .reverseScrolling, .captureSystemKeys, .swapGamepadButtons, .backgroundGamepad]
                #else
                [.absoluteMouse, .swapMouseButtons, .reverseScrolling, .captureSystemKeys, .swapGamepadButtons, .backgroundGamepad]
                #endif
            case .about: [.appVersion, .checkUpdates, .restartSetup]
            case .advanced: [.vsync, .framePacing, .gameOpt, .quitAppAfter, .keepAwake, .performanceOverlay, .stopStreamOnExit]
            case .themes: [.background]
            }
        }
    }

    static let resolutionPresets: [(w: Int, h: Int, label: String)] = [
        (1280, 720, "720p"), (1920, 1080, "1080p"), (2560, 1440, "1440p"),
        (3440, 1440, "Ultrawide 1440p"), (3840, 2160, "4K"),
    ]
    static let fpsPresets = [30, 60, 90, 120, 144, 165, 240]

    /// The client display's native pixel resolution (backing-scaled).
    var nativeResolution: (w: Int, h: Int)? {
        #if os(macOS)
        guard let screen = NSScreen.main else { return nil }
        let scale = screen.backingScaleFactor
        return (Int((screen.frame.width * scale).rounded()), Int((screen.frame.height * scale).rounded()))
        #else
        let screen = UIScreen.main
        let scale = screen.nativeScale
        return (Int((screen.bounds.width * scale).rounded()), Int((screen.bounds.height * scale).rounded()))
        #endif
    }

    /// The resolution values the ◀ ▶ cycle steps through: the built-in presets,
    /// the display's native resolution, and the current custom value if it's
    /// none of those — all sorted by pixel count so native lands in the right
    /// spot (further along when it's higher than the presets).
    var resolutionOptions: [(w: Int, h: Int, label: String)] {
        var options = Self.resolutionPresets
        if let native = nativeResolution,
           !options.contains(where: { $0.w == native.w && $0.h == native.h }) {
            options.append((native.w, native.h, "Native (\(native.w)×\(native.h))"))
        }
        if !options.contains(where: { $0.w == settings.width && $0.h == settings.height }) {
            options.append((settings.width, settings.height, "\(settings.width)×\(settings.height)"))
        }
        return options.sorted { $0.w * $0.h < $1.w * $1.h }
    }

    /// Custom-resolution entry (typed via the resolution row → select).
    var customResText: String = ""
    var customResError: String?

    func openCustomResolution() {
        customResText = "\(settings.width)x\(settings.height)"
        customResError = nil
        presentOverlay(.customResolution)
    }

    func applyCustomResolution() {
        let parts = customResText.lowercased().split(whereSeparator: { $0 == "x" || $0 == "×" || $0 == " " })
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
              w >= 256, h >= 144, w <= 7680, h <= 4320 else {
            customResError = "Enter a resolution like 2560x1440."
            return
        }
        settings.width = w
        settings.height = h
        customResError = nil
        dismissOverlay()
    }

    /// Bitrate steps in clean 10 Mbps increments (Kbps).
    static let bitrateStep = 10_000
    static let bitrateMin = 10_000
    static let bitrateMax = 200_000

    func value(for row: SettingsRow) -> String {
        switch row {
        case .resolution:
            resolutionOptions.first { $0.w == settings.width && $0.h == settings.height }?.label
                ?? "\(settings.width)×\(settings.height)"
        case .fps: "\(settings.fps) fps"
        // Whole-number Mbps now that bitrate snaps to the 10 Mbps grid.
        case .bitrate: "\(settings.bitrateKbps / 1000) Mbps"
        case .codec: settings.codec.label
        case .hdr: settings.hdr ? "On" : "Off"
        case .decoder: settings.decoder.label
        case .yuv444: settings.yuv444 ? "On" : "Off"
        case .audio: settings.audio.label
        case .muteHostSpeakers: settings.muteHostSpeakers ? "On" : "Off"
        case .muteOnFocusLoss: settings.muteOnFocusLoss ? "On" : "Off"
        case .touchControls: settings.touchControls ? "On" : "Off"
        case .externalDisplay: settings.externalDisplay ? "On" : "Off"
        case .absoluteMouse: settings.absoluteMouse ? "On" : "Off"
        case .swapMouseButtons: settings.swapMouseButtons ? "On" : "Off"
        case .reverseScrolling: settings.reverseScrolling ? "On" : "Off"
        case .captureSystemKeys: settings.captureSystemKeys.label
        case .swapGamepadButtons: settings.swapGamepadButtons ? "On" : "Off"
        case .backgroundGamepad: settings.backgroundGamepad ? "On" : "Off"
        case .vsync: settings.vsync ? "On" : "Off"
        case .framePacing: settings.framePacing ? "On" : "Off"
        case .gameOpt: settings.gameOptimizations ? "On" : "Off"
        case .quitAppAfter: settings.quitAppAfter ? "On" : "Off"
        case .keepAwake: settings.keepAwake ? "On" : "Off"
        case .performanceOverlay: settings.performanceOverlay ? "On" : "Off"
        case .stopStreamOnExit: settings.stopStreamOnExit ? "On" : "Off"
        case .background: backgroundTheme.title
        case .appVersion: "v\(updateService.currentVersion)"
        case .checkUpdates: updateStatusText
        case .restartSetup: "Replay the intro"
        }
    }

    /// Runs an action row's action (the `.isAction` rows respond to select, not
    /// left/right). Keeps the row views generic instead of hard-coding one action.
    func performSettingAction(_ row: SettingsRow) {
        switch row {
        case .checkUpdates: checkForUpdates()
        case .restartSetup: restartSetup()
        default: break
        }
    }

    /// Right-hand status for the "Software Update" row.
    var updateStatusText: String {
        switch updateService.phase {
        case .checking: "Checking…"
        case .available: "Update available →"
        case .downloading(let f): "Downloading \(Int(f * 100))%"
        case .installing: "Verifying…"
        case .readyToInstall: "Restart to update →"
        case .failed: "Check failed — try again"
        case .upToDate, .idle: "Up to date"
        }
    }

    func adjust(row: SettingsRow, forward: Bool) {
        sfx.play(.move)   // value change ticks like a focus move
        switch row {
        case .resolution:
            let options = resolutionOptions
            let current = options.firstIndex { $0.w == settings.width && $0.h == settings.height } ?? 0
            let next = min(max(current + (forward ? 1 : -1), 0), options.count - 1)
            settings.width = options[next].w
            settings.height = options[next].h
        case .fps:
            let presets = Self.fpsPresets
            let current = presets.firstIndex(of: settings.fps) ?? 1
            let next = min(max(current + (forward ? 1 : -1), 0), presets.count - 1)
            settings.fps = presets[next]
        case .bitrate:
            // Snap to a clean 10 Mbps grid so values read 80/90/100, never
            // the imported 87.5. If already on the grid, step; otherwise jump
            // to the neighboring grid line in the pressed direction.
            let step = Self.bitrateStep
            let onGrid = settings.bitrateKbps % step == 0
            let base = (settings.bitrateKbps / step) * step
            let next = onGrid ? settings.bitrateKbps + (forward ? step : -step)
                              : (forward ? base + step : base)
            settings.bitrateKbps = min(max(next, Self.bitrateMin), Self.bitrateMax)
        case .codec: settings.codec = Self.cycle(settings.codec, forward: forward)
        case .audio: settings.audio = Self.cycle(settings.audio, forward: forward)
        case .decoder: settings.decoder = Self.cycle(settings.decoder, forward: forward)
        case .captureSystemKeys: settings.captureSystemKeys = Self.cycle(settings.captureSystemKeys, forward: forward)
        case .hdr: settings.hdr.toggle()
        case .yuv444: settings.yuv444.toggle()
        case .muteHostSpeakers: settings.muteHostSpeakers.toggle()
        case .muteOnFocusLoss: settings.muteOnFocusLoss.toggle()
        case .touchControls: settings.touchControls.toggle()
        case .externalDisplay: settings.externalDisplay.toggle()
        case .absoluteMouse: settings.absoluteMouse.toggle()
        case .swapMouseButtons: settings.swapMouseButtons.toggle()
        case .reverseScrolling: settings.reverseScrolling.toggle()
        case .swapGamepadButtons: settings.swapGamepadButtons.toggle()
        case .backgroundGamepad: settings.backgroundGamepad.toggle()
        case .vsync: settings.vsync.toggle()
        case .framePacing: settings.framePacing.toggle()
        case .gameOpt: settings.gameOptimizations.toggle()
        case .quitAppAfter: settings.quitAppAfter.toggle()
        case .keepAwake: settings.keepAwake.toggle(); refreshKeepAwake()
        case .performanceOverlay: settings.performanceOverlay.toggle()
        case .stopStreamOnExit: settings.stopStreamOnExit.toggle()
        case .background: backgroundTheme = Self.cycle(backgroundTheme, forward: forward)
        case .appVersion, .checkUpdates, .restartSetup: break  // not value rows
        }
    }

    /// Cycles a CaseIterable enum value forward/backward, clamped at the ends.
    private static func cycle<T: CaseIterable & Equatable>(_ value: T, forward: Bool) -> T {
        let all = Array(T.allCases)
        guard let i = all.firstIndex(of: value) else { return value }
        let next = min(max(all.index(i, offsetBy: forward ? 1 : -1), all.startIndex), all.index(before: all.endIndex))
        return all[next]
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }
}
