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

/// One hint in the bar. Clickable — a mouse user gets the same action a
/// controller/keyboard does, with a subtle hover lift.
private struct HintChip: View {
    @Environment(AppState.self) private var state
    let event: NavigationEvent
    let label: String?
    @State private var hovering = false

    var body: some View {
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

/// Bottom hint bar: live button glyphs for what each input does right now.
/// Adapts to the connected controller (Xbox / PlayStation / Nintendo / keyboard).
struct HintBarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // iOS/iPadOS is touch-first: show the controller/keyboard bind hints ONLY
        // when a controller is actually connected AND driving (`.directed`). A
        // touch-only iPad never shows them (even at launch); touching a device
        // that has a controller flips to `.pointer` and hides them too.
        #if os(iOS)
        if !state.controller.connectedControllers.isEmpty && state.inputMode != .pointer { bar }
        #else
        bar
        #endif
    }

    private var bar: some View {
        HStack(spacing: 26) {
            ForEach(hints, id: \.0) { _, event, label in
                HintChip(event: event, label: label)
            }
            Spacer()
        }
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
