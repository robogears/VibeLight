import SwiftUI

/// Renders a glyph as either its SF Symbol or, for keyboard chords, a text
/// keycap showing the actual keys (so "Settings" reads "⌘ ," not a bare ⌘).
struct GlyphBadge: View {
    let glyph: InputGlyph

    var body: some View {
        if let cap = glyph.keyCap {
            Text(cap)
                .font(.system(size: Theme.labelSize(12), weight: .heavy, design: .rounded))
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
/// label — no controller/keyboard glyph. Shared with the setup wizard's hints
/// so the two bars can't drift (UX-onboarding-hints-generic-glyphs).
struct HintChip: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast
    let event: NavigationEvent
    let label: String?
    var touch = false
    @State private var hovering = false
    @State private var holding = false

    /// Only the quit-GAME hint is press-and-hold (fills the ring). Quit-app (⌘Q /
    /// the "Quit VibeLight" chip) is an instant tap; everything else taps too.
    private var isHold: Bool { event == .quitChord }

    var body: some View {
        activation(chrome)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            // Hold-gesture robustness: when the ring clears for ANY reason (fired,
            // cancelled, input reset) release the once-guard so the next press
            // works; if the chip is torn down mid-hold, cancel it so an
            // interrupted gesture can't silently complete the quit.
            .onChange(of: state.controller.holdProgress == nil) { _, cleared in
                if cleared { holding = false }
            }
            .onDisappear {
                if holding { holding = false; state.controller.cancelPointerHold() }
            }
    }

    @ViewBuilder private var chrome: some View {
        if touch {
            Text(label ?? InputGlyphs.glyph(for: event, style: .keyboard).label)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary.opacity(0.95))
                .padding(.horizontal, 18)
                // Authored ≈ 44 pt tall; the iPad canvas scale draws it at
                // 35–42 pt (UX-ios-scale-shrinks-text-targets). Touch only.
                .padding(.vertical, 13)
                .background(.white.opacity(hovering ? 0.16 : 0.09), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline(0.12, contrast), lineWidth: 1))
                .contentShape(Capsule())
                // A Text with a tap gesture; tell VoiceOver it's a button.
                .accessibilityAddTraits(.isButton)
        } else {
            let glyph = InputGlyphs.glyph(for: event, style: state.effectiveGlyphStyle)
            HStack(spacing: 7) {
                GlyphBadge(glyph: glyph)
                Text(label ?? glyph.label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, Theme.perPlatform(iOS: 8, macOS: 5))
            .background(.white.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            // A glyph + label row with a tap gesture: one element, announced as
            // a button, as the wizard's Back/Continue were before they shared
            // this chip (UX-onboarding-hints-generic-glyphs follow-up).
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        }
    }

    /// Quit = press-and-hold to fill the ring (touch or mouse), releasing early
    /// cancels; everything else routes on a tap.
    @ViewBuilder private func activation(_ content: some View) -> some View {
        if isHold {
            content.gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !holding { holding = true; state.controller.beginPointerHold(for: event) }
                    }
                    .onEnded { _ in
                        holding = false
                        state.controller.cancelPointerHold()
                    }
            )
        } else {
            content.onTapGesture { state.route(event) }
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

    private var touchButtons: Bool { Self.touchPresentation(state) }

    /// Touch presentation on iOS: no controller connected, or the user is
    /// touching (`.pointer`). A connected controller that's driving keeps glyphs.
    /// The setup wizard's hints read the same rule (UX-onboarding-hints-generic-glyphs).
    static func touchPresentation(_ state: AppState) -> Bool {
        #if os(iOS)
        let touchPlatform = true
        #else
        let touchPlatform = false
        #endif
        return touchPresentation(touchPlatform: touchPlatform,
                                 controllerConnected: !state.controller.connectedControllers.isEmpty,
                                 inputMode: state.inputMode)
    }

    /// The pure rule behind `touchPresentation(_:)`. The Mac always shows glyphs
    /// (it has a keyboard even with no pad).
    nonisolated static func touchPresentation(touchPlatform: Bool, controllerConnected: Bool,
                                              inputMode: InputMode) -> Bool {
        touchPlatform && (!controllerConnected || inputMode == .pointer)
    }

    /// Touch shows only hints that carry a label. Quit now carries one and is a
    /// press-and-hold button (fills the ring like the controller); unlabeled
    /// hints still drop out.
    private var shownHints: [(String, NavigationEvent, String?)] {
        touchButtons ? hints.filter { $0.2 != nil } : hints
    }

    /// What A/Return does on Home, named for the button it will press. Never a
    /// dangling "Play" with no games: nil drops the touch pill, and a pad or
    /// keyboard shows the glyph's own generic label (UX-empty-home-no-invitation).
    nonisolated static func homeSelectLabel(focusedID: String?, hasApps: Bool) -> String? {
        switch focusedID {
        case "header:addhost": "Add Computer"
        case "shelf:pair": "Pair Computer"
        case "shelf:wake": "Wake Computer"
        default: hasApps ? "Play" : nil
        }
    }

    /// (stable id, event, label override)
    private var hints: [(String, NavigationEvent, String?)] {
        switch state.screen {
        case .home:
            // On a preset slot in the row under the shelf. A filled slot can be
            // used/managed; an empty one can only be filled from Settings, so
            // say THAT instead of dangling a "Use Preset" that does nothing.
            if let i = state.presetSlotIndex(state.focus.focusedItemID) {
                if state.presets[i] != nil {
                    return [
                        ("use", .select, "Use Preset"),
                        ("opts", .contextMenu, "Rename / Clear"),
                        ("games", .move(.up), "Back to Games"),
                    ]
                }
                return [
                    ("fill", .settings, "Save One in Settings"),
                    ("games", .move(.up), "Back to Games"),
                ]
            }
            // No "Presets" hint: the row is one nudge down and discoverable.
            // No quit-app hint on iOS: apps don't self-quit there (HIG), and
            // the chord is disabled in ControllerManager anyway.
            var home: [(String, NavigationEvent, String?)] = [
                ("select", .select, Self.homeSelectLabel(focusedID: state.focus.focusedItemID,
                                                         hasApps: !state.apps.isEmpty)),
                ("menu", .settings, "Settings"),
                ("sheet", .contextMenu, "Shortcuts"),
            ]
            // Only when there's a game to quit (the hold is off otherwise).
            if state.canQuitRemoteGame { home.append(("quitgame", .quitChord, "Hold to Quit Game")) }
            #if os(macOS)
            home.append(("quitapp", .quitApp, "Quit VibeLight"))
            #endif
            return home
        case .settings:
            // On a preset slot: save into it / manage it. On a row the value
            // arrows are directly tappable and tabs are tappable up top, so no
            // "Adjust"/"Switch Tab" chips — they only restated the obvious.
            if let i = state.presetSlotIndex(state.focus.focusedItemID) {
                var slot: [(String, NavigationEvent, String?)] = [
                    ("save", .select, "Save to Preset"),
                ]
                if state.presets[i] != nil { slot.append(("opts", .contextMenu, "Rename / Clear")) }
                slot.append(("back", .back, "Done"))
                return slot
            }
            return [
                ("back", .back, "Done"),
            ]
        }
    }
}
