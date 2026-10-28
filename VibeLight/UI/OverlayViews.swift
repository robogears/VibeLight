import SwiftUI

/// Renders whichever modal overlay is active. Overlays own all input while
/// visible (AppState routes navigation to them first).
struct OverlayHost: View {
    @Environment(AppState.self) private var state
    let overlay: Overlay

    var body: some View {
        ZStack {
            // Dim + blur the world behind the modal. Tapping the dimmed area
            // closes the overlay (routes Back) so a touch user isn't soft-locked
            // in a popup with no controller/keyboard to back out with. Overlays
            // that lock input (e.g. the launching HUD) ignore Back, so they stay.
            Rectangle()
                .fill(.black.opacity(0.55))
                .background(.ultraThinMaterial)
                .contentShape(Rectangle())
                .onTapGesture { state.route(.back) }
                // Back to Library from the still-running card lifts the scrim
                // while the poster flies into its tile, so you see it land;
                // after Quit it fades out slowly with the card.
                .opacity(scrimLifted ? 0 : 1)
                .animation(endedQuitting ? Animation.easeInOut(duration: AppState.endedQuitFade)
                                         : Animation.easeOut(duration: 0.3),
                           value: scrimLifted)

            // The card absorbs its own taps so tapping inside never dismisses.
            card
                .contentShape(Rectangle())
                .onTapGesture { }
        }
    }

    private var scrimLifted: Bool {
        if case .sessionEnded = overlay { return state.endedSession?.leaving == true || endedQuitting }
        return false
    }

    private var endedQuitting: Bool {
        if case .sessionEnded = overlay { return state.endedSession?.quitting == true }
        return false
    }

    @ViewBuilder private var card: some View {
        switch overlay {
            case .sessionHUD:
                PosterLiftCard()
            case .sessionEnded(let app):
                PosterRestCard(app: app)
            case .error(let message):
                ErrorCard(message: message)
            case .cheatSheet:
                CheatSheetCard()
            case .update:
                UpdateCard()
            case .hosts:
                HostMenuCard()
            case .relocate:
                RelocateCard()
            case .customResolution:
                CustomResolutionCard()
            case .confirmRemoveHost(let hostID):
                ConfirmRemoveHostCard(hostID: hostID)
            case .presetMenu(let id):
                PresetMenuCard(id: id)
            case .namePreset(let target):
                NamePresetCard(target: target)
            case .moonDeckSetup(let hostID):
                MoonDeckSetupCard(hostID: hostID)
            case .confirmRestartPC(let hostID):
                ConfirmRestartCard(hostID: hostID)
            case .confirmSwitchStream(let running, let target):
                ConfirmSwitchStreamCard(runningName: running, target: target)
            }
    }
}

// MARK: - Starting card (Poster Lift)

