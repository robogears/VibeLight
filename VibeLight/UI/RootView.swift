import SwiftUI

/// Top-level scene composition: ambient background, current screen, overlays.
struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            AmbientBackground()

            switch state.screen {
            case .home:
                HomeView()
                    .transition(.opacity)
            case .settings:
                SettingsView()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if let overlay = state.overlay {
                OverlayHost(overlay: overlay)
                    .transition(.opacity)
            }
        }
        .animation(Theme.focusSpring, value: state.screen)
        .animation(.easeOut(duration: 0.18), value: state.overlay)
        .ignoresSafeArea()
    }
}

/// Deep console-dark backdrop with a slow-breathing accent wash — gives the
/// whole app the ambient glow Big Picture screens have, without any artwork
/// dependency.
private struct AmbientBackground: View {
    @State private var breathe = false

    var body: some View {
        ZStack {
            Theme.background

            RadialGradient(
                colors: [Theme.accent.opacity(breathe ? 0.16 : 0.09), .clear],
                center: .init(x: 0.25, y: 0.15),
                startRadius: 0,
                endRadius: 900
            )
            RadialGradient(
                colors: [Color(red: 0.45, green: 0.2, blue: 0.75).opacity(breathe ? 0.08 : 0.13), .clear],
                center: .init(x: 0.85, y: 0.85),
                startRadius: 0,
                endRadius: 800
            )
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}
