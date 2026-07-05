#if os(iOS)
import Foundation
import Observation

/// iOS Phase-1 stub: streaming is not implemented yet on iOS (that needs the
/// in-process moonlight-common-c engine — plan Phases 2–5). Conforms to
/// `StreamEngine` so the shared `AppState` builds and runs unchanged; the whole
/// library browser — host discovery, in-app pairing, app list, box art, settings,
/// and controller/focus navigation — is fully functional. Only `launch()` is a
/// dead end that reports "not supported yet".
///
/// When the real engine lands, this file is replaced by `InProcessStreamEngine`
/// and nothing in `AppState` changes — that is the point of the seam.
@MainActor
@Observable
final class DisabledStreamEngine: StreamEngine {

    private(set) var phase: SessionPhase = .idle {
        didSet {
            guard oldValue != phase else { return }
            onPhaseChange?(phase)
        }
    }

    /// Never true — there is no remote-quit path on iOS yet. Present so the
    /// ended-card suppression logic in `AppState` compiles and reads `false`.
    private(set) var remoteQuitRequested = false

    @ObservationIgnored var onPhaseChange: ((SessionPhase) -> Void)?
    @ObservationIgnored var onStreamDidStart: ((_ helperPID: pid_t?) -> Void)?
    @ObservationIgnored var onStreamDidEnd: ((_ cleanly: Bool) -> Void)?

    init() {}

    /// The one meaningful behavior: refuse the launch with a user-facing reason.
    /// Setting `.failed` fires `onPhaseChange`, which `AppState.wireCallbacks()`
    /// already turns into the `.error` overlay — so the couch UI shows a proper
    /// card, then `acknowledgeEnd()` returns us to `.idle`.
    func launch(app: StreamApp, on host: StreamHost, settings: StreamSettings) async {
        phase = .failed("Streaming isn\u{2019}t available on iPhone or iPad yet — this build is a library browser and pairing tool. Launch \u{201C}\(app.name)\u{201D} from the Mac app for now.")
    }

    func disconnect() {}
    func quitCompletely(host: StreamHost) async {}

    /// Mirror the real engine: from `.failed`/`.ending`, return to `.idle`.
    func acknowledgeEnd() {
        switch phase {
        case .ending, .failed:
            phase = .idle
        default:
            break
        }
    }
}
#endif