/// The starting card — "Poster Lift", the owner's pick of five (Fable design
/// lead, Oct 2026). The tile you pressed lifts out of the shelf to the middle
/// of the screen as a poster; its accent glow breathes while the real launch
/// steps tick by underneath (never a percentage). When the first frame
/// arrives it grows into the picture under the stream's 0.45 s fade-in (the
/// card is dismissed after that fade — AppState.onStreamDidStart). Replaced a
/// spinner with rotating quips.
private struct PosterLiftCard: View {
    @Environment(AppState.self) private var state
    @Environment(\.liftGeometry) private var lift
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 300, height: 400)

    /// The pressed tile's art, relative to the poster's resting place — where
    /// the lift starts. Nil until both are measured, or when there's no tile
    /// to lift from (then the poster fades in place).
    @State private var start: (offset: CGSize, scale: CGSize)?
    @State private var landed = false
    @State private var breathe = false

    /// The game: from the engine once it says so, from the press before that
    /// (macOS checks the PC first, with no app in its phase).
    private var app: StreamApp? {
        switch state.session.phase {
        case .launching(let app), .streaming(let app): app
        default: state.launchTarget
        }
    }

    private var streamingNow: Bool {
        if case .streaming = state.session.phase { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 26) {
            if let app {
                poster(app)
                VStack(spacing: 10) {
                    Text(app.name)
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(statusLine)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.3), value: statusLine)
                    HStack(spacing: 12) {
                        Badge(text: state.value(for: .resolution))
                        Badge(text: "\(state.settings.fps) FPS")
                        Badge(text: "\(state.settings.bitrateKbps / 1000) MBPS")
                        if let preset = state.activePreset {
                            Badge(text: preset.name.uppercased(),
                                  tint: state.isActivePresetEdited ? .orange : .white)
                        }
                    }
                }
                .opacity(landed && !streamingNow ? 1 : 0)
                .animation(.easeOut(duration: streamingNow ? 0.2 : 0.25), value: landed && !streamingNow)
            }
        }
        .onAppear {
            if reduceMotion { breathe = true; return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
        }
    }

    private func poster(_ app: StreamApp) -> some View {
        let lifting = !landed && start != nil
        return PosterArt(app: app)
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.accent, lineWidth: 4))
            .background {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Theme.accent)
                    .blur(radius: 36)
                    .opacity(landed ? (breathe ? 0.75 : 0.25) : 0)
            }
            // The lift: begin exactly over the pressed tile, spring to here.
            .scaleEffect(lifting ? start!.scale : CGSize(width: 1, height: 1))
            .offset(lifting ? start!.offset : .zero)
            // The exit: grow into the picture as the stream fades in above.
            .scaleEffect(streamingNow && !reduceMotion ? 1.35 : 1)
            .opacity(streamingNow ? 0 : (landed || start != nil ? 1 : 0))
            .animation(.easeIn(duration: 0.4), value: streamingNow)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(LiftGeometry.space)) }) { frame in
                guard !landed, start == nil else { return }
                // The pressed tile, or the still-running card's poster on Resume.
                liftOff(from: lift?.artFrames[state.liftSourceID ?? "app:\(state.appKey(app))"], to: frame)
            }
    }

    /// One frame drawn over the tile, then the spring to centre. No tile to
    /// lift from (or Reduce Motion): a plain fade in place.
    private func liftOff(from tile: CGRect?, to poster: CGRect) {
        guard let tile, !reduceMotion, poster.width > 0, poster.height > 0 else {
            withAnimation(.easeOut(duration: 0.25)) { landed = true }
            return
        }
        start = (CGSize(width: tile.midX - poster.midX, height: tile.midY - poster.midY),
                 CGSize(width: tile.width / poster.width, height: tile.height / poster.height))
        Task { @MainActor in
            withAnimation(Theme.focusSpring) { landed = true }
        }
    }

    /// The real step, in words. macOS's helper reports no steps, so there the
    /// line follows the phase alone.
    private var statusLine: String {
        let host = state.selectedHost?.name ?? "the PC"
        switch state.session.phase {
        case .reconciling: return "Checking \(host)…"
        case .waitingForQuit(let running): return "Closing \(running.name)…"
        default: break
        }
        switch state.session.launchStep {
        case .checkingHost: return "Checking \(host)…"
        case .starting(resume: true): return "Resuming on \(host)…"
        case .connecting: return "Connecting…"
        case .waitingForVideo: return "Waiting for video…"
        case .starting(resume: false), nil: return "Starting on \(host)…"
        }
    }
}

/// The poster's art: the same box art (or bespoke tile) as the shelf tile.
private struct PosterArt: View {
    @Environment(AppState.self) private var state
    let app: StreamApp
    @State private var artwork: TileArtwork = .pending

    var body: some View {
        Group {
            switch artwork {
            case .image(let url):
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        BespokeTileView(kind: .generic, title: app.name)
                    }
                }
            case .bespoke(let kind):
                BespokeTileView(kind: kind, title: app.name)
            case .pending:
                Theme.surface
            }
        }
        .task(id: app.id) {
            guard let host = state.selectedHost else { return }
            artwork = await state.artwork.artwork(for: app, host: host, address: state.hostAddress)
        }
    }
}

// MARK: - Still running (Poster Rest)

/// The still-running card — "Poster Rest", the owner's pick of five (Fable
/// design lead, Oct 2026): Poster Lift at rest. The curtain fades onto the
/// game's poster, LIVE and green, with the choices beside it. Resume lifts
/// this poster straight into Poster Lift (AppState.endedPosterID); Quit is
/// held — A, Return or a press — filling the button while the badge reads
/// CLOSING; Back to Library flies the poster home into its tile. If the PC
/// closes the game meanwhile, it greys out: Play Again, no Quit.
private struct PosterRestCard: View {
    @Environment(AppState.self) private var state
    @Environment(\.liftGeometry) private var lift
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let app: StreamApp

    @State private var settled = false
    @State private var breathe = false
    @State private var posterFrame: CGRect = .zero
    /// The way home on Back to Library: onto the tile's art.
    @State private var home: (offset: CGSize, scale: CGSize)?
    @State private var faded = false
    @State private var nudged = false

