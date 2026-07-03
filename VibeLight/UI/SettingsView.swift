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
            .padding(.bottom, 40)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(AppState.SettingsRow.allCases, id: \.rawValue) { row in
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
            }

            Spacer(minLength: 0)

            HintBarView()
                .padding(.horizontal, 96)
                .padding(.bottom, 36)
        }
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
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isFocused ? .white.opacity(0.8) : .clear)
                Text(state.value(for: row))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(isFocused ? .white : Theme.accent)
                    .monospacedDigit()
                    .frame(minWidth: 120, alignment: .center)
                    .contentTransition(.numericText())
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isFocused ? .white.opacity(0.8) : .clear)
            }
        }
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
        .onHover { if $0 { state.focus.focus(itemID: row.focusID) } }
    }
}
