import Observation
import SwiftUI
import os

/// The selected `AppTheme`, readable from any isolation and observed by
/// SwiftUI: a view whose body reads any `Theme` token re-renders when the
/// theme changes, so switching in Settings ▸ Themes never leaves a stale
/// colour behind. Starts at Default (the test host never boots `AppState`, so
/// tests always see Default); `AppState.appTheme` is the only writer.
final class ThemeStore: Observable, @unchecked Sendable {
    static let shared = ThemeStore()

    private let registrar = ObservationRegistrar()
    private let storage = OSAllocatedUnfairLock(initialState: AppTheme.default)

    var theme: AppTheme {
        get {
            registrar.access(self, keyPath: \.theme)
            return storage.withLock { $0 }
        }
        set {
            registrar.withMutation(of: self, keyPath: \.theme) {
                storage.withLock { $0 = newValue }
            }
        }
    }
}

/// VibeLight visual language. Every token follows the selected `AppTheme`;
/// Default is the original console-dark look — high contrast, glow accents —
/// value for value.
enum Theme {
    /// The selected theme.
    static var current: AppTheme { ThemeStore.shared.theme }
    static var palette: ThemePalette { current.palette }

    static var background: Color { palette.background }
    static var surface: Color { palette.surface }
    static var accent: Color { palette.accent }
    static var accentGlow: Color { palette.accentGlow }
    static var textPrimary: Color { palette.textPrimary }
    static var textSecondary: Color { palette.textSecondary }
    /// Ink on a solid or near-solid `accent` fill (6.8:1 on the full accent). White on the full
    /// accent is 2.7:1 — under the 3:1 bold minimum — so every label, glyph and secondary line on
    /// `Theme.accent` uses this (UX-white-on-accent-contrast). On a near-solid fill (0.85–0.9) navy
    /// always passes (≥ 4.6:1) but white is only ~3.2–3.5:1, so white may stay there for LARGE
    /// text alone (the 18–19 pt bold Settings and setup quality rows, which need 3:1); any small
    /// text takes navy (the 0.85 setup-wizard preset chip's 11–13 pt line; the 0.9 PIN tiles are
    /// navy too). The setup wizard's Continue button set the precedent.
    static var onAccent: Color { palette.onAccent }
    /// Accent-coloured SMALL text on the theme's ground. Default's blue reads as
    /// is; elsewhere the accent sits under 4.5:1 on its own paper, so text
    /// takes a lighter (or, on Grid 72's paper, deeper) shade of it.
    static var accentText: Color { palette.accentText }
    /// What hairlines and faint fills are made of: white on a dark ground,
    /// ink on Grid 72's paper.
    static var ink: Color { palette.ink }
    /// Running now: the LIVE ring, dot and wash; `liveText` for words.
    static var live: Color { palette.live }
    static var liveText: Color { palette.liveText }
    /// A loaded preset that has changed: the dot; `editedText` for words.
    static var edited: Color { palette.edited }
    static var editedText: Color { palette.editedText }
    /// A problem worth reading (the computer chip's error, a dropped stream).
    static var warning: Color { palette.warning }
    /// What quiets the backdrop behind the setup wizard: black, or paper on
    /// Grid 72 so the wizard stays a light page.
    static var veil: Color { palette.veil }

    /// The ink on a lit surface: navy on a full-strength accent fill, white on a light tint (the
    /// accent at 0.35–0.4 over the dark backdrop, where navy falls to ~2:1) or the destructive red
    /// (UX-white-on-accent-contrast). Near-solid 0.85–0.9 fills don't use this switch; they pick
    /// their ink by text size — see `onAccent`. On Grid 72's paper a light tint keeps dark ink.
    nonisolated static func labelInk(onSolidAccent solid: Bool) -> Color {
        solid ? onAccent : palette.tintInk
    }

    /// A faint hairline that Increase Contrast lifts to at least 0.35, so no border is
    /// conveyed by faintness alone (HIG › Accessibility › Vision; UX-white-on-accent-contrast).
    nonisolated static func hairline(_ base: Double, _ contrast: ColorSchemeContrast) -> Color {
        ink.opacity(contrast == .increased ? max(base, 0.35) : base)
    }