    private var ended: AppState.EndedSession? { state.endedSession }
    private var closed: Bool { ended?.closedOnHost == true }
    private var leaving: Bool { ended?.leaving == true }
    /// Quit fired: hold the closing look (it would otherwise snap back for a
    /// frame as the hold clears) and fade out.
    private var quitting: Bool { ended?.quitting == true }
    private var hostName: String { state.selectedHost?.name ?? "the PC" }
    /// How far Quit has been held, 0…1 (pinned full once it fired).
    private var hold: Double {
        if quitting { return 1 }
        guard let p = state.controller.holdProgress, p.kind == .quitGameButton else { return 0 }
        return p.fraction
    }
    /// The leave curtain (iPad) has lifted, so the arrival plays where it's seen.
    private var curtainDown: Bool {
        #if os(iOS)
        return state.session.exitCurtain == 0
        #else
        return true
        #endif
    }

    var body: some View {
        HStack(spacing: 26) {
            poster
            column
                .frame(width: 380, alignment: .leading)
                .opacity(settled && !leaving ? 1 : 0)
                .animation(leaving ? Animation.easeOut(duration: 0.2)
                                   : Animation.easeOut(duration: 0.25).delay(0.45),
                           value: settled && !leaving)
        }
        // After Quit: the whole card fades out slowly (owner), with the scrim.
        .opacity(quitting ? 0 : 1)
        .scaleEffect(quitting && !reduceMotion ? 0.97 : 1)
        .animation(.easeInOut(duration: AppState.endedQuitFade), value: quitting)
        .onAppear {
            if curtainDown { settle() }
            if reduceMotion { breathe = true; return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
        }
        .onChange(of: curtainDown) { _, down in if down { settle() } }
        .onChange(of: leaving) { _, now in if now { flyHome() } }
        .onChange(of: state.endedQuitNudges) { _, _ in nudge() }
    }

    private var poster: some View {
        PosterArt(app: app)
            .frame(width: PosterLiftCard.size.width, height: PosterLiftCard.size.height)
            // Holding Quit drains the colour; a game the PC closed is grey.
            .saturation(closed ? 0 : 1 - 0.8 * hold)
            .brightness(closed ? -0.15 : 0)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20)
                .strokeBorder(closed ? Color.white.opacity(0.3) : .green, lineWidth: 4))
            .overlay(alignment: .topLeading) {
                LiveBadge(mode: closed ? .closed : hold > 0 ? .closing : .live).padding(14)
            }
            .background {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.green)
                    .blur(radius: 36)
                    .opacity(closed || leaving ? 0 : (breathe ? 0.55 : 0.2))
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(LiftGeometry.space)) }) { frame in
                guard !leaving else { return }
                posterFrame = frame
                lift?.artFrames[AppState.endedPosterID] = frame   // Resume lifts from here
            }
            .scaleEffect(home?.scale ?? CGSize(width: 1, height: 1))
            .offset(home?.offset ?? .zero)
            .scaleEffect(settled || reduceMotion ? 1 : 0.96)
            .opacity(faded ? 0 : 1)
            .animation(.easeOut(duration: 0.3), value: closed)
            .animation(.linear(duration: 0.05), value: hold)
            .accessibilityHidden(true)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(app.name)
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            if let reason = ended?.dropReason, !closed {
                VStack(alignment: .leading, spacing: 3) {
                    Text("The stream dropped")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.orange)
                    Text(reason)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(quitting ? "Closing \(app.name) on \(hostName)…"
                          : AppState.endedStatusLine(game: app.name, host: hostName, closed: closed,
                                                     played: ended?.played))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                OverlayButton(id: "ended:resume", title: closed ? "Play Again" : "Resume Stream",
                              symbol: "play.fill")
                if !closed {
                    OverlayButton(id: "ended:quit", title: "Quit Stream Completely",
                                  symbol: "xmark.octagon.fill", destructive: true, holdEvent: .quitChord,
                                  held: quitting)
                }
                OverlayButton(id: "ended:home", title: "Back to Library", symbol: "square.grid.2x2")
            }
            .padding(.top, 8)
            if !closed { holdHint }
        }
        .animation(.easeOut(duration: 0.3), value: closed)
    }

    /// "Hold Ⓐ on Quit…" in the glyphs of the hand in use; a tap on Quit
    /// (which does nothing by itself) makes it flash.
    @ViewBuilder private var holdHint: some View {
        let ink = nudged ? Theme.textPrimary : Theme.textSecondary
        Group {
            if HintBarView.touchPresentation(state) {
                Text("Press and hold Quit to end the game on \(hostName)")
            } else {
                HStack(spacing: 6) {
                    Text("Hold")
                    GlyphBadge(glyph: InputGlyphs.glyph(for: .select, style: state.effectiveGlyphStyle))
                    Text("on Quit to end the game on \(hostName)")
                }
            }
        }
        .font(.system(size: Theme.labelSize(12), weight: .semibold))
        .foregroundStyle(ink)
        .scaleEffect(nudged && !reduceMotion ? 1.06 : 1, anchor: .leading)
        .animation(Theme.focusSpring, value: nudged)
        .padding(.top, 4)
    }

    /// The arrival, as the curtain fades: the poster settles, the choices
    /// follow (their delay is on the column).
    private func settle() {
        guard !settled else { return }
        withAnimation(.easeOut(duration: 0.5)) { settled = true }
    }

    /// Back to Library: onto the tile's art on the focus spring. The card is
    /// dismissed a beat later (AppState) and its fade cross-fades the poster
    /// into the tile underneath. No tile to land on, or Reduce Motion: a fade.
    private func flyHome() {
        guard !reduceMotion, let tile = lift?.artFrames["app:\(state.appKey(app))"],
              posterFrame.width > 0, posterFrame.height > 0 else {
            withAnimation(.easeOut(duration: 0.25)) { faded = true }
            return
        }
        withAnimation(Theme.focusSpring) {
            home = (CGSize(width: tile.midX - posterFrame.midX, height: tile.midY - posterFrame.midY),
                    CGSize(width: tile.width / posterFrame.width, height: tile.height / posterFrame.height))
        }
    }

    private func nudge() {
        nudged = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            nudged = false
        }
    }
}

