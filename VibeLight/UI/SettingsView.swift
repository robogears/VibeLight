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
        HStack(spacing: 14) {
            bumper(.prevSection)
            ForEach(AppState.SettingsTab.allCases, id: \.rawValue) { tab in
                let selected = state.settingsTab == tab
                Text(tab.title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(selected ? .white : Theme.textSecondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(
                        selected ? Theme.accent : Color.white.opacity(0.06),
                        in: Capsule()
                    )
                    .overlay {
                        Capsule().strokeBorder(.white.opacity(selected ? 0.3 : 0), lineWidth: 1)
                    }
                    .onTapGesture {
                        // Jump directly on click, keeping controller behavior.
                        while state.settingsTab != tab {
                            let forward = (AppState.SettingsTab.allCases.firstIndex(of: tab) ?? 0)
                                > (AppState.SettingsTab.allCases.firstIndex(of: state.settingsTab) ?? 0)
                            state.switchSettingsTab(forward: forward)
                        }
                    }
            }
            bumper(.nextSection)
            Spacer()
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
                // Adjustable rows get ◀ ▶; action/readonly rows don't.
                let showChevrons = !(row.isAction || row.isReadonly)
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(showChevrons && isFocused ? .white.opacity(0.8) : .clear)
                Text(state.value(for: row))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(isFocused ? .white : Theme.accent)
                    .monospacedDigit()
                    .frame(minWidth: 120, alignment: .center)
                    .contentTransition(.numericText())
                Image(systemName: row.isAction ? "chevron.forward.circle.fill" : "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(row.isAction ? (isFocused ? .white : Theme.accent)
                                     : (showChevrons && isFocused ? .white.opacity(0.8) : .clear))
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
            if row.isAction { state.checkForUpdates() }
        }
    }
}
