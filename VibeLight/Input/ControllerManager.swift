#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import CoreHaptics
import GameController
import Observation

/// Translates game-controller and keyboard input into the semantic
/// `NavigationEvent` stream the UI consumes (`Core/Contracts.swift`).
///
/// Why a custom layer exists at all: on macOS, game controllers do NOT drive
/// the SwiftUI/AppKit focus system (that machinery is UIKit/tvOS-only), so
/// every pad press must be translated by hand and fed to our own focus
/// engine. This type is the single place in the app that touches GCController.
///
/// Concurrency: everything lives on the main actor. GCController is not
/// Sendable, and with `handlerQueue = .main` its notifications and element
/// handlers all arrive on the main thread, so callbacks hop in with
/// `MainActor.assumeIsolated` instead of paying for cross-actor sends.
///
/// Stream arbitration: `GCController.shouldMonitorBackgroundEvents` is
/// deliberately LEFT at its default `false`. Foreground-only delivery IS the
/// controller arbitration between the launcher and the Moonlight stream
/// process — the moment the stream window is frontmost we go deaf, and when
/// our window is key again the handlers resume automatically. Never set it
/// to true: we would react to in-game button presses behind the stream.
@MainActor
@Observable
final class ControllerManager {

    // MARK: - Observable state

    /// All currently attached game controllers (keyboards/mice excluded —
    /// GameController reports those separately).
    private(set) var connectedControllers: [GCController] = []

    /// Which glyph family hint bars should render. Follows the most recently
    /// used controller; `.keyboard` when no controller is attached.
    private(set) var glyphStyle: ControllerGlyphStyle = .keyboard

    /// The single output. UI wires this once; both controllers and the
    /// keyboard funnel through it. Always invoked on the main actor.
    @ObservationIgnored var onEvent: ((NavigationEvent) -> Void)?

    /// Set false while a text field is being edited so typing is not
    /// swallowed by the navigation key monitor.
    var keyboardCaptureEnabled = true

    /// Live press-and-hold progress for the quit chords, published for the
    /// on-screen ring. Nil when no chord is armed. Appears only after a short
    /// grace period so quick taps never flash the ring.
    private(set) var holdProgress: HoldProgress?

    /// Context gate for the hold-B quit-app chord: AppState returns whether
    /// the chord is meaningful right now (home screen, no overlay). When it
    /// returns false the chord never arms and B is a plain Back button — a
    /// hold that visibly fills a ring and then does nothing is worse than
    /// no ring at all.
    @ObservationIgnored var quitAppChordEnabled: (@MainActor () -> Bool)?

    /// Fired on every input event with the modality that produced it, so the
    /// UI can hide the cursor on controller/keyboard use and swap to pointer
    /// UI on mouse use.
    @ObservationIgnored var onInputActivity: ((InputMode) -> Void)?

    /// Fired when a pad disconnects (after transient state is cleared). The
    /// stream engine uses this to send a neutral snapshot so the host doesn't
    /// keep the vanished pad's last buttons/sticks latched.
    @ObservationIgnored var onPadDisconnected: (@MainActor () -> Void)?

    /// Stream passthrough. While non-nil, launcher navigation is fully unwired
    /// (no focus moves, no haptics, no chords) and every state change on any
    /// pad is forwarded raw to this closure — the stream owns the controller.
    /// Setting or clearing it rewires all pads and resets transient state so
    /// nothing spuriously fires at the hand-off in either direction.
    @ObservationIgnored var streamForwarder: (@MainActor (GCExtendedGamepad) -> Void)? {
        didSet {
            resetTransientInputState()
            for controller in connectedControllers { wire(controller) }
        }
    }

    // MARK: - Tuning (values from docs/research/swiftui-bigpicture.md)

    private enum Tuning {
        /// Thumbstick hysteresis: engage the dominant axis at ≥ 0.6, release
        /// only when it falls to ≤ 0.4. The gap prevents diagonal jitter and
        /// slow stick returns from re-triggering moves.
        static let engageThreshold: Float = 0.6
        static let releaseThreshold: Float = 0.4
        /// Key-repeat for directional input: first repeat after 0.45 s, then
        /// 10 Hz while held. Buttons never repeat.
        static let initialRepeatDelay: Duration = .milliseconds(450)
        static let repeatInterval: Duration = .milliseconds(100)
        /// Menu held this long fires `.quitChord` once and suppresses the
        /// short-press `.settings` on release.
        static let quitChordHold: Duration = .seconds(1.0)
        /// B/Circle held this long fires `.quitApp` once and suppresses the
        /// short-press `.back` on release. Longer than the Menu chord so a
        /// deliberate "close the app" gesture is never a fumbled Back tap.
        static let quitAppHold: Duration = .seconds(1.5)
    }

