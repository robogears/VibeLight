#if os(iOS)
import Foundation
import Observation
import AVFoundation
import GameController

/// iOS streaming engine (Phases 3+). Drives an in-process moonlight-common-c
/// connection via `MoonlightSession`, replacing the Phase-1 `DisabledStreamEngine`
/// behind the `StreamEngine` seam — so `AppState` is unchanged.
///
/// Phase 3a (this): fresh `/launch` → `LiStartConnection` with no-op video/audio
/// sinks, surfacing connection stages as `SessionPhase`. This validates the
/// launch/RTSP/crypto path on-device. Phase 3b feeds the decoder into
/// VideoToolbox for actual pixels; Phase 4 adds audio + input.
@MainActor
@Observable
final class InProcessStreamEngine: StreamEngine {

    private(set) var phase: SessionPhase = .idle {
        didSet {
            guard oldValue != phase else { return }
            onPhaseChange?(phase)
        }
    }
    private(set) var remoteQuitRequested = false

    @ObservationIgnored var onPhaseChange: ((SessionPhase) -> Void)?
    @ObservationIgnored var onStreamDidStart: ((_ helperPID: pid_t?) -> Void)?
    @ObservationIgnored var onStreamDidEnd: ((_ cleanly: Bool) -> Void)?

    @ObservationIgnored private let api: HostAPIClient
    @ObservationIgnored private var session: MoonlightSession?
    @ObservationIgnored private var proxy: SessionDelegateProxy?
    @ObservationIgnored private var connectedOnce = false

    /// The layer decoded video renders into. `StreamView` displays it while
    /// `phase == .streaming`.
    @ObservationIgnored let displayLayer = AVSampleBufferDisplayLayer()

    /// The app's controller manager (set by AppState). While streaming, the
    /// engine flips it into stream-passthrough so pads drive the remote game
    /// instead of launcher navigation.
    @ObservationIgnored weak var controllerSource: ControllerManager?

    init(api: HostAPIClient) {
        self.api = api
        displayLayer.videoGravity = .resizeAspect
    }

