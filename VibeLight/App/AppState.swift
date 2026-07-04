import AppKit
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
    let session: StreamSessionManager
    let focus = FocusEngine()
    let controller = ControllerManager()
    let updateService = UpdateService()
    @ObservationIgnored weak var windowCoordinator: WindowCoordinator?

    // MARK: Library state

    private(set) var hosts: [StreamHost] = []      // merged: Moonlight + user-added, capped at 4
    private(set) var selectedHostID: String?
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
    /// read-only plist).
    struct AddedHost: Codable, Equatable, Sendable {
        var name: String
        var ip: String
        var uuid: String?
    }

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

    /// Settings rows currently adjustable via left/right (vList doesn't consume
    /// horizontal moves — that's how value adjustment works).
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// The active settings tab (L1/R1 switch between them). Grouping keeps each
    /// screen short instead of one long scroll.
    var settingsTab: SettingsTab = .video

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

    // MARK: - Boot

    init() {
        let importer = MoonlightConfigImporter()
        let imported = try? importer.importAll()

        let identity = imported?.identity ?? ClientIdentity(
            certificatePEM: Data(), privateKeyPEM: Data(), uniqueID: "0123456789ABCDEF"
        )
        let identityProvider = ClientIdentityProvider(identity: identity)
        let client = HostAPIClient(identityProvider: identityProvider)
        api = client
        artwork = ArtworkStore(api: client)
        session = StreamSessionManager(api: client)

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

        importedHosts = (imported?.hosts ?? []).filter(\.isPaired)
        addedHosts = Self.loadAddedHosts()
        rebuildHosts()
        selectedHostID = hosts.first?.id
        apps = displayApps(from: selectedHost?.apps ?? [])
        if imported == nil {
            hostError = "Moonlight isn't set up on this Mac. Install and pair Moonlight once, then relaunch VibeLight."
        } else if hosts.isEmpty {
            hostError = "No paired hosts found in Moonlight. Pair a host in Moonlight once, then relaunch VibeLight."
        }

        wireCallbacks()
        rebuildFocus()
        focus.focusFirst()
        startRefreshLoop()
        checkForUpdatesOnLaunch()
    }

    private func wireCallbacks() {
        controller.onEvent = { [weak self] event in
            self?.route(event)
        }
        controller.onInputActivity = { [weak self] mode in
            guard let self else { return }
            if mode == .directed {
                // Console mode: cursor vanishes until the mouse moves again
                // (the OS auto-reveals it on movement — no unhide bookkeeping).
                NSCursor.setHiddenUntilMouseMoves(true)
            }
            if inputMode != mode { inputMode = mode }
        }
        controller.quitAppChordEnabled = { [weak self] in
            guard let self else { return false }
            return screen == .home && overlay == nil
        }
        focus.onFocusChange = { [weak self] _, new in
            guard new != nil else { return }
            self?.controller.focusTick()
        }
        // Failures arrive asynchronously (startup watchdog, child termination
        // handler) long after launch() returned — this observer is the ONLY
        // reliable way to catch them. Without it a failed launch strands the
        // user on the input-locked session HUD forever.
        session.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            if case .failed(let message) = phase {
                windowCoordinator?.endStreamHandoffIfActive()
                presentOverlay(.error(message))
            }
        }
        session.onStreamDidStart = { [weak self] helperPID in
            guard let self else { return }
            windowCoordinator?.beginStreamHandoff(helperPID: helperPID)
            overlay = nil
            rebuildFocus()
        }
        session.onStreamDidEnd = { [weak self] _ in
            guard let self else { return }
            windowCoordinator?.endStreamHandoff()
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
                   macAddress: nil, serverCertPEM: nil, apps: [])
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
            var ids = hosts.map { "hostmenu:\($0.id)" }
            if hosts.count < Self.maxHosts { ids.append("hostmenu:add") }
            sections = [FocusSection(id: "hosts", kind: .vList, itemIDs: ids)]
        case .sessionHUD, .cheatSheet:
            // Nothing focusable in these overlays — but keep the underlying
            // sections installed. routeOverlay() gates all input anyway, and
            // preserving sections keeps the user's shelf position (and the
            // engine's per-section memory) intact for when they return.
            return
        case nil:
            switch screen {
            case .home:
                // NOTE: host switching UI is deliberately not a focus section
                // yet — never emit focusable IDs that no view renders, or
                // focus goes invisible. Multi-host switching lives in the
                // header (mouse) until a proper host shelf exists.
                sections.append(FocusSection(
                    id: "apps", kind: .shelf,
                    itemIDs: apps.map { "app:\(appKey($0))" }
                ))
            case .settings:
                // Only the active tab's rows are focusable; L1/R1 switch tabs.
                sections = [FocusSection(id: "settings", kind: .vList,
                                         itemIDs: settingsTab.rows.map(\.focusID))]
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
        if inputMode != .pointer { inputMode = .pointer }
        focus.focus(itemID: id)
        route(.select)
    }

    func route(_ event: NavigationEvent) {
        // Global chord: hold Menu → quit the remote game completely.
        if event == .quitChord {
            quitRemoteGameCompletely()
            return
        }

        // Hold B/Circle on the home screen → quit VibeLight itself. Gated to
        // home-with-no-overlay so it can never fire mid-stream or from a menu.
        if event == .quitApp {
            if screen == .home, overlay == nil {
                NSApplication.shared.terminate(nil)
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
        switch event {
        case .select:
            if let id = focus.focusedItemID, id.hasPrefix("host:") {
                selectHost(String(id.dropFirst(5)))
            } else if let app = focusedApp {
                launch(app)
            }
        case .settings:
            openSettings()
        case .detail, .contextMenu:
            presentOverlay(.cheatSheet)
        case .back:
            break // home is the root — nowhere to go back to
        default:
            _ = focus.handle(event)
        }
    }

    private func routeSettings(_ event: NavigationEvent) {
        switch event {
        case .back, .settings:
            closeSettings()
        case .move(.left), .move(.right):
            if let rowID = focus.focusedItemID,
               let row = SettingsRow.allCases.first(where: { $0.focusID == rowID }) {
                adjust(row: row, forward: event == .move(.right))
            }
        case .prevSection:
            switchSettingsTab(forward: false)
        case .nextSection:
            switchSettingsTab(forward: true)
        case .select:
            // Action rows respond to select; value rows adjust with left/right.
            if focus.focusedItemID == SettingsRow.checkUpdates.focusID {
                checkForUpdates()
            }
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
        focus.focusFirst()
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
            switch event {
            case .select:
                if focus.focusedItemID == "hostmenu:add" {
                    addHost()
                } else if let id = focus.focusedItemID, id.hasPrefix("hostmenu:") {
                    selectHost(String(id.dropFirst("hostmenu:".count)))
                    dismissOverlay()
                }
            case .back:
                dismissOverlay()
            default:
                _ = focus.handle(event)
            }
        }
    }

    private func dismissOverlay() {
        overlay = nil
        rebuildFocus()
        if focus.focusedItemID == nil { focus.focusFirst() }
    }

    func openSettings() {
        screen = .settings
        rebuildFocus()
        focus.focusFirst()
    }

    func closeSettings() {
        screen = .home
        rebuildFocus()
        if focus.focusedItemID == nil { focus.focusFirst() }
    }

    // MARK: - Actions

    func launch(_ app: StreamApp) {
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

    // MARK: - Settings rows

    enum SettingsRow: String, CaseIterable {
        case resolution, fps, bitrate, codec, hdr, decoder, yuv444
        case audio, muteHostSpeakers, muteOnFocusLoss
        case absoluteMouse, swapMouseButtons, reverseScrolling, captureSystemKeys, swapGamepadButtons, backgroundGamepad
        case vsync, framePacing, gameOpt, quitAppAfter, keepAwake, performanceOverlay
        case appVersion, checkUpdates

        var focusID: String { "setting:\(rawValue)" }

        /// Action/readonly rows don't adjust with left/right and render without
        /// value chevrons (checkUpdates responds to select instead).
        var isAction: Bool { self == .checkUpdates }
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
            case .appVersion: "Version"
            case .checkUpdates: "Software Update"
            }
        }
    }

    /// Settings groups, switched with L1/R1 so each screen stays short.
    enum SettingsTab: String, CaseIterable {
        case video, audio, input, advanced, about
        var title: String {
            switch self {
            case .video: "Video"; case .audio: "Audio"; case .input: "Input"
            case .advanced: "Advanced"; case .about: "About"
            }
        }
        var rows: [SettingsRow] {
            switch self {
            case .video: [.resolution, .fps, .bitrate, .codec, .hdr, .decoder, .yuv444]
            case .audio: [.audio, .muteHostSpeakers, .muteOnFocusLoss]
            case .input: [.absoluteMouse, .swapMouseButtons, .reverseScrolling, .captureSystemKeys, .swapGamepadButtons, .backgroundGamepad]
            case .about: [.appVersion, .checkUpdates]
            case .advanced: [.vsync, .framePacing, .gameOpt, .quitAppAfter, .keepAwake, .performanceOverlay]
            }
        }
    }

    static let resolutionPresets: [(w: Int, h: Int, label: String)] = [
        (1280, 720, "720p"), (1920, 1080, "1080p"), (2560, 1440, "1440p"),
        (3440, 1440, "Ultrawide 1440p"), (3840, 2160, "4K"),
    ]
    static let fpsPresets = [30, 60, 90, 120, 144, 165, 240]

    /// Bitrate steps in clean 10 Mbps increments (Kbps).
    static let bitrateStep = 10_000
    static let bitrateMin = 10_000
    static let bitrateMax = 200_000

    func value(for row: SettingsRow) -> String {
        switch row {
        case .resolution:
            Self.resolutionPresets.first { $0.w == settings.width && $0.h == settings.height }?.label
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
        case .appVersion: "v\(updateService.currentVersion)"
        case .checkUpdates: updateStatusText
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
        switch row {
        case .resolution:
            let presets = Self.resolutionPresets
            let current = presets.firstIndex { $0.w == settings.width && $0.h == settings.height } ?? 1
            let next = min(max(current + (forward ? 1 : -1), 0), presets.count - 1)
            settings.width = presets[next].w
            settings.height = presets[next].h
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
        case .absoluteMouse: settings.absoluteMouse.toggle()
        case .swapMouseButtons: settings.swapMouseButtons.toggle()
        case .reverseScrolling: settings.reverseScrolling.toggle()
        case .swapGamepadButtons: settings.swapGamepadButtons.toggle()
        case .backgroundGamepad: settings.backgroundGamepad.toggle()
        case .vsync: settings.vsync.toggle()
        case .framePacing: settings.framePacing.toggle()
        case .gameOpt: settings.gameOptimizations.toggle()
        case .quitAppAfter: settings.quitAppAfter.toggle()
        case .keepAwake: settings.keepAwake.toggle()
        case .performanceOverlay: settings.performanceOverlay.toggle()
        case .appVersion, .checkUpdates: break  // not value rows
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