    // MARK: - Private state

    @ObservationIgnored private var dpadLatch = DirectionLatch()
    @ObservationIgnored private var stickLatch = DirectionLatch()
    @ObservationIgnored private var heldDirection: MoveDirection?
    @ObservationIgnored private var repeatTask: Task<Void, Never>?

    @ObservationIgnored private var menuIsDown = false
    @ObservationIgnored private var menuLongPressFired = false
    @ObservationIgnored private var menuHoldTask: Task<Void, Never>?

    @ObservationIgnored private var backIsDown = false
    @ObservationIgnored private var backLongPressFired = false
    @ObservationIgnored private var backHoldTask: Task<Void, Never>?

    @ObservationIgnored private var hapticEngine: CHHapticEngine?
    #if os(macOS)
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var mouseMonitor: Any?
    #endif
    @ObservationIgnored private var observerTokens: [NSObjectProtocol] = []

    // MARK: - Lifecycle

    /// Starts observing immediately. The manager is designed to live for the
    /// whole app session; call `stop()` only for tests or explicit teardown
    /// (there is no `deinit` cleanup — main-actor state cannot be touched
    /// from a nonisolated deinit under strict concurrency).
    init() {
        installNotificationObservers()
        #if os(macOS)
        installKeyboardMonitor()
        installMouseMonitor()
        #endif
        refreshControllers()
    }

    /// Single funnel for semantic events: every controller/keyboard event is
    /// directed-modality input activity in addition to its meaning, so the
    /// activity callback can never drift out of sync with event delivery.
    private func emit(_ event: NavigationEvent) {
        onInputActivity?(.directed)
        onEvent?(event)
    }

    /// Tears down observers, the key monitor, timers, and haptics.
    func stop() {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
        #if os(macOS)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        #endif
        resetTransientInputState()
        hapticEngine?.stop(completionHandler: nil)
        hapticEngine = nil
    }

    // MARK: - Notifications

    private func installNotificationObservers() {
        // GameController notifications post on the main thread; requesting
        // the .main queue makes delivery synchronous there, so
        // assumeIsolated inside `observe` is always valid.
        observe(.GCControllerDidConnect) { [weak self] in
            self?.refreshControllers()
        }
        observe(.GCControllerDidDisconnect) { [weak self] in
            // A direction held on the vanished pad would never deliver its
            // release — clear everything before rewiring.
            self?.resetTransientInputState()
            self?.refreshControllers()
            // While streaming, the host also holds the pad's last snapshot —
            // the engine sends a neutral state so buttons/sticks don't stay
            // latched in the remote game. (Don't read the vanished pad: its
            // properties still report the stale pressed state.)
            self?.onPadDisconnected?()
        }
        observe(.GCControllerDidBecomeCurrent) { [weak self] in
            // The user switched pads: hint glyphs and the haptic engine both
            // follow the controller actually in hand.
            self?.updateGlyphStyle()
            self?.rebuildHapticsEngine()
        }
        // CRITICAL: releases are dropped while we are backgrounded (the
        // stream/OS owns the foreground), so any held/repeat state from before
        // the handoff is stale. Without this reset, a d-pad held across the
        // transition auto-repeats forever — the runaway-repeat bug.
        #if os(macOS)
        let didBecomeActive = NSApplication.didBecomeActiveNotification
        #else
        let didBecomeActive = UIApplication.didBecomeActiveNotification
        #endif
        observe(didBecomeActive) { [weak self] in
            self?.handleAppBecameActive()
        }
    }

    /// Runaway-repeat guard: clears stale held/repeat state and re-scans pads.
    /// Fired on `didBecomeActive` (both platforms) and, on iOS, also reachable
    /// from the SwiftUI scene-phase hook.
    func handleAppBecameActive() {
        resetTransientInputState()
        refreshControllers()
    }

    private func observe(_ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
        let token = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
        observerTokens.append(token)
    }

    // MARK: - Controller wiring

    private func refreshControllers() {
        connectedControllers = GCController.controllers()
        for controller in connectedControllers {
            wire(controller)
        }
        updateGlyphStyle()
        rebuildHapticsEngine()
    }

