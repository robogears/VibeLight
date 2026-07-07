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
                                .padding(.bottom, 8)
                        }
                        ForEach(state.settingsTab.rows, id: \.rawValue) { row in
                            SettingsRowView(row: row)
                                .id(row.focusID)
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
        // Horizontal scroll so the tabs + preset slots never compress on a
        // narrow window (on a wide Mac it all fits with no scrolling).
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                bumper(.prevSection)
                ForEach(AppState.SettingsTab.allCases, id: \.rawValue) { tab in
                    TabChip(tab: tab)
                }
                bumper(.nextSection)

                // Divider, then the six preset slots. Clicking a slot saves the
                // current settings into it (override-confirm if taken).
                Rectangle().fill(.white.opacity(0.12))
                    .frame(width: 1, height: 26)
                    .padding(.horizontal, 6)
                Text("PRESETS")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
                ForEach(0..<AppState.presetSlotCount, id: \.self) { slot in
                    SettingsPresetSlot(slot: slot)
                }
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
    @State private var hovering = false

    private var selected: Bool { state.settingsTab == tab }

    var body: some View {
        Text(tab.title)
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundStyle(selected ? .white : Theme.textSecondary)
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
            .scaleEffect(selected ? 1.0 : (hovering && state.inputMode == .pointer ? 1.03 : 1.0))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .onTapGesture { state.setSettingsTab(tab) }
            .animation(Theme.focusSpring, value: selected)
            .animation(Theme.focusSpring, value: hovering)
    }
}

/// One of the six preset slots in the settings header. Number always shown; a
/// filled slot gets a solid look + dot, empty is a dashed ghost. Click = save
/// current settings here (override-confirm if taken); right-click = rename/clear.
private struct SettingsPresetSlot: View {
    @Environment(AppState.self) private var state
    let slot: Int
    @State private var hovering = false

    private var preset: StreamPreset? { state.presets[slot] }
    private var isFilled: Bool { preset != nil }
    private var isActive: Bool { state.activePresetSlot == slot }
    private var focusID: String { "presetslot:\(slot)" }
    private var isFocused: Bool { state.focus.focusedItemID == focusID }
    private var lit: Bool { isActive || isFocused }

    var body: some View {
        VStack(spacing: 3) {
            Text("\(slot + 1)")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(lit || isFilled ? .white : Theme.textSecondary)
            Circle()
                .fill(isFilled ? (lit ? Color.white : Theme.accent) : .clear)
                .frame(width: 5, height: 5)
        }
        .frame(width: 44, height: 44)
        .background(fill, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(border, style: StrokeStyle(lineWidth: isFocused ? 2.5 : 1,
                                                         dash: isFilled ? [] : [4, 3]))
        }
        .shadow(color: isActive ? Theme.accentGlow : .clear, radius: 10, y: 2)
        .scaleEffect(isFocused ? 1.07 : 1.0)
        .help(preset?.name ?? "Empty — click to save the current settings here")
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover {
            hovering = $0
            if $0 && state.inputMode == .pointer { state.focus.focus(itemID: focusID) }
        }
        .onTapGesture { state.requestSaveToSlot(slot) }
        .contextMenu {
            if isFilled {
                Button { state.openRename(slot) } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) { state.clearSlot(slot) } label: { Label("Clear", systemImage: "trash") }
            }
        }
        .animation(Theme.focusSpring, value: isActive)
        .animation(Theme.focusSpring, value: isFocused)
        .animation(Theme.focusSpring, value: isFilled)
    }

    private var fill: AnyShapeStyle {
        if isActive { return AnyShapeStyle(Theme.accent) }
        if isFocused { return AnyShapeStyle(Theme.accent.opacity(0.4)) }
        if isFilled { return AnyShapeStyle(Color.white.opacity(hovering && state.inputMode == .pointer ? 0.16 : 0.1)) }
        return AnyShapeStyle(Color.white.opacity(hovering && state.inputMode == .pointer ? 0.08 : 0.035))
    }
    private var border: Color {
        if isFocused { return .white.opacity(0.8) }
        if isActive { return .white.opacity(0.3) }
        return .white.opacity(isFilled ? 0.15 : 0.2)
    }
}

private struct SettingsRowView: View {
    @Environment(AppState.self) private var state
    let row: AppState.SettingsRow

    private var isFocused: Bool { state.focus.focusedItemID == row.focusID }

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
                let showChevrons = !(row.isAction || row.isReadonly)
                Button { state.adjust(row: row, forward: false) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(showChevrons ? .white.opacity(isFocused ? 0.9 : 0.55) : .clear)
                        .frame(width: 34, height: 34)
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
                        .frame(width: 34, height: 34)
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
                .strokeBorder(.white.opacity(isFocused ? 0.3 : 0.06), lineWidth: 1)
        }
        .scaleEffect(isFocused ? 1.015 : 1.0)
        .animation(Theme.focusSpring, value: isFocused)
        .animation(Theme.focusSpring, value: state.value(for: row))
        .onHover { if $0 && state.inputMode == .pointer { state.focus.focus(itemID: row.focusID) } }
        .onTapGesture {
            // Clicking an action row (Software Update) triggers it; value rows
            // just take focus so the mouse and controller agree.
            state.focus.focus(itemID: row.focusID)
            if row.isAction { state.performSettingAction(row) }
        }
    }
}

/// Visual theme picker shown atop Settings ▸ Themes — tap a card to select it;
/// the controller/keyboard still cycles via the Background row below.
private struct ThemePreviewStrip: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 22) {
            ForEach(BackgroundTheme.allCases, id: \.self) { theme in
                ThemeCard(theme: theme, selected: state.backgroundTheme == theme, width: 210)
                    .onTapGesture { state.backgroundTheme = theme }
            }
            Spacer(minLength: 0)
        }
    }
}
