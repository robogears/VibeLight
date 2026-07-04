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
                    .stroke(.white.opacity(0.14), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: progress.fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.05), value: progress.fraction)
                Image(systemName: symbolName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(width: 68, height: 68)

            Text(label)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 24)
        .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 110)
    }

    private var symbolName: String {
        let event: NavigationEvent = progress.kind == .quitApp ? .quitApp : .quitChord
        return InputGlyphs.glyph(for: event, style: state.effectiveGlyphStyle).symbolName
    }

    private var label: String {
        switch progress.kind {
        case .quitApp: "Keep holding to quit VibeLight"
        case .quitGame: "Keep holding to quit the game"
        }
    }

    private var tint: Color {
        switch progress.kind {
        case .quitApp: Theme.accent
        case .quitGame: Color.red.opacity(0.9)   // destructive: kills the remote game
        }
    }
}
