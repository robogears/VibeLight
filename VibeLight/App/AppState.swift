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
    case confirmRemoveHost(String)  // forget a computer + its pairing — confirm
    case presetMenu(String)         // one preset's options (preset id)
    case namePreset(PresetNameTarget)  // name a new preset, or rename one
    case confirmRestartPC(String)   // confirm force-restarting host id (VibeLight Helper)
    case confirmSwitchStream(running: String, target: StreamApp)  // host busy — switch to target?
}

/// What the preset name card is naming.
enum PresetNameTarget: Equatable {
    case new                // the live settings, as a new preset
    case rename(String)     // an existing preset (id)
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

    private(set) var hosts: [StreamHost] = []      // the user-added hosts, de-duped, capped at 4
    /// Persisted so a relaunch reopens on the PC you last used (not whichever
    /// host happens to sort first). Restored in init when the host still exists.
    private(set) var selectedHostID: String? {
        didSet {
            guard selectedHostID != oldValue else { return }
            #if DEBUG
            if DebugInstruments.fakeHost != nil { return }   // never persist the synthetic host
            #endif
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
    /// Normal progress about the selected computer ("Restarting Gaming PC…").
    /// Kept apart from `hostError` so it's drawn in the neutral secondary
    /// colour with a spinner, not error orange (UX-host-banner-truncates).
    private(set) var hostNotice: String?
    @ObservationIgnored private var noticeClearTask: Task<Void, Never>?
    /// The selected computer has answered at least once since it was selected
    /// (games list, or a failure saying why not) — so an empty shelf means
    /// something. Reset on every selection change (UX-empty-home-no-invitation).
    private(set) var selectedHostChecked = false
    private(set) var isRefreshing = false
    /// Apps to render: fresh from the host when online, else the plist cache.
    private(set) var apps: [StreamApp] = []

    // Host management (the top-right chip menu).
    @ObservationIgnored private var importedHosts: [StreamHost] = []
    private(set) var addedHosts: [AddedHost] = []
    static let maxHosts = 4
    var addHostIP: String = ""
    var addHostError: String?

    /// A computer the user added by IP, in VibeLight's own saved hosts.
    /// `serverCert` is filled in once we pair with it.
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

    // MARK: Restart PC (VibeLight Helper)

    /// True while a restart request is in flight (locks the confirm overlay).
    /// Restart PC goes through VibeLight Helper on the PC, which replaced
    /// MoonDeckBuddy (owner) and restarts the way MoonDeckBuddy did.
    private(set) var restartingPC = false

    var selectedHost: StreamHost? {
        hosts.first { $0.id == selectedHostID }
    }
    var hostOnline: Bool { serverInfo != nil }

    /// The app the starting card (Poster Lift) is about. Known from the press,
    /// so the card can name and lift it before the engine's phase carries it
    /// (macOS reconciles first). Only read while that card is up.
    private(set) var launchTarget: StreamApp?
    /// Where the starting card lifts its poster from: the pressed tile, or
    /// the still-running card's poster when Resume carries on from it.
    private(set) var liftSourceID: String?

    /// What the still-running card (Poster Rest) knows about the session it
    /// ended. Set when the card appears; only read while it is up.
    struct EndedSession: Equatable {
        /// How long the stream ran ("played 42 min"); nil if never seen live.
        var played: TimeInterval?
        /// Set when the connection dropped rather than the player leaving.
        var dropReason: String?
        /// The PC has since reported the game gone: Resume becomes Play Again
        /// and Quit disappears.
        var closedOnHost = false
        /// Select / Back are ignored until then, so a button still being
        /// mashed from the stream can't pick something on the card unseen.
        var readyAt: Date
        /// Back to Library is under way (the poster flies home).
        var leaving = false
        /// Quit has fired: the card holds its "closing" look and fades out.
        var quitting = false
        /// …and it was Quit Stream and Game (that button stays full).
        var closingGame = false
        /// Put up by leaving the app mid-stream (iPad): it opens on Rejoin and
        /// says so (see handleAppDidEnterBackground).
        var fromAppExit = false
    }
    private(set) var endedSession: EndedSession?
    /// Bumped when Quit on the card is tapped instead of held, so its hint flashes.
    private(set) var endedQuitNudges = 0
    /// Per tile (focus id): bumped to play the one-time landing bloom.
    private(set) var tileBlooms: [String: Int] = [:]
    /// The stream this device has live and when it started: "played 42 min",
    /// and how a mid-stream drop is told from a failed launch.
    @ObservationIgnored private var liveStream: (app: StreamApp, since: Date)?
    @ObservationIgnored private var endedWatchTask: Task<Void, Never>?

    /// The status dot beside a computer's name.
    enum HostDot: Equatable, Sendable {
        case online        // green
        case unreachable   // red: not answering at all (offline, asleep, stuck)
        case attention     // orange: still being checked, or it answered with a problem
    }

    /// Red only once a check has actually failed to get an answer: a stuck
    /// service (`notResponding`) or nothing there (no error recorded — asleep
    /// or offline is not an error). An error means the PC DID answer (e.g.
    /// "pair it again"), so it stays orange.
    nonisolated static func hostDot(online: Bool, checked: Bool,
                                    notResponding: Bool, hasError: Bool) -> HostDot {
        if online { return .online }
        guard checked else { return .attention }
        return (notResponding || !hasError) ? .unreachable : .attention
    }

    var selectedHostDot: HostDot {
        Self.hostDot(online: hostOnline, checked: selectedHostChecked,
                     notResponding: hostNotResponding, hasError: hostError != nil)
    }

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

    // The saved-computers warnings lead with what happened and stay within the
    // banner's two lines (~130 characters at 420 pt): the old 150-character
    // text lost its reassuring half to "…" (UX-host-banner-truncates).
    nonisolated static let someSavedHostsUnreadableMessage =
        "Some saved computers couldn't be read, so they're hidden. Nothing was deleted, and your other computers still work."
    nonisolated static let savedHostsUnreadableMessage =
        "Your saved computers couldn't be read, so the list starts empty. Nothing was deleted — the original is kept aside."

    /// The saved-computers warning to show at launch, if any. With NO readable
    /// computer left, the "some" wording's "your other computers still work"
    /// would be false (the no-computer panel shows it), so every-record-failed
    /// reads like the whole list failing — which, to the person, it did
    /// (3H review: unreadable warning on the no-computer panel).
    nonisolated static func savedHostsWarning(blobUnreadable: Bool, unreadableCount: Int,
                                              readableCount: Int) -> String? {
        if blobUnreadable || (unreadableCount > 0 && readableCount == 0) {
            return savedHostsUnreadableMessage
        }
        return unreadableCount > 0 ? someSavedHostsUnreadableMessage : nil
    }

    /// The banner error to keep once the selected computer is removed: its own
    /// error named the computer that is gone, and with none left the empty
    /// panel would tell the person to fix it. A saved-computers warning is
    /// about the list, not that computer, so it stays (3H last review) — in
    /// its whole-list wording once no readable computer is left, since "your
    /// other computers still work" would then be false.
    nonisolated static func hostErrorAfterRemovingSelected(_ error: String?, computersLeft: Int) -> String? {
        if error == someSavedHostsUnreadableMessage {
            return computersLeft == 0 ? savedHostsUnreadableMessage : error
        }
        return error == savedHostsUnreadableMessage ? error : nil
    }

    /// What the selected computer's header chip says beside its name.
    enum HostBanner: Equatable, Sendable {
        case error(String)    // orange, up to two lines
        case notice(String)   // normal progress: secondary colour + spinner
        case status(String)   // "asleep" / "offline"
    }

    /// A real error wins over a progress notice — it must never hide behind
    /// one, just as it must never masquerade as "asleep".
    nonisolated static func hostBanner(error: String?, notice: String?,
                                       online: Bool, hasMAC: Bool) -> HostBanner? {
        if let error { return .error(error) }
        if let notice { return .notice(notice) }
        if !online { return .status(hasMAC ? "asleep" : "offline") }
        return nil
    }

    /// The header chip's error text. The chip already shows the computer's
    /// name, so an error that opens with it ("UAE Server is offline") drops
    /// the repeat and reads "is offline" beside the name. Elsewhere (the
    /// Computers card) the full sentence is shown.
    nonisolated static func chipBannerText(_ error: String, hostName: String) -> String {
        let prefix = hostName + " "
        guard !hostName.isEmpty, error.hasPrefix(prefix) else { return error }
        return String(error.dropFirst(prefix.count))
    }

    var hostBanner: HostBanner? {
        Self.hostBanner(error: hostError, notice: hostNotice, online: hostOnline,
                        hasMAC: selectedHost?.macAddress != nil)
    }

    /// Why the games shelf is empty, so it can say so and offer the next step
    /// instead of a blank row (UX-empty-home-no-invitation).
    enum EmptyShelf: Equatable, Sendable {
        case noComputer, notPaired, checking, asleep, waking, offline, notResponding, problem, noGames
    }

    nonisolated static func emptyShelf(hasHost: Bool, isPaired: Bool, checked: Bool, online: Bool,
                                       notResponding: Bool, hasError: Bool,
                                       canWake: Bool, waking: Bool) -> EmptyShelf {
        guard hasHost else { return .noComputer }
        if !isPaired { return .notPaired }
        // Until the first answer (games list or failure) the shelf is empty only
        // because nothing has loaded yet: an awake PC must not read "asleep" with
        // a Wake button, nor "No games", while it's being asked.
        if !checked { return .checking }
        if online { return .noGames }
        if notResponding { return .notResponding }
        // An error (e.g. "pair it again") is never shown as "asleep"; the
        // header chip spells it out.
        if hasError { return .problem }
        if waking { return .waking }
        return canWake ? .asleep : .offline
    }

    /// The shelf's own focusable buttons while it's empty. SINGLE source of
    /// truth: rebuildFocus emits these and HomeView's empty panel draws a
    /// button only for these ids. (No computer: the panel's Add Computer
    /// carries `header:addhost`, emitted in the header section.)
    nonisolated static func emptyShelfFocusIDs(_ shelf: EmptyShelf) -> [String] {
        switch shelf {
        case .notPaired: ["shelf:pair"]
        case .asleep: ["shelf:wake"]
        default: []
        }
    }

    /// nil while there are games to show.
    var emptyShelf: EmptyShelf? {
        guard apps.isEmpty else { return nil }
        let host = selectedHost
        // needsPairing, not isPaired: a computer whose certificate changed or
        // that now refuses us needs pairing again too, and the shelf should
        // offer Pair Computer rather than point at the header chip (3H review:
        // broken pairing showed no button).
        return Self.emptyShelf(hasHost: host != nil, isPaired: host.map { !needsPairing($0) } ?? false,
                               checked: selectedHostChecked, online: hostOnline,
                               notResponding: hostNotResponding,
                               hasError: hostError != nil, canWake: canWakeSelectedHost,
                               waking: host != nil && wakingHostID == host?.id)
    }

    // MARK: UI state

    var screen: Screen = .home
    var overlay: Overlay?
    var settings: StreamSettings {
        didSet {
            // A TV's own preset is live (TV Presets): the change is that TV's,
            // saved into its preset — never over the settings and presets
            // that come back when it's unplugged.
            if liveTV != nil {
                saveLiveTVPreset()
                return
            }
            persistSettings()
            // A change keeps the loaded preset marked — it reads "edited"
            // (Live Loadout) instead of the marker silently dropping. With
            // nothing loaded, settings that land exactly on a saved preset
            // pick it up, so the row never shows "+ Save current" for
            // something already saved.
            if activePresetID == nil, let match = presets.first(where: { $0.settings == settings }) {
                activePresetID = match.id
                persistPresets()
            }
        }
    }

    /// Settings ▸ Themes ▸ Theme: the launcher's whole look (it replaced the
    /// Background picker). Global appearance pref, stored on its own key so it's
    /// NOT captured into per-session stream presets. `ThemeStore` hands it to
    /// every `Theme` token, so whatever reads one redraws in the new theme.
    var appTheme: AppTheme = .default {
        didSet {
            ThemeStore.shared.theme = appTheme
            guard oldValue != appTheme else { return }
            UserDefaults.standard.set(appTheme.rawValue, forKey: AppTheme.storageKey)
        }
    }

    /// Settings ▸ Themes ▸ Interface Size. Global appearance pref on its own key,
    /// like `appTheme`: inside `settings` it would be captured into
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

    /// Settings ▸ Video ▸ Adaptive Bitrate (on by default): the Link Governor
    /// lowers the bitrate mid-stream when the connection struggles and brings
    /// it back to the preset's number when it's calm. Its own key, like Menu
    /// Sounds: the preset's bitrate is the ceiling, so this is not part of a
    /// preset. iPad only for now (the Mac's helper has no live bitrate).
    var adaptiveBitrate: Bool = true {
        didSet {
            #if os(iOS)
            session.adaptiveBitrate = adaptiveBitrate
            #endif
            guard oldValue != adaptiveBitrate else { return }
            UserDefaults.standard.set(adaptiveBitrate, forKey: Self.adaptiveBitrateKey)
        }
    }
    static let adaptiveBitrateKey = "vibelight.adaptiveBitrate"

    /// The saved Adaptive Bitrate choice; a missing or non-Bool value reads as On.
    static func storedAdaptiveBitrate(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: adaptiveBitrateKey) as? Bool ?? true
    }

    // MARK: Windows Helper (VibeLight Helper on the PC)

    /// Settings ▸ Windows Helper. VibeLight Helper is the small tray app on
    /// the gaming PC (`WindowsHelper/`, `WindowsHelperClient`); it does what
    /// the stream can't: Match TV and Quit Game. It needs no pairing — a
    /// device the PC's host has paired gets in — and everything it controls
    /// is greyed out until it's found on the selected PC (owner: "blank out
    /// all of the features that the helper will control if the user doesn't
    /// have the app installed").
    enum WindowsHelperState: Equatable, Sendable {
        case unknown, checking
        case ready(pcName: String)
        /// Running, but the PC's host hasn't paired this device.
        case notAllowed(pcName: String)
        case notFound
        /// A different helper certificate than the one trusted before.
        case certChanged
    }
    private(set) var windowsHelper: WindowsHelperState = .unknown {
        didSet {
            // Quit Stream and Game and the header's Restart PC take focus
            // only while the helper is ready.
            guard Self.helperReady(oldValue) != windowsHelperReady else { return }
            if overlay == nil { rebuildFocus() }
            else if case .sessionEnded = overlay { rebuildFocus() }
        }
    }
    var windowsHelperReady: Bool { Self.helperReady(windowsHelper) }
    nonisolated static func helperReady(_ state: WindowsHelperState) -> Bool {
        if case .ready = state { return true }
        return false
    }
    @ObservationIgnored let windowsHelperClient: WindowsHelperClient
    /// Which host `windowsHelper` describes, and when it last answered.
    @ObservationIgnored private var windowsHelperHostID: String?
    @ObservationIgnored private var windowsHelperCheckedAt: Date?
    @ObservationIgnored private var windowsHelperCheck: Task<Void, Never>?
    /// The helper certificate trusted per host (by host id): pinned on the
    /// first good check, required from then on.
    @ObservationIgnored private var windowsHelperPins: [String: Data] = [:]
    static let windowsHelperPinsKey = "vibelight.windowsHelper.pins"
    /// How long an answer stands before the host refresh asks again.
    nonisolated static let windowsHelperRecheck: TimeInterval = 60

    /// Settings ▸ Windows Helper ▸ Match TV (on by default; needs the helper):
    /// with a TV attached, the stream restarts at the TV's size (TV
    /// Resolution) and the PC's display and game follow; unplugged, all of it
    /// goes back. The frame rate never changes.
    var matchTV: Bool = true {
        didSet {
            guard oldValue != matchTV else { return }
            UserDefaults.standard.set(matchTV, forKey: Self.matchTVKey)
        }
    }
    static let matchTVKey = "vibelight.matchTV"

    /// Settings ▸ Windows Helper ▸ TV Resolution: Quarter (4K → 1080p, the
    /// default), Half (4K → 1440p) or Full.
    var tvMatchScale: TVMatchScale = .quarter {
        didSet {
            guard oldValue != tvMatchScale else { return }
            UserDefaults.standard.set(tvMatchScale.rawValue, forKey: Self.tvMatchScaleKey)
        }
    }
    static let tvMatchScaleKey = "vibelight.tvMatchScale"

    /// The saved Match TV choice; missing or unreadable reads as On.
    static func storedMatchTV(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: matchTVKey) as? Bool ?? true
    }

