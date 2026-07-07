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

/// "Diagonal Drift": near-black with fine diagonal grooves that slowly crawl
/// across the screen. A `TimelineView` advances the stripe phase; the whole
/// pattern is one `Canvas` pass, so it's cheap regardless of stripe count.
struct DiagonalStripesBackground: View {
    // Tunables — safe to tweak to taste.
    private let spacing: CGFloat = 62         // gap between grooves
    private let tilt = Angle(degrees: 58)     // "/" lean — negate to lean the other way
    private let driftPerSecond: CGFloat = 6   // slow crawl

    private let base = Color(red: 0.035, green: 0.042, blue: 0.05)
    private let highlight = Color(red: 0.42, green: 0.58, blue: 0.62)   // cool steel/teal edge

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = CGFloat((t * Double(driftPerSecond))
                .truncatingRemainder(dividingBy: Double(spacing)))
            Canvas { context, size in
                var ctx = context
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))
                // Draw in a rotated, oversized space so the vertical grooves read
                // as parallel diagonals covering the whole view.
                let diag = hypot(size.width, size.height)
                ctx.translateBy(x: size.width / 2, y: size.height / 2)
                ctx.rotate(by: tilt)
                ctx.translateBy(x: -diag, y: -diag)
                let count = Int((2 * diag) / spacing) + 2
                for i in 0...count {
                    let x = CGFloat(i) * spacing + phase
                    // A dark groove with a faint cool highlight on its edge —
                    // reads as a subtle beveled diagonal line.
                    var groove = Path()
                    groove.move(to: CGPoint(x: x, y: 0))
                    groove.addLine(to: CGPoint(x: x, y: 2 * diag))
                    ctx.stroke(groove, with: .color(.black.opacity(0.55)), lineWidth: 2.2)

                    var edge = Path()
                    edge.move(to: CGPoint(x: x + 1.4, y: 0))
                    edge.addLine(to: CGPoint(x: x + 1.4, y: 2 * diag))
                    ctx.stroke(edge, with: .color(highlight.opacity(0.06)), lineWidth: 1.0)
                }
            }
        }
        .ignoresSafeArea()
    }
}
