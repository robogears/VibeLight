import SwiftUI

/// Top-level scene composition: ambient background, current screen, overlays —
/// laid out in a resolution-adaptive virtual canvas so the big-picture UI keeps
/// the same physical proportions at any display size (see `uiScale`).
struct RootView: View {
    @Environment(AppState.self) private var state
    #if os(iOS)
    /// Detects the accidental case where iPadOS puts THIS window on an external
    /// screen (Stage Manager, launched from the TV). Safe-by-default — see
    /// `ExternalScenePlacement`. Scene-scoped state, not a singleton.
    @State private var placement = ExternalScenePlacement()

    /// Equatable flag the stream overlay's enter/exit animation binds to.
    private var isStreamingPhase: Bool {
        if case .streaming = state.session.phase { return true }
        return false
    }

    /// Idle and a TV owns the launcher: the iPad shows only the companion
    /// panel. Needs a gamepad — the TV takes no touch, so without one the
    /// launcher stays on the iPad and the TV mirrors it.
    private var companionOwnsIPad: Bool {
        AppState.companionPanelOwnsIPad(useTV: state.settings.externalDisplay,
                                        tvConnected: ExternalDisplay.shared.isConnected,
                                        streaming: isStreamingPhase,
                                        hasGamepad: state.controller.hasGamepad)
    }

    /// Screen edges whose system swipes (Home, app switcher, Control Center,
    /// Notification Center) wait for a second swipe: every edge while a stream
    /// is live, none in the launcher. (UX-stream-edge-gestures-not-deferred)
    static func deferredSystemEdges(streaming: Bool) -> Edge.Set {
        streaming ? .all : []
    }