    /// Focus animation used across the whole UI — one curve per theme: Default's
    /// spring; Night Edition's paper ease-out (nothing overshoots); Grid 72's
    /// 180 ms standard decelerate; Kabuki Cut's short overshoot.
    static var focusSpring: Animation {
        switch current {
        case .default:             .spring(response: 0.28, dampingFraction: 0.72)
        case .nightEdition:        .timingCurve(0.2, 0.75, 0.2, 1, duration: 0.26)
        case .grid72, .grid72Dark: .timingCurve(0.2, 0, 0, 1, duration: 0.18)
        case .kabukiCut:           .spring(response: 0.2, dampingFraction: 0.62)
        }
    }

    /// A focus (or selection) scale in the current theme (see
    /// `AppTheme.focusScale(_:)`).
    static func focusScale(_ scale: CGFloat) -> CGFloat { current.focusScale(scale) }

    /// A resting drop shadow: black at `opacity`, or none on Grid 72, where
    /// nothing casts a shadow on the paper.
    static func restShadow(_ opacity: Double) -> Color {
        current.isGrid ? .clear : .black.opacity(opacity)
    }

    /// Large text on a near-solid (0.85) accent fill — the focused Settings and
    /// setup quality rows: white in Default (enough at 18–19 pt bold; see
    /// `onAccent`), the theme's own on-accent ink elsewhere.
    static var onAccentLarge: Color { current == .default ? .white : palette.onAccent }

    /// Kabuki Cut's lean, in degrees (CSS `skewX`): slabs, chips and captions.
    static let slant: Double = -10

    // MARK: Per-platform sizes
    //
    // An iPad draws the 1440×860 canvas at about 0.79–0.96×, so its small
    // labels are authored at 13 pt and its tap targets at 44 pt, which keeps
    // them nearer Apple's minimums once scaled (UX-ios-scale-shrinks-text-targets).
    // A Mac draws the same canvas at 1.0× under a pointer and keeps its
    // original sizes: 44 pt targets are iPhone padding on a Mac, where the
    // HIG's control default is 28 pt (polish 1A).

    /// A small label's point size: `macOS` on the Mac, at least 13 pt on iOS.
    nonisolated static func labelSize(_ macOS: CGFloat,
                                      on platform: RootView.Platform = .current) -> CGFloat {
        platform == .iOS ? max(macOS, 13) : macOS
    }

    /// A tap-target size (or the padding that makes one) that differs by platform.
    nonisolated static func perPlatform<T>(iOS: T, macOS: T,
                                           on platform: RootView.Platform = .current) -> T {
        platform == .iOS ? iOS : macOS
    }
}

// MARK: - Palettes

/// One theme's colours. Text-on-ground pairs are checked in ThemeContrastTests.
struct ThemePalette: Sendable {
    let background: Color
    let surface: Color
    let accent: Color
    let accentGlow: Color
    let accentText: Color
    let textPrimary: Color
    let textSecondary: Color
    let onAccent: Color
    let ink: Color
    /// Words on a light accent tint (`Theme.labelInk(onSolidAccent: false)`).
    let tintInk: Color
    let live: Color
    let liveText: Color
    let edited: Color
    let editedText: Color
    let warning: Color
    let veil: Color
    /// A light ground (Grid 72): faint white fills vanish on it.
    let isLight: Bool

    static let `default` = ThemePalette(
        background: Color(red: 0.05, green: 0.06, blue: 0.09),
        surface: Color(red: 0.10, green: 0.11, blue: 0.16),
        accent: Color(red: 0.35, green: 0.62, blue: 1.0),
        accentGlow: Color(red: 0.35, green: 0.62, blue: 1.0).opacity(0.55),
        accentText: Color(red: 0.35, green: 0.62, blue: 1.0),
        textPrimary: .white,
        textSecondary: .white.opacity(0.6),
        onAccent: Color(red: 0.04, green: 0.08, blue: 0.16),   // #0A1429
        ink: .white,
        tintInk: .white,
        live: .green, liveText: .green,
        edited: .orange, editedText: .orange,
        warning: .orange,
        veil: .black,
        isLight: false)

