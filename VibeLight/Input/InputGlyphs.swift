import GameController

/// One renderable input hint: an SF Symbol depicting the physical control
/// plus a short action label ("Select", "Back", …) for hint bars.
struct InputGlyph: Hashable, Sendable {
    var symbolName: String
    var label: String
    /// For keyboard chords (⌘,, ⌘⇧Q…) — the UI renders this as a text keycap
    /// instead of the SF Symbol, so the hint shows the ACTUAL keys to press
    /// rather than a bare, misleading ⌘.
    var keyCap: String? = nil
}

/// Maps (NavigationEvent, ControllerGlyphStyle) → glyphs.
///
/// Two tiers:
/// 1. Static per-style tables — always available, used for hint bars even
///    before any controller input has happened.
/// 2. A live helper that prefers `GCControllerElement.sfSymbolsName`, which
///    respects user remapping done in System Settings > Game Controllers.
///    It can return nil (observed when the d-pad is remapped onto an analog
///    stick), so the static table is ALWAYS the fallback, never an error.
enum InputGlyphs {

    /// Static table lookup. Total over all events and styles.
    static func glyph(for event: NavigationEvent, style: ControllerGlyphStyle) -> InputGlyph {
        InputGlyph(
            symbolName: symbolName(for: event, style: style),
            label: label(for: event, style: style),
            keyCap: style == .keyboard ? keyboardKeyCap(for: event) : nil
        )
    }

    /// The literal keys for events bound to keyboard chords, shown as a keycap.
    private static func keyboardKeyCap(for event: NavigationEvent) -> String? {
        switch event {
        case .settings: "⌘ ,"
        case .quitChord: "⌘ ⇧ Q"
        case .quitApp: "⌘ Q"
        default: nil
        }
    }

    /// Live-first lookup: uses the controller's remap-aware element symbol
    /// when present, otherwise falls back to the static table for the
    /// controller's style (`.keyboard` when `controller` is nil).
    @MainActor
    static func glyph(for event: NavigationEvent, controller: GCController?) -> InputGlyph {
        let style = ControllerGlyphStyle(controller: controller)
        var glyph = glyph(for: event, style: style)
        if let pad = controller?.extendedGamepad,
           let liveSymbol = element(for: event, on: pad)?.sfSymbolsName {
            glyph.symbolName = liveSymbol
        }
        return glyph
    }

    // MARK: - Live element mapping

    /// The physical element that produces a given semantic event, mirroring
    /// ControllerManager's wiring (buttonA → select, etc.).
    @MainActor
    private static func element(for event: NavigationEvent, on pad: GCExtendedGamepad) -> GCControllerElement? {
        switch event {
        case .move: pad.dpad
        case .select: pad.buttonA
        case .back, .quitApp: pad.buttonB
        case .contextMenu: pad.buttonX
        case .detail: pad.buttonY
        case .prevSection: pad.leftShoulder
        case .nextSection: pad.rightShoulder
        case .settings, .quitChord: pad.buttonMenu
        }
    }

    // MARK: - Labels

    /// Action labels. Quit-game is press-and-hold on every input; quit-app only
    /// holds on a controller (whose B is also Back), so ⌘Q reads a plain "Quit".
    private static func label(for event: NavigationEvent, style: ControllerGlyphStyle) -> String {
        switch event {
        case .move: "Move"
        case .select: "Select"
        case .back: "Back"
        case .contextMenu: "Options"
        case .detail: "Details"
        case .prevSection: "Prev"
        case .nextSection: "Next"
        case .settings: "Settings"
        case .quitChord: "Hold to Quit Game"
        case .quitApp: style == .keyboard ? "Quit" : "Hold to Quit"
        }
    }

    // MARK: - Static symbol tables

    private static func symbolName(for event: NavigationEvent, style: ControllerGlyphStyle) -> String {
        switch style {
        case .xbox: xboxSymbol(for: event)
        case .playStation: playStationSymbol(for: event)
        case .nintendo: nintendoSymbol(for: event)
        case .generic: genericSymbol(for: event)
        case .keyboard: keyboardSymbol(for: event)
        }
    }

