import SwiftUI

/// VibeLight visual language — console-dark, high contrast, glow accents.
enum Theme {
    static let background = Color(red: 0.05, green: 0.06, blue: 0.09)
    static let surface = Color(red: 0.10, green: 0.11, blue: 0.16)
    static let accent = Color(red: 0.35, green: 0.62, blue: 1.0)
    static let accentGlow = Color(red: 0.35, green: 0.62, blue: 1.0).opacity(0.55)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.6)
    /// Ink on a full-strength `accent` fill (6.8:1). White on the accent is 2.7:1 — under the 3:1
    /// bold minimum — so every label, glyph and secondary line that sits on `Theme.accent` uses
    /// this (UX-white-on-accent-contrast). The setup wizard's Continue button set the precedent.
    static let onAccent = Color(red: 0.04, green: 0.08, blue: 0.16)   // #0A1429

    /// The ink on a lit surface: navy only on a FULL-strength accent fill. A merely tinted fill
    /// (the accent at 0.35 over the dark backdrop) or the destructive red would swallow navy,
    /// so those keep white (UX-white-on-accent-contrast).
    nonisolated static func labelInk(onSolidAccent solid: Bool) -> Color {
        solid ? onAccent : .white
    }

    /// A faint white hairline that Increase Contrast lifts to at least 0.35, so no border is
    /// conveyed by faintness alone (HIG › Accessibility › Vision; UX-white-on-accent-contrast).
    nonisolated static func hairline(_ base: Double, _ contrast: ColorSchemeContrast) -> Color {
        .white.opacity(contrast == .increased ? max(base, 0.35) : base)
    }

    /// Focus animation used across the whole UI — one spring to rule them all.
    static let focusSpring = Animation.spring(response: 0.28, dampingFraction: 0.72)

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