    /// Night Edition: ivory ink on black paper, one vermilion. The spec's
    /// #D8402A carries no ink at 4.5:1 (ivory 4.0, white 4.48), so the fill is
    /// cut a shade deeper — ivory on it 4.7:1 — and still frames the paper at
    /// 3.5:1. Vermilion WORDS on the paper take a lighter cut (5.3:1).
    static let nightEdition = ThemePalette(
        background: Color(hex: 0x15130F),
        surface: Color(hex: 0x1E1B16),
        accent: Color(hex: 0xC53A26),
        accentGlow: Color(hex: 0xC53A26).opacity(0.45),
        accentText: Color(hex: 0xE85A40),
        textPrimary: Color(hex: 0xF2EAD8),
        textSecondary: Color(hex: 0x9A9184),
        onAccent: Color(hex: 0xF8F1E2),
        ink: Color(hex: 0xF2EAD8),
        tintInk: Color(hex: 0xF2EAD8),
        live: Color(hex: 0x78C27A), liveText: Color(hex: 0x78C27A),
        edited: Color(hex: 0xE7A33C), editedText: Color(hex: 0xE7A33C),
        warning: Color(hex: 0xE7A33C),
        veil: .black,
        isLight: false)

    /// Grid 72: Swiss paper, ink, one red, nothing glows. The red is 4.4:1 on
    /// the paper and the green 2.9:1, so words in them take deeper cuts.
    static let grid72 = ThemePalette(
        background: Color(hex: 0xF3F2EE),
        surface: Color(hex: 0xFFFFFF),
        accent: Color(hex: 0xE3001B),
        accentGlow: .clear,
        accentText: Color(hex: 0xD10018),
        textPrimary: Color(hex: 0x111111),
        textSecondary: Color(hex: 0x6E6E6A),
        onAccent: .white,
        ink: Color(hex: 0x111111),
        tintInk: Color(hex: 0x111111),
        live: Color(hex: 0x00A651), liveText: Color(hex: 0x007A3C),
        edited: Color(hex: 0xF28C00), editedText: Color(hex: 0xA35400),
        warning: Color(hex: 0xA35400),
        veil: Color(hex: 0xF3F2EE),
        isLight: true)

    /// Grid 72 Dark, the ink inversion: paper and ink swap, the same red. That
    /// red is 3.9:1 on the ink, so it marks (the focus bar, frames, large
    /// bold type) and red WORDS take a lighter cut (5.9:1).
    static let grid72Dark = ThemePalette(
        background: Color(hex: 0x111111),
        surface: Color(hex: 0x1B1B1B),
        accent: Color(hex: 0xE3001B),
        accentGlow: .clear,
        accentText: Color(hex: 0xFF4F5A),
        textPrimary: Color(hex: 0xF3F2EE),
        textSecondary: Color(hex: 0x9C9B96),
        onAccent: .white,
        ink: Color(hex: 0xF3F2EE),
        tintInk: Color(hex: 0xF3F2EE),
        live: Color(hex: 0x2BC46E), liveText: Color(hex: 0x2BC46E),
        edited: Color(hex: 0xF28C00), editedText: Color(hex: 0xF28C00),
        warning: Color(hex: 0xF28C00),
        veil: .black,
        isLight: false)

    /// Kabuki Cut: black, crimson and white; lime for LIVE. White on crimson
    /// is 4.7:1; crimson words on black take a lighter cut (6.0:1).
    static let kabukiCut = ThemePalette(
        background: Color(hex: 0x0B0B0C),
        surface: Color(hex: 0x161617),
        accent: Color(hex: 0xE5102E),
        accentGlow: Color(hex: 0xE5102E).opacity(0.5),
        accentText: Color(hex: 0xFF4A60),
        textPrimary: .white,
        textSecondary: Color(hex: 0xB9B9B9),
        onAccent: .white,
        ink: .white,
        tintInk: .white,
        live: Color(hex: 0xB6FF3B), liveText: Color(hex: 0xB6FF3B),
        edited: Color(hex: 0xFF8A00), editedText: Color(hex: 0xFF8A00),
        warning: Color(hex: 0xFF8A00),
        veil: .black,
        isLight: false)
}

extension AppTheme {
    var palette: ThemePalette {
        switch self {
        case .default:      .default
        case .nightEdition: .nightEdition
        case .grid72:       .grid72
        case .grid72Dark:   .grid72Dark
        case .kabukiCut:    .kabukiCut
        }
    }
}