    /// The saved TV Resolution; missing or unreadable reads as Quarter.
    static func storedTVMatchScale(in defaults: UserDefaults) -> TVMatchScale {
        defaults.string(forKey: tvMatchScaleKey).flatMap(TVMatchScale.init(rawValue:)) ?? .quarter
    }

    static func storedWindowsHelperPins(in defaults: UserDefaults) -> [String: Data] {
        (defaults.dictionary(forKey: windowsHelperPinsKey) ?? [:]).compactMapValues { $0 as? Data }
    }

    // MARK: TV Presets (one remembered preset per TV, iPad)

    /// Settings ▸ Video ▸ TV Presets (off by default). With it on, plugging
    /// into a TV swaps the presets row for that TV's one preset — made the
    /// first time from what the TV can do (`TVPreset.starting`), changed in
    /// place by Settings while it's plugged in — and unplugging brings the
    /// usual presets and settings back. A different TV gets its own. Mid-game,
    /// with Match TV on, the stream restarts at the TV preset's size, frame
    /// rate and bitrate and the PC follows (`tvConnectionChanged`). It takes
    /// over from Windows Helper ▸ TV Resolution, which is greyed while it's on.
    var tvPresetsEnabled: Bool = false {
        didSet {
            guard oldValue != tvPresetsEnabled else { return }
            UserDefaults.standard.set(tvPresetsEnabled, forKey: Self.tvPresetsEnabledKey)
            #if os(iOS)
            refreshTVPreset()
            #endif
        }
    }
    static let tvPresetsEnabledKey = "vibelight.tvPresets"
    static let tvPresetsKey = "vibelight.tvPresets.v1"

    /// Every TV's preset, by `TVIdentity.key`.
    @ObservationIgnored private var tvPresets: [TVPreset] = []
    /// The TV whose preset is live now (nil: the usual presets).
    private(set) var liveTV: TVIdentity?
    /// What comes back when that TV is unplugged (or TV Presets turned off).
    @ObservationIgnored private var beforeTV: (settings: StreamSettings, presets: [StreamPreset], activeID: String?)?

    /// The presets row's id for a TV's preset.
    nonisolated static func tvPresetID(_ key: String) -> String { "tv:\(key)" }

    static func storedTVPresets(in defaults: UserDefaults) -> [TVPreset] {
        guard let data = defaults.data(forKey: tvPresetsKey),
              let list = try? JSONDecoder().decode([FailableDecodable<TVPreset>].self, from: data) else { return [] }
        return list.compactMap(\.value)
    }

    /// The live TV preset, as the row shows it (renamed, edited), into the TV store.
    private func saveLiveTVPreset() {
        guard let tv = liveTV else { return }
        let row = presets.first { $0.id == Self.tvPresetID(tv.key) }
        let saved = TVPreset(key: tv.key, name: row?.name ?? tv.name, settings: settings)
        if let i = tvPresets.firstIndex(where: { $0.key == tv.key }) { tvPresets[i] = saved } else { tvPresets.append(saved) }
        if let i = presets.firstIndex(where: { $0.id == Self.tvPresetID(tv.key) }) { presets[i].settings = settings }
        if let data = try? JSONEncoder().encode(tvPresets) {
            UserDefaults.standard.set(data, forKey: Self.tvPresetsKey)
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

    // MARK: Presets — a short named list ("Live Loadout")

    /// "Live Loadout", the owner's pick of five preset reworks (Fable design
    /// lead, Oct 2026): six numbered slots became a short list of named
    /// presets, and the loaded one stays marked when you change a setting —
    /// it shows "edited" and what changed, A keeps the change, Revert drops
    /// it — instead of silently going dark.
    static let maxPresets = 6
    private(set) var presets: [StreamPreset] = []
    /// Saved entries this build can't read, kept as their original bytes and
    /// written back on every save. (audit DAT-preset-recovery-loss)
    @ObservationIgnored private var unreadablePresets: [Data] = []
    /// The preset the live settings came from. It is NOT cleared when a
    /// setting changes — that's the "edited" state (`isActivePresetEdited`).
    private(set) var activePresetID: String?
    private static let presetsKey = "vibelight.presets.v3"
    private static let slotPresetsKey = "vibelight.presets.v2"     // the six-slot store, read once
    private static let activePresetKey = "vibelight.activePresetID"
    private static let activeSlotKey = "vibelight.activePresetSlot" // its marker, read once

    var activePreset: StreamPreset? { presets.first { $0.id == activePresetID } }
    /// The loaded preset and the live settings no longer agree.
    var isActivePresetEdited: Bool { activePreset.map { $0.settings != settings } ?? false }
    /// What changed since the loaded preset, in the chip's words.
    var activePresetChanges: [String] {
        activePreset.map { StreamPreset.changes(from: $0.settings, to: settings) } ?? []
    }
    /// A TV's own preset stands alone while it's plugged in: nothing to save beside it.
    var canSaveNewPreset: Bool { liveTV == nil && presets.count < Self.maxPresets }
    /// The row's "+" chip: nothing is loaded (the settings match no preset),
    /// so offer to save them. An edited preset offers Save as New instead.
    var offersSaveCurrentPreset: Bool { activePresetID == nil && canSaveNewPreset }

    /// A confirmation under the header ("Using Tailscale", "Deleted Handheld ·
    /// Undo"). Deleting and updating can be undone while it shows.
    struct PresetToast: Equatable {
        var verb: String
        var name: String
        var detail: String?
        var canUndo: Bool
        var serial: Int
    }
    private(set) var presetToast: PresetToast?
    @ObservationIgnored private var presetUndo: (@MainActor () -> Void)?
    @ObservationIgnored private var presetToastTask: Task<Void, Never>?
    @ObservationIgnored private var presetToastSerial = 0

    /// The name card's text (a picked suggestion, or typed) and its offers.
    var presetNameDraft = ""
    private(set) var presetNameSuggestions: [String] = []
    /// Where focus goes back to when a preset card closes.
    @ObservationIgnored private var presetCardReturnID: String?

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
        windowsHelperClient = WindowsHelperClient(identityProvider: identityProvider)
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
        ThemeFonts.register()   // the themes' bundled faces, before anything draws
        appTheme = AppTheme.migrated(in: .standard)
        ThemeStore.shared.theme = appTheme   // didSet doesn't fire during init
        if let raw = UserDefaults.standard.string(forKey: Self.interfaceSizeKey),
           let size = InterfaceSize(rawValue: raw) {
            interfaceSize = size
        }
        menuSounds = Self.storedMenuSounds(in: .standard)
        sfx.isEnabled = menuSounds   // didSet doesn't fire during init
        adaptiveBitrate = Self.storedAdaptiveBitrate(in: .standard)
        #if os(iOS)
        session.adaptiveBitrate = adaptiveBitrate
        #endif
        matchTV = Self.storedMatchTV(in: .standard)
        tvMatchScale = Self.storedTVMatchScale(in: .standard)
        tvPresetsEnabled = UserDefaults.standard.bool(forKey: Self.tvPresetsEnabledKey)
        tvPresets = Self.storedTVPresets(in: .standard)
        windowsHelperPins = Self.storedWindowsHelperPins(in: .standard)
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
        // (No "No computers yet" banner: with no computer the shelf itself
        // says so and offers Add Computer — UX-empty-home-no-invitation.)
        if let warning = Self.savedHostsWarning(blobUnreadable: savedHosts.blobUnreadable,
                                                unreadableCount: savedHosts.unreadable.count,
                                                readableCount: hosts.count) {
            hostError = warning
        }

        let savedPresets = Self.loadPresets()
        presets = savedPresets.list
        unreadablePresets = savedPresets.unreadable
        // Only an id that's really in the list; else whichever preset the
        // live settings already match (none: the row offers "+ Save current").
        let savedActive = UserDefaults.standard.string(forKey: Self.activePresetKey) ?? savedPresets.migratedActiveID
        activePresetID = presets.contains { $0.id == savedActive } ? savedActive
            : presets.first { $0.settings == settings }?.id
        if savedPresets.migrated { persistPresets() }

        #if DEBUG
        // Simulator instruments (see DebugInstruments). In-memory only: the
        // selection's didSet skips persisting the synthetic host, and the
        // refresh loop and wakeHost skip it on the network.
        if let fake = Self.debugFakeHost() {
            hosts = [fake.host]
            selectedHostID = fake.host.id
            apps = []
            hostError = nil
            hostNotResponding = fake.notResponding
            serverInfo = fake.info
            selectedHostChecked = true   // never refreshed, so mark it answered
        }
        switch DebugInstruments.fakeHostError {
        case .long: hostError = Self.someSavedHostsUnreadableMessage
        case .restarting: hostNotice = "Restarting \(selectedHost?.name ?? "Gaming PC")…"
        case nil: break
        }
        #endif

        migrateTouchDefaultsOnce()
        wireCallbacks()
        rebuildFocus()
        focus.focusFirst()
        startRefreshLoop()
        runStartupChecks()
    }

    private static let touchDefaultsMigratedKey = "vibelight.migrated.touchDefaultsOn"

    /// Touch Control and Touch With Controller became default-on (owner, Oct
    /// 2026). Once, turn them on in what was saved before — every preset FIRST,
    /// then the live settings, so the loaded preset never reads "edited" over
    /// it, and an old preset left at Off can't switch touch back off the next
    /// time it's applied.
    private func migrateTouchDefaultsOnce() {
        guard !UserDefaults.standard.bool(forKey: Self.touchDefaultsMigratedKey) else { return }
        for i in presets.indices {
            presets[i].settings.touchControls = true
            presets[i].settings.touchWithController = true
        }
        persistPresets()
        // One assignment, not two: between two separate ones the live settings
        // would briefly differ from the (already updated) preset and lose its
        // marker. didSet persists.
        var updated = settings
        updated.touchControls = true
        updated.touchWithController = true
        settings = updated
        UserDefaults.standard.set(true, forKey: Self.touchDefaultsMigratedKey)
    }

    // MARK: - Presets

    private static func loadPresets() -> (list: [StreamPreset], unreadable: [Data],
                                          migratedActiveID: String?, migrated: Bool) {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: presetsKey) {
            // An entry this build can't read is kept as its bytes and written
            // back with every save. (audit DAT-preset-recovery-loss)
            guard let decoded = SavedDataRecovery.decodeList(StreamPreset.self, from: data) else {
                // Not even a list: the next save writes over it, so keep the
                // original aside first.
                SavedDataRecovery.backUpOnce(data, to: "\(presetsKey).unreadable", in: .standard)
                return ([], [], nil, false)
            }
            return (decoded.records, decoded.unreadable, nil, false)
        }
        // First run of the list: adopt the six-slot store in slot order, ids
        // kept (so the loaded marker carries over), empty slots dropped, an
        // unreadable slot still kept as its bytes. The old keys stay put.
        if let data = defaults.data(forKey: slotPresetsKey),
           let decoded = SavedDataRecovery.decodeSlots(StreamPreset.self, from: data, count: 6) {
            let slot = defaults.object(forKey: activeSlotKey) as? Int
            let activeID = slot.flatMap { decoded.slots.indices.contains($0) ? decoded.slots[$0]?.id : nil }
            return (decoded.slots.compactMap { $0 }, decoded.raw.compactMap { $0 }, activeID, true)
        }
        if let data = defaults.data(forKey: slotPresetsKey) {
            SavedDataRecovery.backUpOnce(data, to: "\(slotPresetsKey).unreadable", in: .standard)
        }
        // Older still: the pre-0.1.7 list.
        if let legacy = migrateLegacyPresets() { return (legacy, [], nil, true) }
        return ([], [], nil, false)
    }

