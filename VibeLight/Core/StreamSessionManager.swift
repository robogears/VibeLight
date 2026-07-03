import Foundation
import Observation

/// The stream lifecycle state machine: drives the Moonlight CLI child process
/// and reconciles it against host truth.
///
/// Truth model (docs/research/moonlight-cli.md): `/serverinfo` polling is the
/// ONLY reliable signal for remote state. The CLI child is merely a liveness
/// signal — its error paths pop modal GUI dialogs and then exit 0, and the
/// `quit` action blocks FOREVER on failure. Every watchdog in this file exists
/// because some CLI failure mode hangs on a dialog instead of exiting.
///
/// Activation handoff (NSApp activation policy, hiding/showing the launcher
/// window) is deliberately NOT handled here — the integrator wires it through
/// `onStreamDidStart` / `onStreamDidEnd` so this class stays AppKit-free.
@MainActor @Observable
final class StreamSessionManager {

    // MARK: - Public surface

    /// Current position in the session lifecycle. Observable so the UI can
    /// render overlays (reconciling spinner, "quitting X…", failure sheets).
    /// `onPhaseChange` fires on every transition because several of them
    /// happen from detached work (watchdogs, termination handlers) long after
    /// any UI-initiated call has returned — one-shot checks WILL miss them.
    private(set) var phase: SessionPhase = .idle {
        didSet {
            guard oldValue != phase else { return }
            onPhaseChange?(phase)
        }
    }

    /// Fired on every phase transition (see `phase`). The integrator uses this
    /// to surface `.failed` — which can arrive asynchronously via the startup
    /// watchdog or the child's termination handler.
    @ObservationIgnored var onPhaseChange: ((SessionPhase) -> Void)?

    /// True from the moment `quitCompletely` commits to killing the remote app
    /// until the next launch/acknowledge — lets the UI suppress the
    /// "still running on the host" ended-card when the user explicitly quit.
    @ObservationIgnored private(set) var remoteQuitRequested = false

    /// Path of the `/tmp/Moonlight-<epoch>.log` file the CLI announced on
    /// stderr for the current/last stream. Kept for diagnostics: CLI status
    /// text goes to stdout/stderr, but connection progress and errors land
    /// only in this Qt log file.
    private(set) var moonlightLogPath: String?

    /// Fired once, the first time the host reports busy after our launch —
    /// the moment the integrator should hand focus to the stream (hide the
    /// launcher window, adjust activation policy).
    @ObservationIgnored var onStreamDidStart: (() -> Void)?

    /// Fired when the local stream process ends and the phase moves to
    /// `.ending`. `cleanly` is best-effort only: `true` for intentional local
    /// termination (disconnect/quit) or a plain exit-0; `false` otherwise.
    /// It must never gate correctness — exit codes lie (error dialogs exit 0).
    @ObservationIgnored var onStreamDidEnd: ((_ cleanly: Bool) -> Void)?

    init(
        api: any HostAPIProviding,
        moonlightBinary: URL = StreamSessionManager.resolveStreamBinary()
    ) {
        self.api = api
        self.moonlightBinary = moonlightBinary
    }