extension Color {
    /// An sRGB colour from a 0xRRGGBB literal (the design spec's hexes).
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Type

extension AppTheme {
    /// This theme's display face (also what a theme preview card shows).
    func displayFont(_ size: CGFloat) -> Font {
        switch self {
        case .default:             .system(size: size, weight: .black, design: .rounded)
        case .nightEdition:        ThemeFace.frauncesBlack.font(size)
        case .grid72, .grid72Dark: ThemeFace.archivoExpandedBlack.font(size)
        case .kabukiCut:           ThemeFace.delaGothic.font(size)
        }
    }

    /// A focus (or selection) scale in this theme: Default and Kabuki Cut grow
    /// what's focused; Night Edition and Grid 72 never scale anything — focus
    /// is a frame there.
    func focusScale(_ scale: CGFloat) -> CGFloat {
        switch self {
        case .default, .kabukiCut:                scale
        case .nightEdition, .grid72, .grid72Dark: 1
        }
    }

    /// A corner radius in this theme: Default keeps the radius it is given,
    /// Night Edition prints at 2 pt, Grid 72 and Kabuki Cut are square.
    func corner(_ radius: CGFloat) -> CGFloat {
        switch self {
        case .default:                         radius
        case .nightEdition:                    min(radius, 2)
        case .grid72, .grid72Dark, .kabukiCut: 0
        }
    }
}

extension Theme {
    /// The display face: hero, wordmark, screen and card titles. Default is
    /// SF Rounded Black.
    static func display(_ size: CGFloat) -> Font { current.displayFont(size) }

    /// Labels, values and captions. Default keeps the system design the call
    /// site asks for (SF Rounded unless it says otherwise); the other themes
    /// set them in their UI family at the nearest weight they bundle.
    static func ui(_ size: CGFloat, _ weight: Font.Weight, design: Font.Design = .rounded) -> Font {
        switch current {
        case .default:             .system(size: size, weight: weight, design: design)
        case .nightEdition:        ThemeFace.plex(weight).font(size)
        case .grid72, .grid72Dark: ThemeFace.archivo(weight).font(size)
        case .kabukiCut:           ThemeFace.zenKaku(weight).font(size)
        }
    }

    /// Dense data — badges, chip summaries, the seconds clock: Grid 72 sets it
    /// in Archivo's narrow width; everywhere else it is `ui`.
    static func narrow(_ size: CGFloat, _ weight: Font.Weight, design: Font.Design = .rounded) -> Font {
        current.isGrid ? ThemeFace.archivoNarrow(weight).font(size) : ui(size, weight, design: design)
    }

    /// One text element's face, tracking and case in this theme.
    static func text(_ role: TextRole) -> ThemeTextStyle {
        switch current {
        case .default:             role.defaultStyle
        case .nightEdition:        role.nightStyle
        case .grid72, .grid72Dark: role.gridStyle
        case .kabukiCut:           role.kabukiStyle
        }
    }
}

/// A face plus the tracking and case it is set with.
struct ThemeTextStyle {
    var font: Font
    var tracking: CGFloat = 0
    var uppercase = false
}

/// The home screen's text elements, each styled per theme from the design
/// spec (docs: the Home Screen Concepts page). Default reproduces the
/// original fonts and tracking exactly.
enum TextRole {
    case wordmark, clock, hostName, hero, badge
    case tileCaption, tileCaptionFocused
    case sectionLabel, chipName, chipSummary, chipEdited
    case hint, hintTouch, keyCap, liveBadge
    case screenTitle, sheetTitle

