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
        // Without this, game audio is permanently silent after a phone call,
        // Siri, alarm, or timer: the interruption stops the audio unit and
        // nothing restarts it. Registered once for the engine's lifetime.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                NSLog("[VibeLight] audio session reactivation after interruption failed: \(error.localizedDescription)")
            }
            MoonlightSession.resumeAudio()
        }
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
        touchControlsEnabled = settings.touchControls
        phase = .launching(app)
        // Game audio must play regardless of the silent switch, and keep going
        // if Control Center pauses other audio. Failures here are the root of
        // "stream has no sound" reports — log them or they're undebuggable.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("[VibeLight] audio session setup failed: \(error.localizedDescription)")
        }
        do {
            // Fresh serverinfo for the working address + host generation/codecs.
            let (info, address) = try await api.serverInfo(for: host)

            // User settings pass through untouched — resolution/fps/bitrate are
            // theirs to choose (a too-hot profile over a relay shows up as FEC
            // starvation in the log, and they can dial it down in Settings).
            var effective = settings
            // The stream is H.264 SDR until iOS HEVC/HDR ships — advertising
            // hdrMode=1 in /launch while negotiating an SDR stream makes hosts
            // engage HDR for a client that can't display it.
            effective.hdr = false

            // Remote-input AES material: rikey = 16 random bytes (hex), rikeyid =
            // a positive 31-bit int whose big-endian bytes seed the IV.
            let key = GameStreamCrypto.randomBytes(16)
            let rikeyId = Int(UInt32.random(in: 1...0x7FFF_FFFF))
            var iv = Data(count: 16)
            iv[0] = UInt8((rikeyId >> 24) & 0xFF); iv[1] = UInt8((rikeyId >> 16) & 0xFF)
            iv[2] = UInt8((rikeyId >> 8) & 0xFF);  iv[3] = UInt8(rikeyId & 0xFF)

            // Host already streaming → /resume (Sunshine rejects /launch while
            // any session is active; a DIFFERENT running app is reconciled
            // upstream in AppState before we're called).
            let extraParams = MoonlightSession.launchUrlQueryParameters()
            let sessionUrl: String?
            if info.currentGameID != 0 {
                sessionUrl = try await api.resume(
                    app: app, on: host, at: address, settings: effective,
                    rikeyHex: key.lowercaseHex, rikeyId: rikeyId, extraLaunchParams: extraParams)
            } else {
                sessionUrl = try await api.launch(
                    app: app, on: host, at: address, settings: effective,
                    rikeyHex: key.lowercaseHex, rikeyId: rikeyId, extraLaunchParams: extraParams)
            }

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

    // MARK: - Touch → stream forwarding

    /// Whether direct-touch control is on for the current stream
    /// (Settings ▸ Input ▸ Touch Control; captured at launch).
    @ObservationIgnored private var touchControlsEnabled = true

    /// Forwards a touch from the stream view. `location` is in view coordinates;
    /// the engine maps it into the aspect-fit video rect (mirroring
    /// `.resizeAspect` letterboxing) and normalizes to 0…1 for the host.
    func sendTouch(_ phase: MoonlightTouchPhase, pointerId: UInt32,
                   location: CGPoint, viewSize: CGSize) {
        guard touchControlsEnabled, let session else { return }
        let vw = CGFloat(max(session.videoWidth(), 1))
        let vh = CGFloat(max(session.videoHeight(), 1))
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        // ±1 pt outward bias toward the nearest edge so host screen-edge
        // gestures can actually reach 0/1 (a finger can't physically land on
        // the last pixel row; mirrors moonlight-ios).
        var loc = location
        loc.x += loc.x < viewSize.width / 2 ? -1 : 1
        loc.y += loc.y < viewSize.height / 2 ? -1 : 1
        let scale = min(viewSize.width / vw, viewSize.height / vh)
        let rw = vw * scale, rh = vh * scale
        let ox = (viewSize.width - rw) / 2, oy = (viewSize.height - rh) / 2
        let nx = Float(min(max((loc.x - ox) / rw, 0), 1))
        let ny = Float(min(max((loc.y - oy) / rh, 0), 1))
        session.sendTouch(phase, pointerId: pointerId, normalizedX: nx, normalizedY: ny)
    }

    // MARK: - Controller → stream forwarding

    /// Installs (or removes) the stream-passthrough on the controller manager.
    /// While active, every pad state change becomes a LiSendMultiControllerEvent
    /// snapshot and the launcher UI hears nothing (no focus moves, no haptics).
    /// The single pad driving player 1. Elected on first input after the
    /// forwarder installs (or after a disconnect); other pads are ignored —
    /// two pads' full-state snapshots otherwise fight and cancel each other.
    @ObservationIgnored private weak var electedPad: GCExtendedGamepad?
    /// Holds START down for ≥100 ms after a Menu press: old MFi pads emit an
    /// instantaneous down+up that games otherwise miss.
    @ObservationIgnored private var menuStickyUntil: ContinuousClock.Instant?

    private func setStreamInput(active: Bool) {
        guard let cm = controllerSource else { return }
        if active {
            electedPad = nil
            cm.streamForwarder = { [weak self] pad in self?.forward(pad) }
            cm.onPadDisconnected = { [weak self] in
                // Release everything host-side — the vanished pad's last
                // snapshot stays latched in the game otherwise.
                self?.session?.sendControllerButtonFlags(
                    0, leftTrigger: 0, rightTrigger: 0,
                    leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0)
                self?.electedPad = nil   // re-elect on the next input
            }
        } else if cm.streamForwarder != nil {
            cm.streamForwarder = nil
            cm.onPadDisconnected = nil
        }
    }

    private func forward(_ pad: GCExtendedGamepad) {
        guard let session else { return }
        if electedPad == nil { electedPad = pad }
        guard pad === electedPad else { return }
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

        // Menu minimum-hold: old MFi pads report an instantaneous down+up for
        // Menu; latch START for 100 ms so games see a real press. A trailing
        // re-send delivers the release even if no further pad events arrive.
        let now = ContinuousClock.now
        if pad.buttonMenu.isPressed {
            if menuStickyUntil == nil {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(120))
                    guard let self else { return }
                    self.menuStickyUntil = nil
                    if let pad = self.electedPad { self.forward(pad) }
                }
            }
            menuStickyUntil = now.advanced(by: .milliseconds(100))
        } else if let until = menuStickyUntil, now < until {
            flags |= 0x0010
        }

        // Standard Moonlight quit chord: EXACTLY Start+Select+LB+RB (extra held
        // buttons veto — a mid-game mash must not end the session). Release
        // everything host-side first so the game isn't left with buttons stuck.
        let quitChord: Int32 = 0x0010 | 0x0020 | 0x0100 | 0x0200
        if flags == quitChord {
            session.sendControllerButtonFlags(0, leftTrigger: 0, rightTrigger: 0,
                                              leftStickX: 0, leftStickY: 0,
                                              rightStickX: 0, rightStickY: 0)
            // Defer the teardown out of this pad-handler invocation: disconnect()
            // clears streamForwarder, which rewires (and releases) the very
            // handler currently executing — re-entrant mutation of GameController
            // handler state from inside its own dispatch is a crash hazard.
            Task { @MainActor [weak self] in self?.disconnect() }
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
            var last = VLStreamStats()
            var lastTime = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let session else { return }
                var s = VLStreamStats()
                session.getStats(&s)
                let now = ContinuousClock.now
                let dt = Double(lastTime.duration(to: now).components.seconds)
                    + Double(lastTime.duration(to: now).components.attoseconds) / 1e18
                defer { last = s; lastTime = now }
                guard dt > 0 else { continue }

                // Interval deltas → rates (Moonlight-style: stats over the last second).
                let frames = Double(s.framesReceived - last.framesReceived)
                let fps = frames / dt
                let mbps = Double(s.videoBytes - last.videoBytes) * 8 / dt / 1_000_000
                let dropped = s.networkDroppedFrames - last.networkDroppedFrames
                let received = s.framesReceived - last.framesReceived
                let dropPct = (dropped + received) > 0
                    ? Double(dropped) * 100 / Double(dropped + received) : 0
                // Host processing latency (interval average, 1/10 ms units).
                let hlCount = s.hostLatencyCount - last.hostLatencyCount
                let hlAvgMs = hlCount > 0
                    ? Double(s.hostLatencySumTenthMs - last.hostLatencySumTenthMs) / Double(hlCount) / 10 : 0
                // Frame assembly time (µs the average frame took to arrive in full).
                let rxAvgMs = frames > 0
                    ? Double(s.receiveDurationSumUs - last.receiveDurationSumUs) / frames / 1000 : 0

                var lines: [String] = []
                lines.append(String(format: "%d×%d  H.264  %.0f fps  %.1f Mbps",
                                    session.videoWidth(), session.videoHeight(), fps, mbps))
                var rtt: UInt32 = 0, variance: UInt32 = 0
                if session.getEstimatedRtt(&rtt, variance: &variance) {
                    lines.append(String(format: "Network: RTT %d ms ±%d  assembly %.1f ms", rtt, variance, rxAvgMs))
                } else {
                    lines.append(String(format: "Network: assembly %.1f ms", rxAvgMs))
                }
                if hlAvgMs > 0 {
                    lines.append(String(format: "Host encode: %.1f ms (max %.1f)",
                                        hlAvgMs, Double(s.hostLatencyMaxTenthMs) / 10))
                }
                lines.append(String(format: "Dropped: %.1f%% (%d total)", dropPct, s.networkDroppedFrames))
                self.perfStats = lines.joined(separator: "\n")
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
            // Announce the pad so the host materializes the virtual controller
            // before first input (games list it in controller menus right away).
            // Only when a pad is actually attached — announcing on a touch-only
            // session would create a phantom gamepad on the host.
            if controllerSource?.connectedControllers.contains(where: { $0.extendedGamepad != nil }) == true {
                let standardButtons: UInt32 = 0xF000 | 0x000F | 0x0330 | 0x00C0 | 0x0400
                session?.sendControllerArrival(withButtons: standardButtons,
                                               capabilities: 0x01)   // LI_CCAP_ANALOG_TRIGGERS
            }
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
        // Remote termination only DELIVERS the callback — the connection's
        // receive threads and the audio unit keep running until LiStopConnection.
        // Without this, a host-side quit leaks the whole stream stack.
        session?.stop()
        session = nil
        proxy = nil
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