// MARK: - Error

private struct ErrorCard: View {
    let message: String

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            OverlayButton(id: "error:ok", title: "OK", symbol: "checkmark")
        }
        .padding(52)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 24))
    }
}

// MARK: - Keybind cheat sheet

private struct CheatSheetCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("SHORTCUTS")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .tracking(4)
                .foregroundStyle(Theme.textPrimary)

            Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 14) {
                sheetSection("In VibeLight")
                row(.select, "Play the selected app")
                row(.back, "Back / close")
                row(.settings, "Open settings")
                row(.nextSection, "Switch settings tab (L1/R1)")
                row(.move(.up), "Up from the games: Restart PC / computer")
                row(.move(.down), "Down from the games: your presets")
                row(.quitChord, "Quit the remote game completely")
                #if os(macOS)
                row(.quitApp, "Quit VibeLight")
                keyRow("⌘⇧ Q", "Hold to quit the remote game completely (keyboard)")
                #endif

                #if os(iOS)
                sheetSection("During a stream")
                keyRow("Start+Select+L1+R1", "Leave the stream — game keeps running")
                keyRow("Tap ✕", "Leave the stream (top-right)")
                keyRow("Tap ⌨", "Type on the PC with the iPad's keyboard")
                keyRow("Swipe in ←", "Buttons hide after 7 s — swipe from the top-right edge")
                // Press TWICE is iPadOS's rule, not ours: the first press opens
                // Apple's Game Overlay, and iOS itself tells the user to press
                // again to reach the app. Saying "press it" here sent people
                // hunting for a bug in VibeLight.
                keyRow("PS / Xbox button ×2", "Opens the game's own menu (Steam, PS) — iOS takes the first press")
                keyRow("Touch", "Tap = click, drag = cursor (Settings ▸ Input)")
                #else
                sheetSection("During a stream")
                keyRow("Start+Select+L1+R1", "Leave the stream — game keeps running")
                keyRow("⌃⌥⇧ Q", "Disconnect — game keeps running")
                keyRow("⌃⌥⇧ E", "Quit the game completely")
                keyRow("⌃⌥⇧ Z", "Release mouse/keyboard capture")
                keyRow("⌃⌥⇧ S", "Performance overlay")
                #endif
            }

            Text("Press any button to close")
                .font(.system(size: Theme.labelSize(12), weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(48)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder
    private func sheetSection(_ title: String) -> some View {
        GridRow {
            Text(title)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(Theme.accent)
                .padding(.top, 10)
                .gridCellColumns(2)
        }
    }

    @ViewBuilder
    private func row(_ event: NavigationEvent, _ text: String) -> some View {
        let glyph = InputGlyphs.glyph(for: event, style: state.effectiveGlyphStyle)
        GridRow {
            HStack(spacing: 6) {
                GlyphBadge(glyph: glyph)
                Text(glyph.label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(Theme.textPrimary)
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private func keyRow(_ keys: String, _ text: String) -> some View {
        GridRow {
            Text(keys)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - Shared focusable overlay button

struct OverlayButton: View {
    @Environment(AppState.self) private var state
    let id: String
    let title: String
    let symbol: String
    var destructive = false
    /// Hold-to-activate: the button fires this event only when held (A,
    /// Return, or a press), filling as it goes; a tap just selects it, which
    /// its card answers with a nudge. The still-running card's Quit.
    var holdEvent: NavigationEvent? = nil
    /// The hold already fired: stay full while the card fades out.
    var held = false

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false
    @State private var pressing = false
    private var isFocused: Bool { state.focus.focusedItemID == id }
    /// How far this button has been held, 0…1.
    private var holdFraction: Double {
        if held { return 1 }
        guard holdEvent != nil, isFocused,
              let p = state.controller.holdProgress, p.kind == .quitGameButton else { return 0 }
        return p.fraction
    }
    /// Hover feedback only reads while the mouse is the active device, so a
    /// cursor parked over a button can't glow while you navigate by controller.
    private var hoverActive: Bool { hovering && state.inputMode == .pointer }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
            Text(title)
                .font(.system(size: 17, weight: .bold, design: .rounded))
            Spacer()
        }
        // Navy on the blue, white on the red (UX-white-on-accent-contrast).
        .foregroundStyle(isFocused ? Theme.labelInk(onSolidAccent: !destructive) : Theme.textPrimary.opacity(0.85))
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
        .frame(width: 360)
        .contentShape(Rectangle())   // whole button (incl. padding) is clickable
        .background {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 13)
                    .fill(isFocused ? (destructive ? Color.red.opacity(0.85) : Theme.accent)
                                    : (hoverActive ? Color.white.opacity(0.12) : Theme.surface))
                // The hold, filling from the leading edge.
                if holdEvent != nil {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(.white.opacity(0.3))
                        .scaleEffect(x: holdFraction, anchor: .leading)
                        .animation(.linear(duration: 0.05), value: holdFraction)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(Theme.hairline(isFocused ? 0.35 : (hoverActive ? 0.22 : 0.08), contrast),
                              lineWidth: 1)
        }
        // Hover brightens; only focus scales (owner rule: nothing zooms on hover).
        .scaleEffect(isFocused ? 1.04 : 1.0)
        .animation(Theme.focusSpring, value: isFocused)
        .animation(Theme.focusSpring, value: hoverActive)
        .onHover { hovering = $0
            if $0 && state.inputMode == .pointer { state.focus.focus(itemID: id) }
        }
        .modifier(Activation(id: id, holdEvent: holdEvent, pressing: $pressing))
        // A tap-gesture stack, not a Button: tell VoiceOver what it is and
        // what activating it does. VoiceOver's activation is deliberate, so a
        // hold button fires outright there.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isFocused ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            if let holdEvent { state.route(holdEvent) } else { state.pointerSelect(id) }
        }
    }

    /// Click/tap activates THIS button (focus it first), not whatever the
    /// controller last focused. A hold button instead holds while pressed;
    /// letting go early counts as a tap.
    private struct Activation: ViewModifier {
        @Environment(AppState.self) private var state
        let id: String
        let holdEvent: NavigationEvent?
        @Binding var pressing: Bool

        @ViewBuilder func body(content: Content) -> some View {
            if let holdEvent {
                content.gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !pressing else { return }
                            pressing = true
                            state.pressHoldButton(id, event: holdEvent)
                        }
                        .onEnded { _ in
                            pressing = false
                            state.releaseHoldButton(id)
                        }
                )
                .onDisappear {
                    if pressing { pressing = false; state.controller.cancelPointerHold() }
                }
            } else {
                content.onTapGesture { state.pointerSelect(id) }
            }
        }
    }
}

/// Removing a computer erases its pairing certificate and box art. That is one
/// PIN re-entry away from unrecoverable, and the trash glyph sits inside a row
/// that is itself a tap target — so it gets a confirm, with Cancel focused.
private struct ConfirmRemoveHostCard: View {
    @Environment(AppState.self) private var state
    let hostID: String

    private var name: String {
        state.hosts.first { $0.id == hostID }?.name ?? "this computer"
    }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                    .font(.system(size: 34)).foregroundStyle(.orange)
                Text("Forget \(name)?")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Its pairing will be lost — you'll need to enter a new PIN on the PC to use it again. Saved box art is removed too.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            VStack(spacing: 12) {
                OverlayButton(id: "removehost:cancel", title: "Keep It", symbol: "xmark")
                OverlayButton(id: "removehost:yes", title: "Forget Computer", symbol: "trash.fill",
                              destructive: true)
            }
        }
        .padding(48).frame(width: 460)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 24))
    }
}