    /// The controller whose identity drives glyphs and haptics: the most
    /// recently used one, as long as it is still attached.
    private var activeController: GCController? {
        connectedControllers.first { $0 === GCController.current } ?? connectedControllers.first
    }

    private func updateGlyphStyle() {
        glyphStyle = ControllerGlyphStyle(controller: activeController)
    }

    /// Assigning handlers is idempotent, so rewiring on every connect/refresh
    /// is safe and keeps the logic in one place.
    private func wire(_ controller: GCController) {
        controller.handlerQueue = .main
        guard let pad = controller.extendedGamepad else { return }

        if streamForwarder != nil {
            // Stream passthrough: drop every launcher binding and forward the
            // whole profile on any element change (fires for sticks, triggers,
            // and buttons the launcher never listens to).
            pad.dpad.valueChangedHandler = nil
            pad.leftThumbstick.valueChangedHandler = nil
            pad.buttonA.pressedChangedHandler = nil
            pad.buttonX.pressedChangedHandler = nil
            pad.buttonY.pressedChangedHandler = nil
            pad.leftShoulder.pressedChangedHandler = nil
            pad.rightShoulder.pressedChangedHandler = nil
            pad.buttonB.pressedChangedHandler = nil
            pad.buttonMenu.pressedChangedHandler = nil
            pad.valueChangedHandler = { [weak self] pad, _ in
                MainActor.assumeIsolated {
                    self?.streamForwarder?(pad)
                }
            }
            return
        }
        pad.valueChangedHandler = nil

        // D-pad and left thumbstick are one logical directional source;
        // whichever produced input last wins (see directionalInputChanged).
        pad.dpad.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated {
                self?.directionalInputChanged(.dpad, x: x, y: y)
            }
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated {
                self?.directionalInputChanged(.leftStick, x: x, y: y)
            }
        }

        bind(pad.buttonA, to: .select)
        bind(pad.buttonX, to: .contextMenu)
        bind(pad.buttonY, to: .detail)
        bind(pad.leftShoulder, to: .prevSection)
        bind(pad.rightShoulder, to: .nextSection)

