import SwiftUI

/// Big-picture settings: every row is controller-navigable, values adjust with
/// left/right — the single biggest fix over stock Moonlight's mouse-only panel.
struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Text("SETTINGS")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .tracking(6)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let host = state.selectedHost {
                    Text("Streaming from \(host.name)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 96)
            .padding(.top, 64)
            .padding(.bottom, 24)

            SettingsTabBar()
                .padding(.horizontal, 96)
                .padding(.bottom, 28)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        // Themes tab: visual previews of each background above the
                        // Background row, so the choice is something you SEE.
                        if state.settingsTab == .themes {
                            ThemePreviewStrip()
                                .padding(.top, 38)      // sit a touch lower — less top-heavy
                                .padding(.bottom, 8)
                        }
                        ForEach(state.settingsTab.rows, id: \.rawValue) { row in
                            SettingsRowView(row: row)
                                .id(row.focusID)
                        }
                        if state.settingsTab == .windowsHelper {
                            WindowsHelperNote()
                                .padding(.top, 14)
                        }
                    }
                    .padding(.horizontal, 96)
                    .padding(.bottom, 40)
                }
                .onChange(of: state.focus.focusedItemID) { _, new in
                    guard let new, new.hasPrefix("setting:") else { return }
                    withAnimation(Theme.focusSpring) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
                // Keep the transition snappy when tabs change.
                .animation(Theme.focusSpring, value: state.settingsTab)
            }

            Spacer(minLength: 0)

            HintBarView()
                .padding(.horizontal, 96)
                .padding(.bottom, 36)
        }
    }
}

/// The tab strip with L1/R1 bumper glyphs on either side — switched with the
/// shoulder buttons (or clicked with the mouse).
private struct SettingsTabBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // Horizontal scroll so the tabs + preset pill never compress on a
        // narrow window (on a wide Mac it all fits with no scrolling).
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                bumper(.prevSection)
                ForEach(AppState.SettingsTab.allCases, id: \.rawValue) { tab in
                    TabChip(tab: tab)
                }
                bumper(.nextSection)

                // Divider, then which preset these settings belong to.
                Rectangle().fill(.white.opacity(0.12))
                    .frame(width: 1, height: 26)
                    .padding(.horizontal, 6)
                PresetStatusPill()
            }
        }
        .animation(Theme.focusSpring, value: state.settingsTab)
    }

    private func bumper(_ event: NavigationEvent) -> some View {
        let glyph = InputGlyphs.glyph(for: event, style: state.effectiveGlyphStyle)
        return Image(systemName: glyph.symbolName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Theme.textPrimary.opacity(0.85))
    }
}

/// One clickable tab chip with a clear selected highlight and hover feedback.
private struct TabChip: View {
    @Environment(AppState.self) private var state
    let tab: AppState.SettingsTab
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    private var selected: Bool { state.settingsTab == tab }

    var body: some View {
        Text(tab.title)
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundStyle(selected ? Theme.onAccent
                             : (contrast == .increased ? Theme.textPrimary.opacity(0.85) : Theme.textSecondary))
            .fixedSize()
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(
                selected ? Theme.accent
                         : Color.white.opacity(hovering && state.inputMode == .pointer ? 0.14 : 0.06),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(.white.opacity(selected ? 0.3 : 0), lineWidth: 1)
            }
            // Hover brightens, never scales (owner rule: nothing zooms on hover).
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .onTapGesture { state.setSettingsTab(tab) }
            .animation(Theme.focusSpring, value: selected)
            .animation(Theme.focusSpring, value: hovering)
    }
}

/// Which preset these settings are (Live Loadout): its name with a check;
/// "edited" in orange once a row has changed it (Y updates it, X reverts);
/// "Not saved as a preset" when nothing is loaded (Y saves). Click or
/// right-click for the same actions.
private struct PresetStatusPill: View {
    @Environment(AppState.self) private var state

    private var edited: Bool { state.isActivePresetEdited }