// MARK: - Presets (Live Loadout)

/// One preset's options (X on its chip): no slot numbers, one card. Revert
/// leads when the loaded preset has changed; Delete is immediate (the toast
/// holds Undo), so there's no confirm card behind it.
private struct PresetMenuCard: View {
    @Environment(AppState.self) private var state
    let id: String

    private var preset: StreamPreset? { state.presets.first { $0.id == id } }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text(preset?.name ?? "Preset")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(preset?.summary ?? "")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            VStack(spacing: 12) {
                ForEach(state.presetMenuItems(for: id), id: \.self) { item in
                    switch item {
                    case "presetmenu:revert":
                        OverlayButton(id: item, title: "Revert Changes", symbol: "arrow.uturn.backward")
                    case "presetmenu:edit":
                        OverlayButton(id: item, title: "Edit in Settings", symbol: "slider.horizontal.3")
                    case "presetmenu:rename":
                        OverlayButton(id: item, title: "Rename", symbol: "pencil")
                    case "presetmenu:saveas":
                        OverlayButton(id: item, title: "Save Current as New", symbol: "plus.square.on.square")
                    default:
                        OverlayButton(id: item, title: "Delete", symbol: "trash.fill", destructive: true)
                    }
                }
            }
        }
        .padding(48).frame(width: 460)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 24))
    }
}

