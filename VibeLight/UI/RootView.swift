import SwiftUI

/// Top-level scene composition: ambient background, current screen, overlays —
/// laid out in a resolution-adaptive virtual canvas so the big-picture UI keeps
/// the same physical proportions at any display size (see `uiScale`).
struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        GeometryReader { geo in
            let scale = Self.uiScale(for: geo.size)
            content
                // Lay the whole UI out in a virtual canvas (real size ÷ scale),
                // then scale it to fill the screen from the top-leading corner
                // (GeometryReader anchors its child there). On a normal Mac scale
                // is exactly 1.0 → identity, zero change. On a 4K/5K display it
                // upscales so elements aren't tiny; on iPhone/iPad it fits the
                // full design to the screen. topLeading anchor keeps the scaled
                // canvas exactly overlaying the screen (a .center anchor pushes
                // an oversized virtual frame off-screen).
                .frame(width: geo.size.width / scale, height: geo.size.height / scale,
                       alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
        }
        .ignoresSafeArea()
        #if os(iOS)
        // Live stream covers the whole screen (unscaled) while it's up.
        .overlay {
            if case .streaming = state.session.phase {
                StreamView(layer: state.session.displayLayer)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        #endif
    }

    private var content: some View {
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

            if let hold = state.controller.holdProgress {
                HoldProgressRing(progress: hold)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .animation(Theme.focusSpring, value: state.screen)
        .animation(.easeOut(duration: 0.18), value: state.overlay)
        .animation(.easeOut(duration: 0.15), value: state.controller.holdProgress == nil)
    }

    /// The scale that maps the design canvas onto the real window. The UI is
    /// authored on a landscape design canvas; we fit that canvas to the real
    /// window across BOTH dimensions so it never overflows — the previous
    /// width-only, floor-1.0 rule left a small/windowed Mac at full design size,
    /// so the title, logo and preset rail overflowed and collided.
    /// - macOS: 1.0 through the normal Mac range (design flexes comfortably at
    ///   ≥ 1440×860 pt); SHRINK to fit a smaller window; scale UP on 4K/5K so
    ///   fixed-size elements aren't tiny.
    /// - iOS/iPadOS: fit the ~1920×1080 design to the (landscape) screen.
    static let macDesignMin = CGSize(width: 1440, height: 860)

    static func uiScale(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        #if os(macOS)
        // Shrink to fit when the window is smaller than the design canvas…
        let fit = min(size.width / macDesignMin.width, size.height / macDesignMin.height)
        if fit < 1 { return max(fit, 0.3) }
        // …otherwise 1.0 in the normal range, scaling up only on huge displays.
        return min(max(size.width / 2000, 1.0), 2.5)
        #else
        // iOS/iPadOS: fit the ~1920×1080 design to the (landscape) screen, then
        // zoom 1.25× so the big-picture UI reads larger on iPhone/iPad.
        let fit = min(size.width / 1920, size.height / 1080)
        return min(max(fit * 1.25, 0.3), 1.6)
        #endif
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