    func launch(app: StreamApp, on host: StreamHost, settings: StreamSettings) async {
        // Tear down any prior connection FIRST — moonlight-common-c is
        // single-connection, and a second LiStartConnection over a live one
        // double-frees + scrambles the per-session AES keys (observed on-device as
        // a malloc crash + 100% audio-decrypt failures on relaunch).
        if let existing = session {
            existing.stop()
            session = nil
            proxy = nil
        }
        connectedOnce = false
        remoteQuitRequested = false
        showPerfOverlay = settings.performanceOverlay
        phase = .launching(app)
        do {
            // Fresh serverinfo for the working address + host generation/codecs.
            let (info, address) = try await api.serverInfo(for: host)

            // User settings pass through untouched — resolution/fps/bitrate are
            // theirs to choose (a too-hot profile over a relay shows up as FEC
            // starvation in the log, and they can dial it down in Settings).
            let effective = settings

            // Remote-input AES material: rikey = 16 random bytes (hex), rikeyid =
            // a positive 31-bit int whose big-endian bytes seed the IV.
            let key = GameStreamCrypto.randomBytes(16)
            let rikeyId = Int(UInt32.random(in: 1...0x7FFF_FFFF))
            var iv = Data(count: 16)
            iv[0] = UInt8((rikeyId >> 24) & 0xFF); iv[1] = UInt8((rikeyId >> 16) & 0xFF)
            iv[2] = UInt8((rikeyId >> 8) & 0xFF);  iv[3] = UInt8(rikeyId & 0xFF)

            let sessionUrl = try await api.launch(
                app: app, on: host, at: address, settings: effective,
                rikeyHex: key.lowercaseHex, rikeyId: rikeyId,
                extraLaunchParams: MoonlightSession.launchUrlQueryParameters())

            let proxy = SessionDelegateProxy()
            proxy.engine = self
            self.proxy = proxy
            let session = MoonlightSession(
                address: address,
                appVersion: info.appVersion.isEmpty ? "7.1.431.0" : info.appVersion,
                gfeVersion: nil,
                rtspUrl: sessionUrl,
                codecModeSupport: Int32(info.serverCodecModeSupport),
                width: Int32(effective.width), height: Int32(effective.height),
                fps: Int32(effective.fps), bitrateKbps: Int32(effective.bitrateKbps),
                enableHevc: false, enableHdr: false,   // H.264 for the first connect
                aesKey: key, aesIv: iv)
            session.delegate = proxy
            displayLayer.flush()
            session.attach(displayLayer)
            self.session = session
            self.launchingApp = app
            session.start()
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription
                            ?? "Couldn't start \u{201C}\(app.name)\u{201D} on \(host.name).")
        }
    }

    func disconnect() {
        setStreamInput(active: false)
        setStatsHUD(active: false)
        session?.stop()
        session = nil
        proxy = nil
        // stop() interrupts the connection but its termination callback can no
        // longer reach us (session/proxy just released) — transition the phase
        // HERE or the UI stays stuck on a dead, frozen stream. (On-device bug:
        // the X button "did nothing" — the session died but .streaming never
        // ended.)
        switch phase {
        case .streaming(let app), .launching(let app):
            phase = .ending(app)
            onStreamDidEnd?(true)
        default:
            break
        }
    }

    // MARK: - Controller → stream forwarding

    /// Installs (or removes) the stream-passthrough on the controller manager.
    /// While active, every pad state change becomes a LiSendMultiControllerEvent
    /// snapshot and the launcher UI hears nothing (no focus moves, no haptics).
    private func setStreamInput(active: Bool) {
        guard let cm = controllerSource else { return }
        if active {
            cm.streamForwarder = { [weak self] pad in self?.forward(pad) }
        } else if cm.streamForwarder != nil {
            cm.streamForwarder = nil
        }
    }

    private func forward(_ pad: GCExtendedGamepad) {
        guard let session else { return }
        var flags: Int32 = 0
        if pad.buttonA.isPressed { flags |= 0x1000 }                      // A
        if pad.buttonB.isPressed { flags |= 0x2000 }                      // B
        if pad.buttonX.isPressed { flags |= 0x4000 }                      // X
        if pad.buttonY.isPressed { flags |= 0x8000 }                      // Y
        if pad.dpad.up.isPressed { flags |= 0x0001 }
        if pad.dpad.down.isPressed { flags |= 0x0002 }
        if pad.dpad.left.isPressed { flags |= 0x0004 }
        if pad.dpad.right.isPressed { flags |= 0x0008 }
        if pad.leftShoulder.isPressed { flags |= 0x0100 }                 // LB
        if pad.rightShoulder.isPressed { flags |= 0x0200 }                // RB
        if pad.buttonMenu.isPressed { flags |= 0x0010 }                   // START
        if pad.buttonOptions?.isPressed == true { flags |= 0x0020 }       // BACK
        if pad.buttonHome?.isPressed == true { flags |= 0x0400 }          // GUIDE
        if pad.leftThumbstickButton?.isPressed == true { flags |= 0x0040 }
        if pad.rightThumbstickButton?.isPressed == true { flags |= 0x0080 }

        // Standard Moonlight quit chord: Start+Select+LB+RB together ends the
        // stream from the couch. Release everything host-side first so the game
        // isn't left with four buttons stuck down.
        let quitChord: Int32 = 0x0010 | 0x0020 | 0x0100 | 0x0200
        if flags & quitChord == quitChord {
            session.sendControllerButtonFlags(0, leftTrigger: 0, rightTrigger: 0,
                                              leftStickX: 0, leftStickY: 0,
                                              rightStickX: 0, rightStickY: 0)
            disconnect()
            return
        }

        func axis(_ v: Float) -> Int16 { Int16(clamping: Int(v * 32767)) }
        session.sendControllerButtonFlags(
            flags,
            leftTrigger: UInt8(min(max(pad.leftTrigger.value, 0), 1) * 255),
            rightTrigger: UInt8(min(max(pad.rightTrigger.value, 0), 1) * 255),
            leftStickX: axis(pad.leftThumbstick.xAxis.value),
            leftStickY: axis(pad.leftThumbstick.yAxis.value),
            rightStickX: axis(pad.rightThumbstick.xAxis.value),
            rightStickY: axis(pad.rightThumbstick.yAxis.value))
    }

    // MARK: - Performance stats

    /// One-line perf readout for the stream HUD (nil = hidden). Driven by a 1 Hz
    /// task while streaming with the "Performance Stats" setting on.
    private(set) var perfStats: String?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var showPerfOverlay = false

    private func setStatsHUD(active: Bool) {
        statsTask?.cancel()
        statsTask = nil
        perfStats = nil
        guard active, showPerfOverlay, let session else { return }
        statsTask = Task { [weak self, weak session] in
            var lastFrames: Int32 = 0
            var lastTime = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let session else { return }
                let frames = session.framesEnqueuedCount()
                let now = ContinuousClock.now
                let dt = Double(lastTime.duration(to: now).components.seconds)
                    + Double(lastTime.duration(to: now).components.attoseconds) / 1e18
                let fps = dt > 0 ? Double(frames - lastFrames) / dt : 0
                lastFrames = frames; lastTime = now
                var rtt: UInt32 = 0, variance: UInt32 = 0
                let haveRtt = session.getEstimatedRtt(&rtt, variance: &variance)
                var line = String(format: "%dx%d  %.0f fps", session.videoWidth(), session.videoHeight(), fps)
                if haveRtt { line += String(format: "  RTT %d ms", rtt) }
                self.perfStats = line
            }
        }
    }

    func quitCompletely(host: StreamHost) async {
        remoteQuitRequested = true
        setStreamInput(active: false)
        setStatsHUD(active: false)
        session?.stop()
        session = nil
        do {
            let (_, address) = try await api.serverInfo(for: host)
            try await api.cancel(for: host, at: address)
        } catch {
            // Best-effort — the host may already be idle.
        }
        if let app = launchingApp { phase = .ending(app) } else { phase = .idle }
    }

    func acknowledgeEnd() {
        switch phase {
        case .ending, .failed: phase = .idle
        default: break
        }
    }

    // MARK: - MoonlightSession stage handling (called on the main actor by the proxy)

    @ObservationIgnored private var launchingApp: StreamApp?

    fileprivate func handleStage(_ stage: MoonlightStage) {
        guard let app = launchingApp else { return }
        // "Connected" (or reaching the video-start stage) means the stream is live.
        if !connectedOnce, stage == .connected || stage.rawValue >= MoonlightStage.videoStart.rawValue {
            connectedOnce = true
            phase = .streaming(app)
            setStreamInput(active: true)
            setStatsHUD(active: true)
            onStreamDidStart?(nil)
        }
    }

    fileprivate func handleFail(stage: MoonlightStage, error: Int) {
        setStreamInput(active: false)
        setStatsHUD(active: false)
        phase = .failed("Stream failed at stage \(stage.rawValue) (error \(error)). Make sure the host is awake and not busy.")
    }

    fileprivate func handleTerminated(error: Int) {
        setStreamInput(active: false)
        setStatsHUD(active: false)
        let cleanly = (error == 0) || remoteQuitRequested
        if let app = launchingApp { phase = .ending(app) } else { phase = .idle }
        onStreamDidEnd?(cleanly)
    }
}

/// ObjC bridge for MoonlightSession's delegate (an @objc protocol needs an
/// NSObject). Callbacks arrive on the main queue; forward to the @MainActor engine.
private final class SessionDelegateProxy: NSObject, MoonlightSessionDelegate {
    weak var engine: InProcessStreamEngine?

    func session(_ session: MoonlightSession, didReach stage: MoonlightStage) {
        Task { @MainActor [weak engine] in engine?.handleStage(stage) }
    }
    func session(_ session: MoonlightSession, didFailAt stage: MoonlightStage, error errorCode: Int32) {
        Task { @MainActor [weak engine] in engine?.handleFail(stage: stage, error: Int(errorCode)) }
    }
    func session(_ session: MoonlightSession, didTerminateWithError errorCode: Int32) {
        Task { @MainActor [weak engine] in engine?.handleTerminated(error: Int(errorCode)) }
    }
}
#endif
