#if os(iOS)
import Foundation
import Observation
import AVFoundation

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

    init(api: HostAPIClient) {
        self.api = api
        displayLayer.videoGravity = .resizeAspect
    }

    func launch(app: StreamApp, on host: StreamHost, settings: StreamSettings) async {
        connectedOnce = false
        remoteQuitRequested = false
        phase = .launching(app)
        do {
            // Fresh serverinfo for the working address + host generation/codecs.
            let (info, address) = try await api.serverInfo(for: host)

            // Remote-input AES material: rikey = 16 random bytes (hex), rikeyid =
            // a positive 31-bit int whose big-endian bytes seed the IV.
            let key = GameStreamCrypto.randomBytes(16)
            let rikeyId = Int(UInt32.random(in: 1...0x7FFF_FFFF))
            var iv = Data(count: 16)
            iv[0] = UInt8((rikeyId >> 24) & 0xFF); iv[1] = UInt8((rikeyId >> 16) & 0xFF)
            iv[2] = UInt8((rikeyId >> 8) & 0xFF);  iv[3] = UInt8(rikeyId & 0xFF)

            let sessionUrl = try await api.launch(
                app: app, on: host, at: address, settings: settings,
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
                width: Int32(settings.width), height: Int32(settings.height),
                fps: Int32(settings.fps), bitrateKbps: Int32(settings.bitrateKbps),
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
        session?.stop()
        session = nil
    }

    func quitCompletely(host: StreamHost) async {
        remoteQuitRequested = true
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
            onStreamDidStart?(nil)
        }
    }

    fileprivate func handleFail(stage: MoonlightStage, error: Int) {
        phase = .failed("Stream failed at stage \(stage.rawValue) (error \(error)). Make sure the host is awake and not busy.")
    }

    fileprivate func handleTerminated(error: Int) {
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
