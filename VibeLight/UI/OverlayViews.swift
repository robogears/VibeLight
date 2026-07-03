import SwiftUI

/// Renders whichever modal overlay is active. Overlays own all input while
/// visible (AppState routes navigation to them first).
struct OverlayHost: View {
    @Environment(AppState.self) private var state
    let overlay: Overlay

    var body: some View {
        ZStack {
            // Dim + blur the world behind the modal.
            Rectangle()
                .fill(.black.opacity(0.55))
                .background(.ultraThinMaterial)

            switch overlay {
            case .sessionHUD:
                SessionHUD()
            case .sessionEnded(let app):
                SessionEndedCard(app: app)
            case .error(let message):
                ErrorCard(message: message)
            case .cheatSheet:
                CheatSheetCard()
            }
        }
    }
}

// MARK: - Launching HUD

private struct SessionHUD: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 22) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.accent)
            Text(label)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("Handing off to the stream…")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(60)
        .background(Theme.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 24))
    }

    private var label: String {
        switch state.session.phase {
        case .reconciling: "Checking what's running…"
        case .waitingForQuit(let app): "Closing \(app.name)…"
        case .launching(let app): "Starting \(app.name)"
        case .streaming(let app): "Streaming \(app.name)"
        default: "Preparing…"
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
                OverlayButton(id: "ended:quit", title: "Quit Game Completely", symbol: "xmark.octagon.fill", destructive: true)
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
                row(.quitChord, "Quit the remote game completely")
                row(.quitApp, "Quit VibeLight (hold on home)")
                keyRow("⌘⇧ Q", "Quit the remote game completely (keyboard)")

                sheetSection("During a stream (Moonlight)")
                keyRow("⌃⌥⇧ Q", "Disconnect — game keeps running")
                keyRow("⌃⌥⇧ E", "Quit the game completely")
                keyRow("⌃⌥⇧ Z", "Release mouse/keyboard capture")
                keyRow("⌃⌥⇧ S", "Performance overlay")
            }

            Text("Press any button to close")
                .font(.system(size: 12, weight: .medium))
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
        let glyph = InputGlyphs.glyph(for: event, style: state.controller.glyphStyle)
        GridRow {
            HStack(spacing: 6) {
                Image(systemName: glyph.symbolName)
                    .font(.system(size: 15, weight: .semibold))
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

    private var isFocused: Bool { state.focus.focusedItemID == id }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
            Text(title)
                .font(.system(size: 17, weight: .bold, design: .rounded))
            Spacer()
        }
        .foregroundStyle(isFocused ? .white : Theme.textPrimary.opacity(0.85))
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
        .frame(width: 360)
        .background(
            isFocused ? (destructive ? Color.red.opacity(0.85) : Theme.accent) : Theme.surface,
            in: RoundedRectangle(cornerRadius: 13)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(.white.opacity(isFocused ? 0.35 : 0.08), lineWidth: 1)
        }
        .scaleEffect(isFocused ? 1.04 : 1.0)
        .animation(Theme.focusSpring, value: isFocused)
        .onHover { if $0 { state.focus.focus(itemID: id) } }
        .onTapGesture { state.route(.select) }
    }
}
