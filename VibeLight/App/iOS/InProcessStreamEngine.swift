#if os(iOS)
import Foundation
import Observation
import AVFoundation
import GameController
import UIKit   // UIResponder keyboard notifications (arrives transitively via
               // AVFoundation, but this file depends on it directly)

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
        mirrorLayer.videoGravity = .resizeAspect
        // Without this, game audio is permanently silent after a phone call,
        // Siri, alarm, or timer: the interruption stops the audio unit and
        // nothing restarts it. Registered once for the engine's lifetime.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            // queue: .main guarantees main-thread delivery.
            MainActor.assumeIsolated {
                // Only fight for the audio session while a stream is actually
                // live. An interruption that ENDS after the stream already
                // stopped must not re-grab audio focus from whatever the user
                // switched to (Music, a video, another game).
                guard let self, self.session != nil else { return }
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    NSLog("[VibeLight] audio session reactivation after interruption failed: \(error.localizedDescription)")
                }
                MoonlightSession.resumeAudio()
            }
        }
        // Control Center, Notification Center or an alert taking over the
        // screen mid-stream: key releases made while we're inactive never
        // reach us, so a key held as the overlay came down would stay held on
        // the PC. Release everything: a key still physically down reads as
        // up until it's pressed again, which beats one stuck down for good.
        // (LIF-stream-keys-stuck-after-keyboard-loss)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseHeldKeys() }
        }
        // Track where the on-screen keyboard actually is, so only the area it
        // covers stops accepting stream touches. willChangeFrame reports it
        // appearing, dismissing, docking and being dragged; for split,
        // undocked and floating keyboards iPadOS may also post "will hide"
        // (handled below), and those frames still need a live check.
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
        ) { [weak self] note in
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            MainActor.assumeIsolated { self?.keyboardFrameInScreen = frame ?? .zero }
        }
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Cleared on a real dismissal: the final willChangeFrame parks the
            // keyboard just off the bottom rather than reporting an empty
            // rect, and a stale rect would keep blocking a strip of a stream
            // with no keyboard over it. But iPadOS also posts "will hide" when
            // the keyboard is split, undocked or floated — still on screen —
            // so the rule below keeps the frame then.
            // (QUA-keyboard-hide-clears-undocked-frame)
            let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            let keyboardScreen = note.object as? UIScreen   // iOS 16.1+: the keyboard's screen
            MainActor.assumeIsolated {
                guard let self else { return }
                self.keyboardFrameInScreen = Self.keyboardFrame(
                    afterHideEndingAt: end, current: self.keyboardFrameInScreen,
                    screen: keyboardScreen?.bounds)
            }
        }
    }

    /// Release the audio session so other apps (Music, podcasts) resume — the
    /// mirror of the `setActive(true)` on launch. `.notifyOthersOnDeactivation`
    /// is what actually un-ducks the app we interrupted. Best-effort; called on
    /// every teardown path.
    ///
    /// Then hands the category back to the launcher's `.ambient`. Deactivating
    /// alone left it `.playback`, so the next menu tick re-activated the
    /// session in a mode that stops the person's music and ignores the Silent
    /// switch. The stream is already stopped here; the next launch() sets
    /// `.playback` again before it activates. (LIF-menu-sfx-audio-category-leak)
    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            NSLog("[VibeLight] audio session deactivate failed: \(error.localizedDescription)")
        }
        MenuSFX.useLauncherAudioSession()
    }

    /// The selected preset owns encoded quality on every screen. TV output
    /// chooses where the layer is presented, not the host's stream mode.
    nonisolated static func settingsForStream(_ settings: StreamSettings) -> StreamSettings {
        var requested = settings
        // iOS currently negotiates H.264 SDR; do not promise HDR to the host.
        requested.hdr = false
        return requested
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
        streamQuitProgress = nil   // never start a new stream pre-blacked (ON-7 pin)
        exitCurtain = 0
        activeTouchIDs.removeAll()
        showPerfOverlay = settings.performanceOverlay
        touchControlsEnabled = settings.touchControls
        touchWithControllerEnabled = settings.touchWithController
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
        // If a /launch we issued against a FREE host fails (classically: it times
        // out while the host has ALREADY started capturing — the PC screen goes
        // black), the host is left streaming to nobody and the next attempt
        // collides with that orphan. Remember enough to clean it up in `catch`.
        // Deliberately NOT set on the /resume path: that session predates us and
        // may belong to another client, so cancelling it would be hostile.
        var launchedOnFreeHost = false
        var resolvedAddress: String?
        do {
            // Fresh serverinfo for the working address + host generation/codecs.
            let (info, address) = try await api.serverInfo(for: host)
            resolvedAddress = address

            let effective = Self.settingsForStream(settings)
            NSLog("[VibeLight] requested stream: \(effective.width)×\(effective.height)@\(effective.fps) \(effective.bitrateKbps)kbps tv=\(effective.externalDisplay)")

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
            //
            // Use the model's own rule (`runningAppID`, which requires state ==
            // .busy) rather than reading currentGameID alone. A host that is
            // FREE can still report a non-zero currentgame — it's the last app
            // it ran, and Sunshine doesn't always clear it — so `!= 0` on its
            // own sent /resume to a host with nothing to resume, which fails
            // instead of just launching the game.
            let extraParams = MoonlightSession.launchUrlQueryParameters()
            let sessionUrl: String?
            if info.runningAppID != nil {
                sessionUrl = try await api.resume(
                    app: app, on: host, at: address, settings: effective,
                    rikeyHex: key.lowercaseHex, rikeyId: rikeyId, extraLaunchParams: extraParams)
            } else {
                launchedOnFreeHost = true
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
                // Every one of these crosses into int32_t. `Int32(x)` traps on
                // overflow, so nothing that came off the wire or out of
                // persisted settings gets converted that way — clamp instead.
                // (HostAPIClient already narrows serverCodecModeSupport at the
                // parse boundary; this is the second line of defence.)
                codecModeSupport: Int32(clamping: info.serverCodecModeSupport),
                width: Int32(clamping: effective.width), height: Int32(clamping: effective.height),
                fps: Int32(clamping: effective.fps), bitrateKbps: Int32(clamping: effective.bitrateKbps),
                // Hardcoded H.264 SDR: the iOS in-process decode path only
                // handles H.264 today. HEVC/HDR are on the roadmap
                // (docs/STREAMING-STATUS.md) and NOT wired to the
                // AVSampleBufferDisplayLayer yet — `settings.hdr` is deliberately
                // ignored here rather than promised to a decoder that can't honor
                // it. Flip these only when the HEVC/HDR decode path ships.
                enableHevc: false, enableHdr: false,
                aesKey: key, aesIv: iv)
            session.delegate = proxy
            displayLayer.flush()
            session.attach(displayLayer)
            // Route the video to the TV if one is attached (else it stays on the
            // iPad's StreamView). Safe when no display is connected — no-op.
            if settings.externalDisplay { ExternalDisplay.shared.present(displayLayer) }
            tvOutputRequested = settings.externalDisplay
            self.session = session
            self.launchingApp = app
            session.start()
        } catch is CancellationError {
            // Deliberately DON'T deactivate audio here: a CancellationError almost
            // always means a newer launch() superseded us and has already
            // re-grabbed the audio session, so deactivating would stomp the new
            // stream's audio. A genuine user-abort is cleaned up by the next
            // launch/teardown.
            phase = .idle
        } catch {
            // Hand the audio session back on a real launch failure (host asleep/
            // busy): we grabbed it at setActive(true) above but no stream started,
            // so without this the user's Music/podcast stays paused with nothing
            // playing. (audit ERR-launch-failure-leaves-audio-active)
            deactivateAudioSession()
            // Orphan cleanup: our /launch may have reached a host that started
            // capturing and then never replied. Best-effort /cancel so the host
            // isn't left streaming to nobody (which makes the NEXT attempt fail
            // at the RTSP handshake against a session we can't join).
            if launchedOnFreeHost, let address = resolvedAddress {
                let api = self.api, cancelHost = host
                Task.detached { try? await api.cancel(for: cancelHost, at: address) }
            }
            phase = .failed((error as? LocalizedError)?.errorDescription
                            ?? "Couldn't start \u{201C}\(app.name)\u{201D} on \(host.name).")
        }
    }

    func disconnect() {
        setStreamInput(active: false)
        setStatsHUD(active: false)
        cancelCompanionIdle()
        ExternalDisplay.shared.dismiss()   // hand the video layer back to the iPad
        session?.stop()
        session = nil
        proxy = nil
        deactivateAudioSession()
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
    /// Whether touches still forward while a controller is connected
    /// (Settings ▸ Input ▸ Touch With Controller; captured at launch).
    @ObservationIgnored private var touchWithControllerEnabled = false

    /// Forwards a touch from the stream view. `location` is in view coordinates;
    /// the engine maps it into the aspect-fit video rect (mirroring
    /// `.resizeAspect` letterboxing) and normalizes to 0…1 for the host.
    /// Pointer ids whose .down was forwarded to the host — their .up/.cancel
    /// must ALWAYS be delivered (gating a release strands a pressed left
    /// button / touch contact in the game).
    @ObservationIgnored private var activeTouchIDs: Set<UInt32> = []

    func sendTouch(_ phase: MoonlightTouchPhase, pointerId: UInt32,
                   location: CGPoint, viewSize: CGSize) {
        guard touchControlsEnabled, let session else { return }
        // (Touches landing ON the keyboard are filtered by StreamView, which is
        // the only place that knows the view's coordinate space. Doing it there
        // also means a touch that STARTED on the stream keeps working if it
        // drags over the keyboard — and its release still arrives.)
        // Controller-only play: a stray palm/grip touch used to warp the host
        // cursor to that spot AND left-click (absolute touch → mouse fallback)
        // — the "phantom cursor mid-game" bug. While an extended gamepad is
        // connected, NEW touches stay quiet unless the user opts back in;
        // touches already in flight still deliver their release.
        let gated = !touchWithControllerEnabled &&
            controllerSource?.connectedControllers.contains(where: { $0.extendedGamepad != nil }) == true
        switch phase {
        case .down:
            if gated { return }
            activeTouchIDs.insert(pointerId)
        case .move:
            if gated && !activeTouchIDs.contains(pointerId) { return }
        case .up, .cancel:
            if gated && !activeTouchIDs.contains(pointerId) { return }
            activeTouchIDs.remove(pointerId)
        @unknown default:
            break
        }
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

    /// Multi-controller: each physical pad owns its own host slot (0–3 — the
    /// GFE-safe cap; Sunshine allows more). Keyed on GCController identity —
    /// `playerIndex` is not stable and `GCController.controllers()` has no
    /// documented ordering, so we own the map (mirrors moonlight-ios).
    /// A slot is never renumbered while its pad is present.
    @ObservationIgnored private var padSlots: [ObjectIdentifier: UInt8] = [:]
    /// Live set of allocated slots, sent as activeGamepadMask with every event.
    /// An event whose mask has a slot's bit CLEARED destroys that virtual pad.
    @ObservationIgnored private var slotMask: UInt16 = 0
    /// Slots whose arrival event has been sent (once per pad per stream).
    @ObservationIgnored private var announcedSlots: Set<UInt8> = []
    /// Holds START down for ≥100 ms after a Menu press: old MFi pads emit an
    /// instantaneous down+up that games otherwise miss.
    @ObservationIgnored private var menuStickyUntil: ContinuousClock.Instant?
    @ObservationIgnored private weak var menuStickyPad: GCExtendedGamepad?
    /// Select + Start → one Guide press, per pad (keyed like `padSlots`). See
    /// GuideChord for why, and the rules.
    @ObservationIgnored private var guideChords: [ObjectIdentifier: GuideChord] = [:]

    /// LI_CTYPE_* values (Limelight.h) — what family of pad the user holds.
    private enum LiControllerType {
        static let unknown: UInt8 = 0x00
        static let xbox: UInt8 = 0x01
        static let ps: UInt8 = 0x02
        static let nintendo: UInt8 = 0x03
    }

    private func resetPadSlots() {
        padSlots.removeAll()
        slotMask = 0
        announcedSlots.removeAll()
    }

    /// The slot for this pad, allocating the lowest free one (and attempting
    /// its arrival announcement) on first sight. nil = four pads already active.
    private func slot(for pad: GCExtendedGamepad) -> UInt8? {
        guard let controller = pad.controller else { return nil }
        let key = ObjectIdentifier(controller)
        if let existing = padSlots[key] { return existing }
        for candidate: UInt8 in 0..<4 where slotMask & (1 << candidate) == 0 {
            padSlots[key] = candidate
            slotMask |= (1 << candidate)
            ensureAnnounced(controller, slot: candidate)
            return candidate
        }
        return nil
    }

    /// Arrival event: tells the host WHAT this pad is so Sunshine/Apollo's
    /// `gamepad=auto` materializes a matching virtual pad — a DualSense or
    /// DualShock becomes a virtual DS4 (PlayStation glyphs + features in
    /// games) instead of the default X360. Ordering is load-bearing: the
    /// arrival must be the slot's FIRST packet, or the host permanently
    /// allocates an X360 for the session the moment a plain event leaks out.
    ///
    /// RETRIED until it actually lands: the arrival API returns nonzero while
    /// the input stream is still handshaking, and our "streaming" flip fires
    /// on first VIDEO packets — which can beat the input channel. The old
    /// fire-and-forget dropped the announcement silently, and the first plain
    /// controller event then locked the slot as X360 for the whole session
    /// (seen on device as "my pads always show up as Xbox"). Mirrors
    /// moonlight-ios: a slot's events are held back until its arrival lands.
    @discardableResult
    private func ensureAnnounced(_ controller: GCController, slot: UInt8) -> Bool {
        if announcedSlots.contains(slot) { return true }
        guard let session else { return false }
        let pad = controller.extendedGamepad
        var type = LiControllerType.unknown
        if pad is GCXboxGamepad {
            type = LiControllerType.xbox
        } else if pad is GCDualShockGamepad || pad is GCDualSenseGamepad {
            type = LiControllerType.ps
        } else if controller.productCategory.localizedCaseInsensitiveContains("switch")
                    || controller.productCategory.localizedCaseInsensitiveContains("nintendo") {
            type = LiControllerType.nintendo
        }
        // A/B/X/Y + dpad + LB/RB + START + stick clicks + GUIDE; BACK only when
        // the pad actually has an Options button.
        var buttons: UInt32 = 0xF000 | 0x000F | 0x0310 | 0x00C0 | 0x0400
        if pad?.buttonOptions != nil { buttons |= 0x0020 }
        // Honest caps only (analog triggers): rumble/motion/touchpad aren't
        // forwarded yet — advertising them would make the host expect events
        // we never send, and a virtual-DS4 touchpad that Steam maps to mouse
        // is exactly the phantom-cursor trap we're avoiding elsewhere.
        let ok = session.sendControllerArrival(forNumber: slot, activeMask: slotMask,
                                               type: type, supportedButtons: buttons,
                                               capabilities: 0x01) == 0
        if ok { announcedSlots.insert(slot) }
        return ok
    }

    /// A pad vanished: release its slot. The zeroed event with the bit cleared
    /// from the mask is what makes the host destroy the virtual pad (and
    /// unsticks its last snapshot from the game).
    private func reconcileSlots() {
        let live = Set(GCController.controllers()
            .filter { $0.extendedGamepad != nil }
            .map(ObjectIdentifier.init))
        for (key, slot) in padSlots where !live.contains(key) {
            padSlots.removeValue(forKey: key)
            slotMask &= ~(UInt16(1) << UInt16(slot))
            announcedSlots.remove(slot)
            session?.sendControllerNumber(slot, activeMask: slotMask,
                                          buttonFlags: 0, leftTrigger: 0, rightTrigger: 0,
                                          leftStickX: 0, leftStickY: 0,
                                          rightStickX: 0, rightStickY: 0)
        }
    }

    /// PS/HOME NEEDS TWO PRESSES ON iPadOS, BY DESIGN — DO NOT "FIX" IT.
    ///
    /// PROVEN, not inferred: iOS 18's Game Overlay says so in its own words,
    /// on screen, naming this app:
    ///
    ///     "Features in VibeLight may be designed to use 'PS Button'. To access
    ///      this functionality instead of the Game Overlay, press [PS] twice."
    ///
    /// The FIRST press opens Apple's Game Overlay; the second reaches us. There
    /// is no opt-out. `preferredSystemGestureState = .disabled` (below) is still
    /// required and still correct — without it the button never arrives at all —
    /// but it does not override the Overlay's claim on the first press.
    ///
    /// Four things were tried and reverted before the iPad simply said it:
    ///   1. subscribing to the Home element directly instead of the aggregate
    ///      `valueChangedHandler` (it was already firing);
    ///   2. giving GUIDE the minimum-hold latch START genuinely needs for old
    ///      MFi pads (the press duration was never the problem);
    ///   3. announcing every pad as an Xbox controller, in case Sunshine's
    ///      virtual DS4 swallowed it host-side (it does not);
    ///   4. device logging, which showed a clean down/up pair per DELIVERED
    ///      press — and could not see the presses the system had already taken,
    ///      which was the entire answer.
    ///
    /// The one-press way to Guide is therefore Select + Start (GuideChord,
    /// applied in `forward`).
    ///
    /// Declaring the app a game (LSApplicationCategoryType / LSSupportsGameMode
    /// in project.yml) does NOT change this. It was kept anyway: Game Mode
    /// meaningfully lowers controller Bluetooth latency, which matters here.
    ///
    /// iOS reserves the PS/Home ("Guide"), Share, and Options buttons for its own
    /// system gestures by default, so those presses never reach the app and the
    /// host never sees them (the Steam/PS overlay won't open in-game). Disabling
    /// the gesture on every pad element while streaming routes them to us; we
    /// restore the default when the stream ends so the launcher/system behave
    /// normally. (macOS has no equivalent reservation — hence "works on Mac".)
    private func setSystemGestures(disabled: Bool) {
        let state: GCControllerElement.SystemGestureState = disabled ? .disabled : .enabled
        for controller in GCController.controllers() where controller.extendedGamepad != nil {
            for element in controller.physicalInputProfile.allElements {
                element.preferredSystemGestureState = state
            }
        }
    }

    private func setStreamInput(active: Bool) {
        guard let cm = controllerSource else { return }
        if active {
            resetPadSlots()
            guideChords.removeAll()
            keyboardModifiers = 0
            heldKeys.removeAll()
            setSystemGestures(disabled: true)
            cm.streamForwarder = { [weak self] pad in self?.forward(pad) }
            cm.keyboardForwarder = { [weak self] code, pressed in self?.forwardKey(code, pressed: pressed) }
            cm.onPadDisconnected = { [weak self] in
                // Release the vanished pad's slot host-side — its last
                // snapshot stays latched in the game otherwise.
                self?.reconcileSlots()
            }
            cm.onKeyboardDisconnected = { [weak self] in
                // The keys it was holding will never report a release —
                // send them now or the game keeps W (or Ctrl) held down.
                self?.releaseHeldKeys()
            }
            cm.onPadConnected = { [weak self] in
                // A pad that arrives DURING a stream never went through the
                // setup above, so its PS/Home, Share and Options presses kept
                // being eaten by iOS instead of reaching the game. Re-apply to
                // the whole roster (the call is idempotent per pad).
                self?.setSystemGestures(disabled: true)
                self?.reconcileSlots()
            }
        } else if cm.streamForwarder != nil {
            releaseHeldKeys()            // no keys stuck down in the game on leave
            cm.streamForwarder = nil
            cm.keyboardForwarder = nil
            cm.onPadDisconnected = nil
            cm.onKeyboardDisconnected = nil
            cm.onPadConnected = nil
            cancelQuitHold()
            setSystemGestures(disabled: false)   // restore the OS's PS/Share/Options gestures
        }
    }

    // MARK: - Keyboard → stream forwarding

    /// MODIFIER_* mask of currently-held modifier keys, sent with every event.
    @ObservationIgnored private var keyboardModifiers: UInt8 = 0
    /// Virtual-key codes currently held down, so a stream that ends mid-keypress
    /// can release them (the host latches the last state otherwise).
    @ObservationIgnored private var heldKeys: Set<Int16> = []

    private func forwardKey(_ code: GCKeyCode, pressed: Bool) {
        guard let session, let vk = KeyboardMap.virtualKey(for: code) else { return }
        if let bit = KeyboardMap.modifierBit(for: code) {
            if pressed { keyboardModifiers |= bit } else { keyboardModifiers &= ~bit }
        }
        if pressed { heldKeys.insert(vk) } else { heldKeys.remove(vk) }
        session.sendKeyboardEvent(vk, down: pressed, modifiers: keyboardModifiers)
    }

    private func releaseHeldKeys() {
        if let session {
            for vk in heldKeys { session.sendKeyboardEvent(vk, down: false, modifiers: 0) }
        }
        heldKeys.removeAll()
        keyboardModifiers = 0
    }

    // MARK: - On-screen keyboard

    /// Where the keyboard actually is, in SCREEN coordinates — `.zero` when it
    /// is down. Only the area it covers stops accepting stream touches; the rest
    /// of the screen stays live, so you can still tap a text field in the game
    /// and then type into it.
    ///
    /// Read from the notification rather than assumed, because "the keyboard"
    /// is not one shape: docked fills the width, split leaves a gap in the
    /// middle, and floating is a small pane the user can park anywhere. The
    /// reported frame covers each of those; guessing "the bottom half" would be
    /// wrong for two of the three.
    private(set) var keyboardFrameInScreen: CGRect = .zero

    /// The keyboard's frame after a "will hide" notification. A hide whose end
    /// frame still overlaps the screen is a keyboard being split, undocked or
    /// floated, not leaving: keep the last frame we were told about (or the
    /// hide's own end frame if we had none). Only a hide that ends off screen
    /// clears it. When the screen is unknown, clear as before — never worse
    /// than the old behaviour. (QUA-keyboard-hide-clears-undocked-frame)
    nonisolated static func keyboardFrame(afterHideEndingAt end: CGRect?, current: CGRect,
                                          screen: CGRect?) -> CGRect {
        guard let end, let screen else { return .zero }
        let overlap = end.intersection(screen)
        guard !overlap.isNull, !overlap.isEmpty else { return .zero }
        return current.isNull || current.isEmpty ? end : current
    }

    /// True while the iPad's own keyboard is raised over the stream.
    var onScreenKeyboardUp = false {
        didSet {
            guard oldValue != onScreenKeyboardUp, !onScreenKeyboardUp else { return }
            // Dismissing while a modifier is latched would strand it down on the
            // host — every later keystroke would arrive Ctrl-ed.
            releaseHeldKeys()
        }
    }

    /// Types one character from the on-screen keyboard: press (with shift if the
    /// character needs it), then release, so the host sees a complete keystroke.
    ///
    /// Shift is sent as a real key event AROUND the character rather than only as
    /// a modifier mask, because a host that reads the mask alone still needs the
    /// shift key's own down/up to produce an uppercase letter in most games.
    func typeCharacter(_ character: Character) {
        guard let session, let route = KeyboardMap.route(for: character) else { return }
        let stroke: (vk: Int16, shift: Bool)
        switch route {
        case .key(let vk, let shift):
            stroke = (vk, shift)
        case .text(let text):
            // No US key types it (é, emoji): send the character itself, which
            // the PC's layout can't change. (QUA-onscreen-keyboard-assumes-us-pc-layout)
            session.sendText(text)
            return
        }
        let shiftVK: Int16 = 0xA0   // VK_LSHIFT
        var mods = keyboardModifiers
        if stroke.shift {
            mods |= KeyboardMap.modShift
            session.sendKeyboardEvent(shiftVK, down: true, modifiers: mods)
        }
        session.sendKeyboardEvent(stroke.vk, down: true, modifiers: mods)
        session.sendKeyboardEvent(stroke.vk, down: false, modifiers: mods)
        if stroke.shift {
            mods &= ~KeyboardMap.modShift
            session.sendKeyboardEvent(shiftVK, down: false, modifiers: mods)
        }
    }

    /// Backspace from the on-screen keyboard.
    func typeBackspace() {
        guard let session else { return }
        session.sendKeyboardEvent(KeyboardMap.backspaceVK, down: true, modifiers: keyboardModifiers)
        session.sendKeyboardEvent(KeyboardMap.backspaceVK, down: false, modifiers: keyboardModifiers)
    }

    /// 0…1 progress of the hold-to-leave chord (nil = not holding).
    /// `StreamExitOverlay` (Frame Trace) draws from this.
    private(set) var streamQuitProgress: Double?

    /// How long Start + Select + L1 + R1 must be held to leave (owner: 0.7 s
    /// longer than the original 1.0 s, so it can't fire by accident).
    nonisolated static let leaveHoldSeconds = 1.7

    /// Black over EVERYTHING — iPad and the TV launcher — from the end of the
    /// hold until the stream has fully closed (owner: "fade to black for a
    /// second, the stream completely closed, then slowly fade back into the
    /// menu"). 1 = black; set back to 0 after `exitBlackHold`, and
    /// `ExitCurtain` animates that over `exitCurtainFadeOut` seconds. It has
    /// to live here, not in the stream view: teardown removes that view.
    private(set) var exitCurtain: Double = 0
    nonisolated static let exitBlackHold: Duration = .seconds(1)
    nonisolated static let exitCurtainFadeOut = 0.9
    @ObservationIgnored private var quitHoldTask: Task<Void, Never>?
    /// The pad holding the leave chord — only ITS deviating input aborts the
    /// hold. Without this, player 2's ordinary inputs would cancel player 1's
    /// hold every frame and the chord could never complete in 2-player play.
    @ObservationIgnored private weak var quitHoldPad: GCExtendedGamepad?

    /// Drives the ~1s leave-stream hold: publishes ring progress after a short
    /// grace (so a quick brush never flashes it), then leaves when it completes.
    private func startQuitHold() {
        guard quitHoldTask == nil else { return }
        let start = ContinuousClock.now
        quitHoldTask = Task { @MainActor [weak self] in
            let grace = 0.15, total = Self.leaveHoldSeconds
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, !Task.isCancelled else { return }
                let d = start.duration(to: .now)
                let elapsed = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
                if elapsed >= total {
                    quitHoldTask = nil
                    // Pin the fade fully black through the teardown (the scrim
                    // in RootView reads this) so the exit is a fade, not a jump
                    // cut. launch() resets it before the next stream.
                    streamQuitProgress = 1
                    // Release every pad host-side, then leave (game keeps running).
                    for slot in padSlots.values {
                        session?.sendControllerNumber(slot, activeMask: slotMask,
                                                      buttonFlags: 0, leftTrigger: 0, rightTrigger: 0,
                                                      leftStickX: 0, leftStickY: 0,
                                                      rightStickX: 0, rightStickY: 0)
                    }
                    // Input stops NOW (nothing more reaches the game, and the
                    // still-held chord can't start a second hold), but teardown
                    // waits for the exit overlay's finish — the frame swelling
                    // to black (StreamExitOverlay.fireDuration). Disconnecting
                    // in the same turn removed the stream view mid-swell, so the
                    // game faded straight into the launcher instead of to black.
                    setStreamInput(active: false)
                    try? await Task.sleep(for: StreamExitOverlay.fireDuration + .milliseconds(60))
                    guard case .streaming = phase else { return }   // it already ended on its own
                    // The screen is black under the swell now; the curtain
                    // takes over (no visible change) and outlives the stream
                    // view, so teardown — the old "chop" — happens unseen.
                    exitCurtain = 1
                    disconnect()
                    try? await Task.sleep(for: Self.exitBlackHold)
                    exitCurtain = 0                       // ExitCurtain fades this out slowly
                    return
                }
                if elapsed >= grace {
                    streamQuitProgress = min(max((elapsed - grace) / (total - grace), 0), 1)
                }
            }
        }
    }

    private func cancelQuitHold() {
        // No-op once the hold has COMPLETED (the completion nils the task
        // before pinning progress to 1) — otherwise disconnect()'s teardown
        // path would wipe the fade-to-black pin in the same MainActor turn
        // and the exit would jump-cut again. Genuine mid-hold aborts still
        // clear the ring.
        guard quitHoldTask != nil else { return }
        quitHoldTask?.cancel()
        quitHoldTask = nil
        quitHoldPad = nil
        if streamQuitProgress != nil { streamQuitProgress = nil }
    }

    private func forward(_ pad: GCExtendedGamepad) {
        guard let session else { return }
        guard let slot = slot(for: pad) else { return }   // 5th+ pad: no free slot
        // Hold back events until the slot's arrival announcement has landed —
        // a plain event slipping out first would lock the slot as X360.
        guard let controller = pad.controller,
              ensureAnnounced(controller, slot: slot) else { return }
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
                    if let sticky = self.menuStickyPad { self.forward(sticky) }
                }
            }
            menuStickyUntil = now.advanced(by: .milliseconds(100))
            menuStickyPad = pad
        } else if let until = menuStickyUntil, now < until, pad === menuStickyPad {
            flags |= 0x0010
        }

        // Select + Start → one PS / Guide press (GuideChord): the pad's own
        // PS button needs two presses on iPadOS. Runs AFTER the Menu latch so a
        // latched START reads as still held rather than as a fresh press, and
        // BEFORE the leave-stream check, which it leaves intact (L1/R1 joining
        // abandons the chord and passes the full combo through).
        let chordKey = ObjectIdentifier(controller)
        var chord = guideChords[chordKey] ?? GuideChord()
        let chordOut = chord.process(flags, now: now)
        guideChords[chordKey] = chord
        flags = chordOut.flags
        if let at = chordOut.recheckAt {
            // A held-back lone Start/Select must go out even if the pad then
            // reports nothing new (no stick wiggle to trigger a forward).
            Task { @MainActor [weak self, weak pad] in
                try? await Task.sleep(until: at, clock: .continuous)
                guard let self, let pad else { return }
                self.forward(pad)
            }
        }

        // Leave-stream combo — Start + Select/Share + L1 + R1. HELD 1.7 s (with a
        // progress ring, like the launcher's hold-to-quit) so it's deliberate and
        // gives feedback. While held, the buttons are suppressed (not forwarded
        // to the game). The game keeps running on the PC.
        let quitCombo: Int32 = 0x0010 | 0x0020 | 0x0100 | 0x0200   // START|BACK|LB|RB
        if flags == quitCombo {
            quitHoldPad = pad
            startQuitHold()
            return   // don't forward the combo to the game while it's held
        }
        // Only the HOLDER's deviating input aborts the hold — another player's
        // ordinary inputs must not reset the ring.
        if pad === quitHoldPad { cancelQuitHold() }

        // A pulse (the chord's Guide, or a lone tap the chord held back) goes
        // out pressed now; a re-forward 100 ms later sends the pad's real
        // state, which no longer carries it — that is the release.
        if chordOut.pulse != 0 {
            Task { @MainActor [weak self, weak pad] in
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let pad else { return }
                self.forward(pad)
            }
        }

        func axis(_ v: Float) -> Int16 { Int16(clamping: Int(v * 32767)) }
        session.sendControllerNumber(
            slot, activeMask: slotMask,
            buttonFlags: flags | chordOut.pulse,
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
    /// Whether this stream shows the perf HUD. Starts from Settings ▸
    /// Performance Stats (the active preset's value) at every launch; the
    /// stream controls' button flips it for THIS stream only. Observed, so the
    /// button shows its state.
    private(set) var showPerfOverlay = false

    /// The in-stream Performance Stats button (owner). Deliberately leaves the
    /// setting alone: editing settings mid-game would detach the active preset
    /// (its marker clears the moment they differ), and the next stream should
    /// come back to what the preset says.
    func togglePerformanceStats() {
        showPerfOverlay.toggle()
        if case .streaming = phase { setStatsHUD(active: true) }
    }

    private func setStatsHUD(active: Bool) {
        statsTask?.cancel()
        statsTask = nil
        perfStats = nil
        ExternalDisplay.shared.setPerfHUD(nil)   // clear the TV mirror too
        guard active, showPerfOverlay, let session else { return }
        statsTask = Task { [weak self, weak session] in
            var last = VLStreamStats()
            var lastTime = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                // `try?` swallows the cancellation, so a task stopped mid-sleep
                // (the stats button turned off, or the stream ending) used to
                // run once more and write a reading back: the HUD vanished,
                // then reappeared frozen. Stop here instead.
                guard !Task.isCancelled, let self, let session else { return }
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
                ExternalDisplay.shared.setPerfHUD(self.perfStats)   // mirror to the TV
            }
        }
    }

    // MARK: - Companion (iPad) while a TV shows the game

    /// What the iPad shows while a TV owns the video (owner's design):
    /// - `.panel`  — "Playing on the display", with ✕ and the keyboard button.
    ///   Fades to `.dimmed` after `panelDimAfter` untouched.
    /// - `.dimmed` — pure black (the display itself stays on; keep-awake).
    /// - `.stream` — the game itself, mirrored onto the iPad and touchable.
    ///   Back to `.panel` after `streamHideAfter` untouched.
    /// A touch on the panel or the black screen is NOT sent to the game; it
    /// only brings the game onto the iPad. Only meaningful with a TV attached.
    enum CompanionView: Equatable, Sendable { case panel, dimmed, stream }
    private(set) var companionView: CompanionView = .panel
    var companionDimmed: Bool { companionView == .dimmed }
    var companionShowsStream: Bool { companionView == .stream }

    nonisolated static let panelDimAfter: Duration = .seconds(5)
    nonisolated static let streamHideAfter: Duration = .seconds(15)

    /// The iPad's own copy of the picture for `.stream` (the TV keeps
    /// `displayLayer`). Fed by the session only while it is showing.
    @ObservationIgnored let mirrorLayer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private var companionIdleTask: Task<Void, Never>?
    @ObservationIgnored private var lastCompanionActivity = ContinuousClock.now
    /// Whether this stream was routed to a TV (`externalDisplay`, always on, at
    /// launch); with a display actually connected, the companion is live.
    @ObservationIgnored private var tvOutputRequested = false
    private var companionLive: Bool { tvOutputRequested && ExternalDisplay.shared.isConnected }

    /// The timing rule, pure so it is tested: where the companion goes after
    /// `idle` untouched, or nil to stay. The keyboard holds the panel up —
    /// typing on it never touches the stream view, so it would read as idle.
    nonisolated static func companionNext(_ view: CompanionView, idle: Duration,
                                          keyboardUp: Bool) -> CompanionView? {
        switch view {
        case .panel: return (!keyboardUp && idle >= panelDimAfter) ? .dimmed : nil
        case .stream: return idle >= streamHideAfter ? .panel : nil
        case .dimmed: return nil
        }
    }

    /// Any iPad touch during a stream. Returns whether a touch BEGINNING now
    /// may reach the game: false while the panel (lit or black) is up — that
    /// touch only brings the game onto the iPad.
    func noteCompanionActivity() -> Bool {
        lastCompanionActivity = .now
        guard companionLive, companionView != .stream else { return true }
        setCompanionView(.stream)
        return false
    }

    private func setCompanionView(_ view: CompanionView) {
        guard view != companionView else { return }
        if view == .stream {
            mirrorLayer.flush()
            session?.attachMirror(mirrorLayer)
        } else if companionView == .stream {
            session?.attachMirror(nil)          // stop decoding a second copy
            mirrorLayer.flushAndRemoveImage()
        }
        companionView = view
        lastCompanionActivity = .now            // each view gets its full time
    }

    private func armCompanionIdle() {
        companionIdleTask?.cancel()
        setCompanionView(.panel)
        companionIdleTask = Task { @MainActor [weak self] in
            // Task-local: Swift 6 forbids mutating a captured outer var here.
            var wasLive = self?.companionLive ?? false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                // A TV plugged in or pulled out mid-stream (owner: perfect
                // continuity). The stream never changes — quality comes only
                // from the preset (settingsForStream), never the display — so a
                // restart isn't needed; the picture just moves. Ask for a
                // keyframe so the screen taking it starts clean.
                if companionLive != wasLive {
                    wasLive = companionLive
                    session?.requestKeyframe()
                }
                // No TV: the companion isn't on screen. Hold it lit with a fresh
                // clock — its 5 s dim used to keep running here, so plugging a
                // TV in mid-stream put the iPad straight to black instead of
                // "Playing on …". Unplugged while the game was on the iPad, this
                // also stops the mirror (the main layer comes back here).
                if !companionLive {
                    if companionView != .panel { setCompanionView(.panel) }
                    lastCompanionActivity = .now
                    continue
                }
                let idle = lastCompanionActivity.duration(to: .now)
                if let next = Self.companionNext(companionView, idle: idle,
                                                 keyboardUp: onScreenKeyboardUp) {
                    setCompanionView(next)
                }
            }
        }
    }

    private func cancelCompanionIdle() {
        companionIdleTask?.cancel()
        companionIdleTask = nil
        setCompanionView(.panel)
    }

    func quitCompletely(host: StreamHost) async {
        remoteQuitRequested = true
        setStreamInput(active: false)
        setStatsHUD(active: false)
        cancelCompanionIdle()
        ExternalDisplay.shared.dismiss()   // hand the video layer back to the iPad
        session?.stop()
        session = nil
        deactivateAudioSession()
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
        NSLog("[VibeLight] stream reached stage \(stage.rawValue)")
        // "Connected" (or reaching the video-start stage) means the stream is live.
        if !connectedOnce, stage == .connected || stage.rawValue >= MoonlightStage.videoStart.rawValue {
            connectedOnce = true
            phase = .streaming(app)
            setStreamInput(active: true)
            setStatsHUD(active: true)
            armCompanionIdle()   // the iPad companion's panel / dim / show-the-game timers
            onStreamDidStart?(nil)
        }
        // Announce every attached pad — with its REAL family — so the host
        // materializes matching virtual controllers before first input
        // (a DualSense shows up as a PlayStation pad, games list them in
        // controller menus right away). Touch-only sessions announce nothing:
        // a phantom gamepad would appear on the host otherwise. Runs on the
        // video-start flip (may be too early for the input stream — that's
        // fine, ensureAnnounced retries) AND on .connected (connectionStarted:
        // every stream including input is up, so announcements land for sure).
        if connectedOnce {
            for controller in GCController.controllers() {
                if let pad = controller.extendedGamepad { _ = slot(for: pad) }
            }
            for (key, slot) in padSlots {
                if let controller = GCController.controllers().first(where: { ObjectIdentifier($0) == key }) {
                    ensureAnnounced(controller, slot: slot)
                }
            }
        }
    }

    fileprivate func handleFail(stage: MoonlightStage, error: Int) {
        NSLog("[VibeLight] stream failed: stage=\(stage.rawValue) error=\(error)")
        setStreamInput(active: false)
        setStatsHUD(active: false)
        cancelCompanionIdle()
        ExternalDisplay.shared.dismiss()   // hand the video layer back to the iPad
        // Clear the dead connection like handleTerminated does: LiStopConnection is
        // stage-guarded (a safe no-op after a failed LiStartConnection that already
        // unwound), and nil-ing session/proxy stops the audio-interruption guard —
        // which keys on `session != nil` — from treating a failed stream as live
        // and re-grabbing audio focus later. (audit LIF-handlefail-leaves-session-nonnil)
        session?.stop()
        session = nil
        proxy = nil
        deactivateAudioSession()
        phase = .failed("Stream failed at stage \(stage.rawValue) (error \(error)). Make sure the host is awake and not busy.")
    }

    fileprivate func handleTerminated(error: Int) {
        NSLog("[VibeLight] stream terminated: error=\(error) requestedQuit=\(remoteQuitRequested)")
        setStreamInput(active: false)
        setStatsHUD(active: false)
        cancelCompanionIdle()
        ExternalDisplay.shared.dismiss()   // hand the video layer back to the iPad
        // Remote termination only DELIVERS the callback — the connection's
        // receive threads and the audio unit keep running until LiStopConnection.
        // Without this, a host-side quit leaks the whole stream stack.
        session?.stop()
        session = nil
        proxy = nil
        deactivateAudioSession()
        let cleanly = (error == 0) || remoteQuitRequested
        phase = Self.terminationPhase(error: error, remoteQuitRequested: remoteQuitRequested,
                                      app: launchingApp)
        onStreamDidEnd?(cleanly)
    }

    /// Keep the protocol's failure reason instead of treating missing video as
    /// a normal game exit. Explicit quits retain their existing end flow.
    nonisolated static func terminationPhase(error: Int, remoteQuitRequested: Bool,
                                             app: StreamApp?) -> SessionPhase {
        guard error != 0, !remoteQuitRequested else {
            return app.map(SessionPhase.ending) ?? .idle
        }
        let reason: String
        // ML_ERROR_* values from moonlight-common-c's Limelight.h.
        switch error {
        case -100: reason = "No video data arrived from the PC. Check the host's connection and firewall."
        case -101: reason = "A complete video frame could not arrive. Try a lower bitrate and reconnect."
        case -102: reason = "The PC stopped the stream before video could start. Check the host's capture and encoder."
        case -103: reason = "The PC stopped video because protected content is on screen."
        case -104: reason = "The PC could not convert its video frames. Check the host's display settings."
        default: reason = "The stream connection ended unexpectedly. Reconnect to try again."
        }
        return .failed("\(reason) (Error \(error))")
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
