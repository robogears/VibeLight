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
    case confirmClearPreset(Int)    // wipe a filled slot — destructive, confirm
    case confirmRemoveHost(String)  // forget a computer + its pairing — confirm
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

    /// The Computers menu's row order: the selected computer (persisted, so
    /// also the last one used) first, then the rest in their existing order
    /// (owner, 26 Oct 2026: "the last used PC should be at the top with a
    /// little bar that seperates it from the other PCS"). The ONE source of
    /// that order — HostMenuCard draws it and rebuildFocus emits it, so the
    /// controller's up/down always walks the rows as drawn.
    nonisolated static func hostMenuOrder(hosts: [StreamHost], selectedID: String?) -> [StreamHost] {
        guard let selectedID, let i = hosts.firstIndex(where: { $0.id == selectedID }) else { return hosts }
        var ordered = hosts
        ordered.insert(ordered.remove(at: i), at: 0)
        return ordered
    }

    /// The row the Computers menu opens on: the computer you're on. The rows
    /// reorder whenever the selection changes, so the focus engine's
    /// remembered row NUMBER can point at a different computer after a
    /// selection made while the menu wasn't listing (pairing a new computer
    /// selects it behind the pair panel) — audit finding HM. Nil when nothing
    /// is selected, so the engine's own repair decides.
    nonisolated static func hostMenuOpeningFocusID(hosts: [StreamHost], selectedID: String?) -> String? {
        guard let selectedID, hosts.contains(where: { $0.id == selectedID }) else { return nil }
        return "hostmenu:\(selectedID)"
    }

    /// The row to land on when leaving the pair panel for the list: the
    /// computer that was being paired if it is still listed (a cancelled
    /// pairing never changed the selection, so that's the row you came from),
    /// else the computer you're on.
    nonisolated static func hostMenuReturnFocusID(hosts: [StreamHost], pairedID: String?, selectedID: String?) -> String? {
        if let pairedID, hosts.contains(where: { $0.id == pairedID }) { return "hostmenu:\(pairedID)" }
        return hostMenuOpeningFocusID(hosts: hosts, selectedID: selectedID)
    }

    /// Whether the menu draws the divider under its first row: only when the
    /// selected computer was lifted to the top AND other computers follow it.
    nonisolated static func hostMenuHasDivider(hosts: [StreamHost], selectedID: String?) -> Bool {
        hosts.count > 1 && hosts.contains { $0.id == selectedID }
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
        /// Learned from serverinfo on refresh — enables Wake-on-LAN for hosts
        /// paired in-app (optional: old saved records decode with nil).
        var mac: Data?
    }

    /// Decodes one element as `T?`: a bad or schema-incompatible element becomes
    /// nil instead of making the whole array/dictionary decode throw — so one
    /// corrupt saved record can't silently wipe every saved host/preset (and its
    /// pinned pairing cert). (audit DAT-decode-failure-wipes-hosts)
    private struct FailableDecodable<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
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
    /// Saved configs this build can't read, by key, as their original bytes.
    /// Written back unchanged beside `moonDeckConfigs` on every save, so they
    /// survive AND other computers' Restart PC pairings still save. Replaces a
    /// latch that silently refused every save once one entry failed to read.
    /// (audit DAT-buddy-config-latch-silent)
    @ObservationIgnored private var unreadableMoonDeckConfigs: [String: Data] = [:]
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

    /// The host answered at the socket level but never replied — its streaming
    /// service is stuck, not asleep. Kept distinct from plain offline so the UI
    /// can say something true and skip the useless wake offer.
    private(set) var hostNotResponding = false

    /// The selected computer can be woken: it's asleep (not online) and we have a
    /// MAC for the magic packet. SINGLE source of truth for the home-header wake
    /// button — HomeView's render gate AND rebuildFocus's `header:power` id both
    /// read this, so the focus invariant (id emitted iff view drawn) can't drift.
    /// A NOT-RESPONDING host is excluded: it demonstrably has power, so a magic
    /// packet is noise — the fix there is restarting its streaming service.
    var canWakeSelectedHost: Bool {
        !hostOnline && !hostNotResponding && selectedHost?.macAddress != nil
    }

    // MARK: UI state

    var screen: Screen = .home
    var overlay: Overlay?
    var settings: StreamSettings {
        didSet {
            persistSettings()
            // The "this preset is active" marker documents itself as "nil once
            // settings diverge", but nothing ever cleared it: only clearSlot
            // did, so every tweak after applying a preset left the slots still
            // showing that slot as active while the live settings no longer
            // matched it. Clear it the moment they stop agreeing.
            if let i = activePresetSlot, presets.indices.contains(i),
               presets[i]?.settings != settings {
                activePresetSlot = nil
                persistPresets()
            }
        }
    }

    /// The launcher background style (Settings ▸ Themes). Global appearance pref,
    /// stored on its own key so it's NOT captured into per-session stream presets.
    var backgroundTheme: BackgroundTheme = .parallaxDeep {
        didSet {
            guard oldValue != backgroundTheme else { return }
            UserDefaults.standard.set(backgroundTheme.rawValue, forKey: Self.backgroundThemeKey)
        }
    }

    /// Settings ▸ Themes ▸ Interface Size. Global appearance pref on its own key,
    /// like `backgroundTheme`: inside `settings` it would be captured into
    /// presets, so loading a preset would undo it and changing it would
    /// deselect the active preset. (UX-ios-scale-shrinks-text-targets)
    var interfaceSize: InterfaceSize = .default {
        didSet {
            guard oldValue != interfaceSize else { return }
            UserDefaults.standard.set(interfaceSize.rawValue, forKey: Self.interfaceSizeKey)
        }
    }

    /// Settings ▸ Audio ▸ Menu Sounds (on by default). Its own key, like
    /// `interfaceSize`, so loading a preset can't switch the launcher's sounds
    /// back on and turning them off doesn't deselect the active preset.
    /// (UX-menu-sounds-no-toggle)
    var menuSounds: Bool = true {
        didSet {
            sfx.isEnabled = menuSounds
            guard oldValue != menuSounds else { return }
            UserDefaults.standard.set(menuSounds, forKey: Self.menuSoundsKey)
        }
    }

    /// The saved Menu Sounds choice; a missing or non-Bool value reads as On.
    static func storedMenuSounds(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: menuSoundsKey) as? Bool ?? true
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
    static let requiredSetupVersion = 11
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
    /// The original bytes of saved slots this build can't read (nil where the
    /// slot read fine), written back unchanged on every preset save.
    /// (audit DAT-preset-recovery-loss)
    @ObservationIgnored private var unreadablePresetSlots: [Data?] = []
    /// Which slot's settings are currently loaded (nil once settings diverge or
    /// a slot is cleared).
    private(set) var activePresetSlot: Int?
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
    private static let interfaceSizeKey = "vibelight.interfaceSize"
    static let menuSoundsKey = "vibelight.menuSounds"
    private static let setupVersionKey = "vibelight.setupVersion"

    // MARK: - Boot

    init() {
        // VibeLight is SEPARATE from Moonlight: it no longer reads Moonlight's
        // preferences for identity, hosts, apps or stream defaults. Sharing that
        // file meant installing/resetting/removing Moonlight silently rewrote
        // VibeLight's pairings and settings. A user switching over pairs their
        // computers once, in-app, by PIN — Moonlight is never consulted and never
        // written to.
        let identity = IdentityStore.resolve(moonlightIdentity: nil)
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
        var loaded: StreamSettings = .fallback   // no Moonlight import — our own defaults
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey) {
            if let saved = try? JSONDecoder().decode(StreamSettings.self, from: data) {
                loaded = saved
            } else {
                // The first setting the user changes saves the defaults over
                // this key, so keep the unreadable original aside first, as the
                // other stores do. (audit DAT-settings-reset-overwrites-original)
                SavedDataRecovery.backUpOnce(data, to: "\(Self.settingsKey).unreadable", in: .standard)
            }
        }
        // Snap the imported bitrate (e.g. 87500) onto the clean 10 Mbps grid so
        // it reads "90 Mbps", not "87". didSet doesn't fire during init.
        let step = Self.bitrateStep
        // Clamp FIRST, snap second. `+ step / 2` on a persisted Int traps on
        // overflow, and JSONDecoder accepts Int.max without complaint — so a
        // corrupt (or hand-edited) defaults value crashed the app inside init,
        // before any UI existed, on every launch. Unrecoverable without
        // deleting preferences.
        loaded.bitrateKbps = min(max(loaded.bitrateKbps, Self.bitrateMin), Self.bitrateMax)
        loaded.bitrateKbps = min(max(((loaded.bitrateKbps + step / 2) / step) * step,
                                     Self.bitrateMin), Self.bitrateMax)
        settings = loaded
        if let raw = UserDefaults.standard.string(forKey: Self.backgroundThemeKey),
           let theme = BackgroundTheme(rawValue: raw) {
            backgroundTheme = theme   // didSet doesn't fire during init
        }
        if let raw = UserDefaults.standard.string(forKey: Self.interfaceSizeKey),
           let size = InterfaceSize(rawValue: raw) {
            interfaceSize = size
        }
        menuSounds = Self.storedMenuSounds(in: .standard)
        sfx.isEnabled = menuSounds   // didSet doesn't fire during init
        // Show the setup wizard when the user hasn't completed the CURRENT
        // required version (fresh install → 0; a bump forces a redo for all).
        let completedSetup = UserDefaults.standard.integer(forKey: Self.setupVersionKey)
        if completedSetup < Self.requiredSetupVersion { onboardingStep = .welcome }

        importedHosts = []   // hosts come from VibeLight's own store only
        let savedHosts = Self.loadAddedHosts()
        addedHosts = savedHosts.hosts
        unreadableAddedHosts = savedHosts.unreadable
        rebuildHosts()
        // Sweep box-art directories belonging to hosts that are gone. Removal
        // is handled at the point of removal, but a host's identity can also
        // change underneath us (re-pair, Sunshine reinstall, an added-by-IP
        // entry learning its real UUID), and each of those orphans a directory
        // nothing would ever delete.
        // Never sweep on a partial read: loadAddedHosts returns [] when the
        // blob is unreadable, and sweeping against an empty live-set deletes
        // EVERY host's box art (an unreadable record's id is unknown too).
        // Build the set from the store rather than the maxHosts-truncated
        // view, so a de-duped-away record's cache survives.
        if savedHosts.readFully {
            let liveHostIDs = Set(addedHosts.map { $0.uuid ?? "added:\($0.ip)" })
                .union(hosts.map(\.id))
            Task { [artwork] in await artwork.pruneOrphanedCaches(liveHostIDs: liveHostIDs) }
        }
        // Reopen on the last-used PC if it's still around (by id, or by its
        // stable address if the id's representation changed); else the first host.
        let savedHostID = UserDefaults.standard.string(forKey: Self.selectedHostKey)
        let savedHostAddr = UserDefaults.standard.string(forKey: Self.selectedHostAddrKey)
        selectedHostID = Self.resolveSelectedHostID(in: hosts, savedID: savedHostID, savedAddr: savedHostAddr)
        apps = displayApps(from: selectedHost?.apps ?? [])
        if savedHosts.blobUnreadable {
            hostError = "Your saved computers couldn't be read, so the list starts empty. "
                + "The original is kept aside. Open the computer menu (top-right) to add one by IP."
        } else if !savedHosts.unreadable.isEmpty {
            hostError = "Some saved computers couldn't be read, so they're hidden. "
                + "They're kept as they were, and changes to your other computers are still saved."
        } else if hosts.isEmpty {
            hostError = "No computers yet — open the computer menu (top-right) to add one by IP."
        }

        let savedPresets = Self.loadPresets()
        presets = savedPresets.slots
        unreadablePresetSlots = savedPresets.raw
        // Range-check AND require the slot to actually hold a preset: after one
        // fails to decode (FailableDecodable -> nil slot) the saved index could
        // point at an empty slot, leaving the row highlighting nothing.
        let savedSlot = UserDefaults.standard.object(forKey: Self.activePresetKey) as? Int
        activePresetSlot = savedSlot.flatMap {
            (0..<Self.presetSlotCount).contains($0) && presets[$0] != nil ? $0 : nil
        }

        // MoonDeckBuddy: a stable per-install client id + saved per-host configs.
        if let existing = UserDefaults.standard.string(forKey: Self.moonDeckClientKey), !existing.isEmpty {
            moonDeckClientID = existing
        } else {
            moonDeckClientID = UUID().uuidString
            UserDefaults.standard.set(moonDeckClientID, forKey: Self.moonDeckClientKey)
        }
        if let data = UserDefaults.standard.data(forKey: Self.moonDeckConfigsKey) {
            if let decoded = SavedDataRecovery.decodeMap(MoonDeckConfig.self, from: data) {
                // Unreadable entries stay as their original bytes and are
                // written back with every save (see persistMoonDeckConfigs).
                moonDeckConfigs = decoded.records
                unreadableMoonDeckConfigs = decoded.unreadable
            } else {
                // TOP-LEVEL failure (truncated blob, not an object): the map
                // starts empty and the next save writes over this key, so keep
                // the original aside first.
                SavedDataRecovery.backUpOnce(data, to: "\(Self.moonDeckConfigsKey).unreadable", in: .standard)
            }
        }

        wireCallbacks()
        rebuildFocus()
        focus.focusFirst()
        startRefreshLoop()
        runStartupChecks()
    }

    // MARK: - Presets

    private static func loadPresets() -> (slots: [StreamPreset?], raw: [Data?]) {
        let empty = Array<StreamPreset?>(repeating: nil, count: presetSlotCount)
        guard let data = UserDefaults.standard.data(forKey: presetsKey) else {
            // No v2 blob. Before giving up, adopt the pre-0.1.7 one: presets
            // moved from a dynamic list to six fixed slots and the key gained a
            // ".v2" suffix with no migration, so every preset made before that
            // release has been sitting in defaults unread ever since.
            return (migrateLegacyPresets() ?? empty, [])
        }
        // A bad or incompatible slot shows as empty — preserving slot positions
        // — instead of dropping EVERY preset when one entry can't be read. Its
        // original bytes are kept and written back on every save, so saving,
        // applying or renaming ANOTHER slot (or the settings hook) never erases
        // it; only saving into that slot replaces it.
        // (audit DAT-preset-recovery-loss)
        guard let decoded = SavedDataRecovery.decodeSlots(StreamPreset.self, from: data, count: presetSlotCount) else {
            // Not even an array: the next save writes six slots over it, so
            // keep the original aside first.
            SavedDataRecovery.backUpOnce(data, to: "\(presetsKey).unreadable", in: .standard)
            return (empty, [])
        }
        return decoded
    }

    /// One-shot adoption of the pre-0.1.7 `vibelight.presets` blob into the six
    /// fixed slots. Returns nil when there is nothing to migrate.
    private static func migrateLegacyPresets() -> [StreamPreset?]? {
        let legacyKey = "vibelight.presets"
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              let arr = try? JSONDecoder().decode([FailableDecodable<StreamPreset>].self, from: data)
        else { return nil }
        let recovered = arr.compactMap(\.value)
        guard !recovered.isEmpty else { return nil }
        var slots = Array<StreamPreset?>(repeating: nil, count: presetSlotCount)
        for (i, preset) in recovered.prefix(presetSlotCount).enumerated() { slots[i] = preset }
        if let encoded = try? JSONEncoder().encode(slots) {
            UserDefaults.standard.set(encoded, forKey: presetsKey)
            // Leave the legacy key in place: if this migration is ever wrong,
            // the original is still there to re-read. It is a few hundred bytes.
        }
        return slots
    }

    private func persistPresets() {
        if let data = SavedDataRecovery.encodeSlots(presets, preserving: unreadablePresetSlots) {
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
        // An explicit save into the slot is the one thing that replaces an
        // unreadable original there (so a later Clear can't resurrect it).
        if unreadablePresetSlots.indices.contains(i) { unreadablePresetSlots[i] = nil }
        activePresetSlot = i
        persistPresets()
        controller.focusTick()
    }

    /// Home preset row: load slot `i`'s settings (no-op for an empty slot).
    func applySlot(_ i: Int) {
        guard presets.indices.contains(i), let preset = presets[i] else { return }
        // Decoding already clamps; this keeps a preset that reached memory any
        // other way from carrying an out-of-range number into the live
        // settings. (audit DAT-stored-size-overflow)
        settings = preset.settings.clampedToLegalRanges()
        activePresetSlot = i
        persistPresets()
    }

    /// Ask before wiping a preset. Every entry point (controller slot menu and
    /// the right-click context menu) routes through here; `clearSlot` is the
    /// unguarded action the confirm calls.
    func requestClearSlot(_ i: Int) {
        guard presets.indices.contains(i), presets[i] != nil else { return }
        presentOverlay(.confirmClearPreset(i))
    }

    /// True when the focused settings row OPENS something (rather than cycling a
    /// value), so a pointer tap can route the same semantic event Select does.
    func settingsRowOpens(_ row: SettingsRow) -> Bool {
        row.isAction || row == .resolution
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
        dismissOverlay(returningTo: "presetslot:\(i)")
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
            // Scrolling the app shelf, the preset row, and settings rows is
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
            // A launch-time update offer that arrived mid-stream waits for the
            // stream to be over. The phase turns idle a moment before the
            // ended/error card is dismissed, so look again on the next turn,
            // once the card has gone. (audit QUA-launch-update-card-no-stream-gate)
            if phase == .idle, launchUpdateCardWaiting {
                Task { [weak self] in self?.presentLaunchUpdateCardIfDue() }
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
                    // Default focus = the headline action. Landing on "Resume"
                    // meant an impatient double-press resumed by accident.
                    focus.focus(itemID: "ended:quit")
                }
            } else {
                rebuildFocus()
            }
            // refreshSelectedHost bails while the session manager owns host
            // truth, and this fires with the phase still at .ending — so on the
            // ordinary end-of-stream path (the .sessionEnded card) it returned
            // immediately and the shelf stayed stale until the 12 s poll came
            // round. Refresh when the phase really is idle; the acknowledgement
            // sites refresh for the card path.
            if session.phase == .idle {
                Task { await self.refreshSelectedHost() }
            }
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
                if overlay == nil, screen == .home, !isOnboarding { presentOverlay(.relocate) }
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
            launchUpdateCardWaiting = false
            presentLaunchUpdateCardIfDue(firstLook: true)
        }
    }

    /// The launch-time update card found an update while a stream was starting
    /// or live; it is shown once the stream is over instead of being dropped.
    @ObservationIgnored private var launchUpdateCardWaiting = false

    enum LaunchUpdateCardDecision: Equatable { case show, waitForStreamEnd, skip }

    /// Pure rule for the launch-time update card. The GitHub check can answer
    /// up to ~17 s after launch; by then a game may be streaming, and the Mac
    /// clears the card slot when a stream goes live — so "no card open" alone
    /// put the update card under the game, where it was then replaced by the
    /// stream-ended card and lost. A live (or starting/ending) session now
    /// means "wait"; any other card open or a screen other than Home means
    /// "skip" (the Settings row still offers the update), as before.
    /// (audit QUA-launch-update-card-no-stream-gate)
    nonisolated static func launchUpdateCardDecision(updateAvailable: Bool, sessionIdle: Bool,
                                                     overlayOpen: Bool, onHome: Bool,
                                                     onboarding: Bool) -> LaunchUpdateCardDecision {
        guard updateAvailable else { return .skip }
        guard sessionIdle else { return .waitForStreamEnd }
        return overlayOpen || !onHome || onboarding ? .skip : .show
    }

    /// Shows the launch-time update card when the rule allows. `firstLook` is
    /// the check's own answer; later looks only happen when a stream returns to
    /// idle, for a card that was waiting on one.
    private func presentLaunchUpdateCardIfDue(firstLook: Bool = false) {
        guard firstLook || launchUpdateCardWaiting else { return }
        let decision = Self.launchUpdateCardDecision(
            updateAvailable: updateService.phase == .available,
            sessionIdle: session.phase == .idle,
            overlayOpen: overlay != nil, onHome: screen == .home, onboarding: isOnboarding)
        switch decision {
        case .show:
            launchUpdateCardWaiting = false
            presentOverlay(.update)
        case .waitForStreamEnd:
            launchUpdateCardWaiting = true
        case .skip:
            // A card already waiting on a stream keeps waiting (for any skip
            // reason) until a later stream ends with the update still
            // available; Settings offers the update meanwhile. A first look
            // that skips never waits.
            if firstLook || updateService.phase != .available { launchUpdateCardWaiting = false }
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
        if let id = Self.hostMenuOpeningFocusID(hosts: hosts, selectedID: selectedHostID) {
            focus.focus(itemID: id)
        }
    }

    private static let addedHostsKey = "vibelight.addedHosts"

    /// Saved-computer records this build can't read, as their original bytes.
    /// Written back unchanged beside `addedHosts` on every save, so they
    /// survive untouched AND adding, pairing or removing the other computers
    /// is still saved. Replaces a latch that refused every write once one
    /// record failed to read — which nothing could ever clear, so every later
    /// change vanished on quit. (audit DAT-added-hosts-latch-forever)
    @ObservationIgnored private var unreadableAddedHosts: [Data] = []

    private static func loadAddedHosts()
        -> (hosts: [AddedHost], unreadable: [Data], blobUnreadable: Bool, readFully: Bool) {
        guard let data = UserDefaults.standard.data(forKey: addedHostsKey) else { return ([], [], false, true) }

        // Decode entries one-by-one and keep the good ones, so a single corrupt
        // or schema-incompatible record can't drop the whole list — each
        // AddedHost carries a pinned pairing cert whose loss forces re-pairing.
        // The ones that don't decode are kept byte for byte (see above).
        guard let decoded = SavedDataRecovery.decodeList(AddedHost.self, from: data) else {
            // The whole blob is unreadable (truncated, not an array). The list
            // starts empty and the next save writes over this key, so keep the
            // original aside first.
            SavedDataRecovery.backUpOnce(data, to: "\(addedHostsKey).unreadable", in: .standard)
            return ([], [], true, false)
        }
        var hosts = decoded.records
        // Heal uuid collisions left by older builds: when the same PC was saved
        // at two addresses (LAN + Tailscale), both records could end up carrying
        // the same learned uuid, and rebuildHosts then de-duped one out of the
        // LIST while its record stayed in storage — a computer that is invisible
        // yet un-re-addable. Strip the uuid from the later records; they fall
        // back to the synthetic `added:<ip>` id and become visible (and
        // removable) again. upgradeAddedHost refuses to create new collisions.
        var seenUUIDs = Set<String>()
        for i in hosts.indices {
            if let uuid = hosts[i].uuid, !seenUUIDs.insert(uuid).inserted { hosts[i].uuid = nil }
        }
        return (hosts, decoded.unreadable, false, decoded.unreadable.isEmpty)
    }

    private func persistAddedHosts() {
        // Never re-encode only the survivors: that is what turns "one record
        // didn't decode today" into "that computer's pairing is gone forever"
        // (the first successful probe calls upgradeAddedHost, which persists).
        if let data = SavedDataRecovery.encodeList(addedHosts, preserving: unreadableAddedHosts) {
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
        #if os(macOS)
        // Hand the stream helper the same host list — critically each host's
        // pinned server cert, without which it can't use HTTPS 47984 and would
        // read PairStatus off the unauthenticated 47989 port as "not paired".
        // Runs on every rebuild so pairing a host, renaming it, or removing one
        // reaches the helper immediately.
        IdentityStore.syncHelperHosts(hosts)
        #endif
    }

    private static func streamHost(from added: AddedHost) -> StreamHost {
        StreamHost(id: added.uuid ?? "added:\(added.ip)", name: added.name,
                   localAddress: added.ip, localPort: 47989,
                   remoteAddress: nil, remotePort: 47989,
                   manualAddress: added.ip, manualPort: 47989,
                   macAddress: added.mac, serverCertPEM: added.serverCert, apps: [])
    }

    // MARK: - Pairing

    /// Whether this host still needs pairing (no pinned server cert yet).
    /// Hosts that answered but refused our client identity — the certificate on
    /// the PC changed (streaming software reinstalled), or our identity was
    /// removed from its paired pool. Populated by `refreshSelectedHost`, cleared
    /// the moment the host answers normally again.
    @ObservationIgnored private var hostsNeedingRepair: Set<String> = []

    /// True when selecting this computer should start PAIRING rather than just
    /// switching to it.
    ///
    /// "Do we hold a certificate?" was the whole test, which left no way back
    /// from a certificate that CHANGED: the pin correctly rejected the host and
    /// the banner correctly said "pair it again", but every pairing entry point
    /// was gated behind not having a certificate — so the one host that needed
    /// re-pairing was the one host that could never reach it.
    func needsPairing(_ host: StreamHost) -> Bool {
        !host.isPaired || hostsNeedingRepair.contains(host.id)
    }

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
        let pairedID = pairing?.hostID
        pairingTask?.cancel()
        pairingTask = nil
        pairing = nil
        setPairingKeepAwake(false)
        rebuildFocus()
        // Back on the Computers list: land on the computer whose pairing you
        // just left — by ID, not the engine's remembered row NUMBER, because a
        // successful pairing selects that computer and moves it to the top.
        // If its ID changed mid-pairing (upgradeAddedHost learns the real
        // UUID), fall back to the computer you're on, as openHostMenu does.
        if case .hosts = overlay,
           let id = Self.hostMenuReturnFocusID(hosts: hosts, pairedID: pairedID, selectedID: selectedHostID) {
            focus.focus(itemID: id)
        }
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
    private var bgQuitTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Ends the quit-on-background assertion exactly once. Safe to call from both
    /// the completion path and the expiration handler (idempotent via `.invalid`).
    private func endBGQuitTask() {
        if bgQuitTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgQuitTaskID)
            bgQuitTaskID = .invalid
        }
    }

    /// iOS "Quit Game on App Exit": backgrounding suspends our sockets, so the
    /// stream can't survive anyway — tear down locally, and when the setting is
    /// on also /cancel the remote game. Runs inside a UIKit background task so
    /// the HTTPS round-trip has time to land before suspension.
    func handleAppDidEnterBackground() {
        // DELIBERATELY narrow: only a stream THIS device is running right now.
        // Backgrounding is app-switching, not quitting — a broader predicate
        // (hasActiveRemoteSession) would /cancel games this device merely
        // *sees* running: another client's live session, or a game the user
        // explicitly kept playing via disconnect-keep-playing (invariant 6).
        let live: Bool
        switch session.phase {
        case .streaming, .launching: live = true
        default: live = false
        }
        guard live else { return }
        // One quit-on-background episode at a time: if a prior assertion's Task is
        // still in flight (rapid foreground→background toggle), let it finish
        // rather than begin a second and cross-end them — ending id=2 from Task_A
        // could cut off Task_B's /cancel mid-round-trip. The in-flight Task's own
        // disconnect() already covers the teardown. (review: bgQuitTaskID race)
        guard bgQuitTaskID == .invalid else { return }
        // An expiration handler is mandatory: if the task outlives iOS's grace
        // window with no handler, the app is force-terminated. Here we just end
        // the assertion cleanly — the /cancel is best-effort, staying alive isn't.
        bgQuitTaskID = UIApplication.shared.beginBackgroundTask(withName: "vibelight.quit-on-background") { [weak self] in
            self?.endBGQuitTask()
        }
        Task {
            // 2.5 s budget: iOS SIGKILLs (0x8BADF00D) any app that takes ≥5 s to
            // terminate — the /cancel is best-effort, staying alive is not.
            await stopStreamForAppExit(budget: .milliseconds(2500))
            session.disconnect()           // always: never strand a dead .streaming UI
            endBGQuitTask()
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
        // Setting up Restart PC again for this computer replaces its
        // unreadable entry, if it had one.
        unreadableMoonDeckConfigs[key] = nil
        persistMoonDeckConfigs()
    }

    /// Writes the readable configs back together with the unreadable entries'
    /// original bytes, so a save never flattens what didn't read.
    private func persistMoonDeckConfigs() {
        if let data = SavedDataRecovery.encodeMap(moonDeckConfigs, preserving: unreadableMoonDeckConfigs) {
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
              let host = hostForCapturedID(hostID),
              let addr = moonDeckConnectAddress(for: host) else { return }
        // Reject an out-of-range port before it is saved or reaches a URL.
        // (audit NET-negative-buddy-port)
        guard let port = MoonDeckBuddyClient.port(fromField: moonDeckPortText) else {
            moonDeckPairing = MoonDeckPairing(
                hostID: hostID, pin: "",
                status: .failed("Enter a port from 1 to 65535. MoonDeckBuddy uses 59999 unless you changed it."))
            rebuildFocus()
            return
        }
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
                switch error as? MoonDeckBuddyClient.MDError {
                case .offline:
                    moonDeckPairing?.status = .offline
                case .certChanged:
                    // The Buddy on the PC presents a different cert than the one
                    // pinned at the last pairing — a reinstall/update, normally.
                    // Pairing is the user's explicit act of (re)establishing
                    // trust, so this is the ONE place the old pin may be
                    // dropped: forget it, mark unpaired, and the next attempt
                    // trust-on-first-use captures the new cert. Without this
                    // the stale pin gated re-pairing itself, and Restart PC was
                    // dead for good after any Buddy reinstall.
                    updateMoonDeckConfig(for: host) { $0.pinnedCert = nil; $0.paired = false }
                    moonDeck.setExpectedCert(nil, forHost: addr)
                    moonDeckPairing?.status = .failed(
                        "MoonDeckBuddy was reinstalled or updated on the PC. Try pairing again — the new certificate will be trusted from now on.")
                default:
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
        guard let host = hostForCapturedID(hostID),
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
                // hostOnline just flipped false AFTER dismissOverlay()'s
                // rebuildFocus already ran — rebuild again so the now-visible
                // wake button's header:power id becomes focusable immediately
                // instead of only on the next refresh. (review: restart focus gap)
                rebuildFocus()
            } catch {
                moonDeckRestarting = false
                guard inRestartFlow(for: hostID) else { return }
                cancelMoonDeckPairing()
                // A changed Buddy certificate (or a revoked client) is
                // RECOVERABLE, but only if we route it back to pairing. Showing
                // a plain error here was a permanent dead end: requestRestartPC
                // sends paired hosts to the confirm card, and the only code that
                // clears a stale pin lives inside beginMoonDeckPairing, which is
                // reachable only from the setup card that paired hosts never
                // see. Once Buddy was reinstalled, Restart PC could never work
                // again — with no forget/re-pair path anywhere in the app.
                if let md = error as? MoonDeckBuddyClient.MDError,
                   md == .certChanged || md == .unauthorized {
                    updateMoonDeckConfig(for: host) { $0.pinnedCert = nil; $0.paired = false }
                    if let addr = moonDeckConnectAddress(for: host) {
                        moonDeck.setExpectedCert(nil, forHost: addr)
                    }
                    presentOverlay(.moonDeckSetup(hostID))
                    return
                }
                let message = (error as? LocalizedError)?.errorDescription ?? "Restart failed."
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
            // Re-probe now that it's paired — directly. This used to route
            // through selectHost(host.id), whose `guard id != selectedHostID`
            // swallowed the whole call in the NORMAL case: the host being paired
            // is almost always the selected one, so the refresh this line
            // existed for never ran, and the UI sat on the unpaired 401 state
            // until something else happened to refresh.
            if host.id == selectedHostID {
                Task { await refreshSelectedHost() }
            } else {
                selectHost(host.id)
            }
        }
    }

    /// Whether a host was added by the user (removable) vs imported from Moonlight.
    func isAddedHost(_ host: StreamHost) -> Bool {
        addedHosts.contains { $0.ip == host.manualAddress || "added:\($0.ip)" == host.id }
    }

    func addHost() {
        let ip = addHostIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else { return }
        // Gate on the STORE, not the visible list. `hosts` is post-de-dupe and
        // post-`prefix(maxHosts)`, so whenever de-duping hid a record the user
        // could add past the cap — and anything beyond the 4th was then
        // invisible, unremovable (the trash button only exists on a rendered
        // row), and treated as an orphan by the box-art sweep every launch.
        guard addedHosts.count < Self.maxHosts else {
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

    /// Ask before forgetting a computer — removeAddedHost erases its pairing
    /// certificate and box art with no undo, and its only trigger is a small
    /// trash glyph inside a row that is itself tappable.
    func requestRemoveHost(_ host: StreamHost) {
        presentOverlay(.confirmRemoveHost(host.id))
    }

    func removeAddedHost(_ host: StreamHost) {
        addedHosts.removeAll { $0.ip == host.manualAddress || "added:\($0.ip)" == host.id }
        persistAddedHosts()
        // Forget the box art too. ArtworkStore.invalidate has always been the
        // "host went away" hook, but nothing called it — so removing a computer
        // left its whole cache directory behind forever, and a host whose UUID
        // later changed (re-pair, reinstall) orphaned another one. Cache growth
        // here is unbounded by design otherwise: nothing else deletes.
        Task { [artwork, id = host.id] in await artwork.invalidate(hostUUID: id) }
        // Forget its MoonDeckBuddy pairing too. That map is keyed by ADDRESS and
        // nothing ever removed an entry, so a removed computer left its pinned
        // Buddy certificate and `paired` flag behind forever — and re-adding the
        // same IP silently inherited a stale pin from a machine that may since
        // have been reinstalled.
        for candidate in host.candidateAddresses {
            moonDeckConfigs[candidate.host] = nil
            unreadableMoonDeckConfigs[candidate.host] = nil
        }
        persistMoonDeckConfigs()
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
    private func upgradeAddedHost(ip: String, uuid: String?, name: String?, mac: Data? = nil) {
        guard let i = addedHosts.firstIndex(where: { $0.ip == ip }) else { return }
        var changed = false
        // Refuse a learned uuid that another saved record already carries: the
        // same PC saved at two addresses (LAN + Tailscale) reports one uuid from
        // both, and adopting it on the second record gave two entries the same
        // id — rebuildHosts then silently dropped one, leaving a computer that
        // was invisible but still stored, so it couldn't be removed OR re-added.
        // Keeping the synthetic `added:<ip>` id keeps the entry visible; the
        // user sees the duplicate and can delete whichever they don't want.
        if let uuid, addedHosts[i].uuid != uuid,
           !addedHosts.contains(where: { $0.ip != ip && $0.uuid == uuid }) {
            addedHosts[i].uuid = uuid; changed = true
        }
        if let name, !name.isEmpty, addedHosts[i].name == ip { addedHosts[i].name = name; changed = true }
        if let mac, addedHosts[i].mac != mac { addedHosts[i].mac = mac; changed = true }
        if changed {
            persistAddedHosts()
            let keepID = selectedHostID
            rebuildHosts()
            // The id may have changed (added:<ip> → uuid); re-point selection.
            // The fallback must be validated: restoring an id that rebuildHosts
            // no longer produces left selectedHost nil — a blank home screen
            // with every host healthy.
            if let match = hosts.first(where: { $0.manualAddress == ip }) {
                selectedHostID = match.id
            } else if hosts.contains(where: { $0.id == keepID }) {
                selectedHostID = keepID
            } else {
                selectedHostID = hosts.first?.id
            }
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
        // Staleness identity for the guards below. The captured id is MUTABLE:
        // for an added-by-IP host, upgradeAddedHost() (called mid-flight, below)
        // swaps the synthetic `added:<ip>` id for the host's real uuid. Comparing
        // the post-upgrade selection against the pre-upgrade capture by id alone
        // therefore read the SAME host refreshing itself as "user switched
        // hosts" — and threw away the first applist a newly-added host ever
        // fetched. Same physical host = same id OR same manual address.
        func selectionStillThisHost() -> Bool {
            guard let now = selectedHost else { return false }
            if now.id == host.id { return true }
            if let ip = host.manualAddress, now.manualAddress == ip { return true }
            return false
        }
        do {
            let (info, address) = try await api.serverInfo(for: host)
            // The user can switch hosts (or a stream can start) during the
            // await; don't clobber the new selection's state with this stale
            // response — the same guard runs again after the applist await.
            guard selectionStillThisHost(), session.phase == .idle else { return }
            serverInfo = info
            hostAddress = address
            hostError = nil
            hostNotResponding = false
            if wakingHostID == host.id {   // it woke up — drop the transient state
                wakingHostID = nil
                wakeClearTask?.cancel()
            }
            // A freshly-added host reports its real name here — and its MAC,
            // which is what makes Wake-on-LAN possible for in-app-paired hosts.
            if isAddedHost(host), let ip = host.manualAddress {
                // Pass the host's REAL uuid (serverinfo <uniqueid>). This used to
                // be nil, so a host added by IP kept the synthetic `added:<ip>` id
                // forever — and the stream helper, which matches saved computers
                // by uuid, rejected it as a different PC ("Found unexpected PC")
                // and reported it offline.
                upgradeAddedHost(ip: ip, uuid: info.hostUUID, name: info.hostname, mac: info.macAddress)
            }
            let fresh = try await api.appList(for: host, at: address)
            guard selectionStillThisHost(), session.phase == .idle else { return }
            apps = displayApps(from: fresh)
            // The host answered normally, so whatever identity trouble we saw
            // before is over.
            hostsNeedingRepair.remove(host.id)
            rememberApps(fresh, for: host)
        } catch let error as HostAPIError {
            serverInfo = nil
            hostAddress = nil
            // A wedged host is NOT the normal asleep case — surface it, and
            // remember it so the wake button stays hidden (see canWakeSelectedHost).
            if case .notResponding = error { hostNotResponding = true } else { hostNotResponding = false }
            if case .unreachable = error {
                hostError = nil // asleep host is a normal state, not an error banner
            } else {
                hostError = error.localizedDescription
            }
            // The host is reachable but refuses our identity — remember it so
            // selecting this computer offers PAIRING again instead of just
            // switching to it (see needsPairing). Without this the banner tells
            // the user to pair again and nothing in the UI lets them.
            switch error {
            case .hostIdentityChanged, .notAuthorized: hostsNeedingRepair.insert(host.id)
            default: break
            }
            // Fall back to the last app list we actually saw for this host.
            // This used to read `host.apps`, which is ALWAYS empty in the
            // shipping app (streamHost(from:) hardcodes `apps: []` and the
            // Moonlight plist import was removed in v0.2.0) — so the "cache"
            // was `apps = []`, and any hiccup blanked the whole shelf.
            apps = displayApps(from: rememberedApps(for: host))
        } catch {
            serverInfo = nil
            hostAddress = nil
            hostNotResponding = false
        }
        rebuildFocus()
        if focus.focusedItemID == nil { focus.focusFirst() }
    }

    // MARK: - Last-known app list

    private static let appCacheKey = "vibelight.appCache"
    /// The last app list each host successfully reported, keyed by host id.
    /// Restored at launch and after an error so the shelf shows what you had
    /// instead of going blank the moment the PC sleeps.
    @ObservationIgnored private lazy var appCache: [String: [StreamApp]] = {
        guard let data = UserDefaults.standard.data(forKey: Self.appCacheKey),
              let decoded = try? JSONDecoder().decode([String: FailableDecodable<[StreamApp]>].self, from: data)
        else { return [:] }
        return decoded.compactMapValues(\.value)
    }()

    private func rememberApps(_ list: [StreamApp], for host: StreamHost) {
        guard !list.isEmpty else { return }
        // Key on the host's id AS IT IS NOW, not as it was when the caller
        // captured it. `refreshSelectedHost` holds a value-type snapshot taken
        // before `upgradeAddedHost` learned the real UUID, so a newly added
        // computer's FIRST app list was filed under `added:<ip>` and then
        // deleted two lines later by the prune below — whose `live` set already
        // held the UUID. The cache existed precisely so a sleeping PC doesn't
        // blank the shelf, and for that computer it stayed empty until the next
        // poll 12 s later.
        let key = currentID(of: host)
        appCache[key] = list
        // Bounded: only the hosts that still exist, so a long-lived install
        // can't accumulate app lists for computers that are long gone.
        let live = Set(addedHosts.map { $0.uuid ?? "added:\($0.ip)" })
        appCache = appCache.filter { live.contains($0.key) }
        if let data = try? JSONEncoder().encode(appCache) {
            UserDefaults.standard.set(data, forKey: Self.appCacheKey)
        }
    }

    private func rememberedApps(for host: StreamHost) -> [StreamApp] {
        appCache[currentID(of: host)] ?? appCache[host.id] ?? host.apps
    }

    /// A host's id is not stable: `upgradeAddedHost` swaps the synthetic
    /// `added:<ip>` for the real UUID the first time /serverinfo answers, and
    /// the 12 s poll can do that while a caller is still holding a snapshot
    /// taken before the swap. Re-resolve through the address, which does not
    /// change, before using an id as a key or a lookup.
    private func currentID(of host: StreamHost) -> String {
        guard let ip = host.manualAddress,
              let added = addedHosts.first(where: { $0.ip == ip }) else { return host.id }
        return added.uuid ?? "added:\(added.ip)"
    }

    /// Resolves a host id captured when a card was opened. Same instability as
    /// `currentID(of:)`, seen from the other side: `.confirmRemoveHost` and
    /// friends store only the id STRING, so an id swap while the card sits open
    /// made the destructive button a silent no-op — it took the not-found
    /// branch and just dismissed, leaving the computer in the list.
    func hostForCapturedID(_ id: String) -> StreamHost? {
        if let host = hosts.first(where: { $0.id == id }) { return host }
        guard id.hasPrefix("added:") else { return nil }
        let ip = String(id.dropFirst("added:".count))
        return hosts.first { $0.manualAddress == ip }
    }

    /// Filters host pseudo-apps out of the library (permission placeholder,
    /// terminate entries, unnamed apps) and hides Moonlight-hidden ones.
    /// Order: most recently LAUNCHED first (what you play lives at the front of
    /// the shelf), then the host's own idx/name order for everything untouched.
    private func displayApps(from raw: [StreamApp]) -> [StreamApp] {
        let hostID = selectedHostID ?? ""
        return raw.filter { app in
            guard app.id != 114514, !app.isHidden else { return false }
            let name = app.name.lowercased()
            return !name.isEmpty && name != "terminate" && !name.hasPrefix("terminate ")
        }
        .sorted { a, b in
            let la = recentLaunches["\(hostID)|\(appKey(a))"] ?? .distantPast
            let lb = recentLaunches["\(hostID)|\(appKey(b))"] ?? .distantPast
            if la != lb { return la > lb }
            return (a.idx ?? Int.max, a.name) < (b.idx ?? Int.max, b.name)
        }
    }

    // MARK: - Launch recency (shelf order)

    private static let recentLaunchesKey = "vibelight.recentLaunches"

    /// Last-launch time per "hostID|appKey". Host-scoped so numeric app ids
    /// can't collide across computers. Loaded once; persisted on every record.
    @ObservationIgnored private lazy var recentLaunches: [String: Date] = {
        guard let data = UserDefaults.standard.data(forKey: Self.recentLaunchesKey),
              let raw = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }()

    private func recordLaunch(of app: StreamApp, on host: StreamHost) {
        recentLaunches["\(host.id)|\(appKey(app))"] = Date()
        // Cap the history so a decade of launches can't grow the blob unbounded:
        // keep the newest 128 entries (a shelf shows far fewer than that).
        if recentLaunches.count > 128 {
            let keep = recentLaunches.sorted { $0.value > $1.value }.prefix(128)
            recentLaunches = Dictionary(uniqueKeysWithValues: Array(keep))
        }
        let raw = recentLaunches.mapValues { $0.timeIntervalSince1970 }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.recentLaunchesKey)
        }
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

    /// The computer we last fired a Wake-on-LAN burst at, held until it comes
    /// online or the wait lapses. Drives the home-header power button's
    /// "waking…" pulse so the wake reads as *working* instead of doing nothing
    /// visible for the ~30–60 s a PC takes to boot.
    private(set) var wakingHostID: String?
    @ObservationIgnored private var wakeClearTask: Task<Void, Never>?

    /// Home-header power button action: wake the selected computer over the
    /// network (WoL) and show a transient waking state. No-op if it's already
    /// online or has no stored MAC. There is deliberately no remote power-OFF —
    /// neither GameStream nor MoonDeckBuddy exposes shutdown/sleep; "power" here
    /// means turn ON, and Restart covers reboot.
    func wakeSelectedHost() {
        guard let host = selectedHost, host.macAddress != nil, !hostOnline else { return }
        wakeHost(host)
        wakingHostID = host.id
        wakeClearTask?.cancel()
        wakeClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard let self, self.wakingHostID == host.id else { return }
            self.wakingHostID = nil
        }
    }

    func wakeHost(_ host: StreamHost) {
        guard let mac = host.macAddress else { return }
        let targets = host.candidateAddresses
        // Burst off the main thread: hostname resolution can block, and Wi-Fi
        // drops broadcast UDP often enough that one packet is a coin flip —
        // three full bursts 300 ms apart is cheap insurance (same reasoning as
        // moonlight-qt re-waking on every seek attempt).
        Task.detached(priority: .utility) {
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(300)) }
                try? WakeOnLAN.wake(mac: mac, targets: targets)
            }
        }
    }

    // MARK: - Focus content


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
                // Same order HostMenuCard draws (selected computer first).
                var ids = Self.hostMenuOrder(hosts: hosts, selectedID: selectedHostID)
                    .map { "hostmenu:\($0.id)" }
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
        case .confirmClearPreset:
            sections = [FocusSection(id: "clearpreset", kind: .vList,
                                     itemIDs: ["clearpreset:cancel", "clearpreset:yes"])]
        case .confirmRemoveHost:
            sections = [FocusSection(id: "removehost", kind: .vList,
                                     itemIDs: ["removehost:cancel", "removehost:yes"])]
        case .presetSlotMenu:
            sections = [FocusSection(id: "slotmenu", kind: .vList,
                                     itemIDs: ["slotmenu:rename", "slotmenu:clear", "slotmenu:cancel"])]
        case .renamePreset:
            sections = [FocusSection(id: "rename", kind: .vList,
                                     itemIDs: ["rename:set", "rename:cancel"])]
        case .moonDeckSetup:
            // Locked while a restart is in flight, matching confirmRestartPC —
            // otherwise the card renders a ProgressView while the focus engine
            // still holds ids for buttons no view is drawing, breaking the
            // "never hold a focusable id nothing renders" invariant.
            if moonDeckRestarting { return }
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
                    var headerIDs = ["header:restart", "header:host"]
                    // The wake/power button sits LEFT of restart, but only when the
                    // selected computer is wakeable — its only useful moment. Shares
                    // canWakeSelectedHost with HomeView's render gate so the id is
                    // emitted iff the view is drawn (focus invariant).
                    if canWakeSelectedHost { headerIDs.insert("header:power", at: 0) }
                    sections.append(FocusSection(id: "header", kind: .shelf, itemIDs: headerIDs))
                } else {
                    // Fresh install (no host): "Add Computer" is the only way in,
                    // so make it controller/keyboard reachable instead of a
                    // pointer-only dead-end. (audit QOL-controller-deadend-no-host)
                    sections.append(FocusSection(
                        id: "header", kind: .shelf, itemIDs: ["header:addhost"]
                    ))
                }
                sections.append(FocusSection(
                    id: "apps", kind: .shelf,
                    itemIDs: apps.map { "app:\(appKey($0))" }
                ))
                // The six preset slots sit in a row UNDER the shelf — d-pad
                // DOWN from a game reaches them, UP returns. Same section and
                // item IDs as the settings strip, so the engine's per-section
                // memory carries your slot position between the two screens.
                sections.append(FocusSection(
                    id: "presetslots", kind: .shelf,
                    itemIDs: (0..<Self.presetSlotCount).map { "presetslot:\($0)" }
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
        // Open on the card's DECLARED first choice, not on whatever the user
        // last touched in it. FocusEngine's per-section memory is deliberately
        // never pruned — right for a shelf, hazardous for a confirm card:
        // hovering "Forget Computer" once records index 1, and `setSections`'
        // repair restores index 1 every later time the card is built, so it
        // opens ARMED and one press destroys something. The cards document
        // "Cancel is focused first"; this is what makes that true.
        // (Pinned by FocusEngineTests.testSectionMemoryCanRestoreADestructive…)
        if opensOnDeclaredFirstChoice(newOverlay) { focus.focusFirst() }
        if focus.focusedItemID == nil { focus.focusFirst() }
    }

    /// Listed explicitly, not applied blanket: `.hosts` opens on the computer
    /// you're on, by ID (`openHostMenu`), `.sessionEnded` picks its own
    /// headline action right after presenting, and the HUD / cheat sheet
    /// deliberately leave the home screen's focus untouched underneath them
    /// (rebuildFocus returns early for those, so forcing focus would move the
    /// shelf behind the card).
    private func opensOnDeclaredFirstChoice(_ overlay: Overlay) -> Bool {
        switch overlay {
        case .confirmRemoveHost, .confirmClearPreset, .confirmOverridePreset,
             .confirmSwitchStream, .presetSlotMenu:
            return true
        case .confirmRestartPC:
            // rebuildFocus installs no section while a restart is in flight.
            return !moonDeckRestarting
        default:
            return false
        }
    }

    /// Rebuild the focus tree and guarantee something is focused — the shared
    /// tail of screen/overlay transitions. Sites that force a specific target
    /// use `focusFirst()` / `focusFirstSettingRow()` directly instead.
    private func refreshFocus() {
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

    // MARK: - TV companion panel (iOS)

    /// Whether the iPad hands the launcher to the TV and shows only the
    /// companion panel. The TV takes no touch, so without a gamepad to drive
    /// it the launcher stays under the user's finger on the iPad (the TV keeps
    /// mirroring it) — UX-tv-attached-touch-dead-end. Streaming has its own
    /// companion (trackpad), so this is the idle case only.
    nonisolated static func companionPanelOwnsIPad(
        useTV: Bool, tvConnected: Bool, streaming: Bool, hasGamepad: Bool
    ) -> Bool {
        useTV && tvConnected && !streaming && hasGamepad
    }

    /// The companion panel's "Use the iPad Instead": turns Use TV / Monitor
    /// off (persisted by `settings.didSet`; Settings ▸ Video turns it back on).
    func useIPadInsteadOfTV() {
        settings.externalDisplay = false
        sfx.play(.select)
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

    /// Whether the user already had presets when the wizard started. Captured
    /// once (not live) so seeding Preset 1 mid-flow for a fresh user doesn't
    /// retroactively change which steps are skipped or the progress pips.
    private(set) var onboardingHadPresets = false

    /// Call when the wizard opens (welcome appears) to snapshot preset state.
    /// Snapshot the preset state ONCE per wizard session. Documented as
    /// "captured once (not live)" so seeding Preset 1 mid-flow doesn't
    /// retroactively change which steps are skipped — but its only caller ran on
    /// every appearance of Welcome, which Back re-enters.
    func beginOnboardingSessionIfNeeded() {
        guard !onboardingSessionSnapshotted else { return }
        onboardingSessionSnapshotted = true
        onboardingHadPresets = hasAnyPreset
    }

    /// Cleared when a wizard session ends, so the next one snapshots afresh.
    @ObservationIgnored private var onboardingSessionSnapshotted = false

    /// Steps skipped for users who already have presets — they've clearly set up
    /// their quality before, so the stream-quality AND presets-tutorial steps are
    /// both redundant. Fresh users (no presets) see the full flow.
    func shouldSkipStep(_ step: OnboardingStep) -> Bool {
        (step == .quality || step == .presets) && onboardingHadPresets
    }

    /// Advance to the next wizard step (hopping over any skipped ones), or finish.
    func advanceOnboarding() {
        guard let step = onboardingStep else { return }
        sfx.play(.select)
        var raw = step.rawValue + 1
        while let s = OnboardingStep(rawValue: raw), shouldSkipStep(s) { raw += 1 }
        if let next = OnboardingStep(rawValue: raw) {
            onboardingStep = next   // view layer animates the step transition
        } else {
            completeSetup()
        }
    }

    func backOnboarding() {
        guard let step = onboardingStep else { return }
        var raw = step.rawValue - 1
        while let s = OnboardingStep(rawValue: raw), shouldSkipStep(s) { raw -= 1 }
        guard let prev = OnboardingStep(rawValue: raw) else { return }
        sfx.play(.back)
        onboardingStep = prev
    }

    /// Finish: persist so the wizard never shows again, and hand off to the
    /// launcher (which plays its own deal-in intro right after).
    /// Called at the END of the finale (not the moment "Jump in" is pressed):
    /// persist the completed version and drop into the launcher.
    func completeSetup() {
        guard onboardingStep != nil else { return }   // idempotent — never re-deal the intro
        UserDefaults.standard.set(Self.requiredSetupVersion, forKey: Self.setupVersionKey)
        // Clear the overlay FIRST → it fades out to reveal the bare background
        // with the UI still hidden (the intro hasn't started, so every element is
        // at opacity 0). Then, after a clean beat of just-background, start the
        // deal-in so the UI fades in on its own instead of appearing mid-fade
        // (which read as a "jump"). First-launch-only — a normal launch deals in
        // immediately via HomeView.onAppear.
        onboardingStep = nil
        onboardingSessionSnapshotted = false
        intro.reset()   // guarantee a fresh, un-played deal-in
        // Same focus rule as restartSetup: the wizard's sections must leave the
        // engine the moment the wizard leaves the screen.
        refreshFocus()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.1))
            self?.intro.begin(protected: true)   // plays out fully — no accidental skip
        }
    }

    /// The setup finale's "arrival" swell (played by `FinaleStep`).
    func playLaunchCue() { sfx.play(.launch) }

    /// A quack (played on the setup welcome screen).
    func playQuack() { sfx.play(.quack) }

    /// Settings ▸ Restart Setup — replay the wizard from the top.
    func restartSetup() {
        onboardingSessionSnapshotted = false   // a new wizard session snapshots afresh
        onboardingQualityFocus = 0
        screen = .home
        overlay = nil
        onboardingStep = .welcome
        // Every other screen/overlay transition funnels through helpers that
        // rebuild the focus tree; this one is reachable only FROM Settings, so
        // skipping the rebuild left the engine holding the settings sections
        // while the home screen rendered — the invariant "never hold focusable
        // IDs no view renders" broken in both directions.
        refreshFocus()
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
        //  • Home: select confirms. The rising reboot cue plays ONLY when a PC
        //    restart actually fires (the confirm/setup overlay buttons) — the
        //    header button just opens the confirm, so it's a plain select.
        switch event {
        case .select:
            if overlay != nil {
                let firesRestart = !moonDeckRestarting &&
                    (focus.focusedItemID == "restartpc:yes" || focus.focusedItemID == "moondeck:restart")
                sfx.play(firesRestart ? .restart : .select)
            } else if screen != .settings {
                sfx.play(.select)
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
        // The preset row under the shelf is a normal focus-engine section, so
        // movement needs no special casing — only select/contextMenu do.
        let onSlot = presetSlotIndex(focus.focusedItemID)
        switch event {
        case .select:
            // (A `host:`-prefixed branch used to sit here. No view and no
            // rebuildFocus path has ever emitted that prefix — the home screen
            // emits `header:*`/`app:*` and the overlay emits `hostmenu:*`, which
            // does not match. Host switching goes through routeOverlay.)
            if let i = onSlot {
                applySlot(i)                    // no-op on an empty slot
            } else if focus.focusedItemID == "header:host" || focus.focusedItemID == "header:addhost" {
                openHostMenu()
            } else if focus.focusedItemID == "header:power" {
                wakeSelectedHost()
            } else if focus.focusedItemID == "header:restart" {
                requestRestartPC()
            } else if let app = focusedApp {
                launch(app)
            }
        case .settings:
            openSettings()
        case .contextMenu:
            // X on a filled slot manages it; anywhere else X (like Y) opens
            // the cheat sheet, same as before the row moved.
            if let i = onSlot, presets[i] != nil { presentOverlay(.presetSlotMenu(i)) }
            else { presentOverlay(.cheatSheet) }
        case .detail:
            presentOverlay(.cheatSheet)
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
                    Task { await refreshSelectedHost() }
                }
            case .back:
                session.acknowledgeEnd()
                dismissOverlay()
                Task { await refreshSelectedHost() }
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
                    if let host = hostForCapturedID(hostID) {
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
        case .confirmClearPreset(let i):
            switch event {
            case .select:
                if focus.focusedItemID == "clearpreset:yes" { dismissOverlay(returningTo: "presetslot:\(i)"); clearSlot(i) }
                else { dismissOverlay(returningTo: "presetslot:\(i)") }
            case .back: dismissOverlay(returningTo: "presetslot:\(i)")
            default: _ = focus.handle(event)
            }
        case .confirmRemoveHost(let hostID):
            switch event {
            case .select:
                if focus.focusedItemID == "removehost:yes",
                   let host = hostForCapturedID(hostID) {
                    dismissOverlay(); removeAddedHost(host)
                } else { dismissOverlay() }
            case .back: dismissOverlay()
            default: _ = focus.handle(event)
            }
        case .confirmOverridePreset(let i):
            switch event {
            case .select:
                if focus.focusedItemID == "override:yes" {
                    dismissOverlay(returningTo: "presetslot:\(i)")
                    performSaveToSlot(i)
                } else { dismissOverlay(returningTo: "presetslot:\(i)") }
            case .back:
                dismissOverlay(returningTo: "presetslot:\(i)")
            default:
                _ = focus.handle(event)
            }
        case .presetSlotMenu(let i):
            switch event {
            case .select:
                switch focus.focusedItemID {
                case "slotmenu:rename": openRename(i)   // replaces this overlay
                case "slotmenu:clear":
                    // Clearing destroys the preset outright and persists
                    // immediately, while merely OVERWRITING one (which loses
                    // strictly less) already shows a confirm. Match them.
                    presentOverlay(.confirmClearPreset(i))
                default: dismissOverlay(returningTo: "presetslot:\(i)")
                }
            case .back:
                dismissOverlay(returningTo: "presetslot:\(i)")
            default:
                _ = focus.handle(event)
            }
        case .renamePreset(let i):
            switch event {
            case .select:
                if focus.focusedItemID == "rename:set" { applyRename(i) }
                else { dismissOverlay(returningTo: "presetslot:\(i)") }
            case .back:
                dismissOverlay(returningTo: "presetslot:\(i)")
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

    /// `returningTo` re-focuses a specific id after the overlay's sections are
    /// gone — used by the preset overlays to land back ON the slot they were
    /// opened from. Without it the engine's repair anchors at ordinal 0, which
    /// happened to be the slot strip on the settings screen but is the HEADER
    /// on home (the row sits below the shelf there). Same double-focus pattern
    /// as quitRemoteGameCompletely's park-on-host-chip.
    private func dismissOverlay(returningTo id: String? = nil) {
        pairingTask?.cancel(); pairingTask = nil; pairing = nil
        setPairingKeepAwake(false)
        moonDeckPairingTask?.cancel(); moonDeckPairingTask = nil; moonDeckPairing = nil
        overlay = nil
        rebuildFocus()
        if let id { focus.focus(itemID: id) }
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
        // ServerInfo's own rule: currentGameID is only meaningful when state
        // is .busy, which `runningAppID` encodes. Sunshine does not always clear
        // currentgame when a session ends, so the raw check offered "Switch to
        // X?" for a game that had already exited. The iOS engine was fixed to
        // use runningAppID in this same branch; this copy was missed.
        if let running = serverInfo?.runningAppID, running != app.id {
            let runningName = apps.first { $0.id == running }?.name ?? "Another app"
            presentOverlay(.confirmSwitchStream(running: runningName, target: app))
            return
        }
        forceLaunch(app)
    }

    /// The unguarded launch path: used directly by the switch-stream confirm
    /// (the user already chose to close what's running).
    private func forceLaunch(_ app: StreamApp) {
        guard let host = selectedHost else { return }
        // Recency for the shelf order: recorded NOW, applied on the next shelf
        // rebuild (post-stream refresh) — resorting the array mid-launch would
        // yank the tile out from under the animation the user is looking at.
        recordLaunch(of: app, on: host)
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
        // Dismiss the card on the SAME press: the /cancel round-trip (~1 s)
        // used to hold it open, which read as "the button didn't work" and
        // invited a double-press that resumed the stream instead.
        if case .sessionEnded = overlay {
            dismissOverlay()
            // Park focus on the host chip — the section-restore would land on
            // Restart PC, where the same impatient mash walks straight into a
            // PC reboot (select → confirm → yes). The chip just opens a menu.
            focus.focus(itemID: "header:host")
        }
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
                // NOW the phase is idle, so the refresh that onStreamDidEnd
                // couldn't run can finally happen.
                Task { await refreshSelectedHost() }
            }
            await refreshSelectedHost()
        }
    }

    /// A stream is active, or the host is still running a game — something the
    /// host would keep doing after VibeLight closes. Used for UI ("host busy")
    /// state, NOT for the quit-cleanup decision — see `isLocalStreamActive`.
    var hasActiveRemoteSession: Bool {
        session.phase != .idle || (serverInfo?.currentGameID ?? 0) != 0
    }

    /// THIS device owns a live (or in-progress) stream. Deliberately narrower
    /// than `hasActiveRemoteSession`: it excludes the `currentGameID != 0` term,
    /// because a running game on the host may belong to another client, or be
    /// one we intentionally left running on disconnect — quitting VibeLight must
    /// not `/cancel` a game we aren't streaming. This is the gate for quit-time
    /// cleanup, matching the iOS background path (see handleAppDidEnterBackground).
    var isLocalStreamActive: Bool {
        switch session.phase {
        case .idle, .failed: return false
        default: return true
        }
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
        guard settings.stopStreamOnExit, let host = selectedHost, isLocalStreamActive else { return }
        let work = Task { await session.quitCompletely(host: host) }
        let watchdog = Task { try? await Task.sleep(for: budget); work.cancel() }
        await work.value
        watchdog.cancel()
    }

    // MARK: - Settings rows

    enum SettingsRow: String, CaseIterable {
        case resolution, fps, bitrate, codec, hdr, decoder, yuv444
        case audio, muteHostSpeakers, muteOnFocusLoss, menuSounds
        case touchControls, touchWithController, externalDisplay, absoluteMouse, swapMouseButtons, reverseScrolling, captureSystemKeys, swapGamepadButtons, backgroundGamepad
        case vsync, framePacing, gameOpt, quitAppAfter, keepAwake, performanceOverlay, stopStreamOnExit
        case background, interfaceSize
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
            case .menuSounds: "Menu Sounds"
            case .touchControls: "Touch Control"
            case .touchWithController: "Touch With Controller"
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
            case .interfaceSize: "Interface Size"
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
                // Codec / HDR / Video Decoder / YUV 4:4:4 are hidden on iOS: the
                // in-process engine forces H.264 SDR, so those rows adjusted a
                // value that never took effect (audit QUA-ios-inert-settings).
                // Re-add each when its decode path ships — HEVC/HDR/frame-pacing
                // are on the roadmap (see InProcessStreamEngine + STREAMING-STATUS).
                [.resolution, .fps, .bitrate, .externalDisplay]
                #else
                [.resolution, .fps, .bitrate, .codec, .hdr, .decoder, .yuv444]
                #endif
            // Stream audio first, the launcher's own sounds last.
            case .audio: [.audio, .muteHostSpeakers, .muteOnFocusLoss, .menuSounds]
            case .input:
                #if os(iOS)
                [.touchControls, .touchWithController, .absoluteMouse, .swapMouseButtons, .reverseScrolling, .captureSystemKeys, .swapGamepadButtons, .backgroundGamepad]
                #else
                [.absoluteMouse, .swapMouseButtons, .reverseScrolling, .captureSystemKeys, .swapGamepadButtons, .backgroundGamepad]
                #endif
            case .about: [.appVersion, .checkUpdates, .restartSetup]
            case .advanced:
                #if os(iOS)
                // V-Sync and Frame Pacing are macOS stream-helper (moonlight-qt)
                // flags with no effect on the iOS in-process engine — hidden so
                // they don't read as working toggles (audit QUA-ios-inert-settings).
                [.gameOpt, .quitAppAfter, .keepAwake, .performanceOverlay, .stopStreamOnExit]
                #else
                [.vsync, .framePacing, .gameOpt, .quitAppAfter, .keepAwake, .performanceOverlay, .stopStreamOnExit]
                #endif
            case .themes: [.background, .interfaceSize]
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
        // Only a Native size that survives a relaunch unclamped is offered.
        if let native = nativeResolution,
           StreamSettings.storedWidthRange.contains(native.w),
           StreamSettings.storedHeightRange.contains(native.h),
           !options.contains(where: { $0.w == native.w && $0.h == native.h }) {
            options.append((native.w, native.h, "Native (\(native.w)×\(native.h))"))
        }
        if !options.contains(where: { $0.w == settings.width && $0.h == settings.height }) {
            options.append((settings.width, settings.height, "\(settings.width)×\(settings.height)"))
        }
        return options.sorted { Self.pixelCount($0.w, $0.h) < Self.pixelCount($1.w, $1.h) }
    }

    /// w × h without the overflow trap: a damaged saved size once made this
    /// sort crash every screen that shows the Resolution row.
    /// (audit DAT-stored-size-overflow)
    nonisolated static func pixelCount(_ w: Int, _ h: Int) -> Int {
        let (product, overflow) = w.multipliedReportingOverflow(by: h)
        guard overflow else { return product }
        return (w < 0) == (h < 0) ? .max : .min
    }

    /// The Frame Rate arrows: step through `presets`, and from a value that
    /// isn't one of them go to the nearest preset in the pressed direction —
    /// it used to restart from 60, so Right from 100 fps gave 90.
    /// (audit QUA-fps-offgrid-jump)
    nonisolated static func steppedFPS(from fps: Int, forward: Bool, presets: [Int]) -> Int {
        guard let first = presets.first, let last = presets.last else { return fps }
        if let i = presets.firstIndex(of: fps) {
            return presets[min(max(i + (forward ? 1 : -1), 0), presets.count - 1)]
        }
        return forward ? (presets.first { $0 > fps } ?? last)
                       : (presets.last { $0 < fps } ?? first)
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
              StreamSettings.widthRange.contains(w), StreamSettings.heightRange.contains(h) else {
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
    static let bitrateMin = StreamSettings.bitrateRange.lowerBound
    static let bitrateMax = StreamSettings.bitrateRange.upperBound

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
        case .menuSounds: menuSounds ? "On" : "Off"
        case .touchControls: settings.touchControls ? "On" : "Off"
        case .touchWithController: settings.touchWithController ? "On" : "Off"
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
        case .interfaceSize: interfaceSize.label
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
            settings.fps = Self.steppedFPS(from: settings.fps, forward: forward, presets: Self.fpsPresets)
        case .bitrate:
            // Snap to a clean 10 Mbps grid so values read 80/90/100, never
            // the imported 87.5. If already on the grid, step; otherwise jump
            // to the neighboring grid line in the pressed direction.
            let step = Self.bitrateStep
            // Clamp before stepping: `+ step` on a near-Int.max value traps.
            // (audit DAT-stored-size-overflow)
            let current = min(max(settings.bitrateKbps, Self.bitrateMin), Self.bitrateMax)
            let onGrid = current % step == 0
            let base = (current / step) * step
            let next = onGrid ? current + (forward ? step : -step)
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
        // The tick above is gated by the old value, so switching sounds back
        // on ticks once now — every press makes exactly one sound.
        case .menuSounds: menuSounds.toggle(); if menuSounds { sfx.play(.move) }
        case .touchControls: settings.touchControls.toggle()
        case .touchWithController: settings.touchWithController.toggle()
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
        case .interfaceSize: interfaceSize = Self.cycle(interfaceSize, forward: forward)
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
