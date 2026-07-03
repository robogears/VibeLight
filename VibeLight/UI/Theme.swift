import SwiftUI

/// VibeLight visual language — console-dark, high contrast, glow accents.
enum Theme {
    static let background = Color(red: 0.05, green: 0.06, blue: 0.09)
    static let surface = Color(red: 0.10, green: 0.11, blue: 0.16)
    static let accent = Color(red: 0.35, green: 0.62, blue: 1.0)
    static let accentGlow = Color(red: 0.35, green: 0.62, blue: 1.0).opacity(0.55)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.6)

    /// Focus animation used across the whole UI — one spring to rule them all.
    static let focusSpring = Animation.spring(response: 0.28, dampingFraction: 0.72)
}
