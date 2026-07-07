import SwiftUI

/// The launcher background, selectable in Settings ▸ Themes. Rendered behind the
/// whole launcher by `LauncherContent`, so the choice applies everywhere the UI
/// shows (iPad, Mac, and the TV mirror).
struct AppBackground: View {
    let theme: BackgroundTheme

    var body: some View {
        switch theme {
        case .ambient:  AmbientBackground()
        case .diagonal: DiagonalStripesBackground()
        }
    }
}

/// Default theme: deep console-dark backdrop with a slow-breathing accent wash —
/// gives the app the ambient glow Big Picture screens have, without any artwork.
struct AmbientBackground: View {
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

/// A selectable theme preview card — a live thumbnail of the real background +
/// its name, with an accent ring + lift when selected. Reused by the setup
/// wizard and Settings ▸ Themes so users SEE each theme, not just a label.
struct ThemeCard: View {
    let theme: BackgroundTheme
    var selected: Bool = false
    var width: CGFloat = 220

    var body: some View {
        VStack(spacing: 10) {
            AppBackground(theme: theme)
                .allowsHitTesting(false)
                .frame(width: width, height: width * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(selected ? Theme.accent : .white.opacity(0.1),
                                      lineWidth: selected ? 3 : 1)
                }
                .shadow(color: selected ? Theme.accentGlow : .black.opacity(0.4),
                        radius: selected ? 20 : 8, y: 5)
            Text(theme.title)
                .font(.system(size: 16, weight: selected ? .bold : .medium, design: .rounded))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
        }
        .scaleEffect(selected ? 1.04 : 1.0)
        .animation(Theme.focusSpring, value: selected)
        // The whole card is clickable — the thumbnail itself is hit-test-off, so
        // without this a mouse click on the preview (most of the card) misses.
        .contentShape(Rectangle())
    }
}

/// "Diagonal Drift": near-black with flat diagonal stripes that slowly crawl
/// across the screen. FLAT on purpose — a single solid stripe with no bevel or
/// sheen, so it reads painted/cartoony rather than brushed-metal. A
/// `TimelineView` advances the stripe phase; the whole pattern is one `Canvas`
/// pass, so it's cheap regardless of stripe count.
struct DiagonalStripesBackground: View {
    // Tunables — safe to tweak to taste.
    private let spacing: CGFloat = 66         // gap between stripes
    private let tilt = Angle(degrees: 58)     // "/" lean — negate to lean the other way
    private let driftPerSecond: CGFloat = 6   // slow crawl
    private let lineWidth: CGFloat = 4        // flat, chunky-ish stripe

    private let base = Color(red: 0.02, green: 0.03, blue: 0.03)     // near-black
    private let stripe = Color(red: 0.13, green: 0.27, blue: 0.24)   // flat, friendly teal-green

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = CGFloat((t * Double(driftPerSecond))
                .truncatingRemainder(dividingBy: Double(spacing)))
            Canvas { context, size in
                var ctx = context
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))
                // Draw in a rotated, oversized space so the vertical stripes read
                // as parallel diagonals covering the whole view.
                let diag = hypot(size.width, size.height)
                ctx.translateBy(x: size.width / 2, y: size.height / 2)
                ctx.rotate(by: tilt)
                ctx.translateBy(x: -diag, y: -diag)
                let count = Int((2 * diag) / spacing) + 2
                for i in 0...count {
                    let x = CGFloat(i) * spacing + phase
                    // One flat, solid stroke — no groove, no highlight, no sheen.
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: 2 * diag))
                    ctx.stroke(line, with: .color(stripe), lineWidth: lineWidth)
                }
            }
        }
        .ignoresSafeArea()
    }
}
