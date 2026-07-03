import SwiftUI

/// Bottom hint bar: live button glyphs for what each input does right now.
/// Adapts to the connected controller (Xbox / PlayStation / Nintendo / keyboard).
struct HintBarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 26) {
            ForEach(hints, id: \.0) { _, event, label in
                let glyph = InputGlyphs.glyph(for: event, style: state.controller.glyphStyle)
                HStack(spacing: 7) {
                    Image(systemName: glyph.symbolName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary.opacity(0.9))
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
                ("quit", .quitChord, nil),
            ]
        case .settings:
            [
                ("adjust", .move(.right), "Adjust"),
                ("back", .back, "Done"),
            ]
        }
    }
}
