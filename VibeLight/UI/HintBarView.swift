import SwiftUI

/// Renders a glyph as either its SF Symbol or, for keyboard chords, a text
/// keycap showing the actual keys (so "Settings" reads "⌘ ," not a bare ⌘).
struct GlyphBadge: View {
    let glyph: InputGlyph

    var body: some View {
        if let cap = glyph.keyCap {
            Text(cap)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: glyph.symbolName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
        }
    }
}

/// Bottom hint bar: live button glyphs for what each input does right now.
/// Adapts to the connected controller (Xbox / PlayStation / Nintendo / keyboard).
struct HintBarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 26) {
            ForEach(hints, id: \.0) { _, event, label in
                let glyph = InputGlyphs.glyph(for: event, style: state.effectiveGlyphStyle)
                HStack(spacing: 7) {
                    GlyphBadge(glyph: glyph)
                    Text(label ?? glyph.label)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
        }
    }

    /// (stable id, event, label override)
    private var hints: [(String, NavigationEvent, String?)] {
        switch state.screen {
        case .home:
            [
                ("select", .select, "Play"),
                ("menu", .settings, "Settings"),
                ("sheet", .contextMenu, "Shortcuts"),
                ("quitgame", .quitChord, nil),
                ("quitapp", .quitApp, nil),
            ]
        case .settings:
            [
                ("adjust", .move(.right), "Adjust"),
                ("tab", .nextSection, "Switch Tab"),
                ("back", .back, "Done"),
            ]
        }
    }
}
