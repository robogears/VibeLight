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
        phase = .launching(app)
        do {
            // Fresh serverinfo for the working address + host generation/codecs.
            let (info, address) = try await api.serverInfo(for: host)

            // Over a relay (Tailscale/WAN), 4K120 @ 150 Mbps can't traverse DERP —
            // IDR frames fragment into ~100 FEC shards and starve ("26 < 103
            // needed" → no video). Cap remote streams to a relay-survivable
            // profile. The SAME capped values must drive /launch (mode=…) and the
            // stream config, or host and client disagree on geometry.
            let effective = Self.relayCapped(settings, address: address)

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
        session?.stop()
        session = nil
        proxy = nil
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

    // MARK: - Relay-safe capping

    /// Caps a stream profile for connections that leave the LAN. 4K120@150Mbps is
    /// fine on a gigabit LAN but hopeless over a Tailscale DERP relay, where huge
    /// IDR frames shatter into more FEC shards than the link can deliver. On a
    /// local address the user's settings pass through untouched.
    static func relayCapped(_ s: StreamSettings, address: String) -> StreamSettings {
        guard isRemoteAddress(address) else { return s }
        var c = s
        // Fit to 1080p, preserving aspect (never upscale).
        let maxW = 1920, maxH = 1080
        if c.width > maxW || c.height > maxH {
            let r = min(Double(maxW) / Double(c.width), Double(maxH) / Double(c.height))
            c.width  = (Int(Double(c.width) * r) / 2) * 2   // keep even dimensions
            c.height = (Int(Double(c.height) * r) / 2) * 2
        }
        c.fps = min(c.fps, 60)
        c.bitrateKbps = min(c.bitrateKbps, 25_000)   // 25 Mbps ceiling for a relay
        return c
    }

    /// True for anything that isn't a private-LAN address — including Tailscale's
    /// 100.64.0.0/10 CGNAT range, which is relayed and bandwidth-limited.
    static func isRemoteAddress(_ address: String) -> Bool {
        // Strip any port/zone suffix.
        let host = address.split(separator: "%").first.map(String.init) ?? address
        let a = host.split(separator: ":").count > 2 ? host   // IPv6 → treat as remote unless link-local
                                                     : String(host.split(separator: ":").first ?? "")
        let o = a.split(separator: ".").map { Int($0) ?? -1 }
        guard o.count == 4 else {
            // Non-IPv4 (hostname or IPv6): assume remote unless obviously local.
            return !(a.hasPrefix("fe80") || a == "::1" || a.lowercased().hasSuffix(".local"))
        }
        switch (o[0], o[1]) {
        case (10, _), (192, 168), (169, 254): return false          // private / link-local LAN
        case (172, 16...31): return false                            // private LAN
        case (127, _): return false                                  // loopback
        default: return true                                         // incl. 100.64/10 Tailscale, public
        }
    }

    func quitCompletely(host: StreamHost) async {
        remoteQuitRequested = true
        setStreamInput(active: false)
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
            onStreamDidStart?(nil)
        }
    }

    fileprivate func handleFail(stage: MoonlightStage, error: Int) {
        setStreamInput(active: false)
        phase = .failed("Stream failed at stage \(stage.rawValue) (error \(error)). Make sure the host is awake and not busy.")
    }

    fileprivate func handleTerminated(error: Int) {
        setStreamInput(active: false)
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
