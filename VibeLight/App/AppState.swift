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
    @ObservationIgnored weak var windowCoordinator: WindowCoordinator?

    // MARK: Library state

    private(set) var hosts: [StreamHost] = []
    private(set) var selectedHostID: String?
    private(set) var serverInfo: ServerInfo?
    private(set) var hostAddress: String?
    private(set) var hostError: String?
    private(set) var isRefreshing = false
    /// Apps to render: fresh from the host when online, else the plist cache.
    private(set) var apps: [StreamApp] = []

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
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(StreamSettings.self, from: data) {
            settings = saved
        } else {
            settings = imported?.settings ?? .fallback
        }

        hosts = (imported?.hosts ?? []).filter(\.isPaired)
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
    }

    private func wireCallbacks() {
        controller.onEvent = { [weak self] event in
            self?.route(event)
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
        session.onStreamDidStart = { [weak self] in
            guard let self else { return }
            windowCoordinator?.beginStreamHandoff()
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
        guard let host = selectedHost, let mac = host.macAddress else { return }
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
                sections = [FocusSection(id: "settings", kind: .vList,
                                         itemIDs: Self.settingsRowIDs)]
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

    func route(_ event: NavigationEvent) {
        // Global chord: hold Menu → quit the remote game completely.
        if event == .quitChord {
            quitRemoteGameCompletely()
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
        case .select:
            break // rows adjust with left/right; select is a no-op for now
        default:
            _ = focus.handle(event)
        }
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
        case resolution, fps, bitrate, hdr, vsync, framePacing

        var focusID: String { "setting:\(rawValue)" }

        var title: String {
            switch self {
            case .resolution: "Resolution"
            case .fps: "Frame Rate"
            case .bitrate: "Bitrate"
            case .hdr: "HDR"
            case .vsync: "V-Sync"
            case .framePacing: "Frame Pacing"
            }
        }
    }

    static let resolutionPresets: [(w: Int, h: Int, label: String)] = [
        (1280, 720, "720p"), (1920, 1080, "1080p"),
        (2560, 1440, "1440p"), (3840, 2160, "4K"),
    ]
    static let fpsPresets = [30, 60, 90, 120, 144]

    func value(for row: SettingsRow) -> String {
        switch row {
        case .resolution:
            Self.resolutionPresets.first { $0.w == settings.width && $0.h == settings.height }?.label
                ?? "\(settings.width)×\(settings.height)"
        case .fps: "\(settings.fps) fps"
        case .bitrate: String(format: "%.1f Mbps", Double(settings.bitrateKbps) / 1000)
        case .hdr: settings.hdr ? "On" : "Off"
        case .vsync: settings.vsync ? "On" : "Off"
        case .framePacing: settings.framePacing ? "On" : "Off"
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
            let step = 5000
            settings.bitrateKbps = min(max(settings.bitrateKbps + (forward ? step : -step), 5000), 150_000)
        case .hdr: settings.hdr.toggle()
        case .vsync: settings.vsync.toggle()
        case .framePacing: settings.framePacing.toggle()
        }
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }
}
