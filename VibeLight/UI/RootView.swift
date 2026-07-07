import SwiftUI

/// Top-level scene composition: ambient background, current screen, overlays —
/// laid out in a resolution-adaptive virtual canvas so the big-picture UI keeps
/// the same physical proportions at any display size (see `uiScale`).
struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        GeometryReader { geo in
            let scale = Self.uiScale(for: geo.size)
            LauncherContent()
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
        // While a TV owns the display, the iPad is a companion screen — the
        // launcher shows ONLY on the TV. Shown the instant a display connects
        // (isConnected is observable), and only when not streaming (the stream
        // overlay below provides its own placeholder + trackpad).
        .overlay {
            let tvActive = state.settings.externalDisplay && ExternalDisplay.shared.isConnected
            let idle: Bool = { if case .streaming = state.session.phase { false } else { true } }()
            if tvActive && idle {
                ExternalDisplayPlaceholder(streaming: false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: ExternalDisplay.shared.isConnected)
        // Live stream covers the whole screen (unscaled) while it's up.
        .overlay {
            if case .streaming = state.session.phase {
                // A TV is showing the video → the iPad keeps only the controls
                // and acts as a trackpad (StreamView doesn't host the layer).
                let onTV = state.settings.externalDisplay && ExternalDisplay.shared.isConnected
                StreamView(layer: state.session.displayLayer, engine: state.session, hostsLayer: !onTV)
                    .ignoresSafeArea()
                    .overlay { if onTV { ExternalDisplayPlaceholder() } }
                    .overlay(alignment: .topLeading) {
                        // Performance HUD (Settings ▸ Advanced ▸ Performance Stats).
                        if let stats = state.session.perfStats {
                            Text(stats)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.9))
                                .multilineTextAlignment(.leading)
                                .lineSpacing(2)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                                .padding(24)
                                .allowsHitTesting(false)   // touches pass through to the stream
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        // Until input lands (Phase 4), a tappable way back out so
                        // the stream screen isn't a trap.
                        Button { state.session.disconnect() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.45), in: Circle())
                        }
                        .padding(24)
                    }
                    .overlay {
                        // Hold Start+Select+L1+R1 → leave-stream progress ring.
                        if let p = state.session.streamQuitProgress {
                            HoldProgressRing(progress: HoldProgress(kind: .disconnectStream, fraction: p))
                                .transition(.opacity)
                        }
                    }
                    .transition(.opacity)
            }
        }
        #endif
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

/// The big-picture launcher surface — ambient background, the current screen,
/// and any overlays. Extracted from `RootView` so the external-display window
/// can render the SAME UI (bound to the SAME `AppState`) on a connected TV.
struct LauncherContent: View {
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

            if let hold = state.controller.holdProgress {
                HoldProgressRing(progress: hold)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .animation(Theme.focusSpring, value: state.screen)
        .animation(.easeOut(duration: 0.18), value: state.overlay)
        .animation(.easeOut(duration: 0.15), value: state.controller.holdProgress == nil)
    }
}

#if os(iOS)
/// What the external display (TV / monitor) shows when NOT streaming: the full
/// launcher UI, fit to the TV. During a stream the window swaps to the raw
/// stream layer (see `ExternalDisplay`), so this view is only the idle surface.
struct ExternalDisplayContent: View {
    @Environment(AppState.self) private var state

    /// TV design canvas. The iPad's effective canvas is ~1536 wide; a SMALLER
    /// one makes tiles/text read larger from the couch, but it must stay wide
    /// enough that the launcher's landscape layout (header row, shelf, preset
    /// rail) doesn't crowd — 1280 was too narrow (that was the "misaligned").
    /// The launcher renders at ≥2× (forced in `ExternalDisplay` — old 1080p TVs
    /// report @1×, which would rasterize this canvas at 1× and upscale → blur),
    /// so a 1440-pt canvas rasterizes at 2880 px and DOWNSAMPLES to the panel:
    /// crisp on a 1080p TV, and sharp at 4K. One-line tunable — smaller = bigger
    /// icons.
    private static let tvDesign = CGSize(width: 1440, height: 810)

    var body: some View {
        GeometryReader { geo in
            let scale = max(min(geo.size.width / Self.tvDesign.width,
                                geo.size.height / Self.tvDesign.height), 0.4)
            LauncherContent()
                .frame(width: geo.size.width / scale, height: geo.size.height / scale,
                       alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
        }
        .ignoresSafeArea()
        .background(Theme.background)
    }
}

/// The iPad companion screen shown whenever a TV / monitor is driving the
/// display — VibeLight itself lives on the big screen, so the iPad is a calm
/// status panel. While streaming it's also a trackpad (touches pass through);
/// while idle it just says "use your controller".
private struct ExternalDisplayPlaceholder: View {
    var streaming = true

    var body: some View {
        // OLED-friendly: mostly black with a dim glow that slowly roams into the
        // corners, and the content itself gently drifts — so no bright pixel
        // stays lit in one place for the whole (possibly hours-long) session.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let dx = CGFloat(sin(t * 0.06))                 // slow, ~100 s period
            let dy = CGFloat(cos(t * 0.045))
            ZStack {
                Color.black
                RadialGradient(colors: [Theme.accent.opacity(0.12), .clear],
                               center: .center, startRadius: 0, endRadius: 520)
                    .offset(x: dx * 180, y: dy * 140)       // the glow roams widely
                    .blendMode(.plusLighter)

                VStack(spacing: 16) {
                    Image(systemName: "tv")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(streaming ? "Playing on \(ExternalDisplay.shared.name)"
                                   : "VibeLight is on \(ExternalDisplay.shared.name)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text(streaming ? "This screen is a trackpad — drag to move the cursor."
                                   : "Use your controller to navigate on the big screen.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    if let geometry = ExternalDisplay.shared.geometrySummary {
                        Text(geometry)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary.opacity(0.7))
                            .padding(.top, 4)
                    }
                }
                .offset(x: dx * 40, y: dy * 34)             // content drifts gently too
            }
        }
        .contentShape(Rectangle())
        // Streaming → pass touches through to the trackpad; idle → consume them
        // so the hidden launcher underneath can't be poked.
        .allowsHitTesting(!streaming)
        .ignoresSafeArea()
    }
}
#endif

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