/// Name a new preset, or rename one: suggestions taken from the settings
/// first ("4K · 120", "Smooth", the computer's name) — ◀ ▶ picks, A saves —
/// and a field for typing your own. The field never opens by itself, so the
/// iPad's keyboard only appears when you tap it.
private struct NamePresetCard: View {
    @Environment(AppState.self) private var state
    let target: PresetNameTarget
    @FocusState private var fieldFocused: Bool

    private var title: String {
        if case .rename = target { return "Rename Preset" }
        return "Name This Preset"
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                if case .new = target {
                    Text("Saved from your current settings · \(StreamPreset.summary(of: state.settings))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            }
            HStack(spacing: 8) {
                ForEach(Array(state.presetNameSuggestions.enumerated()), id: \.offset) { i, name in
                    SuggestionPill(id: "namesugg:\(i)", name: name)
                }
            }
            let draft = Binding(get: { state.presetNameDraft }, set: { state.presetNameDraft = $0 })
            TextField("Name", text: draft)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .focused($fieldFocused)
                .onSubmit { state.commitPresetName(target) }
                .padding(.horizontal, 18).padding(.vertical, 12).frame(width: 320)
                .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 13))
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .strokeBorder(.white.opacity(fieldFocused ? 0.3 : 0.08), lineWidth: 1)
                }
                .onTapGesture { fieldFocused = true }
            Text("◀ ▶ pick a name · or tap to type your own")
                .font(.system(size: Theme.labelSize(12), weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            VStack(spacing: 12) {
                OverlayButton(id: "name:save", title: target == .new ? "Save Preset" : "Save Name",
                              symbol: "checkmark")
                OverlayButton(id: "name:cancel", title: "Cancel", symbol: "xmark")
            }
        }
        .padding(44).frame(width: 480)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 24))
        .onChange(of: fieldFocused) { _, focused in
            state.controller.keyboardCaptureEnabled = !focused
        }
        .onDisappear { state.controller.keyboardCaptureEnabled = true }
    }
}

/// One suggested name: a capsule in the focus row; picking it fills the field.
private struct SuggestionPill: View {
    @Environment(AppState.self) private var state
    let id: String
    let name: String

    private var isFocused: Bool { state.focus.focusedItemID == id }

    var body: some View {
        Text(name)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(isFocused ? Theme.onAccent : Theme.textPrimary.opacity(0.85))
            .lineLimit(1)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(isFocused ? Theme.accent : Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(isFocused ? 0.4 : 0.1), lineWidth: 1))
            .scaleEffect(isFocused ? 1.05 : 1)
            .animation(Theme.focusSpring, value: isFocused)
            .contentShape(Capsule())
            .onHover { if $0 && state.inputMode == .pointer { state.focus.focus(itemID: id) } }
            .onTapGesture { state.pointerSelect(id) }
            .accessibilityAddTraits(.isButton)
    }
}