    private static func xboxSymbol(for event: NavigationEvent) -> String {
        switch event {
        case .move: "dpad"
        case .select: "a.circle"
        case .back, .quitApp: "b.circle"
        case .contextMenu: "x.circle"
        case .detail: "y.circle"
        case .prevSection: "lb.button.roundedbottom.horizontal"
        case .nextSection: "rb.button.roundedbottom.horizontal"
        case .settings, .quitChord: "line.3.horizontal.circle"
        }
    }

    private static func playStationSymbol(for event: NavigationEvent) -> String {
        switch event {
        case .move: "dpad"
        case .select: "xmark.circle"        // Cross
        case .back, .quitApp: "circle.circle"   // Circle
        case .contextMenu: "square.circle"  // Square
        case .detail: "triangle.circle"     // Triangle
        case .prevSection: "l1.button.roundedbottom.horizontal"
        case .nextSection: "r1.button.roundedbottom.horizontal"
        case .settings, .quitChord: "line.3.horizontal.circle"  // Options
        }
    }

    /// GameController maps by POSITION (buttonA = south), but Nintendo pads
    /// label south "B" and east "A" — so the letters here are deliberately
    /// swapped relative to the Xbox table. This matches what live
    /// `sfSymbolsName` reports on Switch controllers.
    private static func nintendoSymbol(for event: NavigationEvent) -> String {
        switch event {
        case .move: "dpad"
        case .select: "b.circle"        // south button, physical B
        case .back, .quitApp: "a.circle"   // east button, physical A
        case .contextMenu: "y.circle"   // west button, physical Y
        case .detail: "x.circle"        // north button, physical X
        case .prevSection: "l.button.roundedbottom.horizontal"
        case .nextSection: "r.button.roundedbottom.horizontal"
        case .settings, .quitChord: "plus.circle"  // "+" button
        }
    }

    /// Unknown pads get positional face-button glyphs (diamond with the
    /// pressed position filled) rather than letters that may not exist on
    /// the hardware.
    private static func genericSymbol(for event: NavigationEvent) -> String {
        switch event {
        case .move: "dpad"
        case .select: "circle.grid.cross.down.filled"
        case .back, .quitApp: "circle.grid.cross.right.filled"
        case .contextMenu: "circle.grid.cross.left.filled"
        case .detail: "circle.grid.cross.up.filled"
        case .prevSection: "l1.button.roundedbottom.horizontal"
        case .nextSection: "r1.button.roundedbottom.horizontal"
        case .settings, .quitChord: "line.3.horizontal.circle"
        }
    }

    private static func keyboardSymbol(for event: NavigationEvent) -> String {
        switch event {
        case .move: "arrowkeys"
        case .select: "return"
        case .back, .quitApp: "escape"
        case .contextMenu: "space"
        case .detail: "arrow.right.to.line"      // Tab
        case .prevSection: "arrow.backward.square"   // no key bound; hint only
        case .nextSection: "arrow.forward.square"    // no key bound; hint only
        case .settings: "command"                // Cmd-,
        case .quitChord: "power"
        }
    }
}

// MARK: - Style detection

extension ControllerGlyphStyle {
    /// Style for the given controller; `.keyboard` when none is attached.
    /// Single source of truth shared by ControllerManager and glyph lookups.
    @MainActor
    init(controller: GCController?) {
        guard let controller else {
            self = .keyboard
            return
        }
        self.init(productCategory: controller.productCategory)
    }

    /// Nintendo has no official GCProductCategory constant across all the
    /// Switch controller variants Apple supports, so those are matched by
    /// substring; Xbox and PlayStation use the official constants.
    init(productCategory: String) {
        switch productCategory {
        case GCProductCategoryXboxOne:
            self = .xbox
        case GCProductCategoryDualSense, GCProductCategoryDualShock4:
            self = .playStation
        default:
            let lowered = productCategory.lowercased()
            if lowered.contains("switch") || lowered.contains("nintendo") || lowered.contains("joy-con") {
                self = .nintendo
            } else {
                self = .generic
            }
        }
    }
}