    fileprivate var defaultStyle: ThemeTextStyle {
        switch self {
        case .screenTitle:        ThemeTextStyle(font: .system(size: 30, weight: .black, design: .rounded), tracking: 6)
        case .sheetTitle:         ThemeTextStyle(font: .system(size: 22, weight: .black, design: .rounded), tracking: 4)
        case .wordmark:           ThemeTextStyle(font: .system(size: 22, weight: .black, design: .rounded), tracking: 6)
        case .clock:              ThemeTextStyle(font: .system(size: 20, weight: .bold, design: .rounded))
        case .hostName:           ThemeTextStyle(font: .system(size: 16, weight: .semibold, design: .rounded))
        case .hero:               ThemeTextStyle(font: .system(size: 52, weight: .black, design: .rounded))
        case .badge:              ThemeTextStyle(font: .system(size: Theme.labelSize(12), weight: .heavy, design: .rounded),
                                                 tracking: 1.2)
        case .tileCaption:        ThemeTextStyle(font: .system(size: 15, weight: .medium, design: .rounded))
        case .tileCaptionFocused: ThemeTextStyle(font: .system(size: 15, weight: .bold, design: .rounded))
        case .sectionLabel:       ThemeTextStyle(font: .system(size: 13, weight: .heavy, design: .rounded), tracking: 2)
        case .chipName:           ThemeTextStyle(font: .system(size: 15, weight: .bold, design: .rounded))
        case .chipSummary:        ThemeTextStyle(font: .system(size: Theme.labelSize(11), weight: .medium))
        case .chipEdited:         ThemeTextStyle(font: .system(size: Theme.labelSize(11), weight: .bold))
        case .hint:               ThemeTextStyle(font: .system(size: 13, weight: .semibold, design: .rounded))
        case .hintTouch:          ThemeTextStyle(font: .system(size: 15, weight: .bold, design: .rounded))
        case .keyCap:             ThemeTextStyle(font: .system(size: Theme.labelSize(12), weight: .heavy, design: .rounded))
        case .liveBadge:          ThemeTextStyle(font: .system(size: 11, weight: .heavy, design: .rounded), tracking: 1.2)
        }
    }

    /// Fraunces for the voice (hero, masthead, the focused caption, the stamp);
    /// IBM Plex Sans Condensed, tracked capitals, for everything small.
    fileprivate var nightStyle: ThemeTextStyle {
        switch self {
        case .screenTitle:        ThemeTextStyle(font: ThemeFace.frauncesBlack.font(34), tracking: 0.5)
        case .sheetTitle:         ThemeTextStyle(font: ThemeFace.frauncesBlack.font(24), tracking: 0.5)
        case .wordmark:           ThemeTextStyle(font: ThemeFace.frauncesBlack.font(26), tracking: 0.5)
        case .clock:              ThemeTextStyle(font: ThemeFace.plexSemiBold.font(20), tracking: 0.8)
        case .hostName:           ThemeTextStyle(font: ThemeFace.plexSemiBold.font(15), tracking: 2.1, uppercase: true)
        case .hero:               ThemeTextStyle(font: ThemeFace.frauncesBlack.font(60), tracking: -0.9)
        case .badge:              ThemeTextStyle(font: ThemeFace.plexSemiBold.font(13), tracking: 1.8, uppercase: true)
        case .tileCaption:        ThemeTextStyle(font: ThemeFace.plexMedium.font(15))
        case .tileCaptionFocused: ThemeTextStyle(font: ThemeFace.frauncesBoldItalic.font(18))
        case .sectionLabel:       ThemeTextStyle(font: ThemeFace.plexSemiBold.font(13), tracking: 2.6)
        case .chipName:           ThemeTextStyle(font: ThemeFace.plexBold.font(15))
        case .chipSummary:        ThemeTextStyle(font: ThemeFace.plexMedium.font(Theme.labelSize(11)))
        case .chipEdited:         ThemeTextStyle(font: ThemeFace.plexBold.font(Theme.labelSize(11)))
        case .hint:               ThemeTextStyle(font: ThemeFace.plexSemiBold.font(13), tracking: 1.6, uppercase: true)
        case .hintTouch:          ThemeTextStyle(font: ThemeFace.plexBold.font(15), tracking: 1.6, uppercase: true)
        case .keyCap:             ThemeTextStyle(font: ThemeFace.plexBold.font(Theme.labelSize(12)))
        case .liveBadge:          ThemeTextStyle(font: ThemeFace.frauncesBlack.font(12), tracking: 0.7)
        }
    }