    #if os(iOS)
    /// A TV companion panel button: the 44 pt dark circle the panel's lone ✕
    /// always used, now beside the keyboard button too.
    private func companionButton(_ symbol: String, label: String, isOn: Bool? = nil,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(isOn == true ? Theme.onAccent : .white)
                .frame(width: 44, height: 44)
                .background(isOn == true ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.black.opacity(0.45)),
                            in: Circle())
        }
        .accessibilityLabel(label)
        .accessibilityValue(isOn.map { $0 ? "On" : "Off" } ?? "")
    }
    #endif

    #endif

    /// True when an opaque stream is covering the launcher on THIS screen — so
    /// the launcher (and its animated background) can stop drawing. False when a
    /// TV owns the video, because then the iPad still shows the companion panel.
    ///
    /// Always false on macOS: there the stream is a separate helper window and
    /// the window coordinator hides the launcher outright, so nothing is
    /// rendering underneath in the first place.
    private var isStreamCovering: Bool {
        #if os(iOS)
        guard isStreamingPhase else { return false }
        let onTV = state.settings.externalDisplay && ExternalDisplay.shared.isConnected
        return !onTV
        #else
        return false
        #endif
    }

    var body: some View {
        GeometryReader { geo in
            let scale = Self.uiScale(for: geo.size, interfaceSize: state.interfaceSize)
            // On iOS the stream is an OVERLAY, so the launcher underneath is
            // never unmounted — and seven of the ten background themes
            // (including the default) animate every display frame. That kept a
            // full-screen animation compositing at 120 Hz behind an opaque
            // stream, burning GPU and battery for pixels nobody can see.
            // Rendering an empty placeholder instead keeps the view identity
            // (so the 0.45 s cross-fade below still animates) while dropping
            // the work to nothing.
            LauncherContent()
                .opacity(isStreamCovering ? 0 : 1)
                .allowsHitTesting(!isStreamCovering)
                // Lay the whole UI out in a virtual canvas (real size ÷ scale),
                // then scale it to fill the screen from the top-leading corner
                // (GeometryReader anchors its child there). On a normal Mac scale
                // is exactly 1.0 → identity, zero change. On a 4K/5K display it
                // upscales so elements aren't tiny; on iPhone/iPad it fits the
                // full design to the screen. topLeading anchor keeps the scaled
                // canvas exactly overlaying the screen (a .center anchor pushes
                // an oversized virtual frame off-screen).
                .frame(width: geo.size.width / scale, height: geo.size.height / scale,
                       alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
        }
        .ignoresSafeArea()
        #if os(iOS)
        // While a TV owns the display, the iPad is a companion screen — the
        // launcher shows ONLY on the TV. Shown the instant a display connects
        // (isConnected is observable), only when not streaming (the stream
        // overlay below provides its own placeholder + trackpad), and only
        // while a gamepad can drive the TV (UX-tv-attached-touch-dead-end):
        // a pad dropping out puts the launcher back under the user's finger.
        .overlay {
            if companionOwnsIPad {
                ExternalDisplayPlaceholder(streaming: false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: companionOwnsIPad)
        // Live stream covers the whole screen (unscaled) while it's up.
        .overlay {
            if case .streaming = state.session.phase {
                // A TV is showing the video → the iPad is a companion panel
                // (StreamView doesn't host the TV's layer).
                let onTV = state.settings.externalDisplay && ExternalDisplay.shared.isConnected
                // When the iPad companion has blacked out for the dark room, hide
                // its lit controls too so the blackout is complete — a touch
                // brings the game onto the iPad.
                let dimmedOnTV = onTV && state.session.companionDimmed
                // A tap on the companion brings the game onto the iPad too (its
                // own mirror layer — the TV keeps the main one) until 15 s
                // without a touch; see InProcessStreamEngine.CompanionView.
                let gameOnIPad = onTV && state.session.companionShowsStream
                StreamView(layer: gameOnIPad ? state.session.mirrorLayer : state.session.displayLayer,
                           engine: state.session, hostsLayer: !onTV || gameOnIPad)
                    .ignoresSafeArea()
                    .overlay {
                        if onTV && !gameOnIPad {
                            ExternalDisplayPlaceholder(dimmed: state.session.companionDimmed)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: gameOnIPad)
                    .overlay(alignment: .topLeading) {
                        // Performance HUD (Settings ▸ Advanced ▸ Performance Stats).
                        // On the iPad it also mirrors to the TV; hidden while the
                        // companion is dimmed (still shown on the TV).
                        if let stats = state.session.perfStats, !dimmedOnTV {
                            Text(stats)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.9))
                                .multilineTextAlignment(.leading)
                                .lineSpacing(2)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                                .padding(24)
                                .allowsHitTesting(false)   // touches pass through to the stream
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        // Leave the stream, and raise the iPad's keyboard so the
                        // host types as if one were plugged into it. Over the
                        // game (handheld, or a TV's game shown on the iPad) they
                        // retire after a few seconds; on the TV companion panel
                        // nothing covers gameplay, so ✕ and the keyboard stay put
                        // (owner: keyboard button on by default there).
                        let keyboardUp = Binding(
                            get: { state.session.onScreenKeyboardUp },
                            set: { state.session.onScreenKeyboardUp = $0 }
                        )
                        if !onTV || gameOnIPad {
                            StreamControls(onLeave: { state.session.disconnect() }, keyboardUp: keyboardUp,
                                           statsOn: state.session.showPerfOverlay,
                                           onToggleStats: { state.session.togglePerformanceStats() })
                        } else if !dimmedOnTV {
                            HStack(spacing: 12) {
                                companionButton("speedometer", label: "Performance stats",
                                                isOn: state.session.showPerfOverlay) {
                                    state.session.togglePerformanceStats()
                                }
                                companionButton(keyboardUp.wrappedValue ? "keyboard.chevron.compact.down" : "keyboard",
                                                label: keyboardUp.wrappedValue ? "Hide the keyboard" : "Show the keyboard") {
                                    keyboardUp.wrappedValue.toggle()
                                }
                                companionButton("xmark", label: "Leave the stream") {
                                    state.session.disconnect()
                                }
                            }
                            .padding(24)
                        }
                    }
                    .overlay {
                        // Zero-size and invisible: it exists only to own the
                        // keyboard and receive what is typed.
                        StreamKeyboard(
                            isUp: Binding(
                                get: { state.session.onScreenKeyboardUp },
                                set: { state.session.onScreenKeyboardUp = $0 }
                            ),
                            onCharacter: { state.session.typeCharacter($0) },
                            onBackspace: { state.session.typeBackspace() }
                        )
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                    }
                    // Hold Start+Select+L1+R1 → the fade + ring. The TV draws
                    // the same view over its video (ExternalDisplay's stream
                    // overlay), so the exit plays on both screens.
                    .overlay { StreamExitOverlay() }
                    .transition(.opacity)
            }
        }
        // Bound to the streaming flag so the overlay's insertion/removal
        // actually animates (the .transition above never ran without it) —
        // the launcher now fades back in when the stream ends.
        .animation(.easeInOut(duration: 0.45), value: isStreamingPhase)
        // Mid-game, a drag that starts at a screen edge must reach the game
        // first: without deferral one bottom-edge swipe goes Home, which ends
        // the stream and (quit game on app exit is always on) closes the
        // game on the PC. Deferred, iOS needs a second swipe, as in Moonlight.
        // Streaming only: the launcher keeps normal one-swipe gestures. The
        // stream controls' grab pill is a tap/drag target inside the edge, so
        // deferral only makes it MORE reliably ours.
        // (UX-stream-edge-gestures-not-deferred)
        .defersSystemGestures(on: Self.deferredSystemEdges(streaming: isStreamingPhase))
        // Accidental case: the app's OWN window is on an external screen (Stage
        // Manager extended display, launched from the TV). Guide the user back to
        // the iPad. Last overlay → wins the z-order; safe-by-default so it can
        // never cover the normal iPad UI (see `ExternalScenePlacement`). The
        // `!isConnected` gate is redundant belt-and-suspenders with the placement
        // guards, and makes the card hide the instant the real TV scene engages.
        .overlay {
            if placement.isOnExternalScreen && !ExternalDisplay.shared.isConnected {
                ExternalRedirectCard()
            }
        }
        // Always-present, invisible probe: reads RootView's own hosting window and
        // updates `placement` on attach + cross-screen moves + display churn.
        .background(ScenePlacementProbe(placement: placement))
        // Leaving a stream: black until it has fully closed, then a slow fade
        // into the menu. Above the stream view and the session-ended card.
        .overlay { ExitCurtain() }
        #endif
        // First-run setup wizard — unskippable, over everything (both platforms).
        // Input is already gated to it in AppState.route while a step is active.
        .overlay {
            ZStack {
                if let step = state.onboardingStep {
                    OnboardingFlow(step: step)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: state.onboardingStep)
        }
    }

    /// The scale that maps the design canvas onto the real window. The UI is
    /// authored on a landscape design canvas; we fit that canvas to the real
    /// window across BOTH dimensions so it never overflows — the previous
    /// width-only, floor-1.0 rule left a small/windowed Mac at full design size,
    /// so the title, logo and preset row overflowed and collided.
    /// - macOS: 1.0 through the normal Mac range (design flexes comfortably at
    ///   ≥ 1440×860 pt); SHRINK to fit a smaller window; scale UP on 4K/5K so
    ///   fixed-size elements aren't tiny.
    /// - iOS/iPadOS: fit the same 1440×860 canvas to the (landscape) screen. It
    ///   used to fit 1920×1080 × 1.25, which shrank every label on iPad below
    ///   Apple's 11 pt minimum (UX-ios-scale-shrinks-text-targets).
    /// Settings ▸ Themes ▸ Interface Size then multiplies the result, but never
    /// past the point where the virtual canvas would drop under `canvasFloor`.
    nonisolated static let designMin = CGSize(width: 1440, height: 860)
    /// Below this canvas Home's fixed vertical stack (header, hero, shelf,
    /// preset row, hint bar ≈ 800 pt) overflows, so "Large" is "as large as
    /// the layout allows" — on a screen already at the floor it changes nothing.
    nonisolated static let canvasFloor = CGSize(width: 1000, height: 860)

    /// Which branch of the rule to use — a parameter so the macOS test target
    /// can check the iOS numbers too.
    enum Platform: Sendable {
        case macOS, iOS
        static var current: Platform {
            #if os(macOS)
            .macOS
            #else
            .iOS
            #endif
        }
    }

    nonisolated static func uiScale(for size: CGSize, interfaceSize: InterfaceSize = .default,
                                    platform: Platform = .current) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        let base = baseScale(for: size, platform: platform)
        let canvas = CGSize(width: size.width / base, height: size.height / base)
        let cap = min(canvas.width / canvasFloor.width, canvas.height / canvasFloor.height)
        return base * min(interfaceSize.factor, max(cap, 1))
    }

    /// The Default-size scale for each platform.
    nonisolated private static func baseScale(for size: CGSize, platform: Platform) -> CGFloat {
        let fit = min(size.width / designMin.width, size.height / designMin.height)
        switch platform {
        case .macOS:
            // Shrink to fit when the window is smaller than the design canvas…
            if fit < 1 { return max(fit, 0.3) }
            // …otherwise 1.0 in the normal range, scaling up only on huge displays.
            return min(max(size.width / 2000, 1.0), 2.5)
        case .iOS:
            return min(max(fit, 0.3), 1.6)
        }
    }
}

/// The big-picture launcher surface — ambient background, the current screen,
/// and any overlays. Extracted from `RootView` so the external-display window
/// can render the SAME UI (bound to the SAME `AppState`) on a connected TV.
struct LauncherContent: View {
    @Environment(AppState.self) private var state
    /// This launcher's tile positions for the starting card (see LiftGeometry).
    @State private var lift = LiftGeometry()

    var body: some View {
        ZStack {
            AppBackground(theme: state.backgroundTheme)

            switch state.screen {
            case .home:
                HomeView()
                    .transition(.opacity)
            case .settings:
                SettingsView()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if let overlay = state.overlay {
                OverlayHost(overlay: overlay)
                    .transition(.opacity)
            }

            // A held button (the still-running card's Quit) fills itself.
            if let hold = state.controller.holdProgress, hold.kind != .quitGameButton {
                HoldProgressRing(progress: hold)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        // Tiles and the starting card share this space, so the card can start
        // exactly over the tile that was pressed.
        .coordinateSpace(.named(LiftGeometry.space))
        .environment(\.liftGeometry, lift)
        .animation(Theme.focusSpring, value: state.screen)
        .animation(.easeOut(duration: 0.18), value: state.overlay)
        .animation(.easeOut(duration: 0.15), value: state.controller.holdProgress == nil)
    }
}

#if os(iOS)
/// The leave-stream hold's feedback, drawn over the video on the iPad AND on
/// the TV (the TV's stream window is UIKit, so it hosts this view on top of
/// the video — see `ExternalDisplay.setStreamOverlayBuilder`). It used to live
/// only in RootView, so on a TV the hold showed nothing on the screen people
/// were actually watching.
struct StreamExitOverlay: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// "Frame Trace" (owner's pick of four, Oct 2026): an accent line traces
    /// the screen's edge from the top centre both ways and meets at the
    /// bottom; gameplay stays visible. At fire the border swells inward and
    /// swallows the picture. The engine waits this long after fire before
    /// tearing the stream view down, so the swell always lands on black.
    static let fireDuration: Duration = .milliseconds(350)

    /// Set one transaction after progress pins at 1, so the p = 1 frame (the
    /// thick, complete border) is drawn once before the swell runs.
    @State private var fired = false
    private static var fireSeconds: Double {
        Double(fireDuration.components.seconds) + Double(fireDuration.components.attoseconds) / 1e18
    }

    var body: some View {
        GeometryReader { geo in
            let p = state.session.streamQuitProgress
            // TV points sit ~1.6× further from the eye than the iPad's at the
            // same visual size; this overlay is also hosted over the TV video.
            let tv = max(1, min(geo.size.width / 1194, 1.6))
            // Redrawn every display refresh while the line is moving (120 Hz on
            // the iPad), from the hold's start time — the engine's 40 ms steps
            // only decide nil / running / fired. Paused otherwise.
            TimelineView(.animation(paused: !(p.map { $0 < 1 } ?? false))) { context in
                ZStack {
                    if let shown = Self.displayProgress(engine: p, startedAt: state.session.quitHoldStartedAt,
                                                        now: context.date) {
                        ZStack { frameTrace(p: shown, tv: tv, size: geo.size) }
                            .transition(.opacity.animation(.easeOut(duration: 0.15)))   // cancel: fades away
                    }
                }
            }
            .onChange(of: p == 1) { _, isFired in
                withAnimation(reduceMotion ? nil : .easeIn(duration: Self.fireSeconds)) { fired = isFired }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)   // touches still reach the stream underneath
    }

    /// The progress to draw at `now`. The engine owns the states (nil = not
    /// holding, 1 = fired); between them the line follows the clock, not the
    /// engine's 40 ms steps, so it moves every frame.
    nonisolated static func displayProgress(engine: Double?, startedAt: Date?, now: Date) -> Double? {
        guard let engine else { return nil }
        guard engine < 1, let startedAt else { return engine }
        let span = InProcessStreamEngine.leaveHoldSeconds - InProcessStreamEngine.leaveHoldGrace
        let t = now.timeIntervalSince(startedAt) - InProcessStreamEngine.leaveHoldGrace
        return min(max(t / span, 0), 0.999)   // 1 is the engine's to declare (fire)
    }

    @ViewBuilder
    private func frameTrace(p: Double, tv: CGFloat, size: CGSize) -> some View {
        let frame = ScreenPerimeter(inset: 10 * tv, radius: 28 * tv)
        Color.black.opacity(0.25 * p)
        frame.stroke(.white.opacity(0.12), lineWidth: 6 * tv)
            .opacity(min(p * 4, 1))
        if reduceMotion {
            // No tracing: the whole border fades in; fire cuts to black.
            frame.stroke(Theme.accent, lineWidth: 6 * tv).opacity(p)
            Color.black.opacity(fired ? 1 : 0)
        } else {
            // The swell: a black stroke on the same path, wide enough to
            // cover the screen from its edge inward.
            frame.stroke(.black, lineWidth: fired ? 2 * hypot(size.width, size.height) : 0)
            ForEach([1.0, -1.0], id: \.self) { direction in
                frame.trim(from: 0, to: p / 2)
                    .stroke(Theme.accent,
                            style: StrokeStyle(lineWidth: (p >= 1 ? 14 : 6) * tv, lineCap: .round))
                    .scaleEffect(x: direction)      // the second line runs anticlockwise
                    .shadow(color: Theme.accentGlow, radius: 10)
                    .opacity(fired ? 0 : 1)
            }
        }
        (Text("Leaving the stream ").bold()
            + Text("· game keeps running on the PC").foregroundStyle(Theme.textSecondary))
            .font(.system(size: 15 * tv, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14 * tv)
            .padding(.vertical, 7 * tv)
            .background(Theme.surface.opacity(0.85), in: Capsule())
            .opacity(min(p * 3, 1) * (fired ? 0 : 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 36 * tv)
    }
}

/// The screen's edge as a rounded rectangle whose path STARTS at the top
/// centre and runs clockwise, so `trim(0, p/2)` grows from there, and its
/// horizontal mirror runs the other way: the two meet at the bottom centre.
private struct ScreenPerimeter: Shape {
    var inset: CGFloat
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let b = rect.insetBy(dx: inset, dy: inset)
        var p = Path()
        p.move(to: CGPoint(x: b.midX, y: b.minY))
        p.addLine(to: CGPoint(x: b.maxX - radius, y: b.minY))
        p.addArc(tangent1End: CGPoint(x: b.maxX, y: b.minY),
                 tangent2End: CGPoint(x: b.maxX, y: b.minY + radius), radius: radius)
        p.addLine(to: CGPoint(x: b.maxX, y: b.maxY - radius))
        p.addArc(tangent1End: CGPoint(x: b.maxX, y: b.maxY),
                 tangent2End: CGPoint(x: b.maxX - radius, y: b.maxY), radius: radius)
        p.addLine(to: CGPoint(x: b.minX + radius, y: b.maxY))
        p.addArc(tangent1End: CGPoint(x: b.minX, y: b.maxY),
                 tangent2End: CGPoint(x: b.minX, y: b.maxY - radius), radius: radius)
        p.addLine(to: CGPoint(x: b.minX, y: b.minY + radius))
        p.addArc(tangent1End: CGPoint(x: b.minX, y: b.minY),
                 tangent2End: CGPoint(x: b.minX + radius, y: b.minY), radius: radius)
        p.closeSubpath()
        return p
    }
}

/// What the external display (TV / monitor) shows when NOT streaming: the full
/// launcher UI, fit to the TV. During a stream the window swaps to the raw
/// stream layer (see `ExternalDisplay`), so this view is only the idle surface.
struct ExternalDisplayContent: View {
    @Environment(AppState.self) private var state

    /// TV design canvas. The iPad's effective canvas is ~1536 wide; a SMALLER
    /// one makes tiles/text read larger from the couch, but it must stay wide
    /// enough that the launcher's landscape layout (header row, shelf, preset
    /// row) doesn't crowd — 1280 was too narrow (that was the "misaligned").
    /// The launcher renders at ≥2× (forced in `ExternalDisplay` — old 1080p TVs
    /// report @1×, which would rasterize this canvas at 1× and upscale → blur),
    /// so a 1440-pt canvas rasterizes at 2880 px and DOWNSAMPLES to the panel:
    /// crisp on a 1080p TV, and sharp at 4K. One-line tunable — smaller = bigger
    /// icons.
    private static let tvDesign = CGSize(width: 1440, height: 810)

    var body: some View {
        GeometryReader { geo in
            let scale = max(min(geo.size.width / Self.tvDesign.width,
                                geo.size.height / Self.tvDesign.height), 0.4)
            LauncherContent()
                .frame(width: geo.size.width / scale, height: geo.size.height / scale,
                       alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
        }
        .ignoresSafeArea()
        .background(Theme.background)
        // The TV swaps from the stream to this launcher the moment the stream
        // closes; the curtain keeps that swap black until it fades with the iPad.
        .overlay { ExitCurtain() }
    }
}

/// The leave-stream curtain (`InProcessStreamEngine.exitCurtain`). Goes black
/// instantly — the Frame Trace swell has already made the screen black — and
/// fades out slowly once the stream has closed.
struct ExitCurtain: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let opacity = state.session.exitCurtain
        Color.black
            .opacity(opacity)
            .ignoresSafeArea()
            .allowsHitTesting(opacity > 0)   // nothing is tapped through the black
            .animation(opacity == 0 ? .easeInOut(duration: InProcessStreamEngine.exitCurtainFadeOut) : nil,
                       value: opacity)
    }
}

/// The iPad companion screen shown whenever a TV / monitor is driving the
/// display — VibeLight itself lives on the big screen, so the iPad is a calm
/// status panel. While streaming it's also a trackpad (touches pass through);
/// while idle it says "use your controller". (It once offered a "Use the iPad
/// Instead" button; the owner removed it. The panel only takes the iPad while a
/// gamepad can drive the TV — see `companionPanelOwnsIPad` — so there is no
/// dead end without it. TV output itself is always on — the owner removed the
/// Use TV / Monitor option.)
private struct ExternalDisplayPlaceholder: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast
    var streaming = true

    /// Whether touches on the game (once a tap brings it onto the iPad) reach
    /// the host: the phantom-cursor gate suppresses touch while a gamepad is
    /// connected (unless the user re-enabled it) — the copy must not promise
    /// touch that won't work.
    private var trackpadLive: Bool {
        state.settings.touchWithController ||
            !state.controller.connectedControllers.contains { $0.extendedGamepad != nil }
    }
    /// True 5 s after the panel appears untouched while streaming: the
    /// companion fades to PURE black (only the lit glow + text fade — the base
    /// black stays opaque) so it isn't a glowing rectangle in a dark room. Any
    /// touch brings the game onto the iPad (see `noteCompanionActivity`).
    var dimmed = false

    var body: some View {
        ZStack {
            Color.black   // always opaque — hides the video underneath on the iPad
            if !dimmed {
                driftingContent
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.8), value: dimmed)
        .contentShape(Rectangle())
        // Streaming → pass touches through to the stream view, where a tap
        // brings the game onto the iPad (it is not sent to the PC); idle →
        // consume them so the hidden launcher can't be poked.
        .allowsHitTesting(!streaming)
        .ignoresSafeArea()
    }

    // OLED-friendly: a dim glow slowly roams into the corners and the content
    // gently drifts — so no bright pixel stays lit in one place for the whole
    // (possibly hours-long) session.
    private var driftingContent: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let dx = CGFloat(sin(t * 0.06))                 // slow, ~100 s period
            let dy = CGFloat(cos(t * 0.045))
            ZStack {
                Color.black
                RadialGradient(colors: [Theme.accent.opacity(0.12), .clear],
                               center: .center, startRadius: 0, endRadius: 520)
                    .offset(x: dx * 180, y: dy * 140)       // the glow roams widely
                    .blendMode(.plusLighter)

                VStack(spacing: 16) {
                    Image(systemName: "tv")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(streaming ? "Playing on \(ExternalDisplay.shared.name)"
                                   : "VibeLight is on \(ExternalDisplay.shared.name)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text(streaming
                         ? (trackpadLive
                            ? "Tap to show the game here and play by touch."
                            : "Tap to show the game here. Touch input is off while a controller is connected — Settings ▸ Input ▸ Touch With Controller.")
                         : "Use your controller to navigate on the big screen.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(contrast == .increased ? Theme.textPrimary.opacity(0.85)
                                                                : Theme.textSecondary)
                    // No pixel/point readout here (UX-companion-geometry-readout):
                    // it was a TV-sizing aid, too faint to read and nothing the
                    // user can act on. `ExternalDisplay` still logs it on connect.
                }
                .offset(x: dx * 40, y: dy * 34)             // content drifts gently too
            }
        }
    }
}
#endif