    var body: some View {
        HStack(spacing: 8) {
            if let preset = state.activePreset {
                Text(preset.name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if edited {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                    Text("edited")
                        .font(.system(size: Theme.labelSize(12), weight: .bold, design: .rounded))
                        .foregroundStyle(Color.orange)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accent)
                }
            } else {
                Text("Not saved as a preset")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(edited ? Color.orange.opacity(0.12) : Theme.accent.opacity(state.activePreset == nil ? 0.06 : 0.16),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(edited ? Color.orange.opacity(0.5) : .white.opacity(0.1), lineWidth: 1))
        .animation(Theme.focusSpring, value: edited)
        .contentShape(Capsule())
        .onTapGesture { state.route(.detail) }
        .contextMenu {
            if let preset = state.activePreset, edited {
                Button { state.updateActivePreset() } label: { Label("Update \(preset.name)", systemImage: "square.and.arrow.down") }
                Button { state.revertActivePreset() } label: { Label("Revert Changes", systemImage: "arrow.uturn.backward") }
            }
            if state.canSaveNewPreset {
                Button { state.openPresetNameCard(.new) } label: { Label("Save as New Preset", systemImage: "plus.square.on.square") }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsRowView: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast
    let row: AppState.SettingsRow

    private var isFocused: Bool { state.focus.focusedItemID == row.focusID }
    /// Greyed: VibeLight Helper isn't on the PC (or Match TV is off).
    private var unavailable: Bool { state.isUnavailable(row) }

    var body: some View {
        HStack {
            Text(row.title)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(isFocused ? .white : Theme.textPrimary.opacity(0.85))

            Spacer()

            HStack(spacing: 16) {
                // Adjustable rows get ◀ ▶ — always visible and DIRECTLY tappable
                // (fingers adjust values without a controller); action/readonly
                // rows don't.
                let showChevrons = !(row.isAction || row.isReadonly || unavailable)
                Button { state.adjust(row: row, forward: false) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(showChevrons ? .white.opacity(isFocused ? 0.9 : 0.55) : .clear)
                        .frame(width: Theme.perPlatform(iOS: 44, macOS: 34),
                               height: Theme.perPlatform(iOS: 44, macOS: 34))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!showChevrons)
                Text(state.value(for: row))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(isFocused ? .white : Theme.accent)
                    .monospacedDigit()
                    .frame(minWidth: 120, alignment: .center)
                    .contentTransition(.numericText())
                Button {
                    if row.isAction { state.performSettingAction(row) }
                    else { state.adjust(row: row, forward: true) }
                } label: {
                    Image(systemName: row.isAction ? "chevron.forward.circle.fill" : "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(row.isAction ? (isFocused ? .white : Theme.accent)
                                         : (showChevrons ? .white.opacity(isFocused ? 0.9 : 0.55) : .clear))
                        .frame(width: Theme.perPlatform(iOS: 44, macOS: 34),
                               height: Theme.perPlatform(iOS: 44, macOS: 34))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!showChevrons && !row.isAction)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(
            isFocused ? Theme.accent.opacity(0.85) : Theme.surface.opacity(0.6),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.hairline(isFocused ? 0.3 : 0.06, contrast), lineWidth: 1)
        }
        .opacity(unavailable ? 0.4 : 1)
        .scaleEffect(isFocused ? 1.015 : 1.0)
        .animation(Theme.focusSpring, value: isFocused)
        .animation(Theme.focusSpring, value: state.value(for: row))
        .animation(Theme.focusSpring, value: unavailable)
        .onHover { if $0 && state.inputMode == .pointer { state.focus.focus(itemID: row.focusID) } }
        .onTapGesture {
            // Rows that OPEN something (Software Update, and Resolution -> the
            // custom-resolution card) act on a tap; value rows just take focus
            // so the mouse and controller agree. Resolution used to be
            // focus-only, which left custom resolution completely unreachable
            // by touch on iOS.
            state.focus.focus(itemID: row.focusID)
            if row.isAction {
                state.performSettingAction(row)
            } else if state.settingsRowOpens(row) {
                state.pointerSelect(row.focusID)
            }
        }
    }
}

/// Under Settings ▸ Windows Helper: what VibeLight Helper does, and — until
/// it's found — how to get it, which is why the rows above are greyed.
private struct WindowsHelperNote: View {
    @Environment(AppState.self) private var state

    private var pc: String { state.selectedHost?.name ?? "the PC" }

    private var text: String {
        let what = "VibeLight Helper is a small app that sits by the clock on the PC. With it, VibeLight can set the PC's resolution to match your TV (and fit the game to it), and Quit Stream and Game can close a game for you."
        switch state.windowsHelper {
        case .ready:
            return what + " Match TV only changes the size: the frame rate stays your preset's."
        case .notFound:
            return what + " It isn't running on \(pc). Copy VibeLightHelper.exe to the PC and run it, then let Windows allow it on private networks. There's no pairing: if this device can stream from \(pc), it can use the helper."
        case .notAllowed:
            return "VibeLight Helper is running on \(pc), but it only lets in devices that the PC's Vibepollo has paired and allowed to launch apps."
        case .certChanged:
            return "VibeLight Helper on \(pc) has a new certificate, probably because it was reinstalled. Select VibeLight Helper above to trust it."
        case .unknown, .checking:
            return state.selectedHost == nil ? "Select a PC first." : "Looking for VibeLight Helper on \(pc)…"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: state.windowsHelperReady ? "checkmark.seal.fill" : "info.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(state.windowsHelperReady ? Color.green : Theme.textSecondary)
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .animation(Theme.focusSpring, value: state.windowsHelper)
    }
}

/// Visual theme picker shown atop Settings ▸ Themes — tap a card to select it;
/// the controller/keyboard still cycles via the Background row below.
private struct ThemePreviewStrip: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // Horizontal scroll so any number of themes fits without squishing; the
        // selected card is kept centered as the controller cycles through them.
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(BackgroundTheme.allCases, id: \.self) { theme in
                        ThemeCard(theme: theme, selected: state.backgroundTheme == theme, width: 200)
                            .id(theme)
                            .onTapGesture { state.backgroundTheme = theme }
                    }
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 2)
            }
            .onChange(of: state.backgroundTheme) { _, theme in
                withAnimation(Theme.focusSpring) { proxy.scrollTo(theme, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(state.backgroundTheme, anchor: .center) }
        }
    }
}