    /// Archivo at three widths: expanded black for the voice, normal for UI,
    /// narrow for dense data; capitals tracked wide.
    fileprivate var gridStyle: ThemeTextStyle {
        switch self {
        case .screenTitle:        ThemeTextStyle(font: ThemeFace.archivoExpandedBlack.font(30), tracking: 2.4)
        case .sheetTitle:         ThemeTextStyle(font: ThemeFace.archivoExpandedBlack.font(22), tracking: 1.8)
        case .wordmark:           ThemeTextStyle(font: ThemeFace.archivoExpandedBlack.font(22), tracking: 1.8)
        case .clock:              ThemeTextStyle(font: ThemeFace.archivoNarrowBold.font(20), tracking: 0.8)
        case .hostName:           ThemeTextStyle(font: ThemeFace.archivoSemiBold.font(13), tracking: 1.6, uppercase: true)
        case .hero:               ThemeTextStyle(font: ThemeFace.archivoExpandedBlack.font(60), tracking: -0.6, uppercase: true)
        case .badge:              ThemeTextStyle(font: ThemeFace.archivoNarrowSemiBold.font(13), tracking: 1.6, uppercase: true)
        case .tileCaption:        ThemeTextStyle(font: ThemeFace.archivoMedium.font(15), tracking: 1.2, uppercase: true)
        case .tileCaptionFocused: ThemeTextStyle(font: ThemeFace.archivoBold.font(15), tracking: 1.2, uppercase: true)
        case .sectionLabel:       ThemeTextStyle(font: ThemeFace.archivoBold.font(13), tracking: 2.6)
        case .chipName:           ThemeTextStyle(font: ThemeFace.archivoBold.font(15))
        case .chipSummary:        ThemeTextStyle(font: ThemeFace.archivoNarrowMedium.font(Theme.labelSize(11)), tracking: 0.2)
        case .chipEdited:         ThemeTextStyle(font: ThemeFace.archivoNarrowBold.font(Theme.labelSize(11)), tracking: 0.2)
        case .hint:               ThemeTextStyle(font: ThemeFace.archivoSemiBold.font(13), tracking: 1.6, uppercase: true)
        case .hintTouch:          ThemeTextStyle(font: ThemeFace.archivoBold.font(15), tracking: 1.2, uppercase: true)
        case .keyCap:             ThemeTextStyle(font: ThemeFace.archivoBold.font(Theme.labelSize(12)))
        case .liveBadge:          ThemeTextStyle(font: ThemeFace.archivoExtraBold.font(Theme.labelSize(12)), tracking: 1.4)
        }
    }

    /// Dela Gothic One shouts (hero, masthead, clock, LIVE); Zen Kaku Gothic
    /// New keeps everything small sober.
    fileprivate var kabukiStyle: ThemeTextStyle {
        switch self {
        case .screenTitle:        ThemeTextStyle(font: ThemeFace.delaGothic.font(30), tracking: 1.2)
        case .sheetTitle:         ThemeTextStyle(font: ThemeFace.delaGothic.font(22), tracking: 1)
        case .wordmark:           ThemeTextStyle(font: ThemeFace.delaGothic.font(24), tracking: 1)
        case .clock:              ThemeTextStyle(font: ThemeFace.delaGothic.font(22))
        case .hostName:           ThemeTextStyle(font: ThemeFace.zenKakuBold.font(14), tracking: 1.4, uppercase: true)
        case .hero:               ThemeTextStyle(font: ThemeFace.delaGothic.font(56), tracking: 0.6, uppercase: true)
        case .badge:              ThemeTextStyle(font: ThemeFace.zenKakuBlack.font(Theme.labelSize(12)), tracking: 1.2,
                                                 uppercase: true)
        case .tileCaption, .tileCaptionFocused:
                                  ThemeTextStyle(font: ThemeFace.zenKakuBold.font(15), tracking: 1.2, uppercase: true)
        case .sectionLabel:       ThemeTextStyle(font: ThemeFace.delaGothic.font(13), tracking: 2.6)
        case .chipName:           ThemeTextStyle(font: ThemeFace.zenKakuBlack.font(15), tracking: 0.6, uppercase: true)
        case .chipSummary:        ThemeTextStyle(font: ThemeFace.zenKakuBold.font(Theme.labelSize(11)))
        case .chipEdited:         ThemeTextStyle(font: ThemeFace.zenKakuBlack.font(Theme.labelSize(11)))
        case .hint:               ThemeTextStyle(font: ThemeFace.zenKakuBlack.font(13), tracking: 1.3, uppercase: true)
        case .hintTouch:          ThemeTextStyle(font: ThemeFace.zenKakuBlack.font(15), tracking: 1, uppercase: true)
        case .keyCap:             ThemeTextStyle(font: ThemeFace.zenKakuBlack.font(Theme.labelSize(12)))
        case .liveBadge:          ThemeTextStyle(font: ThemeFace.delaGothic.font(13), tracking: 0.8)
        }
    }
}

extension View {
    /// Sets a text element in this theme's face, tracking and case.
    func themeText(_ role: TextRole) -> some View {
        modifier(ThemeTextModifier(style: Theme.text(role)))
    }
}

private struct ThemeTextModifier: ViewModifier {
    let style: ThemeTextStyle

