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

/// One hint in the bar. In bind mode it shows the input glyph + label (and is
/// still clickable); in touch mode it's a plain tappable pill with just the
/// label — no controller/keyboard glyph.
private struct HintChip: View {
    @Environment(AppState.self) private var state
    let event: NavigationEvent
    let label: String?
    var touch = false
    @State private var hovering = false

    var body: some View {
        if touch {
            Text(label ?? InputGlyphs.glyph(for: event, style: .keyboard).label)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary.opacity(0.95))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(.white.opacity(hovering ? 0.16 : 0.09), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .contentShape(Capsule())
                .onTapGesture { state.route(event) }
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        } else {
            let glyph = InputGlyphs.glyph(for: event, style: state.effectiveGlyphStyle)
            HStack(spacing: 7) {
                GlyphBadge(glyph: glyph)
                Text(label ?? glyph.label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.white.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { state.route(event) }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Bottom hint bar: what each input does right now. With a controller/keyboard
/// driving it shows the live button glyphs; on touch it becomes a row of plain
/// tappable buttons (no glyphs — you can't press a controller button by touch).
struct HintBarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: touchButtons ? 12 : 26) {
            ForEach(shownHints, id: \.0) { _, event, label in
                HintChip(event: event, label: label, touch: touchButtons)
            }
            Spacer()
        }
    }

    /// Touch presentation on iOS: no controller connected, or the user is
    /// touching (`.pointer`). A connected controller that's driving keeps glyphs.
    private var touchButtons: Bool {
        #if os(iOS)
        return state.controller.connectedControllers.isEmpty || state.inputMode == .pointer
        #else
        return false
        #endif
    }

    /// Touch buttons only make sense for hints that carry a label (the glyph-only
    /// hold-chords like quit have no tappable equivalent).
    private var shownHints: [(String, NavigationEvent, String?)] {
        touchButtons ? hints.filter { $0.2 != nil } : hints
    }

    /// (stable id, event, label override)
    private var hints: [(String, NavigationEvent, String?)] {
        switch state.screen {
        case .home:
            if state.isPresetRailActive {
                let filled = state.focusedPresetSlot.map { state.presets[$0] != nil } ?? false
                var rail: [(String, NavigationEvent, String?)] = [
                    ("use", .select, "Use Preset"),
                ]
                if filled { rail.append(("opts", .contextMenu, "Rename / Clear")) }
                rail.append(("leaveleft", .move(.left), "Back to Games"))
                return rail
            }
            return [
                ("select", .select, "Play"),
                ("menu", .settings, "Settings"),
                ("sheet", .contextMenu, "Shortcuts"),
                ("quitgame", .quitChord, nil),
                ("quitapp", .quitApp, nil),
                ("presets", .move(.right), "Presets"),
            ]
        case .settings:
            // On a preset slot: save into it / manage it. On a row: adjust.
            if let i = state.presetSlotIndex(state.focus.focusedItemID) {
                var slot: [(String, NavigationEvent, String?)] = [
                    ("save", .select, "Save to Preset"),
                ]
                if state.presets[i] != nil { slot.append(("opts", .contextMenu, "Rename / Clear")) }
                slot.append(("tab", .nextSection, "Switch Tab"))
                slot.append(("back", .back, "Done"))
                return slot
            }
            return [
                ("adjust", .move(.right), "Adjust"),
                ("tab", .nextSection, "Switch Tab"),
                ("back", .back, "Done"),
            ]
        }
    }
}
