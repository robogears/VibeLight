import SwiftUI

/// On-screen feedback for the press-and-hold quit chords: a ring that fills
/// while the button is held, so "hold ○ to quit" is visible, not folklore.
/// Appears ~0.25s into the hold (the manager's grace period) and vanishes on
/// release or when the chord fires.
struct HoldProgressRing: View {
    @Environment(AppState.self) private var state
    let progress: HoldProgress

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Theme.ink.opacity(0.14), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: progress.fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbolName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(width: 68, height: 68)

            Text(label)
                .font(Theme.ui(15, .bold))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 24)
        .background(Theme.surface.opacity(0.92), in: Theme.plate(20))
        .overlay {
            Theme.plate(20)
                .strokeBorder(Theme.ink.opacity(Theme.current.isGrid ? 1 : 0.1),
                              lineWidth: Theme.current.isGrid ? 1.5 : 1)
        }
        .shadow(color: Theme.restShadow(0.5), radius: 24, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 110)
    }

    private var symbolName: String {
        switch progress.kind {
        case .disconnectStream:
            return "xmark.circle"
        case .quitApp:
            return InputGlyphs.glyph(for: .quitApp, style: state.effectiveGlyphStyle).symbolName
        case .quitGame, .quitGameButton:
            return InputGlyphs.glyph(for: .quitChord, style: state.effectiveGlyphStyle).symbolName
        }
    }

    private var label: String {
        switch progress.kind {
        case .quitApp: "Keep holding to quit VibeLight"
        case .quitGame, .quitGameButton: "Keep holding to quit the game"
        case .disconnectStream: "Keep holding to leave the stream"
        }
    }

    private var tint: Color {
        switch progress.kind {
        case .quitApp: Theme.accent
        case .quitGame, .quitGameButton: Color.red.opacity(0.9)   // destructive: kills the remote game
        case .disconnectStream: Theme.accent     // game keeps running on the PC
        }
    }
}