    /// Prefers our chromeless headless helper over stock Moonlight, checking
    /// (1) the copy embedded in VibeLight.app (production), then (2) the local
    /// fork dev build, then (3) stock Moonlight as a last resort. The helper
    /// speaks the `@VL` status protocol and hides its own UI; stock Moonlight
    /// still works but shows chrome and can hang on dialogs.
    static func resolveStreamBinary() -> URL {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/StreamHelper.app/Contents/MacOS/Moonlight"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/vibelight-moonlight-helper/app/Moonlight.app/Contents/MacOS/Moonlight"),
            URL(fileURLWithPath: "/Applications/Moonlight.app/Contents/MacOS/Moonlight"),
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0.path) } ?? candidates.last!
    }

    // MARK: - Private state

    private let api: any HostAPIProviding
    private let moonlightBinary: URL

    /// Bumped by every `launch()` (and `acknowledgeEnd()`): stale async work
    /// checks its captured generation before touching state, so a superseded
    /// launch can never clobber the session that replaced it (invariant 6).
    @ObservationIgnored private var generation: UInt64 = 0

    @ObservationIgnored private var streamProcess: Process?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    @ObservationIgnored private var streamPollTask: Task<Void, Never>?
    @ObservationIgnored private var stderrTask: Task<Void, Never>?
    /// Reads the helper's `@VL` status protocol on stdout.
    @ObservationIgnored private var stdoutTask: Task<Void, Never>?

    /// App/generation of the live session, so the `@VL STARTED` handler (which
    /// arrives on stdout, not from a captured closure) can enter the streaming
    /// phase and start the truth-poll for the right session.
    @ObservationIgnored private var currentApp: StreamApp?
    @ObservationIgnored private var currentGen: UInt64 = 0

    /// Last `@VL FAILED reason="…"` from the helper — a precise, human-readable
    /// failure cause that beats scraping stderr.
    @ObservationIgnored private var lastStatusFailure: String?

    /// Last stderr lines from the child, for failure messages. Best effort:
    /// the reader may still be draining when the termination handler fires.
    @ObservationIgnored private var stderrTail: [String] = []

    /// Set before WE terminate the child (disconnect, quit, remote-ended
    /// reconcile) so the termination handler can distinguish an intentional
    /// SIGTERM from the child dying on its own.
    @ObservationIgnored private var expectingTermination = false

    /// Host/address of the live session, so `quitCompletely` can reuse the
    /// address that already proved reachable instead of re-probing.
    @ObservationIgnored private var currentHost: StreamHost?
    @ObservationIgnored private var currentAddress: String?

    /// All the timeouts that make the CLI's hang-on-dialog failure modes
    /// survivable. Values follow docs/research/moonlight-cli.md.
    private enum Timing {
        /// Reconcile: /cancel has fired; how often to re-check serverinfo.
        static let quitPoll: Duration = .seconds(1)
        /// Reconcile: host must report free within this or the launch fails.
        static let quitTimeout: Duration = .seconds(15)
        /// Startup: serverinfo re-check cadence while the CLI connects.
        static let startupPoll: Duration = .seconds(2)
        /// Startup: covers the CLI's 30 s computer seek + 10 s app seek with
        /// margin. Past this, an alive-but-not-busy child means a hung dialog.
        static let startupTimeout: Duration = .seconds(45)
        /// Streaming: serverinfo cadence while the stream is (allegedly) up.
        static let streamingPoll: Duration = .seconds(10)
        /// How long a SIGTERM'd child gets before escalating to SIGKILL when
        /// the host already says the session is gone.
        static let terminateEscalation: Duration = .seconds(5)
        /// Fallback `Moonlight quit`: on failure it never exits (modal error
        /// dialog), so it gets this long and then SIGKILL. NEVER trust it.
        static let cliQuitTimeout: Duration = .seconds(15)
    }

    /// Failure messages only need the last few stderr lines to be useful.
    private static let maxStderrTailLines = 10

    // MARK: - Launch

    /// Runs the full pre-launch reconcile + atomic launch sequence
    /// (invariants 2 and 5), then arms the startup watchdog. Calling this
    /// while a session is active cleanly tears the old one down first.
    func launch(app: StreamApp, on host: StreamHost, settings: StreamSettings) async {
        generation &+= 1
        let gen = generation
        tearDownActiveSession()
        remoteQuitRequested = false

        phase = .reconciling
        do {
            // 1. Reconcile against live host state (invariant 5).
            var (info, address) = try await api.serverInfo(for: host)
            guard isCurrent(gen) else { return }

            // Resume path: host already busy with OUR app before the CLI even
            // connects, so "host reports busy" proves nothing about our child.
            // The watchdog gets a grace period before declaring success.
            let isResume = info.state == .busy && matchesRunningApp(info: info, app: app)

            if info.state == .busy && !matchesRunningApp(info: info, app: app) {
                // Different app holds the host: /cancel it and wait for free.
                // (Same app running falls through — the CLI stream resumes it.)
                phase = .waitingForQuit(runningApp(from: info, on: host))
                try await api.cancel(for: host, at: address)
                guard isCurrent(gen) else { return }
                guard let freedAddress = try await pollUntilFree(host: host, generation: gen) else {
                    if isCurrent(gen) {
                        phase = .failed("The host did not stop the running app within 15 seconds. Try again, or quit it from the host.")
                    }
                    return
                }
                address = freedAddress
            }

            // 2. Atomic launch (invariant 2): fresh app list, resolve by
            // stable identity, then hand the CLI *that response's* raw name
            // verbatim — zero-width padding intact, because padding width
            // shifts whenever the app count crosses a power of two.
            let apps = try await api.appList(for: host, at: address)
            guard isCurrent(gen) else { return }
            guard let target = resolve(app: app, in: apps) else {
                phase = .failed("\u{201C}\(app.name)\u{201D} is no longer available on \(host.name). The library may be stale — refresh and try again.")
                return
            }

            currentApp = target
            currentGen = gen

            // 3. Spawn the CLI. Process argv passes the raw name as a single
            // argument — no shell, so no quoting/escaping hazards.
            phase = .launching(target)
            currentHost = host
            currentAddress = address
            try startStreamProcess(
                address: address, rawAppName: target.rawName,
                settings: settings, generation: gen
            )

            // 4. The child can hang on a modal error dialog instead of
            // exiting, so its startup is guarded by our own watchdog.
            startStartupWatchdog(
                app: target, host: host, generation: gen,
                declareAfter: isResume ? .seconds(6) : .zero
            )
        } catch {
            guard isCurrent(gen) else { return }
            if error is CancellationError {
                // The enclosing task died (e.g. SwiftUI view teardown). If we
                // never got to spawning, don't strand a pre-launch phase; if
                // the child is up, the unstructured watchdogs carry on.
                switch phase {
                case .reconciling, .waitingForQuit: phase = .idle
                default: break
                }
                return
            }
            phase = .failed(failureMessage(for: error))
        }
    }

    // MARK: - Disconnect (keep playing)

    /// Ends the LOCAL stream only, leaving the remote game running. This is
    /// BY DESIGN how "disconnect but keep playing" works: SIGTERM kills just
    /// the Moonlight client process, the host keeps the app alive, and the
    /// session is resumable later (invariant 6). Full remote termination goes
    /// through `quitCompletely` exclusively.
    func disconnect() {
        guard let process = streamProcess, process.isRunning else { return }
        expectingTermination = true
        process.terminate() // SIGTERM; the termination handler drives .ending
    }

    // MARK: - Quit completely

    /// Terminates the remote app AND its sessions — the headline "quit game
    /// completely" action.
    ///
    /// Primary path: `GET /cancel` over mTLS (invariant 3) — fast, headless,
    /// and its XML status is a real answer. Only if the API call fails do we
    /// fall back to the CLI `quit` action, which on ANY failure shows a modal
    /// error dialog and blocks forever with a meaningless exit code — so it
    /// runs under a 15 s watchdog and gets SIGKILLed on expiry. NEVER trust it.
    func quitCompletely(host: StreamHost) async {
        // Generation-guarded across every await: a NEW launch racing this
        // quit must never have its fresh child terminated by stale quit work.
        let gen = generation
        remoteQuitRequested = true
        do {
            let address: String
            if let currentAddress, currentHost?.id == host.id {
                address = currentAddress
            } else {
                address = try await api.serverInfo(for: host).address
            }
            guard isCurrent(gen) else { return }
            try await api.cancel(for: host, at: address)
            guard isCurrent(gen) else { return }
            // The remote side is gone. End the local client deterministically
            // instead of waiting for it to notice the dropped session (which
            // can surface a "connection terminated" dialog and hang).
            endLocalStreamIfRunning()
        } catch {
            if error is CancellationError { return }
            guard isCurrent(gen) else { return }
            let fallbackSucceeded = await runCLIQuitFallback(host: host)
            guard isCurrent(gen) else { return }
            if fallbackSucceeded {
                endLocalStreamIfRunning()
            } else {
                // The headline destructive action must NEVER fail silently.
                remoteQuitRequested = false
                phase = .failed("Could not quit the game on \(host.name): \(failureMessage(for: error)) The host may need attention directly.")
            }
        }
    }

    // MARK: - End acknowledgement

    /// The UI calls this after the user resolves an `.ending` (resume/quit
    /// decision) or dismisses a `.failed` message; the machine returns to
    /// `.idle` and stale background work is invalidated.
    func acknowledgeEnd() {
        switch phase {
        case .ending, .failed:
            generation &+= 1
            tearDownActiveSession()
            remoteQuitRequested = false
            phase = .idle
        default:
            break
        }
    }

    // MARK: - Reconcile helpers

    /// Whether the host's running game is the app we were asked to launch.
    /// UUID (Vibepollo/Apollo stable identity) wins when both sides have one;
    /// the CRC32-derived ID is the fallback.
    private func matchesRunningApp(info: ServerInfo, app: StreamApp) -> Bool {
        if let running = info.currentGameUUID, let target = app.uuid {
            return running.caseInsensitiveCompare(target) == .orderedSame
        }
        return info.runningAppID == app.id
    }

    /// Best-effort identification of what the host is currently running, for
    /// the `.waitingForQuit` phase. Falls back to a synthetic entry when the
    /// cached library doesn't know the ID (stale cache, hidden app).
    private func runningApp(from info: ServerInfo, on host: StreamHost) -> StreamApp {
        if let uuid = info.currentGameUUID,
           let match = host.apps.first(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }) {
            return match
        }
        if let match = host.apps.first(where: { $0.id == info.currentGameID }) {
            return match
        }
        return StreamApp(
            id: info.currentGameID, rawName: "Unknown App",
            uuid: info.currentGameUUID, idx: nil,
            isHDRSupported: false, isHidden: false
        )
    }

    /// After /cancel: polls serverinfo until the host reports free. Returns
    /// the address that answered, or nil on timeout/supersession.
    private func pollUntilFree(host: StreamHost, generation gen: UInt64) async throws -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Timing.quitTimeout)
        while clock.now < deadline {
            try await Task.sleep(for: Timing.quitPoll)
            guard isCurrent(gen) else { return nil }
            let (info, address) = try await api.serverInfo(for: host)
            guard isCurrent(gen) else { return nil }
            if info.state != .busy { return address }
        }
        return nil
    }

    /// Resolves the launch target inside a FRESH app list response. UUID is
    /// preferred (stable across renames); ID is the fallback. A miss means
    /// our library is stale and launching would hit the wrong app.
    private func resolve(app: StreamApp, in apps: [StreamApp]) -> StreamApp? {
        if let uuid = app.uuid,
           let match = apps.first(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }) {
            return match
        }
        return apps.first { $0.id == app.id }
    }

    // MARK: - Child process

    private func streamArguments(address: String, rawAppName: String, settings: StreamSettings) -> [String] {
        var args = [
            "stream", address, rawAppName,
            "--resolution", "\(settings.width)x\(settings.height)",
            "--fps", String(settings.fps),
            // Always pass --bitrate: omitting it makes the CLI recompute a
            // default from resolution/fps instead of honoring user settings.
            "--bitrate", String(settings.bitrateKbps),
            "--display-mode", "fullscreen",
            // Ending the local session must never quit the remote app — the
            // full quit is exclusively quitCompletely()'s /cancel (invariant 6).
            "--no-quit-after",
        ]
        args.append(settings.hdr ? "--hdr" : "--no-hdr")
        args.append(settings.vsync ? "--vsync" : "--no-vsync")
        args.append(settings.framePacing ? "--frame-pacing" : "--no-frame-pacing")
        return args
    }

    private func startStreamProcess(
        address: String, rawAppName: String,
        settings: StreamSettings, generation gen: UInt64
    ) throws {
        let process = Process()
        process.executableURL = moonlightBinary
        process.arguments = streamArguments(address: address, rawAppName: rawAppName, settings: settings)
        process.standardInput = FileHandle.nullDevice

        // Ask the fork to run headless (chromeless, clean signals). Stock
        // Moonlight ignores the var, so this is safe even on the fallback path.
        var environment = ProcessInfo.processInfo.environment
        environment["VIBELIGHT_HEADLESS"] = "1"
        process.environment = environment

        // stdout carries the helper's `@VL` status protocol — the authoritative
        // start/fail/end signal (replaces log-scraping + serverinfo guessing).
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        // stderr carries the /tmp/Moonlight-*.log path (diagnostics only).
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        // Termination handlers arrive on an arbitrary queue: extract only
        // Sendable values there, then hop to the main actor. The process is
        // identified by ObjectIdentifier so a stale handler (from a session
        // that was superseded) can never touch the current one's state.
        process.terminationHandler = { [weak self] proc in
            let id = ObjectIdentifier(proc)
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            Task { @MainActor in
                self?.streamProcessDidTerminate(id: id, status: status, reason: reason)
            }
        }

        try process.run()
        streamProcess = process
        stderrTail = []
        moonlightLogPath = nil
        lastStatusFailure = nil
        expectingTermination = false

        let outHandle = stdoutPipe.fileHandleForReading
        stdoutTask = Task { [weak self] in
            do {
                for try await line in outHandle.bytes.lines {
                    guard let self, self.isCurrent(gen) else { return }
                    self.handleStatusLine(line)
                }
            } catch {}
        }

        let handle = stderrPipe.fileHandleForReading
        stderrTask = Task { [weak self] in
            // Async bytes end at EOF when the child dies; reader failures are
            // non-fatal because stderr is diagnostics only.
            do {
                for try await line in handle.bytes.lines {
                    guard let self, self.isCurrent(gen) else { return }
                    self.recordStderr(line: line)
                }
            } catch {}
        }
    }

    /// Handles one line of the helper's `@VL` status protocol. `STARTED` is the
    /// authoritative "stream is live" signal (faster and more accurate than
    /// serverinfo polling); `FAILED` records a precise cause. `ENDED`/`BYE` are
    /// informational — the process exit that follows drives `.ending`/`.failed`
    /// through the termination handler.
    private func handleStatusLine(_ line: String) {
        guard line.hasPrefix("@VL ") else { return }
        let body = line.dropFirst(4)
        if body.hasPrefix("STARTED") {
            if let app = currentApp, let host = currentHost {
                enterStreaming(app: app, host: host, generation: currentGen)
            }
        } else if body.hasPrefix("FAILED") {
            if let reason = Self.parseField("reason", in: String(body)) {
                lastStatusFailure = reason
            }
        }
    }

    /// Extracts a `key="value"` field from an `@VL` status line.
    private static func parseField(_ key: String, in line: String) -> String? {
        guard let start = line.range(of: "\(key)=\"") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<end])
        return value.isEmpty ? nil : value
    }

    /// Single funnel for entering the streaming phase, from either the helper's
    /// `@VL STARTED` (primary) or the serverinfo watchdog (fallback). Idempotent
    /// — whichever fires first wins; the guard makes the loser a no-op.
    private func enterStreaming(app: StreamApp, host: StreamHost, generation gen: UInt64) {
        guard isCurrent(gen), case .launching = phase else { return }
        phase = .streaming(app)
        onStreamDidStart?()
        startStreamingPoll(host: host, generation: gen)
    }

    private func recordStderr(line: String) {
        if moonlightLogPath == nil,
           let range = line.range(of: "Redirecting log output to ") {
            moonlightLogPath = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        stderrTail.append(line)
        if stderrTail.count > Self.maxStderrTailLines {
            stderrTail.removeFirst(stderrTail.count - Self.maxStderrTailLines)
        }
    }

    /// Main-actor landing point for child exit, whatever the cause. The phase
    /// decides the meaning: exit during `.launching` is a startup failure
    /// (unless we asked for it), exit during `.streaming` moves to `.ending`.
    private func streamProcessDidTerminate(id: ObjectIdentifier, status: Int32, reason: Process.TerminationReason) {
        guard let process = streamProcess, ObjectIdentifier(process) == id else {
            return // stale handler from a superseded session
        }
        streamProcess = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        streamPollTask?.cancel()
        streamPollTask = nil

        // Weak signal only: plain exit 0 also happens after dismissed error
        // dialogs, so this never gates any state decision.
        let exitedCleanly = reason == .exit && status == 0
        let intentional = expectingTermination
        expectingTermination = false

        switch phase {
        case .launching(let app):
            if intentional {
                // User disconnected/quit before the stream came up.
                phase = .ending(app)
                onStreamDidEnd?(true)
            } else {
                // Exited before the host ever reported busy: real failure.
                // No onStreamDidEnd — the stream never started, so the
                // integrator never handed activation away.
                phase = .failed(startupFailureMessage())
            }
        case .streaming(let app):
            phase = .ending(app)
            onStreamDidEnd?(intentional || exitedCleanly)
        default:
            break // watchdog or teardown already resolved this session
        }

        stdoutTask?.cancel()
        stdoutTask = nil
        stderrTask?.cancel()
        stderrTask = nil
    }

    // MARK: - Watchdogs

    /// Startup guard: the host reporting busy WITH OUR APP is the success
    /// signal — a bare `busy` could be a foreign client's game. On the resume
    /// path the host is busy with our app before the CLI even connects, so
    /// `declareAfter` delays the verdict until the child has had time to fail
    /// fast. A child still alive at the deadline without qualifying is stuck
    /// on a modal error dialog and gets SIGKILLed.
    private func startStartupWatchdog(
        app: StreamApp, host: StreamHost, generation gen: UInt64,
        declareAfter: Duration = .zero
    ) {
        watchdogTask = Task { [weak self] in
            let clock = ContinuousClock()
            let started = clock.now
            let deadline = started.advanced(by: Timing.startupTimeout)
            let earliestDeclare = started.advanced(by: declareAfter)
            while !Task.isCancelled {
                try? await Task.sleep(for: Timing.startupPoll)
                guard !Task.isCancelled, let self else { return }
                guard self.isCurrent(gen), case .launching = self.phase else { return }

                if let info = try? await self.api.serverInfo(for: host).info {
                    guard self.isCurrent(gen), case .launching = self.phase else { return }
                    if info.state == .busy,
                       self.matchesRunningApp(info: info, app: app),
                       clock.now >= earliestDeclare,
                       self.streamProcess?.isRunning == true {
                        // Fallback path: the helper's `@VL STARTED` usually
                        // beats us here, but stock Moonlight (no `@VL`) relies
                        // on this. enterStreaming is idempotent.
                        self.enterStreaming(app: app, host: host, generation: gen)
                        return
                    }
                }
                guard self.isCurrent(gen), case .launching = self.phase else { return }

                if clock.now >= deadline {
                    guard let process = self.streamProcess, process.isRunning else {
                        return // exit already in flight; the termination handler owns the outcome
                    }
                    // Set the phase BEFORE killing so the termination handler
                    // (which fires for the SIGKILL) sees .failed and only
                    // cleans up instead of re-deciding the outcome.
                    self.phase = .failed(self.hungStartupMessage())
                    kill(process.processIdentifier, SIGKILL)
                    return
                }
            }
        }
    }

    /// Steady-state guard: serverinfo every 10 s is the truth (invariant 4).
    /// If the host reports free while our child still runs, the session ended
    /// remotely — reconcile by terminating the child (SIGTERM, then SIGKILL
    /// if it lingers on a "connection terminated" dialog).
    private func startStreamingPoll(host: StreamHost, generation gen: UInt64) {
        streamPollTask = Task { [weak self] in
            let clock = ContinuousClock()
            var remoteFreeSince: ContinuousClock.Instant?
            while !Task.isCancelled {
                try? await Task.sleep(for: Timing.streamingPoll)
                guard !Task.isCancelled, let self else { return }
                guard self.isCurrent(gen), case .streaming = self.phase else { return }

                // Transient poll failures (sleepy host, blip) are ignored:
                // the child's liveness still covers us between successes.
                guard let info = try? await self.api.serverInfo(for: host).info else { continue }
                guard self.isCurrent(gen), case .streaming = self.phase else { return }

                if info.state == .busy {
                    remoteFreeSince = nil
                    continue
                }
                guard let process = self.streamProcess, process.isRunning else {
                    continue // exit in flight; termination handler will land
                }
                if let since = remoteFreeSince {
                    if since.duration(to: clock.now) >= Timing.terminateEscalation {
                        kill(process.processIdentifier, SIGKILL) // handler still drives .ending
                    }
                } else {
                    remoteFreeSince = clock.now
                    self.expectingTermination = true
                    process.terminate()
                }
            }
        }
    }

    // MARK: - CLI quit fallback

    /// Last resort when the /cancel API failed. The CLI resolves saved hosts
    /// case-insensitively by UUID and tries every address Moonlight knows, so
    /// the UUID beats a single address here — we only reach this path when
    /// the API address just failed us. Returns whether the quit is credible
    /// (prompt exit 0 — the ONE case where the CLI's exit code means success).
    private func runCLIQuitFallback(host: StreamHost) async -> Bool {
        let process = Process()
        process.executableURL = moonlightBinary
        process.arguments = ["quit", host.id]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Timing.cliQuitTimeout)
        while process.isRunning && clock.now < deadline {
            if Task.isCancelled { break } // fail-safe: never leave a hung quit GUI behind
            try? await Task.sleep(for: .milliseconds(250))
        }
        if process.isRunning {
            // Hung on its modal error dialog — the documented failure mode.
            kill(process.processIdentifier, SIGKILL)
            return false
        }
        return process.terminationStatus == 0
    }

    // MARK: - Teardown

    /// Kills the remote quit's local counterpart deterministically after a
    /// successful remote termination, instead of waiting for the client to
    /// notice its session vanished.
    private func endLocalStreamIfRunning() {
        guard let process = streamProcess, process.isRunning else { return }
        expectingTermination = true
        process.terminate()
    }

    /// Invalidates every piece of the active session so a new launch starts
    /// from a blank slate. Clearing `streamProcess` FIRST detaches the old
    /// termination handler (its identity check fails), so the old child's
    /// exit can't mutate the phases of the session replacing it.
    private func tearDownActiveSession() {
        watchdogTask?.cancel()
        watchdogTask = nil
        streamPollTask?.cancel()
        streamPollTask = nil
        stdoutTask?.cancel()
        stdoutTask = nil
        stderrTask?.cancel()
        stderrTask = nil
        if let process = streamProcess {
            streamProcess = nil
            if process.isRunning {
                process.terminate() // local only; any remote game keeps running
            }
        }
        expectingTermination = false
        stderrTail = []
        currentHost = nil
        currentAddress = nil
        currentApp = nil
    }

    // MARK: - Messages

    private func startupFailureMessage() -> String {
        // Prefer the helper's precise `@VL FAILED reason="…"` when we have it.
        if let lastStatusFailure {
            return lastStatusFailure
        }
        var message = "The stream exited before it started."
        let tail = stderrTail
            .filter { !$0.isEmpty && !$0.hasPrefix("Redirecting log output to ") }
            .suffix(5)
            .joined(separator: "\n")
        if !tail.isEmpty { message += "\n\(tail)" }
        if let moonlightLogPath { message += "\nLog: \(moonlightLogPath)" }
        return message
    }

    private func hungStartupMessage() -> String {
        var message = "The stream did not start within 45 seconds — Moonlight was likely stuck on an error dialog and has been force-quit."
        if let moonlightLogPath { message += " See \(moonlightLogPath) for details." }
        return message
    }

    private func failureMessage(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func isCurrent(_ gen: UInt64) -> Bool { gen == generation }
}
