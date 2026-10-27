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

            // The card absorbs its own taps so tapping inside never dismisses.
            card
                .contentShape(Rectangle())
                .onTapGesture { }
        }
    }

    @ViewBuilder private var card: some View {
        switch overlay {
            case .sessionHUD:
                PosterLiftCard()
            case .sessionEnded(let app):
                SessionEndedCard(app: app)
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
            case .confirmOverridePreset(let slot):
                ConfirmOverridePresetCard(slot: slot)
            case .confirmClearPreset(let slot):
                ConfirmClearPresetCard(slot: slot)
            case .confirmRemoveHost(let hostID):
                ConfirmRemoveHostCard(hostID: hostID)
            case .presetSlotMenu(let slot):
                PresetSlotMenuCard(slot: slot)
            case .renamePreset(let slot):
                RenamePresetCard(slot: slot)
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
                liftOff(from: lift?.artFrames["app:\(state.appKey(app))"], to: frame)
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

// MARK: - Stream ended

private struct SessionEndedCard: View {
    @Environment(AppState.self) private var state
    let app: StreamApp

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text(app.name)
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("is still running on the host")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(spacing: 12) {
                OverlayButton(id: "ended:resume", title: "Resume Stream", symbol: "play.fill")
                OverlayButton(id: "ended:quit", title: "Quit Stream Completely", symbol: "xmark.octagon.fill", destructive: true)
                OverlayButton(id: "ended:home", title: "Back to Library", symbol: "square.grid.2x2")
            }
        }
        .padding(52)
        .frame(width: 480)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 24))
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

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false
    private var isFocused: Bool { state.focus.focusedItemID == id }
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
        .background(
            isFocused ? (destructive ? Color.red.opacity(0.85) : Theme.accent)
                      : (hoverActive ? Color.white.opacity(0.12) : Theme.surface),
            in: RoundedRectangle(cornerRadius: 13)
        )
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
        // Click activates THIS button (focus it first), not whatever the
        // controller last focused.
        .onTapGesture { state.pointerSelect(id) }
        // A tap-gesture stack, not a Button: tell VoiceOver what it is and
        // what activating it does.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isFocused ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { state.pointerSelect(id) }
    }
}

// MARK: - Presets

/// "Slot N is taken — replace it with the current settings?"
private struct ConfirmOverridePresetCard: View {
    @Environment(AppState.self) private var state
    let slot: Int

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 34)).foregroundStyle(Theme.accent)
                Text("Override Preset \(slot + 1)?")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("\u{201C}\(state.presets[slot]?.name ?? "Preset \(slot + 1)")\u{201D} will be replaced with the current settings.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            VStack(spacing: 12) {
                OverlayButton(id: "override:yes", title: "Override", symbol: "square.and.arrow.down.fill")
                OverlayButton(id: "override:cancel", title: "Cancel", symbol: "xmark")
            }
        }
        .padding(48).frame(width: 460)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 24))
    }
}

/// Clearing a preset destroys it outright and persists immediately — strictly
/// more loss than overriding one, which already confirmed. Cancel is focused
/// first so the destructive action is never the default.
private struct ConfirmClearPresetCard: View {
    @Environment(AppState.self) private var state
    let slot: Int

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 34)).foregroundStyle(.orange)
                Text("Clear Preset \(slot + 1)?")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("\u{201C}\(state.presets[slot]?.name ?? "Preset \(slot + 1)")\u{201D} will be emptied. This can't be undone.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            VStack(spacing: 12) {
                OverlayButton(id: "clearpreset:cancel", title: "Keep It", symbol: "xmark")
                OverlayButton(id: "clearpreset:yes", title: "Clear Preset", symbol: "trash.fill", destructive: true)
            }
        }
        .padding(48).frame(width: 460)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 24))
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

/// Rename / clear a filled slot (the controller path; the mouse gets a native
/// right-click menu on the chip).
private struct PresetSlotMenuCard: View {
    @Environment(AppState.self) private var state
    let slot: Int

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("Preset \(slot + 1)")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text(state.presets[slot]?.name ?? "")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            VStack(spacing: 12) {
                OverlayButton(id: "slotmenu:rename", title: "Rename", symbol: "pencil")
                OverlayButton(id: "slotmenu:clear", title: "Clear", symbol: "trash", destructive: true)
                OverlayButton(id: "slotmenu:cancel", title: "Cancel", symbol: "xmark")
            }
        }
        .padding(48).frame(width: 420)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 24))
    }
}

/// Type a new name for a preset slot.
private struct RenamePresetCard: View {
    @Environment(AppState.self) private var state
    let slot: Int
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Image(systemName: "pencil")
                    .font(.system(size: 34)).foregroundStyle(Theme.accent)
                Text("Rename Preset \(slot + 1)")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }
            let text = Binding(get: { state.renameText }, set: { state.renameText = $0 })
            TextField("Preset \(slot + 1)", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .focused($fieldFocused)
                .onSubmit { state.applyRename(slot) }
                .padding(.horizontal, 18).padding(.vertical, 14).frame(width: 300)
                .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 13))
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .strokeBorder(.white.opacity(fieldFocused ? 0.3 : 0.08), lineWidth: 1)
                }
                .onTapGesture { fieldFocused = true }
            VStack(spacing: 12) {
                OverlayButton(id: "rename:set", title: "Save Name", symbol: "checkmark")
                OverlayButton(id: "rename:cancel", title: "Cancel", symbol: "xmark")
            }
        }
        .padding(48).frame(width: 460)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 24))
        .onChange(of: fieldFocused) { _, focused in
            state.controller.keyboardCaptureEnabled = !focused
        }
        .onAppear { fieldFocused = true }
        .onDisappear { state.controller.keyboardCaptureEnabled = true }
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
