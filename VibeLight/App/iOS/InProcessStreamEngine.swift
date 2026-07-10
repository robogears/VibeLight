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
        streamQuitProgress = nil   // never start a new stream pre-blacked (ON-7 pin)
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
            // A TV / monitor is attached → stream at ITS native resolution and
            // render there (fullscreen, sharp) instead of mirroring the iPad.
            if settings.externalDisplay, let tv = ExternalDisplay.shared.pixelSize {
                effective.width = (Int(tv.width) / 2) * 2      // H.264 needs even dims
                effective.height = (Int(tv.height) / 2) * 2
                NSLog("[VibeLight] external display: streaming at \(effective.width)×\(effective.height)")
            }

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
            // Route the video to the TV if one is attached (else it stays on the
            // iPad's StreamView). Safe when no display is connected — no-op.
            if settings.externalDisplay { ExternalDisplay.shared.present(displayLayer) }
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
        cancelCompanionIdle()
        ExternalDisplay.shared.dismiss()   // hand the video layer back to the iPad
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
        } else if cm.streamForwarder != nil {
            releaseHeldKeys()            // no keys stuck down in the game on leave
            cm.streamForwarder = nil
            cm.keyboardForwarder = nil
            cm.onPadDisconnected = nil
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

    /// 0…1 fill of the hold-to-leave combo ring (nil = not holding). RootView
    /// renders `HoldProgressRing` from this.
    private(set) var streamQuitProgress: Double?
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
            let grace = 0.15, total = 1.0
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
                    disconnect()
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

        // Leave-stream combo — Start + Select/Share + L1 + R1. HELD ~2s (with a
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

        func axis(_ v: Float) -> Int16 { Int16(clamping: Int(v * 32767)) }
        session.sendControllerNumber(
            slot, activeMask: slotMask,
            buttonFlags: flags,
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
        ExternalDisplay.shared.setPerfHUD(nil)   // clear the TV mirror too
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
                ExternalDisplay.shared.setPerfHUD(self.perfStats)   // mirror to the TV
            }
        }
    }

    // MARK: - Companion (iPad) idle dimming

    /// While a TV owns the video, the iPad shows a "Playing on the display"
    /// companion. It fades to black after 30 s with no touch so it isn't a
    /// glowing rectangle in a dark room while you play on the TV with a
    /// controller; any touch on the iPad wakes it. Only meaningful when a TV is
    /// attached (the companion is the only thing that reads this).
    private(set) var companionDimmed = false
    @ObservationIgnored private var companionIdleTask: Task<Void, Never>?
    @ObservationIgnored private var lastCompanionActivity = ContinuousClock.now

    /// Any iPad touch during a stream — wakes the companion and defers the dim.
    func noteCompanionActivity() {
        lastCompanionActivity = .now
        if companionDimmed { companionDimmed = false }
    }

    private func armCompanionIdle() {
        companionIdleTask?.cancel()
        companionDimmed = false
        lastCompanionActivity = .now
        companionIdleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                let idle = self.lastCompanionActivity.duration(to: .now)
                let secs = Double(idle.components.seconds)
                    + Double(idle.components.attoseconds) / 1e18
                if secs >= 30, !self.companionDimmed { self.companionDimmed = true }
            }
        }
    }

    private func cancelCompanionIdle() {
        companionIdleTask?.cancel()
        companionIdleTask = nil
        companionDimmed = false
    }

    func quitCompletely(host: StreamHost) async {
        remoteQuitRequested = true
        setStreamInput(active: false)
        setStatsHUD(active: false)
        cancelCompanionIdle()
        ExternalDisplay.shared.dismiss()   // hand the video layer back to the iPad
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
            armCompanionIdle()   // start the iPad companion's 30 s dim timer
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
        setStreamInput(active: false)
        setStatsHUD(active: false)
        cancelCompanionIdle()
        ExternalDisplay.shared.dismiss()   // hand the video layer back to the iPad
        phase = .failed("Stream failed at stage \(stage.rawValue) (error \(error)). Make sure the host is awake and not busy.")
    }

    fileprivate func handleTerminated(error: Int) {
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