    /// Untracked, mixed-case styles (most of Default's) get the font alone, so
    /// Default text carries no modifier it didn't have before.
    @ViewBuilder func body(content: Content) -> some View {
        if style.tracking == 0 && !style.uppercase {
            content.font(style.font)
        } else {
            content
                .font(style.font)
                .tracking(style.tracking)
                .textCase(style.uppercase ? .uppercase : nil)
        }
    }
}

// MARK: - Cards

extension View {
    /// A card's chrome: the surface plate every card sits on, plus the theme's
    /// edge — Night Edition's ivory keyline, Grid 72's ink rule, Kabuki Cut's
    /// white rule over a hard crimson offset shadow. Default is the plain
    /// plate it always was.
    func themeCard(cornerRadius: CGFloat = 24) -> some View {
        modifier(ThemeCardChrome(radius: cornerRadius))
    }
}

private struct ThemeCardChrome: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            // Kabuki's card is opaque, or its crimson shadow tints it through.
            .background(Theme.surface.opacity(Theme.current == .kabukiCut ? 1 : 0.95),
                        in: Theme.plate(radius))
            .overlay { edge }
            .background { shadow }
    }

    @ViewBuilder private var edge: some View {
        switch Theme.current {
        case .default:             EmptyView()
        case .nightEdition:        Theme.plate(radius).strokeBorder(Theme.ink.opacity(0.28), lineWidth: 1)
        case .grid72, .grid72Dark: Theme.plate(radius).strokeBorder(Theme.ink, lineWidth: 1.5)
        case .kabukiCut:           Theme.plate(radius).strokeBorder(Theme.ink, lineWidth: 2)
        }
    }

    @ViewBuilder private var shadow: some View {
        if Theme.current == .kabukiCut {
            Rectangle().fill(Theme.accent).offset(x: 10, y: 10)
        }
    }
}

// MARK: - Shape

extension Theme {
    /// A corner radius in the current theme (see `AppTheme.corner(_:)`).
    static func corner(_ radius: CGFloat) -> CGFloat { current.corner(radius) }

    /// A pill in Default; a 2 pt plate in Night Edition; square elsewhere.
    static var pill: ThemeShape { ThemeShape(cornerRadius: nil) }

    /// A rounded rectangle whose radius follows `corner(_:)`.
    static func plate(_ radius: CGFloat) -> ThemeShape { ThemeShape(cornerRadius: radius) }
}

/// A capsule or rounded rectangle, resolved for the theme it was made in.
/// Insettable, so `strokeBorder` works as it does on `Capsule`.
struct ThemeShape: InsettableShape {
    /// nil = capsule.
    private let radius: CGFloat?
    private var inset: CGFloat = 0

    /// `cornerRadius: nil` asks for a capsule.
    init(cornerRadius: CGFloat?, theme: AppTheme = Theme.current) {
        if theme == .default {
            radius = cornerRadius
        } else {
            radius = theme.corner(cornerRadius ?? 2)
        }
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard let radius else { return Capsule().path(in: r) }
        return RoundedRectangle(cornerRadius: radius).path(in: r)
    }

    func inset(by amount: CGFloat) -> ThemeShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}

extension View {
    /// Slants the view like CSS `skewX(degrees)` — negative leans right, as
    /// italics do — about the horizontal line `pivot` points below its top.
    /// Layout keeps the upright frame; only what's drawn leans.
    func slanted(_ degrees: Double, pivot: CGFloat = 0) -> some View {
        let c = CGFloat(tan(degrees * .pi / 180))
        return transformEffect(CGAffineTransform(a: 1, b: 0, c: c, d: 1, tx: -c * pivot, ty: 0))
    }
}