/// Where the preset toast lives. It eases in, and when its time is up (or a
/// card opens over it) it FADES out — the last message stays on screen while
/// it fades, instead of blinking away the moment AppState clears it (owner:
/// "needs a fade animation when it disappears").
struct PresetToastHost: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The message on screen — kept after AppState clears it, for the fade.
    @State private var shown: AppState.PresetToast?
    @State private var visible = false

    private var wanted: AppState.PresetToast? { state.overlay == nil ? state.presetToast : nil }

    var body: some View {
        ZStack {
            if let shown {
                PresetToastView(toast: shown)
                    .opacity(visible ? 1 : 0)
                    .offset(y: visible || reduceMotion ? 0 : 10)
                    .scaleEffect(visible || reduceMotion ? 1 : 0.97)
                    .allowsHitTesting(visible)
                    .transition(.opacity)
            }
        }
        .onAppear { show(wanted) }
        .onChange(of: wanted) { _, new in show(new) }
    }

    private func show(_ toast: AppState.PresetToast?) {
        if let toast {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                shown = toast
                visible = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.6)) { visible = false }
        }
    }
}

/// The preset confirmation under the header: "Using Tailscale · 1080p · 60
/// fps · 20 Mbps", or "Deleted Handheld · Undo" (Y, or tap it).
struct PresetToastView: View {
    @Environment(AppState.self) private var state
    let toast: AppState.PresetToast

    var body: some View {
        HStack(spacing: 8) {
            Text(toast.verb).foregroundStyle(Theme.textSecondary)
            Text(toast.name).foregroundStyle(Theme.accent).fontWeight(.heavy)
            if let detail = toast.detail {
                Text("· \(detail)").foregroundStyle(Theme.textSecondary)
            }
            if toast.canUndo {
                HStack(spacing: 6) {
                    if !HintBarView.touchPresentation(state) {
                        GlyphBadge(glyph: InputGlyphs.glyph(for: .detail, style: state.effectiveGlyphStyle))
                    }
                    Text("Undo").fontWeight(.heavy).foregroundStyle(Theme.textPrimary)
                }
                .padding(.leading, 6)
            }
        }
        .font(.system(size: 15, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Theme.surface.opacity(0.95), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .contentShape(Capsule())
        .onTapGesture { if toast.canUndo { state.undoPresetChange() } }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Undo") { state.undoPresetChange() }
    }
}

/// Confirm a force-restart of an already-paired host (destructive).
/// Something else is already streaming on the host — offer to switch straight
/// to the newly chosen app instead of making the user quit and relaunch.
private struct ConfirmSwitchStreamCard: View {
    @Environment(AppState.self) private var state
    let runningName: String
    let target: StreamApp

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 34)).foregroundStyle(Theme.accent)
                Text("\(runningName) is running")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Switching closes \(runningName) on the PC and starts \(target.name).")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            VStack(spacing: 12) {
                OverlayButton(id: "switchstream:yes", title: "Switch to \(target.name)",
                              symbol: "arrow.triangle.2.circlepath")
                OverlayButton(id: "switchstream:cancel", title: "Cancel", symbol: "xmark")
            }
        }
        .padding(48).frame(width: 460)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct ConfirmRestartCard: View {
    @Environment(AppState.self) private var state
    let hostID: String
    private var hostName: String { state.hosts.first { $0.id == hostID }?.name ?? "this PC" }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Image(systemName: "restart")
                    .font(.system(size: 34)).foregroundStyle(.orange)
                Text("Restart \(hostName)?")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Windows will reboot right away, closing anything that's running.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            if state.moonDeckRestarting {
                ProgressView().controlSize(.large).tint(Theme.accent).frame(height: 96)
            } else {
                VStack(spacing: 12) {
                    OverlayButton(id: "restartpc:yes", title: "Restart PC", symbol: "restart", destructive: true)
                    OverlayButton(id: "restartpc:cancel", title: "Cancel", symbol: "xmark")
                }
            }
        }
        .padding(48).frame(width: 460)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 24))
    }
}

