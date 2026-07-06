import Foundation

// MARK: - GameStream host API (port 47984, mTLS with reused Moonlight pairing)

/// Live server state parsed from /serverinfo. Only trust `currentGameID`
/// when `state` is `.busy` (Moonlight semantics).
struct ServerInfo: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case free
        case busy
        case unknown(String)

        init(rawState: String) {
            if rawState.hasSuffix("_SERVER_BUSY") { self = .busy }
            else if rawState.hasSuffix("_SERVER_FREE") { self = .free }
            else { self = .unknown(rawState) }
        }
    }

    var hostname: String
    var state: State
    var currentGameID: Int          // 0 when idle
    var currentGameUUID: String?    // Vibepollo/Apollo extension
    var pairStatus: Bool
    var serverCodecModeSupport: Int
    var httpsPort: Int
    var appVersion: String
    var permissionMask: UInt32?     // Vibepollo/Apollo extension
    var virtualDisplayCapable: Bool?

    var runningAppID: Int? {
        state == .busy && currentGameID != 0 ? currentGameID : nil
    }
}

enum HostAPIError: Error, LocalizedError, Sendable {
    case unreachable(String)                 // no address responded
    case xmlStatus(code: Int, message: String)  // <root status_code != 200>
    case notAuthorized                       // XML 401 — cert not in host's paired pool
    case malformedResponse(String)
    case identityUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let host): "\(host) is not reachable."
        case .xmlStatus(let code, let message): "Host error \(code): \(message)"
        case .notAuthorized: "This Mac's pairing was not accepted by the host. Re-pair in Moonlight."
        case .malformedResponse(let detail): "Unexpected host response: \(detail)"
        case .identityUnavailable(let detail): "Client identity unavailable: \(detail)"
        }
    }
}

/// GameStream protocol client. All calls hit HTTPS 47984 with the reused
/// Moonlight client cert; serverinfo may fall back to HTTP 47989 to
/// distinguish "unpaired" from "offline".
protocol HostAPIProviding: Sendable {
    /// Queries candidate addresses in order; returns info from the first that responds.
    /// Also returns the address that worked so callers can stick to it.
    func serverInfo(for host: StreamHost) async throws -> (info: ServerInfo, address: String)

    /// Fresh app list. ALWAYS use this immediately before launching — cached
    /// names go stale because zero-width padding width changes with app count.
    func appList(for host: StreamHost, at address: String) async throws -> [StreamApp]

    /// Raw box-art PNG for an app. Callers must placeholder-detect (see ArtworkStore).
    func appAsset(for host: StreamHost, at address: String, appID: Int) async throws -> Data

    /// Terminates the running app on the host AND kills active sessions.
    /// This is the "quit game completely" primitive.
    func cancel(for host: StreamHost, at address: String) async throws
}

// MARK: - Stream session lifecycle

/// One live streaming session driven through the Moonlight CLI.
/// Source of truth for remote state is serverinfo polling, NOT the child process
/// (the CLI can hang on GUI error dialogs with meaningless exit codes).
enum SessionPhase: Sendable, Equatable {
    case idle
    case reconciling                 // checking host state before launch
    case waitingForQuit(StreamApp)   // different app running; cancel in flight
    case launching(StreamApp)
    case streaming(StreamApp)
    case ending(StreamApp)           // stream window closed; deciding resume/quit
    case failed(String)
}

/// Events the session manager emits for the UI layer.
enum SessionEvent: Sendable {
    case phaseChanged(SessionPhase)
    case streamProcessExited(cleanly: Bool)
    case hostBecameUnreachable
}

// MARK: - Stream engine seam

/// The platform-agnostic surface of the stream lifecycle machine, extracted so
/// macOS (Process-spawned moonlight-qt helper, `StreamSessionManager`) and iOS
/// (a disabled stub in Phase 1; an in-process engine later) present one
/// interface to `AppState`. `AppState` stores the concrete type per platform,
/// so observation stays exact; this protocol keeps the two implementations in
/// lockstep. See docs/plans/ios-support-plan.md §3.2.
@MainActor
protocol StreamEngine: AnyObject {
    var phase: SessionPhase { get }
    var remoteQuitRequested: Bool { get }
    var onPhaseChange: ((SessionPhase) -> Void)? { get set }
    var onStreamDidStart: ((_ helperPID: pid_t?) -> Void)? { get set }
    var onStreamDidEnd: ((_ cleanly: Bool) -> Void)? { get set }
    func launch(app: StreamApp, on host: StreamHost, settings: StreamSettings) async
    func disconnect()
    func quitCompletely(host: StreamHost) async
    func acknowledgeEnd()
}