    /// The pre-0.1.7 `vibelight.presets` list, if one is still lying around.
    private static func migrateLegacyPresets() -> [StreamPreset]? {
        guard let data = UserDefaults.standard.data(forKey: "vibelight.presets"),
              let arr = try? JSONDecoder().decode([FailableDecodable<StreamPreset>].self, from: data)
        else { return nil }
        let recovered = Array(arr.compactMap(\.value).prefix(maxPresets))
        return recovered.isEmpty ? nil : recovered
    }

    private func persistPresets() {
        // TV Presets: the row holds the TV's preset (renamed, say) — it goes
        // to the TV store, never over the presets waiting for the unplug.
        if liveTV != nil {
            saveLiveTVPreset()
            return
        }
        if let data = SavedDataRecovery.encodeList(presets, preserving: unreadablePresets) {
            UserDefaults.standard.set(data, forKey: Self.presetsKey)
        }
        UserDefaults.standard.set(activePresetID, forKey: Self.activePresetKey)
    }

    /// Load a preset (A on its chip).
    func applyPreset(_ id: String) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        // Decoding already clamps; this keeps a preset that reached memory any
        // other way from carrying an out-of-range number into the live
        // settings. (audit DAT-stored-size-overflow)
        settings = preset.settings.clampedToLegalRanges()
        activePresetID = id
        persistPresets()
        presetsChanged()
        showPresetToast(verb: "Using", name: preset.name, detail: preset.summary)
    }

    /// Keep the change: write the live settings into the loaded preset (A on
    /// an edited chip, Y in Settings). Its id and name stay; Undo puts the
    /// old numbers back.
    func updateActivePreset() {
        guard let i = presets.firstIndex(where: { $0.id == activePresetID }) else { return }
        let id = presets[i].id, before = presets[i].settings
        presets[i].settings = settings
        persistPresets()
        presetsChanged()
        controller.focusTick()
        showPresetToast(verb: "Updated", name: presets[i].name, undo: { [weak self] in
            guard let self, let j = presets.firstIndex(where: { $0.id == id }) else { return }
            presets[j].settings = before
            persistPresets()
            presetsChanged()
        })
    }

    /// Drop the change: back to the loaded preset's settings.
    func revertActivePreset() {
        guard let preset = activePreset else { return }
        settings = preset.settings.clampedToLegalRanges()
        presetsChanged()
        showPresetToast(verb: "Reverted", name: preset.name, detail: preset.summary)
    }

    /// The live settings as a new preset, which becomes the loaded one.
    @discardableResult
    func saveCurrentAsNewPreset(named name: String, announce: Bool = true) -> String? {
        guard canSaveNewPreset else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let preset = StreamPreset(id: UUID().uuidString,
                                  name: trimmed.isEmpty ? suggestedPresetNames().first ?? "My Preset" : trimmed,
                                  settings: settings)
        presets.append(preset)
        activePresetID = preset.id
        persistPresets()
        presetsChanged()
        controller.focusTick()
        if announce { showPresetToast(verb: "Saved", name: preset.name) }
        return preset.id
    }

    func renamePreset(_ id: String, to name: String) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        presets[i].name = trimmed
        persistPresets()
    }

    /// Gone at once — no confirm card; the toast holds Undo for 8 s. Returns
    /// the focus id of its neighbour, so focus doesn't fall off the row.
    @discardableResult
    func deletePreset(_ id: String) -> String? {
        guard liveTV == nil, let i = presets.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = presets.remove(at: i)
        let wasActive = activePresetID == id
        if wasActive { activePresetID = nil }
        persistPresets()
        presetsChanged()
        showPresetToast(verb: "Deleted", name: removed.name, undo: { [weak self] in
            guard let self, canSaveNewPreset else { return }
            presets.insert(removed, at: min(i, presets.count))
            if wasActive { activePresetID = removed.id }
            persistPresets()
            presetsChanged()
            focus.focus(itemID: "preset:\(removed.id)")
        })
        let neighbour = presets.indices.contains(i) ? presets[i] : presets.last
        return neighbour.map { "preset:\($0.id)" } ?? (offersSaveCurrentPreset ? "preset:add" : nil)
    }

    /// Y while a toast offers Undo.
    var canUndoPresetChange: Bool { presetUndo != nil }

    func undoPresetChange() {
        guard let undo = presetUndo else { return }
        presetUndo = nil
        presetToast = nil
        undo()
    }

    private func showPresetToast(verb: String, name: String, detail: String? = nil,
                                 undo: (@MainActor () -> Void)? = nil) {
        presetToastSerial += 1
        let serial = presetToastSerial
        presetUndo = undo
        presetToast = PresetToast(verb: verb, name: name, detail: detail, canUndo: undo != nil, serial: serial)
        let shown: Duration = undo != nil ? .seconds(8) : .milliseconds(2500)
        presetToastTask?.cancel()
        presetToastTask = Task { [weak self] in
            try? await Task.sleep(for: shown)
            guard let self, !Task.isCancelled, presetToast?.serial == serial else { return }
            presetToast = nil
            presetUndo = nil
        }
    }

    /// The preset row's chips are focus targets, and which exist ("+") moves
    /// with the settings — rebuild on the home screen after every change.
    private func presetsChanged() {
        guard screen == .home, overlay == nil else { return }
        rebuildFocus()
        if focus.focusedItemID == nil { focus.focusFirst() }
    }

    /// "preset:<id>" → the id (nil for "preset:add" and anything else).
    func presetID(fromFocusID id: String?) -> String? {
        guard let id, id.hasPrefix("preset:"), id != "preset:add" else { return nil }
        return String(id.dropFirst("preset:".count))
    }

    /// The focus id of every chip in the row, "+" last when it shows.
    var presetRowFocusIDs: [String] {
        presets.map { "preset:\($0.id)" } + (offersSaveCurrentPreset ? ["preset:add"] : [])
    }

    /// Names for the live settings (or, renaming, that preset's) — never "Preset 1".
    func suggestedPresetNames(renaming id: String? = nil) -> [String] {
        let target = id.flatMap { id in presets.first { $0.id == id } }
        return StreamPreset.nameSuggestions(
            for: target?.settings ?? settings, hostName: selectedHost?.name, current: target?.name,
            taken: presets.filter { $0.id != id }.map(\.name))
    }

    /// The options card's buttons, top to bottom (the card draws this list).
    func presetMenuItems(for id: String) -> [String] {
        var ids: [String] = []
        if id == activePresetID && isActivePresetEdited { ids.append("presetmenu:revert") }
        ids += ["presetmenu:edit", "presetmenu:rename"]
        if canSaveNewPreset { ids.append("presetmenu:saveas") }
        if liveTV == nil { ids.append("presetmenu:delete") }   // a TV keeps its one preset
        return ids
    }

    /// The options card for one preset (X on its chip).
    func openPresetMenu(_ id: String) {
        guard presets.contains(where: { $0.id == id }) else { return }
        presetCardReturnID = focus.focusedItemID
        presentOverlay(.presetMenu(id))
    }

    /// The name card: suggestions first, typing optional.
    func openPresetNameCard(_ target: PresetNameTarget) {
        if case .new = target, !canSaveNewPreset { return }
        if case .presetMenu = overlay {} else { presetCardReturnID = focus.focusedItemID }
        if case .rename(let id) = target {
            presetNameSuggestions = suggestedPresetNames(renaming: id)
        } else {
            presetNameSuggestions = suggestedPresetNames()
        }
        presetNameDraft = presetNameSuggestions.first ?? ""
        presentOverlay(.namePreset(target))
    }

    /// Save the name card's draft (new preset, or a rename) and close it.
    func commitPresetName(_ target: PresetNameTarget) {
        switch target {
        case .new:
            let id = saveCurrentAsNewPreset(named: presetNameDraft)
            closePresetCard(returningTo: screen == .home ? id.map { "preset:\($0)" } : nil)
        case .rename(let id):
            renamePreset(id, to: presetNameDraft)
            closePresetCard(returningTo: screen == .home ? "preset:\(id)" : nil)
        }
    }

    private func closePresetCard(returningTo id: String? = nil) {
        let back = id ?? presetCardReturnID
        presetCardReturnID = nil
        dismissOverlay(returningTo: back)
    }

    /// True when the focused settings row OPENS something (rather than cycling a
    /// value), so a pointer tap can route the same semantic event Select does.
    func settingsRowOpens(_ row: SettingsRow) -> Bool {
        row.isAction || row == .resolution
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
        controller.quitGameChordEnabled = { [weak self] in self?.canQuitRemoteGame ?? false }
        controller.selectHoldEnabled = { [weak self] in self?.focusedHoldButton ?? false }
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
            switch phase {
            case .streaming(let app): liveStream = (app: app, since: Date())
            case .idle: liveStream = nil
            default: break
            }
            if case .failed(let message) = phase {
                chrome?.endStreamPresentationIfActive()
                // Dropped mid-stream: the game is still on the PC, so land on
                // the still-running card and say why, instead of an error
                // card that hides Resume. A failed launch stays an error.
                if let live = liveStream {
                    presentSessionEnded(live.app, dropReason: message)
                } else {
                    presentOverlay(.error(message))
                }
            }
            // A launch-time update offer that arrived mid-stream waits for the
            // stream to be over. The phase turns idle a moment before the
            // ended/error card is dismissed, so look again on the next turn,
            // once the card has gone. (audit QUA-launch-update-card-no-stream-gate)
            if phase == .idle, launchUpdateCardWaiting {
                Task { [weak self] in self?.presentLaunchUpdateCardIfDue() }
            }
        }
        #if os(iOS)
        // A Match TV restart is up at its new size: the PC follows.
        session.onResized = { [weak self] in self?.syncPCToStream() }
        #endif
        session.onStreamDidStart = { [weak self] helperPID in
            guard let self else { return }
            chrome?.beginStreamPresentation(helperPID: helperPID)
            watchHelperGame()   // which game Quit Stream and Game would close
            #if os(iOS)
            syncPCToStream()   // Match TV: the PC takes the stream's size
            // The starting card's exit (the poster growing into the picture)
            // plays under the stream's 0.45 s fade-in, so keep it until that
            // fade is done. (macOS: the helper's window covers us at once.)
            if overlay == .sessionHUD {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard let self, overlay == .sessionHUD else { return }
                    overlay = nil
                    rebuildFocus()
                }
                return
            }
            #endif
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
            #if os(iOS)
            restorePC()   // Match TV: the PC goes back to normal
            #endif
            if case .ending(let app) = session.phase {
                if session.remoteQuitRequested {
                    // The user explicitly quit the game — no "still running"
                    // decision card, straight back to the library.
                    liveStream = nil
                    session.acknowledgeEnd()
                    dismissOverlay()
                } else {
                    presentSessionEnded(app)
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
        // Keep-awake covers the launcher too, so arm it from the start rather
        // than waiting for a scene-phase change that may not fire on launch.
        refreshKeepAwake()
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

    /// Builds the host list from the user-added hosts, de-duped by address/uuid
    /// and capped at `maxHosts`. (`importedHosts` stays empty: the Moonlight
    /// import was retired in v0.2.0.)
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
        pairingLeftApp = false
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
            case .unreachable: pairing?.status = Self.unreachablePairingStatus(leftAppWhileWaiting: pairingLeftApp)
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
    /// Off also ends any background-time assertion pairing took on its way out
    /// of the foreground (every path that ends a pairing comes through here).
    private func setPairingKeepAwake(_ on: Bool) {
        pairingWantsKeepAwake = on
        refreshKeepAwake()
        #if os(iOS)
        if !on { endBGPairTask() }
        #endif
    }

    @ObservationIgnored private var pairingWantsKeepAwake = false

    /// The app went to the background while phase 1 was still waiting for the
    /// PIN. iOS suspends a backgrounded app within seconds and tears down its
    /// sockets, so the PC's answer then lands on a dead connection — which
    /// HostPairing can only report as "unreachable". The classic way in is
    /// switching to Safari on the iPad to type the PIN into the host's web UI.
    @ObservationIgnored private var pairingLeftApp = false

    nonisolated static let pairingInterruptedMessage =
        "Pairing stopped because VibeLight left the screen — iPadOS pauses it while another app is open. "
        + "Keep VibeLight open here and type the PIN on the PC itself, or on another device "
        + "(phone or laptop), then choose Try Again."

    /// The PIN panel's how-to. On iPad it steers away from typing the PIN in
    /// Safari on the same device — the one way pairing reliably dies there.
    nonisolated static func pairingInstructions(webUIURL: String,
                                                on platform: RootView.Platform = .current) -> String {
        switch platform {
        case .macOS:
            "Open your host's web UI at \(webUIURL) and type the PIN."
        case .iOS:
            "On the PC or another device (not this one), open \(webUIURL) and type the PIN. "
            + "Keep VibeLight open here until it finishes."
        }
    }

    nonisolated static let pairingFailedOnHostHint =
        "If the PC says “Pairing Failed”, another device may be pairing at the same time. "
        + "Restart the host app (or wait 10 minutes), then cancel here and pair again."

    /// What an unreachable pairing result means. After leaving the app it is
    /// almost always the suspension above, not the network, and "Couldn't
    /// reach the computer" sent people chasing a network problem they didn't have.
    nonisolated static func unreachablePairingStatus(leftAppWhileWaiting: Bool) -> PairingState.Status {
        leftAppWhileWaiting ? .failed(pairingInterruptedMessage) : .unreachable
    }

    /// iOS idle-timer ownership, in one place. Controller input never resets
    /// the idle timer, so a big-picture app driven by a pad sleeps mid-game AND
    /// mid-browse; "Keep Display Awake" (default on) therefore covers the whole
    /// app in the foreground, not just a stream. Pairing always holds it (the
    /// PIN is on screen, hands are on the other computer).
    ///
    /// Called on every session phase change, on returning to the foreground
    /// (VibeLightApp), and by the heartbeat below.
    func refreshKeepAwake() {
        #if os(iOS)
        let wanted = pairingWantsKeepAwake || settings.keepAwake
        // Re-arm, don't just assign. iOS can drop the flag on its own (an app
        // that went to the background and back, a scene connecting for the
        // TV) while the property still reads true — and assigning the value it
        // already "has" changes nothing, so the iPad slept mid-stream with
        // keep-awake on. Flipping it off then on re-applies it for real.
        if wanted { UIApplication.shared.isIdleTimerDisabled = false }
        UIApplication.shared.isIdleTimerDisabled = wanted
        setKeepAwakeHeartbeat(wanted)
        #endif
    }

    #if os(iOS)
    /// Re-asserts keep-awake every 20 s while it is wanted — under iPadOS's
    /// shortest auto-lock (30 s), so a silent reset can never outlast it.
    @ObservationIgnored private var keepAwakeHeartbeat: Task<Void, Never>?

    private func setKeepAwakeHeartbeat(_ on: Bool) {
        guard on else { keepAwakeHeartbeat?.cancel(); keepAwakeHeartbeat = nil; return }
        guard keepAwakeHeartbeat == nil else { return }
        keepAwakeHeartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self else { return }
                guard pairingWantsKeepAwake || settings.keepAwake else { continue }
                UIApplication.shared.isIdleTimerDisabled = false
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
    }
    #endif

    #if os(iOS)
    private var bgQuitTaskID: UIBackgroundTaskIdentifier = .invalid
    private var bgPairTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Pairing is waiting on the PIN and the app is leaving the foreground.
    /// Ask iOS for its short background window (~30 s): enough for a quick
    /// switch to the host's web UI and back, so the pending phase-1 request
    /// can still land. Longer than that, the request dies, and the flag makes
    /// the failure say why instead of "Couldn't reach the computer".
    private func holdPairingInBackground() {
        guard pairing?.status == .waiting else { return }
        pairingLeftApp = true
        guard bgPairTaskID == .invalid else { return }
        bgPairTaskID = UIApplication.shared.beginBackgroundTask(withName: "vibelight.pairing") { [weak self] in
            self?.endBGPairTask()
        }
    }

    /// Idempotent, like endBGQuitTask: safe from the expiration handler and
    /// from every path that ends a pairing.
    private func endBGPairTask() {
        if bgPairTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgPairTaskID)
            bgPairTaskID = .invalid
        }
    }

    /// Ends the quit-on-background assertion exactly once. Safe to call from both
    /// the completion path and the expiration handler (idempotent via `.invalid`).
    private func endBGQuitTask() {
        if bgQuitTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgQuitTaskID)
            bgQuitTaskID = .invalid
        }
    }

    /// Leaving the app mid-stream. Backgrounding suspends our sockets, so the
    /// stream ends at once — but the GAME stays on the PC (owner: swiping up
    /// by accident shouldn't cost it). VibeLight keeps running for the
    /// background time iOS allows, and coming back inside it lands on the
    /// still-running card with Rejoin focused. Only if it isn't back in time
    /// does Quit Game on App Exit /cancel the game, before iOS's deadline.
    func handleAppDidEnterBackground() {
        holdPairingInBackground()
        // DELIBERATELY narrow: only a stream THIS device is running right now.
        // Backgrounding is app-switching, not quitting — a broader predicate
        // (hasActiveRemoteSession) would /cancel games this device merely
        // *sees* running: another client's live session, or a game the user
        // explicitly kept playing via disconnect-keep-playing (invariant 6).
        let liveApp: StreamApp?
        switch session.phase {
        case .streaming(let app), .launching(let app): liveApp = app
        default: liveApp = nil
        }
        // Left again from the card an earlier exit put up, still undecided:
        // the same window applies, or the game would run on forever.
        var leftApp = liveApp
        if leftApp == nil, endedSession?.fromAppExit == true, endedCardOffersQuit,
           case .sessionEnded(let shown) = overlay {
            leftApp = shown
        }
        guard let app = leftApp else { return }
        // Written down in case iOS kills the app inside the window (swiped
        // away in the app switcher): the next launch offers the same card.
        if let host = selectedHost { recordPendingAppExit(hostID: host.id, appID: app.id) }
        if liveApp != nil {
            session.disconnect()   // the still-running card comes up underneath
            markEndedFromAppExit(focusRejoin: true)
        }
        // One episode at a time: if a prior assertion is still in flight
        // (rapid foreground→background toggle), its wait covers this one
        // rather than a second crossing it. (review: bgQuitTaskID race)
        guard bgQuitTaskID == .invalid else { return }
        // An expiration handler is mandatory: if the task outlives iOS's grace
        // window with no handler, the app is force-terminated. Here we just end
        // the assertion cleanly — the /cancel is best-effort, staying alive isn't.
        bgQuitTaskID = UIApplication.shared.beginBackgroundTask(withName: "vibelight.quit-on-background") { [weak self] in
            self?.endBGQuitTask()
        }
        guard settings.stopStreamOnExit else {
            endBGQuitTask()
            return
        }
        let grace = Self.appExitGrace(backgroundTimeRemaining: UIApplication.shared.backgroundTimeRemaining)
        appExitQuitTask = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard let self, !Task.isCancelled else { return }
            // 2.5 s budget: the /cancel is best-effort, staying alive is not —
            // iOS SIGKILLs (0x8BADF00D) an app that overruns its deadline.
            await stopStreamForAppExit(budget: .milliseconds(2500))
            clearPendingAppExit()
            appExitQuitTask = nil
            endBGQuitTask()
        }
    }

    /// The game's wait for a return from the background (nil when none).
    @ObservationIgnored private var appExitQuitTask: Task<Void, Never>?

    /// How long the game waits for VibeLight to come back: iOS's remaining
    /// background time, less room for the /cancel (2.5 s budget) to land
    /// before the deadline, and never more than 25 s.
    nonisolated static func appExitGrace(backgroundTimeRemaining remaining: TimeInterval) -> Duration {
        let usable = remaining.isFinite ? remaining - 5 : 25
        return .milliseconds(Int(max(0, min(usable, 25)) * 1000))
    }

    /// Back in the foreground. Inside the window, the game stays and the card
    /// waits on Rejoin.
    func handleAppDidBecomeActive() {
        guard let pending = appExitQuitTask else { return }
        pending.cancel()
        appExitQuitTask = nil
        clearPendingAppExit()
        endBGQuitTask()
    }

    /// The card that leaving the app put up opens on Rejoin, not Quit, and
    /// says why it's there.
    private func markEndedFromAppExit(focusRejoin: Bool) {
        guard case .sessionEnded = overlay, endedSession != nil else { return }
        endedSession?.fromAppExit = true
        if focusRejoin { focus.focus(itemID: "ended:resume") }
    }

    /// A stream left by leaving the app, written when it happens and cleared
    /// when VibeLight comes back or the game is closed. It outlives the window
    /// only if iOS killed the app inside it.
    struct PendingAppExit: Codable, Equatable, Sendable {
        var hostID: String
        var appID: Int
        var at: Date
    }
    static let pendingAppExitKey = "vibelight.pendingAppExit"
    /// Older than this, a leftover note says nothing useful about the PC.
    static let pendingAppExitLifetime: TimeInterval = 12 * 60 * 60

    private func recordPendingAppExit(hostID: String, appID: Int) {
        let pending = PendingAppExit(hostID: hostID, appID: appID, at: Date())
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: Self.pendingAppExitKey)
        }
    }

    private func clearPendingAppExit() {
        UserDefaults.standard.removeObject(forKey: Self.pendingAppExitKey)
    }

    /// Inside the window a relaunch offers Rejoin first; after it, the card
    /// opens on Quit — the quit-on-exit that never got to run.
    nonisolated static func appExitWindowOpen(age: TimeInterval) -> Bool { age <= 30 }

    /// After a relaunch, once this PC has answered: if VibeLight was killed
    /// mid-stream and the PC still runs that game, the still-running card
    /// comes back.
    private func presentPendingAppExitIfAny() {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingAppExitKey) else { return }
        guard let pending = try? JSONDecoder().decode(PendingAppExit.self, from: data) else {
            clearPendingAppExit()
            return
        }
        guard selectedHost?.id == pending.hostID else { return }   // that PC isn't the one showing
        clearPendingAppExit()
        let age = Date().timeIntervalSince(pending.at)
        guard age < Self.pendingAppExitLifetime, serverInfo?.runningAppID == pending.appID,
              let app = apps.first(where: { $0.id == pending.appID }),
              onboardingStep == nil, overlay == nil, session.phase == .idle else { return }
        presentSessionEnded(app)
        markEndedFromAppExit(focusRejoin: Self.appExitWindowOpen(age: age))
    }
    #endif

    // MARK: - Windows Helper (Match TV, Quit Game)

    /// Asks the selected PC whether VibeLight Helper is there and lets this
    /// device in. `force`: now (opening the Windows Helper tab, its status
    /// row); otherwise at most once a minute, from the host refresh.
    func checkWindowsHelper(force: Bool = false) {
        guard let host = selectedHost, let address = hostAddress else {
            windowsHelperCheck?.cancel()
            windowsHelperCheck = nil
            windowsHelperHostID = nil
            windowsHelper = .unknown
            return
        }
        let sameHost = windowsHelperHostID == host.id
        if !force, sameHost {
            if windowsHelperCheck != nil { return }   // one already out
            if let at = windowsHelperCheckedAt, Date().timeIntervalSince(at) < Self.windowsHelperRecheck { return }
        }
        if !sameHost {
            windowsHelperHostID = host.id
            windowsHelperCheckedAt = nil
            windowsHelper = .unknown
        }
        // A helper already found stays usable while it's asked again.
        if !windowsHelperReady { windowsHelper = .checking }
        let pinned = windowsHelperPins[host.id]
        let client = windowsHelperClient
        windowsHelperCheck?.cancel()
        windowsHelperCheck = Task { [weak self] in
            let probe = await client.probe(at: address, pinned: pinned)
            guard let self, !Task.isCancelled, windowsHelperHostID == host.id else { return }
            windowsHelperCheck = nil
            windowsHelperCheckedAt = Date()
            switch probe {
            case .ready(let pcName, let certificate):
                if pinned == nil { setWindowsHelperPin(certificate, for: host.id) }
                windowsHelper = .ready(pcName: pcName)
            case .notAllowed(let pcName):
                windowsHelper = .notAllowed(pcName: pcName)
            case .notRunning:
                windowsHelper = .notFound
            case .certChanged:
                windowsHelper = .certChanged
            }
        }
    }

    /// The status row: ask again — and after a reinstall on the PC (a new
    /// certificate), trust the new one.
    func windowsHelperStatusSelected() {
        if windowsHelper == .certChanged, let id = selectedHost?.id {
            setWindowsHelperPin(nil, for: id)
        }
        checkWindowsHelper(force: true)
    }

    private func setWindowsHelperPin(_ certificate: Data?, for hostID: String) {
        windowsHelperPins[hostID] = certificate
        UserDefaults.standard.set(windowsHelperPins, forKey: Self.windowsHelperPinsKey)
    }

    /// Where to reach the selected PC's helper, when it's ready.
    private var windowsHelperTarget: (address: String, pinned: Data)? {
        guard windowsHelperReady, let host = selectedHost, windowsHelperHostID == host.id,
              let address = hostAddress, let pinned = windowsHelperPins[host.id] else { return nil }
        return (address, pinned)
    }

    /// The game VibeLight Helper sees in front on the PC: only a window with
    /// evidence of being a game (a store's game folder, started by a launcher
    /// or the host, on Windows' game list, exclusive fullscreen) — see the
    /// helper's README. nil with no helper, or nothing that counts.
    private(set) var helperGame: WindowsHelperClient.Game? {
        didSet {
            // Quit Stream and Game takes focus only with a game to quit.
            guard (oldValue == nil) != (helperGame == nil) else { return }
            if case .sessionEnded = overlay { rebuildFocus() }
        }
    }
    @ObservationIgnored private var helperGameWatch: Task<Void, Never>?

    /// Quit Stream and Game can go: the helper is ready and names a game
    /// (owner: greyed out when no game is running).
    var canQuitGame: Bool { windowsHelperReady && helperGame != nil }

    /// Asks the helper which game is in front every 5 s while there's one to
    /// quit — during a stream and while the still-running card is up — so the
    /// Quit buttons show (and close) the game it actually is. A failed ask
    /// keeps the last answer; the watch ends itself once neither is true.
    func watchHelperGame() {
        helperGameWatch?.cancel()
        let client = windowsHelperClient
        helperGameWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard wantsHelperGame, let target = windowsHelperTarget else {
                    helperGame = nil
                    return
                }
                if let status = try? await client.status(at: target.address, pinned: target.pinned),
                   !Task.isCancelled {
                    helperGame = status.game
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var wantsHelperGame: Bool {
        if case .sessionEnded = overlay { return true }
        return isLocalStreamActive
    }

    /// In-stream Quit Game (owner, in the controls over the game and on the
    /// TV companion panel): a tap arms it for 3 s — it turns red and names the
    /// game — and a second tap quits the game and the stream.
    private(set) var quitGameArmed = false
    @ObservationIgnored private var quitGameArmTask: Task<Void, Never>?

    func tapQuitGameInStream() {
        guard canQuitGame else { return }
        quitGameArmTask?.cancel()
        if quitGameArmed {
            quitGameArmed = false
            quitStreamAndGame()
            return
        }
        quitGameArmed = true
        quitGameArmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.quitGameArmed = false
        }
    }

    /// "Quit Stream and Game" (owner: "quit stream completely and quit game,
    /// which basically force quits any active game") — on the still-running
    /// card and in the stream. The helper closes the game it named (its pid:
    /// if another game is in front by now, nothing is closed) — WM_CLOSE, then
    /// by force after `quitGameGrace` — while the stream ends as Quit Stream
    /// Completely does. Only the helper can reach a game the host didn't
    /// start itself (one launched from Steam or Playnite, say).
    func quitStreamAndGame() {
        guard canQuitGame, let target = windowsHelperTarget else { return }
        if case .sessionEnded = overlay, endedSession?.quitting == true { return }
        endedSession?.closingGame = true
        let client = windowsHelperClient
        let pid = helperGame?.pid
        Task { [weak self] in
            let problem: String?
            do {
                let result = try await client.quitGame(graceSeconds: Self.quitGameGrace, pid: pid,
                                                       at: target.address, pinned: target.pinned)
                // No game in front isn't a failure: the stream still ends.
                problem = result.ok || result.title == nil ? nil : result.message
            } catch {
                problem = error.localizedDescription
            }
            guard let problem else { return }
            // Once the card has faded out (quitRemoteGameCompletely below).
            try? await Task.sleep(for: .seconds(Self.endedQuitFade))
            guard let self, overlay == nil else { return }
            presentOverlay(.error("The stream has ended, but the game may still be open on the PC. \(problem)"))
        }
        quitRemoteGameCompletely()
    }

    /// Seconds a game gets to close itself before the helper ends it.
    nonisolated static let quitGameGrace = 5

    /// Quit Stream and Game's focus id on the still-running card.
    nonisolated static let quitGameButtonID = "ended:quitGame"

    #if os(iOS)
    /// The TV's pixels, when one is attached.
    var attachedTVSize: (width: Int, height: Int)? {
        guard ExternalDisplay.shared.isConnected, let pixels = ExternalDisplay.shared.pixelSize else { return nil }
        return (Int(pixels.width), Int(pixels.height))
    }

    /// The stream size Match TV wants right now, or nil when the preset's own
    /// size applies (Match TV off, no helper, no TV). With a TV's own preset
    /// live (TV Presets), that preset already says: TV Resolution steps aside.
    var matchTVSize: (width: Int, height: Int)? {
        guard matchTV, windowsHelperReady, let tv = attachedTVSize else { return nil }
        if liveTV != nil { return (settings.width, settings.height) }
        return TVMatchScale.streamSize(tv: tv, scale: tvMatchScale)
    }

    /// TV Presets: the attached TV's preset in, or the usual presets back.
    /// Runs when a TV comes or goes, when the setting is switched, and once
    /// at launch. The first time a TV is seen its preset is made from what it
    /// can do; after that it's whatever it was left at.
    func refreshTVPreset() {
        let want = tvPresetsEnabled ? ExternalDisplay.shared.tvIdentity : nil
        guard want?.key != liveTV?.key else { return }
        // Leave the TV that was live: its preset is already saved.
        if liveTV != nil, let before = beforeTV {
            liveTV = nil
            beforeTV = nil
            presets = before.presets
            activePresetID = before.activeID
            settings = before.settings
        }
        if let tv = want {
            beforeTV = (settings, presets, activePresetID)
            let preset = tvPresets.first { $0.key == tv.key } ?? TVPreset.starting(for: tv, from: settings)
            liveTV = tv
            presets = [StreamPreset(id: Self.tvPresetID(tv.key), name: preset.name, settings: preset.settings)]
            activePresetID = presets[0].id
            settings = preset.settings.clampedToLegalRanges()   // and saved (a new TV's first time)
            showPresetToast(verb: "Using", name: preset.name, detail: presets[0].summary)
        }
        presetsChanged()
    }

    /// The settings a launch streams with: the preset's, at the TV's size
    /// when Match TV applies. Only the size: the frame rate and bitrate stay
    /// the preset's (owner: "don't change fps at all").
    var launchSettings: StreamSettings {
        var launch = settings
        if let size = matchTVSize {
            launch.width = size.width
            launch.height = size.height
        }
        return launch
    }

    /// The PC was matched for this stream, so it is put back afterwards.
    @ObservationIgnored private var pcMatched = false

    /// A TV plugged in or pulled out (ExternalDisplay). Mid-stream with Match
    /// TV: the stream restarts at the TV's size — or back at the preset's
    /// once it's unplugged — and the PC follows when the new stream is up
    /// (`syncPCToStream`, from the engine's `onResized`).
    func tvConnectionChanged() {
        refreshTVPreset()
        guard case .streaming = session.phase, let live = session.streamResolution else { return }
        if tvPresetsEnabled {
            // TV Presets: the whole preset follows the TV — size, frame rate
            // and bitrate — mid-game only with Match TV on (owner), so the PC
            // can follow too. `settings` is already the TV's (or back).
            guard matchTV, windowsHelperReady else { return }
            let reason = liveTV.map { "\($0.name) preset" } ?? "Back to your preset"
            if !session.resize(width: settings.width, height: settings.height, fps: settings.fps,
                               bitrateKbps: settings.bitrateKbps, reason: reason) {
                syncPCToStream()   // already those numbers: just the PC
            }
            return
        }
        let target: (width: Int, height: Int)
        let reason: String
        if let size = matchTVSize {
            target = size
            reason = "Matching the TV"
        } else if live.width != settings.width || live.height != settings.height {
            target = (settings.width, settings.height)
            reason = "Back to your preset"
        } else {
            return
        }
        if !session.resize(width: target.width, height: target.height, fps: nil, bitrateKbps: nil, reason: reason) {
            syncPCToStream()   // already that size: just the PC
        }
    }

    /// The PC follows the stream: matched when Match TV put the stream at the
    /// TV's size, put back when it didn't. When a stream starts and after
    /// every Match TV restart.
    func syncPCToStream() {
        guard let target = windowsHelperTarget else { return }
        let client = windowsHelperClient
        if let size = matchTVSize, let live = session.streamResolution,
           live.width == size.width, live.height == size.height {
            pcMatched = true
            // A TV's own preset sets the frame rate too: the PC's display
            // follows it where it can (else, as Match TV always did, it keeps
            // its own refresh rate).
            let refreshHz = liveTV != nil ? settings.fps : nil
            Task { [weak self] in
                guard let result = try? await client.match(width: size.width, height: size.height, refreshHz: refreshHz,
                                                           at: target.address, pinned: target.pinned) else { return }
                self?.session.announce(title: result.ok ? "PC matched" : "PC unchanged",
                                       detail: result.message, warn: !result.ok)
            }
        } else {
            restorePC()
        }
    }

    /// Puts the PC's display and game window back (stream over, TV gone).
    func restorePC() {
        guard pcMatched else { return }
        pcMatched = false
        guard let target = windowsHelperTarget else { return }
        let client = windowsHelperClient
        Task { _ = try? await client.restore(at: target.address, pinned: target.pinned) }
    }
    #endif

    // MARK: - Restart PC (VibeLight Helper, MoonDeckBuddy's way)

    /// Restart PC works once VibeLight Helper is ready on the selected PC; the
    /// header button is greyed and out of focus otherwise (owner rule for
    /// everything the helper controls).
    var canRestartPC: Bool { windowsHelperTarget != nil }

    /// The "Restart PC" button in the header: confirm, then restart.
    func requestRestartPC() {
        guard let host = selectedHost, canRestartPC else { return }
        restartingPC = false
        presentOverlay(.confirmRestartPC(host.id))
    }

    /// Seconds the PC waits before restarting — MoonDeckBuddy's own grace
    /// (1…30; VibeLight always asked it for 5).
    nonisolated static let restartDelaySeconds = 5

    /// Still showing the restart card for this host? Guards the async completion
    /// from clobbering whatever overlay the user moved on to.
    private func inRestartFlow(for hostID: String) -> Bool {
        if case .confirmRestartPC(let id) = overlay { return id == hostID }
        return false
    }

    /// Fire the restart (the confirm card's "Restart PC"). The helper answers
    /// at once and restarts Windows after `restartDelaySeconds`, apps forced
    /// closed — the way MoonDeckBuddy does it.
    func performRestartPC(hostID: String) {
        guard let host = hostForCapturedID(hostID), host.id == selectedHostID,
              let target = windowsHelperTarget else { return }
        restartingPC = true
        rebuildFocus()
        let client = windowsHelperClient
        Task { [weak self] in
            let outcome: Result<WindowsHelperClient.RestartResult, Error>
            do {
                outcome = .success(try await client.restart(delaySeconds: Self.restartDelaySeconds,
                                                            at: target.address, pinned: target.pinned))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            restartingPC = false
            guard inRestartFlow(for: hostID) else { return }
            switch outcome {
            case .success(let result) where result.ok:
                dismissOverlay()
                // The PC is rebooting; drop the live connection state so the UI
                // shows it going offline rather than a stale "online".
                serverInfo = nil
                // Normal progress, not an error (UX-host-banner-truncates).
                hostError = nil
                showHostNotice("Restarting \(host.name)…")
                // hostOnline just flipped false AFTER dismissOverlay()'s
                // rebuildFocus already ran — rebuild again so the now-visible
                // wake button's header:power id becomes focusable immediately
                // instead of only on the next refresh. (review: restart focus gap)
                rebuildFocus()
            case .success(let result):
                presentOverlay(.error(result.message))
            case .failure(let error):
                presentOverlay(.error((error as? LocalizedError)?.errorDescription ?? "Restart failed."))
            }
        }
    }

    /// Shows a progress notice in the header chip until the computer answers,
    /// a real error replaces it, you switch computers, or three minutes pass —
    /// so a PC that never comes back doesn't spin "Restarting…" forever.
    private func showHostNotice(_ text: String) {
        hostNotice = text
        noticeClearTask?.cancel()
        noticeClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard let self, !Task.isCancelled, self.hostNotice == text else { return }
            self.hostNotice = nil
        }
    }

    private func clearHostNotice() {
        hostNotice = nil
        noticeClearTask?.cancel()
        noticeClearTask = nil
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

    /// Whether a host is one of the user-added (removable) hosts.
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
        // Forget its VibeLight Helper certificate too (under either id it had),
        // so re-adding the same PC after a reinstall doesn't inherit a stale pin.
        setWindowsHelperPin(nil, for: host.id)
        if let ip = host.manualAddress { setWindowsHelperPin(nil, for: "added:\(ip)") }
        let wasSelected = selectedHostID == host.id
        rebuildHosts()
        if wasSelected {
            selectedHostID = hosts.first?.id
            serverInfo = nil; hostAddress = nil
            selectedHostChecked = false
            clearHostNotice()   // it named the removed computer
            hostError = Self.hostErrorAfterRemovingSelected(hostError, computersLeft: hosts.count)
            apps = displayApps(from: selectedHost?.apps ?? [])
            Task { await refreshSelectedHost() }
        }
        rebuildFocus()
    }

    /// Once a probe learns an added host's real UUID/name, upgrade the stored
    /// entry so it de-dupes by UUID and shows a friendly name.
    /// An unpaired computer added by IP kept showing its IP forever: the name
    /// comes from /serverinfo, and the HTTPS one refuses a client the host
    /// hasn't paired. The plain-HTTP one answers anyone (Moonlight names
    /// unpaired hosts the same way). Unauthenticated, so it supplies the
    /// display NAME only — never the uuid or MAC, which identify the PC.
    @ObservationIgnored private var nameLookupsInFlight: Set<String> = []

    private func learnUnpairedHostName(_ host: StreamHost) {
        guard !host.isPaired, isAddedHost(host), let ip = host.manualAddress, host.name == ip,
              nameLookupsInFlight.insert(ip).inserted else { return }
        let lookup = HostPairing(identityProvider: identityProvider, uniqueID: clientUniqueID)
        Task { [weak self] in
            let info = try? await lookup.plainServerInfo(address: ip)
            guard let self else { return }
            nameLookupsInFlight.remove(ip)
            if let name = info?.hostname.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                upgradeAddedHost(ip: ip, uuid: nil, name: name)   // id unchanged: no uuid
            }
        }
    }

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
        #if DEBUG
        if DebugInstruments.fakeHost != nil { return }   // synthetic host: no network
        #endif
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
        learnUnpairedHostName(host)
        do {
            let (info, address) = try await api.serverInfo(for: host)
            // The user can switch hosts (or a stream can start) during the
            // await; don't clobber the new selection's state with this stale
            // response — the same guard runs again after the applist await.
            guard selectionStillThisHost(), session.phase == .idle else { return }
            serverInfo = info
            hostAddress = address
            hostError = nil
            clearHostNotice()   // it's back — "Restarting…" is over
            hostNotResponding = false
            if wakingHostID == host.id {   // it woke up — drop the transient state
                wakingHostID = nil
                wakeClearTask?.cancel()
                // The empty shelf's Wake/spinner reads wakingHostID; rebuild now,
                // not only at the end (the applist guard below can return early).
                rebuildFocus()
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
            selectedHostChecked = true
            // The host answered normally, so whatever identity trouble we saw
            // before is over.
            hostsNeedingRepair.remove(host.id)
            rememberApps(fresh, for: host)
            #if os(iOS)
            presentPendingAppExitIfAny()
            #endif
            checkWindowsHelper()
        } catch let error as HostAPIError {
            // The host is reachable but refuses our identity — remember it so
            // selecting this computer offers PAIRING again instead of just
            // switching to it (see needsPairing). Without this the banner tells
            // the user to pair again and nothing in the UI lets them. Keyed by
            // host, so it holds even if the selection moved on.
            switch error {
            case .hostIdentityChanged, .notAuthorized: hostsNeedingRepair.insert(host.id)
            default: break
            }
            // A computer switched away from (or removed) during the await must
            // not write its error, address or games onto the new selection: a
            // removed computer's games stayed on the shelf with no computer
            // selected, while focus offered an Add Computer button no view drew
            // (3H last review).
            guard selectionStillThisHost() else { return }
            serverInfo = nil
            hostAddress = nil
            // A wedged host is NOT the normal asleep case — surface it, and
            // remember it so the wake button stays hidden (see canWakeSelectedHost).
            if case .notResponding = error { hostNotResponding = true } else { hostNotResponding = false }
            if case .unreachable = error {
                hostError = nil // asleep host is a normal state, not an error banner
            } else {
                hostError = error.localizedDescription
                clearHostNotice()   // a real error replaces any progress notice
            }
            // Fall back to the last app list we actually saw for this host.
            // This used to read `host.apps`, which is ALWAYS empty in the
            // shipping app (streamHost(from:) hardcodes `apps: []` and the
            // Moonlight plist import was removed in v0.2.0) — so the "cache"
            // was `apps = []`, and any hiccup blanked the whole shelf.
            apps = displayApps(from: rememberedApps(for: host))
            selectedHostChecked = true
        } catch {
            guard selectionStillThisHost() else { return }
            serverInfo = nil
            hostAddress = nil
            hostNotResponding = false
            selectedHostChecked = true
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
        let running = serverInfo?.runningAppID
        return raw.filter { app in
            guard app.id != 114514, !app.isHidden else { return false }
            let name = app.name.lowercased()
            return !name.isEmpty && name != "terminate" && !name.hasPrefix("terminate ")
        }
        .sorted { a, b in
            Self.shelfPrecedes(a, b, runningID: running,
                               lastA: recentLaunches["\(hostID)|\(appKey(a))"] ?? .distantPast,
                               lastB: recentLaunches["\(hostID)|\(appKey(b))"] ?? .distantPast)
        }
    }

    /// Shelf order: whatever is running on the PC right now first — always
    /// the far-left tile (owner) — then most recently launched, then the
    /// host's own order. Every caller sets `serverInfo` before rebuilding the
    /// list, so the running app is known when this runs; with the PC offline
    /// nothing is known to be running and the order is plain recency.
    nonisolated static func shelfPrecedes(_ a: StreamApp, _ b: StreamApp, runningID: Int?,
                                          lastA: Date, lastB: Date) -> Bool {
        if let runningID, (a.id == runningID) != (b.id == runningID) { return a.id == runningID }
        if lastA != lastB { return lastA > lastB }
        return (a.idx ?? Int.max, a.name) < (b.idx ?? Int.max, b.name)
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
        selectedHostChecked = false
        clearHostNotice()   // it named the previous computer
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
    /// GameStream has none, and VibeLight Helper only restarts; "power" here
    /// means turn ON, and Restart covers reboot.
    func wakeSelectedHost() {
        guard let host = selectedHost, host.macAddress != nil, !hostOnline else { return }
        wakeHost(host)
        wakingHostID = host.id
        let wasOnShelfWake = focus.focusedItemID == "shelf:wake"
        // The empty shelf swaps its Wake Computer button (shelf:wake) for a
        // spinner while waking — rebuild so the engine never holds an id no
        // view draws (UX-empty-home-no-invitation).
        rebuildFocus()
        // With the shelf's button gone the engine would fall DOWN to a preset
        // slot, and a second A (nothing seemed to happen) would apply it over
        // the current settings. Land on the header's Wake button instead: it's
        // still drawn while waking, and pressing it again only re-sends the
        // wake (3H review: wake focus falls onto presets).
        if wasOnShelfWake { focus.focus(itemID: "header:power") }
        wakeClearTask?.cancel()
        wakeClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard let self, self.wakingHostID == host.id else { return }
            self.wakingHostID = nil
            self.rebuildFocus()   // the Wake button comes back
        }
    }

    func wakeHost(_ host: StreamHost) {
        guard let mac = host.macAddress else { return }
        #if DEBUG
        if DebugInstruments.fakeHost != nil { return }   // synthetic host: send nothing
        #endif
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
            // Quit leaves once the PC has closed the game — nothing to quit.
            // Quit Stream and Game is drawn greyed without the helper, and
            // takes focus only with it.
            let ids = endedSession?.closedOnHost == true
                ? ["ended:resume", "ended:home"]
                : canQuitGame
                    ? ["ended:resume", "ended:quit", Self.quitGameButtonID, "ended:home"]
                    : ["ended:resume", "ended:quit", "ended:home"]
            sections = [FocusSection(id: "ended", kind: .vList, itemIDs: ids)]
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
        case .confirmRemoveHost:
            sections = [FocusSection(id: "removehost", kind: .vList,
                                     itemIDs: ["removehost:cancel", "removehost:yes"])]
        case .presetMenu(let id):
            sections = [FocusSection(id: "presetmenu", kind: .vList, itemIDs: presetMenuItems(for: id))]
        case .namePreset:
            // Suggestions in a row (◀ ▶), then Save / Cancel below.
            sections = [
                FocusSection(id: "namesugg", kind: .shelf,
                             itemIDs: presetNameSuggestions.indices.map { "namesugg:\($0)" }),
                FocusSection(id: "namecard", kind: .vList, itemIDs: ["name:save", "name:cancel"]),
            ].filter { !$0.itemIDs.isEmpty }
        case .confirmRestartPC:
            // Locked while the request is in flight: the card draws a spinner
            // then, and no focusable id may outlive the view that drew it.
            if restartingPC { return }
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
                    // Restart PC only with VibeLight Helper ready; it's drawn
                    // greyed (and takes no focus) without it.
                    var headerIDs = canRestartPC ? ["header:restart", "header:host"] : ["header:host"]
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
                // An empty shelf offers its own next step instead (Pair or
                // Wake Computer) — the same ids HomeView's empty panel draws.
                sections.append(FocusSection(
                    id: "apps", kind: .shelf,
                    itemIDs: emptyShelf.map(Self.emptyShelfFocusIDs)
                        ?? apps.map { "app:\(appKey($0))" }
                ))
                // The preset row sits UNDER the shelf — d-pad DOWN from a game
                // reaches it, UP returns: one chip per preset, "+" last when the
                // settings aren't saved anywhere.
                sections.append(FocusSection(id: "presets", kind: .shelf, itemIDs: presetRowFocusIDs))
            case .settings:
                // Just the rows (L1/R1 switch tabs). The slot strip that sat
                // above them is gone: a pill names the loaded preset and Y
                // saves into it. Default focus is the first row
                // (openSettings/switchSettingsTab focus it explicitly).
                sections = [
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
    /// you're on, by ID (`openHostMenu`), `.sessionEnded` opens on Quit
    /// (`presentSessionEnded`), and the HUD / cheat sheet
    /// deliberately leave the home screen's focus untouched underneath them
    /// (rebuildFocus returns early for those, so forcing focus would move the
    /// shelf behind the card).
    private func opensOnDeclaredFirstChoice(_ overlay: Overlay) -> Bool {
        switch overlay {
        case .confirmRemoveHost, .confirmSwitchStream, .presetMenu, .namePreset:
            return true
        case .confirmRestartPC:
            // rebuildFocus installs no section while a restart is in flight.
            return !restartingPC
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

    /// A touch or click went down on a hold-to-activate button (the
    /// still-running card's Quit): focus it and start filling it.
    func pressHoldButton(_ id: String, event: NavigationEvent) {
        intro.skip()
        if inputMode != .pointer { inputMode = .pointer }
        focus.focus(itemID: id)
        controller.beginPointerHold(for: event, onButton: true)
    }

    /// …and came up. Before the hold finished, that was a tap: select it,
    /// which the card answers with its "hold it" nudge.
    func releaseHoldButton(_ id: String) {
        if controller.cancelPointerHold(), focus.focusedItemID == id { route(.select) }
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

    // MARK: - Onboarding

    /// True if any preset is saved — used to skip the presets tutorial for
    /// users who clearly already know how to use them.
    var hasAnyPreset: Bool { !presets.isEmpty }

    /// Seed the first preset from the setup's chosen settings, named after
    /// them ("4K · 120") — only for a user with NO presets (the sole case the
    /// presets step is shown). Called from the step.
    func seedFirstPresetIfEmpty() {
        guard !hasAnyPreset else { return }
        saveCurrentAsNewPreset(named: suggestedPresetNames().first ?? "", announce: false)
    }

    /// Whether the user already had presets when the wizard started. Captured
    /// once (not live) so seeding the first preset mid-flow for a fresh user doesn't
    /// retroactively change which steps are skipped or the progress pips.
    private(set) var onboardingHadPresets = false

    /// Call when the wizard opens (welcome appears) to snapshot preset state.
    /// Snapshot the preset state ONCE per wizard session. Documented as
    /// "captured once (not live)" so seeding the first preset mid-flow doesn't
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
            case .move(.left):  appTheme = Self.cycle(appTheme, forward: false); sfx.play(.move)
            case .move(.right): appTheme = Self.cycle(appTheme, forward: true); sfx.play(.move)
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
        #if os(iOS)
        // Rejoining a dropped stream: the pads are back on the launcher's
        // navigation (the stream stopped forwarding), but the launcher is
        // hidden under the held frame, so nothing may act on it. B stops
        // trying and shows the still-running card.
        if session.rejoin != nil {
            if event == .back {
                sfx.play(.back)
                session.stopRejoining()
            }
            return
        }
        #endif
        // Menu SFX — deliberate actions make sound, navigation mostly doesn't:
        //  • Overlays (cards) keep normal select/back — they're deliberate.
        //  • Settings screen is SILENT except an explicit value change (adjust()).
        //  • Home: select confirms. The rising reboot cue plays ONLY when a PC
        //    restart actually fires (the confirm/setup overlay buttons) — the
        //    header button just opens the confirm, so it's a plain select.
        switch event {
        case .select:
            if overlay != nil {
                let firesRestart = !restartingPC && focus.focusedItemID == "restartpc:yes"
                sfx.play(firesRestart ? .restart : .select)
            } else if screen != .settings {
                sfx.play(.select)
            }
        case .back:
            if overlay != nil || screen != .settings { sfx.play(.back) }
        default:
            break
        }
        // Global chord: hold Menu → quit the remote game completely. The
        // still-running card's held Quit Stream and Game fires the same
        // event, from its own button.
        if event == .quitChord {
            if case .sessionEnded = overlay, focus.focusedItemID == Self.quitGameButtonID {
                quitStreamAndGame()
            } else {
                quitRemoteGameCompletely()
            }
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
        // movement needs no special casing — only select/contextMenu/detail do.
        let onPreset = presetID(fromFocusID: focus.focusedItemID)
        let onRow = onPreset != nil || focus.focusedItemID == "preset:add"
        switch event {
        case .select:
            // (A `host:`-prefixed branch used to sit here. No view and no
            // rebuildFocus path has ever emitted that prefix — the home screen
            // emits `header:*`/`app:*` and the overlay emits `hostmenu:*`, which
            // does not match. Host switching goes through routeOverlay.)
            if let id = onPreset {
                // A on the loaded preset after a change keeps the change.
                if id == activePresetID && isActivePresetEdited { updateActivePreset() }
                else { applyPreset(id) }
            } else if focus.focusedItemID == "preset:add" {
                openPresetNameCard(.new)
            } else if focus.focusedItemID == "header:host" || focus.focusedItemID == "header:addhost" {
                openHostMenu()
            } else if focus.focusedItemID == "header:power" || focus.focusedItemID == "shelf:wake" {
                wakeSelectedHost()
            } else if focus.focusedItemID == "shelf:pair" {
                // "Pair Computer" starts pairing, as it says — not just the
                // Computers menu with a second press still to make. The menu
                // draws the PIN panel while pairing; Cancel lands back on this
                // computer's row (3H review: Pair Computer only opened the menu).
                openHostMenu()
                if let host = selectedHost, needsPairing(host) { beginPairing(host) }
            } else if focus.focusedItemID == "header:restart" {
                requestRestartPC()
            } else if let app = focusedApp {
                launch(app)
            }
        case .settings:
            openSettings()
        case .contextMenu:
            // X on a preset opens its options; anywhere else X (like Y) opens
            // the cheat sheet, same as before the row moved.
            if let id = onPreset { openPresetMenu(id) }
            else { presentOverlay(.cheatSheet) }
        case .detail:
            // Y: Undo while a toast offers it; on the row, save the live
            // settings as a new preset when they're not saved as they are.
            if canUndoPresetChange { undoPresetChange() }
            else if onRow, presetRowOffersSaveAsNew { openPresetNameCard(.new) }
            else { presentOverlay(.cheatSheet) }
        case .back:
            break // home is the root — nowhere to go back to
        default:
            _ = focus.handle(event)
        }
    }

    /// Y saves the live settings as a new preset: there's room, and they're
    /// not already saved exactly as they are.
    var presetRowOffersSaveAsNew: Bool {
        canSaveNewPreset && (activePresetID == nil || isActivePresetEdited)
    }

    private func routeSettings(_ event: NavigationEvent) {
        switch event {
        case .back, .settings:
            closeSettings()
        case .prevSection:
            switchSettingsTab(forward: false)
        case .nextSection:
            switchSettingsTab(forward: true)
        case .move(.left), .move(.right):
            if let rowID = focus.focusedItemID,
               let row = SettingsRow.allCases.first(where: { $0.focusID == rowID }) {
                adjust(row: row, forward: event == .move(.right))
            }
        case .select:
            if let rowID = focus.focusedItemID,
               let row = SettingsRow.allCases.first(where: { $0.focusID == rowID }),
               row.isAction {
                performSettingAction(row)      // Software Update / Restart Setup
            } else if focus.focusedItemID == SettingsRow.resolution.focusID {
                openCustomResolution()         // type an arbitrary WxH
            }
        case .detail:
            // Y: Undo while offered; keep the change in the loaded preset;
            // with nothing loaded, save these settings as one.
            if canUndoPresetChange { undoPresetChange() }
            else if isActivePresetEdited { updateActivePreset() }
            else if activePresetID == nil, canSaveNewPreset { openPresetNameCard(.new) }
        case .contextMenu:
            // X: drop the change and go back to the loaded preset.
            if isActivePresetEdited { revertActivePreset() }
        default:
            _ = focus.handle(event)
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
        if tab == .windowsHelper { checkWindowsHelper(force: true) }
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
            // The poster is flying home, or the card is fading out after Quit.
            if endedSession?.leaving == true || endedSession?.quitting == true { return }
            if event == .select || event == .back, !endedAcceptsInput { return }
            switch event {
            case .select:
                switch focus.focusedItemID {
                case "ended:resume":
                    // Poster Lift carries on from this card's poster.
                    session.acknowledgeEnd()
                    dismissOverlay()
                    launch(app, liftFrom: Self.endedPosterID)
                case "ended:quit", Self.quitGameButtonID:
                    // A tap. Quit only fires from a hold (A held on it, or
                    // a press-and-hold), which arrives as .quitChord.
                    endedQuitNudges += 1
                case "ended:home", nil, .some:
                    returnHomeFromEnded(app)
                }
            case .back:
                returnHomeFromEnded(app)
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
        case .presetMenu(let id):
            switch event {
            case .select:
                switch focus.focusedItemID {
                case "presetmenu:revert":
                    closePresetCard()
                    revertActivePreset()
                case "presetmenu:edit":
                    // Settings opens with this preset loaded; its pill names it.
                    closePresetCard()
                    if activePresetID != id { applyPreset(id) }
                    openSettings()
                case "presetmenu:rename":
                    openPresetNameCard(.rename(id))   // replaces this card
                case "presetmenu:saveas":
                    openPresetNameCard(.new)
                case "presetmenu:delete":
                    // No confirm: the toast holds Undo, and focus lands on the
                    // neighbour instead of falling off the row.
                    let neighbour = deletePreset(id)
                    closePresetCard(returningTo: neighbour)
                default:
                    closePresetCard()
                }
            case .back:
                closePresetCard()
            default:
                _ = focus.handle(event)
            }
        case .namePreset(let target):
            switch event {
            case .select:
                let focused = focus.focusedItemID ?? ""
                if focused.hasPrefix("namesugg:"), let i = Int(focused.dropFirst("namesugg:".count)),
                   presetNameSuggestions.indices.contains(i) {
                    presetNameDraft = presetNameSuggestions[i]   // A on a name takes it
                    commitPresetName(target)
                } else if focused == "name:save" {
                    commitPresetName(target)
                } else {
                    closePresetCard()
                }
            case .back:
                closePresetCard()
            default:
                _ = focus.handle(event)
                // ◀ ▶ over the suggestions fills the name in as you go.
                if let focused = focus.focusedItemID, focused.hasPrefix("namesugg:"),
                   let i = Int(focused.dropFirst("namesugg:".count)), presetNameSuggestions.indices.contains(i) {
                    presetNameDraft = presetNameSuggestions[i]
                }
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
            if restartingPC { break }   // locked while in flight
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

    /// `liftFrom`: where the starting card lifts its poster from (a lift
    /// geometry id); the pressed tile when nil.
    func launch(_ app: StreamApp, liftFrom sourceID: String? = nil) {
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
        forceLaunch(app, liftFrom: sourceID)
    }

    /// The unguarded launch path: used directly by the switch-stream confirm
    /// (the user already chose to close what's running).
    private func forceLaunch(_ app: StreamApp, liftFrom sourceID: String? = nil) {
        guard let host = selectedHost else { return }
        // Recency for the shelf order: recorded NOW, applied on the next shelf
        // rebuild (post-stream refresh) — resorting the array mid-launch would
        // yank the tile out from under the animation the user is looking at.
        recordLaunch(of: app, on: host)
        launchTarget = app   // the starting card lifts this tile (set before it appears)
        liftSourceID = sourceID ?? "app:\(appKey(app))"
        presentOverlay(.sessionHUD)
        #if os(iOS)
        let streamSettings = launchSettings   // Match TV: the TV's size
        #else
        let streamSettings = settings
        #endif
        Task {
            await session.launch(app: app, on: host, settings: streamSettings)
            // No post-await phase check needed: every .failed transition —
            // including the asynchronous ones from the startup watchdog and
            // the child's termination handler — lands via onPhaseChange.
        }
    }

    /// The headline feature: fully terminate the remote game, from anywhere.
    func quitRemoteGameCompletely() {
        guard let host = selectedHost else { return }
        // The card's Quit already fired (a second hold, or Menu-hold, during
        // its fade-out is not a second quit).
        if case .sessionEnded = overlay, endedSession?.quitting == true { return }
        // Not a drop: a quit that fails must surface as the error card.
        liveStream = nil
        // The card answers on the SAME press — the /cancel round-trip (~1 s)
        // used to hold it open, which read as "the button didn't work" — but
        // by fading out slowly, not snapping away (owner: "slowly fade out,
        // right now it's choppy"). /cancel runs meanwhile.
        if case .sessionEnded(let app) = overlay { fadeOutEndedCard(app) }
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
                // A card still fading closes itself when the fade is done.
                if case .sessionEnded = overlay, endedSession?.quitting != true { dismissOverlay() }
            }
            // NOW the phase is idle, so the refresh that onStreamDidEnd
            // couldn't run can happen — unless the card is still fading out,
            // which refreshes once it has gone (no shelf re-sort under it).
            if case .sessionEnded = overlay, endedSession?.quitting == true { return }
            await refreshSelectedHost()
        }
    }

    /// A stream is active, or the host is still running a game — something the
    /// host would keep doing after VibeLight closes. Used for UI ("host busy")
    /// state, NOT for the quit-cleanup decision — see `isLocalStreamActive`.
    var hasActiveRemoteSession: Bool {
        session.phase != .idle || (serverInfo?.currentGameID ?? 0) != 0
    }

    /// There is a game to quit: the PC reports one running (`runningAppID`
    /// requires state == busy — `currentgame` alone lingers after a game
    /// closes), or this device is streaming one. Gates the quit-game hold and
    /// its hint; they used to appear with nothing running at all.
    var canQuitRemoteGame: Bool {
        serverInfo?.runningAppID != nil || isLocalStreamActive || endedCardOffersQuit
    }

    // MARK: - Still running (Poster Rest)

    /// The still-running card — "Poster Rest", the owner's pick of five (Fable
    /// design lead, Oct 2026). The poster that lifted when the game started
    /// is what you land on when you leave it, LIVE and green, with Resume,
    /// a held Quit and Back to Library beside it. Opens on Quit (owner) —
    /// safe, since Quit can't fire from one press — and input waits for the
    /// curtain.
    private func presentSessionEnded(_ app: StreamApp, dropReason: String? = nil) {
        let played = liveStream.map { Date().timeIntervalSince($0.since) }
        liveStream = nil
        endedSession = EndedSession(played: played, dropReason: dropReason,
                                    readyAt: Date().addingTimeInterval(endedInputDelay))
        presentOverlay(.sessionEnded(app))
        // Owner: open on Quit Stream Completely. Safe now: Quit only fires
        // from a 0.8 s hold, and nothing is taken until the curtain lifts.
        focus.focus(itemID: "ended:quit")
        watchEndedGame(app)
        watchHelperGame()   // asks again now: the card shows which game Quit would close
    }

    /// How long the card takes to fade out after Quit fires, in seconds
    /// (its views animate over the same span).
    nonisolated static let endedQuitFade = 0.9

    /// Quit fired from the card: it keeps its closing look (grey poster,
    /// CLOSING, the button full) and fades out with the scrim, then goes.
    private func fadeOutEndedCard(_ app: StreamApp) {
        endedSession?.quitting = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.endedQuitFade))
            guard let self, isShowingEnded(app) else { return }
            dismissOverlay()
            // Park focus on the host chip — the section-restore would land on
            // Restart PC, where the same impatient mash walks straight into a
            // PC reboot (select → confirm → yes). The chip just opens a menu.
            focus.focus(itemID: "header:host")
            // Only now: the shelf re-sorting (the game no longer LIVE) showed
            // through the fading scrim. (Bails if /cancel is still out; the
            // quit refreshes when it lands.)
            await refreshSelectedHost()
        }
    }

    /// The lift geometry id of the card's poster (Resume lifts from it).
    nonisolated static let endedPosterID = "ended:poster"

    /// How long the card ignores Select / Back after it appears. On the iPad
    /// it appears under the leave curtain (1 s black, then a 0.9 s fade), so
    /// it waits until the card is plainly visible; otherwise a beat.
    private var endedInputDelay: TimeInterval {
        #if os(iOS)
        if session.exitCurtain > 0 { return 1.5 }
        #endif
        return 0.5
    }

    /// The card takes Select / Back: shown long enough, and not still black.
    var endedAcceptsInput: Bool {
        #if os(iOS)
        if session.exitCurtain > 0 { return false }
        #endif
        return Date() >= (endedSession?.readyAt ?? .distantPast)
    }

    /// The card is up and its game is still running, so there is a game to quit.
    private var endedCardOffersQuit: Bool {
        guard case .sessionEnded = overlay, let ended = endedSession else { return false }
        return !ended.closedOnHost && !ended.leaving && !ended.quitting
    }

    /// Focus is on the card's Quit and it may be held now — A / Return /
    /// a press start the hold instead of selecting (ControllerManager).
    var focusedHoldButton: Bool {
        let onQuit = focus.focusedItemID == "ended:quit"
            || (focus.focusedItemID == Self.quitGameButtonID && canQuitGame)
        return endedCardOffersQuit && onQuit && endedAcceptsInput
    }

    /// Back to Library: the poster flies back into its tile and the scrim
    /// lifts, then the card goes and the tile blooms once. The game keeps
    /// running.
    private func returnHomeFromEnded(_ app: StreamApp) {
        endedSession?.leaving = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard let self else { return }
            // Resolved as the card goes, as before the flight existed: an
            // update offer waiting on the stream's end looks again once the
            // card is gone (onPhaseChange's idle hook).
            session.acknowledgeEnd()
            guard isShowingEnded(app) else { return }
            let tile = "app:\(appKey(app))"
            dismissOverlay(returningTo: apps.contains(where: { $0.id == app.id }) ? tile : nil)
            tileBlooms[tile, default: 0] += 1
            await refreshSelectedHost()
        }
    }

    /// While the card is up, ask the PC now and then whether the game is
    /// still running (the 12 s refresh stands down until the session is
    /// resolved). If it has gone, the card says so: Play Again, no Quit.
    private func watchEndedGame(_ app: StreamApp) {
        endedWatchTask?.cancel()
        guard let host = selectedHost else { return }
        endedWatchTask = Task { [weak self] in
            var wait: Duration = .seconds(2)
            while !Task.isCancelled {
                try? await Task.sleep(for: wait)
                wait = .seconds(6)
                guard let self, !Task.isCancelled, isShowingEnded(app) else { return }
                // A failed ask changes nothing: no answer isn't "closed".
                guard let answer = try? await api.serverInfo(for: host) else { continue }
                // Stops once the card is on its way out — /cancel makes the PC
                // report "closed", which flipped the card to Play Again (Quit
                // gone, everything jumping up) in the middle of its fade.
                guard isShowingEnded(app), endedSession?.leaving == false,
                      endedSession?.quitting == false else { return }
                setEndedClosed(answer.info.runningAppID != app.id)
            }
        }
    }

    private func isShowingEnded(_ app: StreamApp) -> Bool {
        if case .sessionEnded(let shown) = overlay { return shown.id == app.id }
        return false
    }

    private func setEndedClosed(_ closed: Bool) {
        guard endedSession != nil, endedSession?.closedOnHost != closed else { return }
        endedSession?.closedOnHost = closed
        let wasOnQuit = focus.focusedItemID == "ended:quit"
        rebuildFocus()
        if wasOnQuit || focus.focusedItemID == nil { focus.focus(itemID: "ended:resume") }
    }

    /// The card's line under the game's name.
    nonisolated static func endedStatusLine(game: String, host: String, closed: Bool,
                                            played: TimeInterval?, leftApp: Bool = false) -> String {
        let head = closed ? "\(game) has closed on \(host)"
                          : leftApp ? "You left VibeLight · still running on \(host)" : "Still running on \(host)"
        guard let played else { return head }
        return "\(head) · \(playedText(played))"
    }

    /// "played 42 min", "played 1 h 5 min", "played under a minute".
    nonisolated static func playedText(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(seconds, 0) / 60)
        if minutes < 1 { return "played under a minute" }
        if minutes < 60 { return "played \(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "played \(h) h" : "played \(h) h \(m) min"
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
        case resolution, fps, bitrate, adaptiveBitrate, tvPresets, codec, hdr, decoder, yuv444
        case audio, muteHostSpeakers, muteOnFocusLoss, menuSounds
        case touchControls, touchWithController, absoluteMouse, swapMouseButtons, reverseScrolling, captureSystemKeys, swapGamepadButtons, backgroundGamepad
        case vsync, framePacing, keepAwake, performanceOverlay
        case helperStatus, matchTV, tvResolution
        case theme, interfaceSize
        case appVersion, checkUpdates, restartSetup

        var focusID: String { "setting:\(rawValue)" }

        /// Action/readonly rows don't adjust with left/right and render without
        /// value chevrons (they respond to select instead).
        var isAction: Bool { self == .checkUpdates || self == .restartSetup || self == .helperStatus }
        var isReadonly: Bool { self == .appVersion }

        var title: String {
            switch self {
            case .resolution: "Resolution"
            case .fps: "Frame Rate"
            case .bitrate: "Bitrate"
            case .adaptiveBitrate: "Adaptive Bitrate"
            case .tvPresets: "TV Presets"
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
            case .absoluteMouse: "Remote Desktop Mouse"
            case .swapMouseButtons: "Swap Mouse Buttons"
            case .reverseScrolling: "Reverse Scrolling"
            case .captureSystemKeys: "Capture System Keys"
            case .swapGamepadButtons: "Swap A/B & X/Y"
            case .backgroundGamepad: "Background Gamepad"
            case .vsync: "V-Sync"
            case .framePacing: "Frame Pacing"
            case .keepAwake: "Keep Display Awake"
            case .performanceOverlay: "Performance Stats"
            case .helperStatus: "VibeLight Helper"
            case .matchTV: "Match TV"
            case .tvResolution: "TV Resolution"
            case .theme: "Theme"
            case .interfaceSize: "Interface Size"
            case .appVersion: "Version"
            case .checkUpdates: "Software Update"
            case .restartSetup: "Restart Setup"
            }
        }
    }

    /// Settings groups, switched with L1/R1 so each screen stays short.
    enum SettingsTab: String, CaseIterable {
        case video, audio, input, advanced, windowsHelper, themes, about
        var title: String {
            switch self {
            case .video: "Video"; case .audio: "Audio"; case .input: "Input"
            case .advanced: "Advanced"; case .windowsHelper: "Windows Helper"
            case .themes: "Themes"; case .about: "About"
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
                [.resolution, .fps, .bitrate, .adaptiveBitrate, .tvPresets]
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
                [.keepAwake, .performanceOverlay]
                #else
                [.vsync, .framePacing, .keepAwake, .performanceOverlay]
                #endif
            case .windowsHelper:
                #if os(iOS)
                [.helperStatus, .matchTV, .tvResolution]
                #else
                // Match TV is the iPad's (a TV on its adapter); the Mac gets
                // Quit Stream and Game.
                [.helperStatus]
                #endif
            case .themes: [.theme, .interfaceSize]
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
        case .adaptiveBitrate: adaptiveBitrate ? "On" : "Off"
        case .tvPresets: !tvPresetsEnabled ? "Off" : liveTV.map { "On · \($0.name)" } ?? "On"
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
        case .absoluteMouse: settings.absoluteMouse ? "On" : "Off"
        case .swapMouseButtons: settings.swapMouseButtons ? "On" : "Off"
        case .reverseScrolling: settings.reverseScrolling ? "On" : "Off"
        case .captureSystemKeys: settings.captureSystemKeys.label
        case .swapGamepadButtons: settings.swapGamepadButtons ? "On" : "Off"
        case .backgroundGamepad: settings.backgroundGamepad ? "On" : "Off"
        case .vsync: settings.vsync ? "On" : "Off"
        case .framePacing: settings.framePacing ? "On" : "Off"
        case .keepAwake: settings.keepAwake ? "On" : "Off"
        case .performanceOverlay: settings.performanceOverlay ? "On" : "Off"
        case .helperStatus: windowsHelperStatusText
        case .matchTV: matchTV ? "On" : "Off"
        case .tvResolution: tvMatchScale.label(tv: tvSizeForLabel)
        case .theme: appTheme.title
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
        case .helperStatus: windowsHelperStatusSelected()
        default: break
        }
    }

    /// Rows a missing VibeLight Helper controls: drawn greyed, deaf to
    /// left/right. TV Resolution also waits on Match TV, and steps aside for
    /// TV Presets (owner: each TV's own preset sets the size then).
    func isUnavailable(_ row: SettingsRow) -> Bool {
        switch row {
        case .matchTV: !windowsHelperReady
        case .tvResolution: !windowsHelperReady || !matchTV || tvPresetsEnabled
        default: false
        }
    }

    /// The VibeLight Helper row's value.
    var windowsHelperStatusText: String {
        guard selectedHost != nil else { return "No PC selected" }
        switch windowsHelper {
        case .unknown, .checking: return "Checking…"
        case .ready(let pcName): return "Ready on \(pcName)"
        case .notAllowed: return "Not allowed"
        case .notFound: return "Not found"
        case .certChanged: return "Changed — select to trust"
        }
    }

    /// The attached TV's size for the TV Resolution row (nil on the Mac).
    private var tvSizeForLabel: (width: Int, height: Int)? {
        #if os(iOS)
        return attachedTVSize
        #else
        return nil
        #endif
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
        if isUnavailable(row) { return }   // greyed: needs VibeLight Helper
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
        case .adaptiveBitrate: adaptiveBitrate.toggle()
        case .tvPresets: tvPresetsEnabled.toggle()
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
        case .absoluteMouse: settings.absoluteMouse.toggle()
        case .swapMouseButtons: settings.swapMouseButtons.toggle()
        case .reverseScrolling: settings.reverseScrolling.toggle()
        case .swapGamepadButtons: settings.swapGamepadButtons.toggle()
        case .backgroundGamepad: settings.backgroundGamepad.toggle()
        case .vsync: settings.vsync.toggle()
        case .framePacing: settings.framePacing.toggle()
        case .keepAwake: settings.keepAwake.toggle(); refreshKeepAwake()
        case .performanceOverlay: settings.performanceOverlay.toggle()
        case .matchTV: matchTV.toggle()
        case .tvResolution: tvMatchScale = Self.cycle(tvMatchScale, forward: forward)
        case .theme: appTheme = Self.cycle(appTheme, forward: forward)
        case .interfaceSize: interfaceSize = Self.cycle(interfaceSize, forward: forward)
        case .appVersion, .checkUpdates, .restartSetup, .helperStatus: break  // not value rows
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

#if DEBUG
extension AppState {
    /// `VL_FAKE_HOST` (see DebugInstruments): one synthetic "Gaming PC" in the
    /// requested state, plus the server info that state implies.
    fileprivate static func debugFakeHost() -> (host: StreamHost, info: ServerInfo?, notResponding: Bool)? {
        guard let fake = DebugInstruments.fakeHost else { return nil }
        let host = StreamHost(
            id: "debug:fake-host", name: "Gaming PC",
            localAddress: "192.0.2.10", localPort: 47989,
            remoteAddress: nil, remotePort: 47989,
            manualAddress: "192.0.2.10", manualPort: 47989,
            // RFC 7042 documentation MAC: present only where waking is possible.
            macAddress: fake == .asleep ? Data([0x00, 0x00, 0x5E, 0x00, 0x53, 0x01]) : nil,
            serverCertPEM: fake == .unpaired ? nil : Data("debug".utf8),
            apps: [])
        let info = fake == .onlineEmpty
            ? ServerInfo(hostname: host.name, state: .free, currentGameID: 0,
                         currentGameUUID: nil, pairStatus: true,
                         serverCodecModeSupport: 0, httpsPort: 47984,
                         appVersion: "debug", permissionMask: nil,
                         virtualDisplayCapable: nil, macAddress: nil, hostUUID: nil)
            : nil
        return (host, info, fake == .notResponding)
    }
}
#endif