        // B/Circle is special like Menu: a tap is `.back`, a ≥1.5 s hold is the
        // `.quitApp` chord (close VibeLight from the couch). Needs both edges.
        pad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated {
                self?.backButtonChanged(pressed: pressed)
            }
        }

        // Menu is special: short press vs ≥1 s hold diverge (settings vs
        // global quit chord), so it needs both edges, not just the press.
        pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated {
                self?.menuButtonChanged(pressed: pressed)
            }
        }
    }

    /// Buttons fire once on the press edge and never repeat.
    private func bind(_ button: GCControllerButtonInput, to event: NavigationEvent) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated {
                guard pressed else { return }
                self?.emit(event)
            }
        }
    }

    // MARK: - Directional input (hysteresis + key repeat)

    private enum DirectionalSource {
        case dpad, leftStick
    }

    private func directionalInputChanged(_ source: DirectionalSource, x: Float, y: Float) {
        let updated: MoveDirection?
        switch source {
        case .dpad: updated = dpadLatch.update(x: x, y: y)
        case .leftStick: updated = stickLatch.update(x: x, y: y)
        }
        // The source that just produced input wins; if it released, fall back
        // to whatever the other source still holds so letting go of the stick
        // does not cancel a held d-pad (and vice versa).
        let other = source == .dpad ? stickLatch.direction : dpadLatch.direction
        setHeldDirection(updated ?? other)
    }

    private func setHeldDirection(_ direction: MoveDirection?) {
        guard direction != heldDirection else { return }
        repeatTask?.cancel()
        repeatTask = nil
        heldDirection = direction
        guard let direction else { return }

        // Move immediately on engage, then auto-repeat while held.
        emit(.move(direction))
        repeatTask = Task { [weak self] in
            try? await Task.sleep(for: Tuning.initialRepeatDelay)
            while !Task.isCancelled {
                guard let self, let held = self.heldDirection else { return }
                self.emit(.move(held))
                try? await Task.sleep(for: Tuning.repeatInterval)
            }
        }
    }

    // MARK: - Hold chords (shared runner)

    /// Drives one press-and-hold chord: waits a short grace (so quick taps
    /// never flash UI), then publishes ring progress at ~30 Hz until the
    /// threshold, fires the event exactly once, and clears the ring. Release
    /// or reset cancels the task; the defer clears any leftover ring state.
    private func runHoldChord(
        kind: HoldProgress.Kind, duration: Duration, event: NavigationEvent,
        stillHeld: @escaping @MainActor () -> Bool,
        markFired: @escaping @MainActor () -> Void
    ) async {
        let clock = ContinuousClock()
        let start = clock.now
        let grace: Duration = .milliseconds(250)
        defer {
            if holdProgress?.kind == kind { holdProgress = nil }
        }
        while !Task.isCancelled && stillHeld() {
            let elapsed = start.duration(to: clock.now)
            if elapsed >= duration {
                markFired()
                holdProgress = nil
                emit(event)
                return
            }
            if elapsed >= grace {
                let fraction = (elapsed - grace) / (duration - grace)
                holdProgress = HoldProgress(kind: kind, fraction: min(max(fraction, 0), 1))
            }
            try? await Task.sleep(for: .milliseconds(33))
        }
    }

    // MARK: - Menu button (short press vs quit chord)

    private func menuButtonChanged(pressed: Bool) {
        if pressed {
            menuIsDown = true
            menuLongPressFired = false
            menuHoldTask?.cancel()
            menuHoldTask = Task { [weak self] in
                guard let self else { return }
                await self.runHoldChord(
                    kind: .quitGame, duration: Tuning.quitChordHold, event: .quitChord,
                    stillHeld: { self.menuIsDown && !self.menuLongPressFired },
                    markFired: { self.menuLongPressFired = true }
                )
            }
        } else {
            // `wasDown` guards against a phantom release right after the
            // background→foreground reset cleared our state.
            let wasDown = menuIsDown
            let firedLongPress = menuLongPressFired
            menuIsDown = false
            menuLongPressFired = false
            menuHoldTask?.cancel()
            menuHoldTask = nil
            if wasDown && !firedLongPress {
                emit(.settings)
            }
        }
    }

    // MARK: - Back button (tap = back, hold = quit app)

    private func backButtonChanged(pressed: Bool) {
        if pressed {
            backIsDown = true
            backLongPressFired = false
            backHoldTask?.cancel()
            // iOS can't self-quit (HIG), so the quit-app chord is meaningless —
            // never arm the ring there; B stays a plain Back button.
            #if os(iOS)
            return
            #else
            // Only arm the chord where quitting the app is meaningful (home,
            // no overlay). Elsewhere B is a plain Back button.
            guard quitAppChordEnabled?() ?? false else { return }
            backHoldTask = Task { [weak self] in
                guard let self else { return }
                await self.runHoldChord(
                    kind: .quitApp, duration: Tuning.quitAppHold, event: .quitApp,
                    stillHeld: { self.backIsDown && !self.backLongPressFired },
                    markFired: { self.backLongPressFired = true }
                )
            }
            #endif
        } else {
            let wasDown = backIsDown
            let firedLongPress = backLongPressFired
            backIsDown = false
            backLongPressFired = false
            backHoldTask?.cancel()
            backHoldTask = nil
            if wasDown && !firedLongPress {
                emit(.back)
            }
        }
    }

    // MARK: - State reset

    /// Clears every piece of transient held/repeat state. Called on
    /// disconnects and whenever the app becomes active again, because
    /// release events that happened while backgrounded were never delivered.
    private func resetTransientInputState() {
        repeatTask?.cancel()
        repeatTask = nil
        menuHoldTask?.cancel()
        menuHoldTask = nil
        backHoldTask?.cancel()
        backHoldTask = nil
        heldDirection = nil
        dpadLatch.reset()
        stickLatch.reset()
        menuIsDown = false
        menuLongPressFired = false
        backIsDown = false
        backLongPressFired = false
        holdProgress = nil
    }

    // MARK: - Haptics

    /// Plays a light transient tick on the controller for focus moves.
    /// Silently does nothing when the pad exposes no haptics — Xbox
    /// Bluetooth pads on macOS often report none, and that must never crash.
    func focusTick() {
        guard let engine = hapticEngine else { return }
        do {
            // start() is a no-op when already running and revives an engine
            // the system idled/reset — cheaper than juggling resetHandler.
            try engine.start()
            let tick = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.45),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.55),
                ],
                relativeTime: 0
            )
            let pattern = try CHHapticPattern(events: [tick], parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            // Haptics are decoration. A failed engine goes quiet until the
            // next controller change rebuilds it.
            hapticEngine = nil
        }
    }

    /// A CHHapticEngine is bound to one physical controller and becomes
    /// invalid when that controller disconnects, so it is rebuilt on every
    /// connect/disconnect/became-current transition.
    private func rebuildHapticsEngine() {
        hapticEngine?.stop(completionHandler: nil)
        hapticEngine = nil
        guard let haptics = activeController?.haptics else { return }
        hapticEngine = haptics.createEngine(withLocality: .default)
    }

    // MARK: - Keyboard (macOS)

    #if os(macOS)
    /// Pointer activity flips the UI into mouse mode. Observe-only local
    /// monitor — every event passes through untouched. (mouseMoved events
    /// require the key window to opt in via acceptsMouseMovedEvents.)
    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown,
                       .otherMouseDown, .scrollWheel, .leftMouseDragged]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.onInputActivity?(.pointer)
            }
            return event
        }
    }

    /// Local (own-app-only, no Accessibility permission) keyDown monitor so
    /// the keyboard drives the exact same NavigationEvent stream as a pad.
    private func installKeyboardMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Local monitors run on the main thread; hop into the actor
            // without a send (NSEvent is not Sendable).
            var verdict: NSEvent? = event
            MainActor.assumeIsolated {
                verdict = self.handleKeyDown(event)
            }
            return verdict
        }
    }

    /// Returns nil for consumed events so they never reach the responder
    /// chain (this is also what beats the app menu to Cmd-,); anything we do
    /// not understand passes through untouched.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard keyboardCaptureEnabled else { return event }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Chorded bindings: Cmd-, opens settings; Cmd-Shift-Q is the keyboard
        // path to "quit the remote game completely" (the hint bar advertises
        // it, so it must exist — controllers use the Menu long-press instead).
        // Every other Cmd/Ctrl/Opt chord belongs to the system or menus
        // (plain Cmd-Q quits VibeLight itself via the app menu).
        if flags.contains(.command) {
            if event.charactersIgnoringModifiers == "," {
                emit(.settings)
                return nil
            }
            if flags.contains(.shift), event.charactersIgnoringModifiers?.lowercased() == "q" {
                emit(.quitChord)
                return nil
            }
            return event
        }
        guard flags.isDisjoint(with: [.control, .option]) else { return event }

        let navEvent: NavigationEvent?
        switch event.keyCode {
        case 126: navEvent = .move(.up)
        case 125: navEvent = .move(.down)
        case 123: navEvent = .move(.left)
        case 124: navEvent = .move(.right)
        case 36, 76: navEvent = .select      // Return / keypad Enter
        case 53: navEvent = .back            // Escape
        case 49: navEvent = .contextMenu     // Space
        case 48: navEvent = .detail          // Tab
        default: navEvent = nil
        }
        guard let navEvent else { return event }

        // Arrows ride the system's own key repeat (isARepeat); action keys
        // must not machine-gun while held.
        if event.isARepeat {
            if case .move = navEvent {
                emit(navEvent)
            }
            return nil
        }
        emit(navEvent)
        return nil
    }
    #endif

    // MARK: - DirectionLatch

    /// Hysteresis latch for one directional source (d-pad or thumbstick).
    /// Engages on the dominant axis at ≥ `engageThreshold`; once engaged the
    /// direction is held until its component falls to ≤ `releaseThreshold`.
    /// Holding the engaged axis (rather than re-picking the dominant one)
    /// is what stops diagonal jitter mid-hold.
    private struct DirectionLatch {
        private(set) var direction: MoveDirection?

        /// Feeds a new axis sample; returns the currently engaged direction.
        mutating func update(x: Float, y: Float) -> MoveDirection? {
            if let engaged = direction {
                if component(of: engaged, x: x, y: y) <= Tuning.releaseThreshold {
                    direction = nil
                } else {
                    return engaged
                }
            }
            let ax = abs(x), ay = abs(y)
            guard max(ax, ay) >= Tuning.engageThreshold else { return direction }
            direction = ax >= ay ? (x > 0 ? .right : .left) : (y > 0 ? .up : .down)
            return direction
        }

        mutating func reset() {
            direction = nil
        }

        /// Signed magnitude of the sample along a direction (GameController
        /// convention: +y is up).
        private func component(of direction: MoveDirection, x: Float, y: Float) -> Float {
            switch direction {
            case .up: y
            case .down: -y
            case .left: -x
            case .right: x
            }
        }
    }
}