// MARK: - Platform chrome seam

/// The OS/window-chrome surface `AppState` needs, abstracted so it never touches
/// AppKit/UIKit directly. macOS wraps `WindowCoordinator` (window activation,
/// hidden Dock, cursor, sleep). iOS flips `isIdleTimerDisabled` and otherwise
/// no-ops — an iOS app is one full-screen scene with no window/activation dance.
/// `pid_t` resolves via Foundation on both platforms. See §3.4.
@MainActor
protocol PlatformChrome: AnyObject {
    /// Keep the display awake during a session (`true`) or release the assertion.
    func preventSleep(_ on: Bool)
    /// Hide the pointer for console/directed input. iOS: no-op (touch).
    func hidePointer()
    /// The stream is coming up. macOS: activate the helper PID. iOS: nil PID.
    func beginStreamPresentation(helperPID: pid_t?)
    /// The stream ended: reclaim the screen (macOS) / pop the stream layer (iOS).
    func endStreamPresentation()
    /// Reclaim the screen only if a presentation is actually outstanding.
    func endStreamPresentationIfActive()
    /// Quit the app. macOS: `NSApplication.shared.terminate`. iOS: no-op (HIG).
    func quitApp()
}

// MARK: - Controller / navigation

enum MoveDirection: Sendable, Equatable {
    case up, down, left, right
}

/// Semantic navigation events produced by controllers and keyboard alike.
/// The UI consumes these; it never touches GCController directly.
enum NavigationEvent: Sendable, Equatable {
    case move(MoveDirection)
    case select          // A / ✕ / Return
    case back            // B / ○ / Escape
    case contextMenu     // X / □ / Space  (tile options)
    case detail          // Y / △ / Tab    (app detail)
    case prevSection     // LB / L1
    case nextSection     // RB / R1
    case settings        // Menu / Options / Cmd-,
    case quitChord       // long-press Menu — quit the remote GAME completely
    case quitApp         // long-press B/Circle on home — quit VibeLight itself
}

/// Which glyph family the UI should render for hints.
enum ControllerGlyphStyle: String, Sendable {
    case xbox, playStation, nintendo, generic, keyboard
}

/// Which input device the user is currently driving. Controller/keyboard is
/// `.directed` (hide the mouse cursor, focus-ring UI); the mouse is `.pointer`
/// (show the cursor, hover UI). The UI swaps live on the last input used.
enum InputMode: Sendable, Equatable {
    case directed, pointer
}

/// Progress of a press-and-hold chord, for the on-screen "keep holding" ring.
struct HoldProgress: Equatable, Sendable {
    enum Kind: Sendable, Equatable { case quitApp, quitGame, disconnectStream }
    var kind: Kind
    var fraction: Double   // 0…1
}

// MARK: - Artwork

/// Resolved artwork for an app tile.
enum TileArtwork: Sendable, Equatable {
    case image(URL)          // real art cached on disk
    case bespoke(BespokeTile)  // no real art — render a designed tile
    case pending             // fetch in flight

    /// Known utility apps get hand-designed tiles rather than SGDB lookups.
    enum BespokeTile: String, Sendable {
        case desktop, steam, playnite, moonDeck, virtualDisplay, generic
    }
}

protocol ArtworkProviding: Sendable {
    /// Resolve artwork for an app, fetching + caching as needed.
    /// Detects the host's placeholder (200 OK with 130x180 box.png,
    /// sha256 d9164ebd069b5f735eb8efc557801778498da37f572ef70e3d35604739e6c613)
    /// and returns .bespoke instead.
    func artwork(for app: StreamApp, host: StreamHost, address: String?) async -> TileArtwork
}