/// Set up / PIN-pair MoonDeckBuddy for a host, then offer to restart. Adapts to
/// the live pairing status.
private struct MoonDeckSetupCard: View {
    @Environment(AppState.self) private var state
    let hostID: String
    @FocusState private var portFocused: Bool
    private var hostName: String { state.hosts.first { $0.id == hostID }?.name ?? "this PC" }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Image(systemName: "restart.circle")
                    .font(.system(size: 34)).foregroundStyle(Theme.accent)
                Text("Restart via MoonDeckBuddy")
                    .font(.system(size: 23, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
            }
            content
        }
        .padding(44).frame(width: 480)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 24))
        .onChange(of: portFocused) { _, focused in
            state.controller.keyboardCaptureEnabled = !focused
        }
        .onDisappear { state.controller.keyboardCaptureEnabled = true }
    }

    @ViewBuilder private var content: some View {
        switch state.moonDeckPairing?.status {
        case .some(.connecting):
            VStack(spacing: 12) {
                ProgressView().tint(Theme.accent)
                Text("Connecting to MoonDeckBuddy…")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
            .frame(height: 90)
            OverlayButton(id: "moondeck:cancel", title: "Cancel", symbol: "xmark")

        case .some(.waiting):
            VStack(spacing: 10) {
                Text("Type this PIN into the MoonDeckBuddy pop-up on \(hostName):")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
                Text(state.moonDeckPairing?.pin ?? "")
                    .font(.system(size: 46, weight: .black, design: .rounded))
                    .tracking(10).foregroundStyle(Theme.textPrimary)
                ProgressView().tint(Theme.accent)
            }
            OverlayButton(id: "moondeck:cancel", title: "Cancel", symbol: "xmark")

        case .some(.paired):
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30)).foregroundStyle(.green)
                Text("Paired! You can restart \(hostName) from VibeLight any time.")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            // Same in-flight treatment the confirm card gives: two cards written
            // from one template handled `moonDeckRestarting` differently, so
            // restarting from HERE showed live buttons with nothing happening
            // while the request was already away.
            if state.moonDeckRestarting {
                ProgressView().controlSize(.large).tint(Theme.accent).frame(height: 96)
            } else {
                VStack(spacing: 12) {
                    OverlayButton(id: "moondeck:restart", title: "Restart PC Now", symbol: "restart", destructive: true)
                    OverlayButton(id: "moondeck:done", title: "Done", symbol: "checkmark")
                }
            }

        default:   // initial / failed / offline
            VStack(spacing: 14) {
                Text("Install MoonDeckBuddy on \(hostName) and start it, then pair once. VibeLight will show a PIN to enter on the PC.")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 390)
                HStack(spacing: 10) {
                    Text("Port").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    TextField("59999", text: portBinding)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(width: 96)
                        .focused($portFocused)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.white.opacity(portFocused ? 0.3 : 0.08), lineWidth: 1)
                        }
                        .onTapGesture { portFocused = true }
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
                }
                if let msg = errorMessage {
                    Text(msg)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.orange)
                        .multilineTextAlignment(.center).frame(maxWidth: 390)
                }
            }
            VStack(spacing: 12) {
                OverlayButton(id: "moondeck:pair", title: "Pair with MoonDeckBuddy", symbol: "link")
                OverlayButton(id: "moondeck:cancel", title: "Cancel", symbol: "xmark")
            }
        }
    }

    private var portBinding: Binding<String> {
        Binding(get: { state.moonDeckPortText }, set: { state.moonDeckPortText = $0 })
    }

    private var errorMessage: String? {
        switch state.moonDeckPairing?.status {
        case .some(.offline): return MoonDeckBuddyClient.MDError.offline.errorDescription
        case .some(.failed(let m)): return m
        default: return nil
        }
    }
}

/// Type an arbitrary streaming resolution (WxH). Reached by selecting the
/// Resolution row in Settings.
struct CustomResolutionCard: View {
    @Environment(AppState.self) private var state
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Image(systemName: "aspectratio")
                    .font(.system(size: 34)).foregroundStyle(Theme.accent)
                Text("Custom Resolution")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                if let native = state.nativeResolution {
                    Text("Your display is \(native.w)×\(native.h)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            let text = Binding(get: { state.customResText }, set: { state.customResText = $0 })
            TextField("2560x1440", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .focused($fieldFocused)
                .onSubmit { state.applyCustomResolution() }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(width: 260)
                .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 13))
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .strokeBorder(.white.opacity(fieldFocused ? 0.3 : 0.08), lineWidth: 1)
                }
                .onTapGesture { fieldFocused = true }

            if let error = state.customResError {
                Text(error).font(.system(size: 13, weight: .medium)).foregroundStyle(.orange)
            }

            VStack(spacing: 12) {
                OverlayButton(id: "customres:set", title: "Set Resolution", symbol: "checkmark")
                OverlayButton(id: "customres:cancel", title: "Cancel", symbol: "xmark")
            }
        }
        .padding(48)
        .frame(width: 460)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 24))
        .onChange(of: fieldFocused) { _, focused in
            state.controller.keyboardCaptureEnabled = !focused
        }
        .onAppear { fieldFocused = true }
        .onDisappear { state.controller.keyboardCaptureEnabled = true }
    }
}
