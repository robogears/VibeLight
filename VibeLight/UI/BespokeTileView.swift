import SwiftUI

/// Hand-designed tiles for utility apps (Desktop, Steam, Playnite…) where
/// host box art is either the lying 130×180 placeholder or meaningless.
/// These should look BETTER than generic box art, not like fallbacks.
struct BespokeTileView: View {
    let kind: TileArtwork.BespokeTile
    let title: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: palette,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Subtle large glyph anchored off-corner for depth.
            mark(size: 96)
                .foregroundStyle(.white.opacity(0.14))
                .offset(x: 34, y: -30)
                .rotationEffect(.degrees(-8))

            VStack {
                Spacer()
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        mark(size: 28)
                            .foregroundStyle(.white)
                        Text(title)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                }
                .padding(16)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.45)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
    }

    /// The tile's glyph at `size` pt. Steam gets its own mark (owner: "look
    /// like the actual Steam logo while still holding the style"); the rest
    /// use SF Symbols.
    @ViewBuilder
    private func mark(size: CGFloat) -> some View {
        if kind == .steam {
            SteamMark().frame(width: size * 1.15, height: size * 1.15)
        } else {
            Image(systemName: symbol).font(.system(size: size, weight: size > 40 ? .bold : .semibold))
        }
    }

    private var symbol: String {
        switch kind {
        case .desktop: "desktopcomputer"
        case .steam: "gamecontroller.fill"
        case .playnite: "square.grid.2x2.fill"
        case .moonDeck: "moon.stars.fill"
        case .virtualDisplay: "display.2"
        case .generic: "app.dashed"
        }
    }

    private var palette: [Color] {
        switch kind {
        case .desktop: [Color(red: 0.13, green: 0.32, blue: 0.55), Color(red: 0.05, green: 0.12, blue: 0.25)]
        // Steam's own navy → steel blue (#1B2838 → #2A475E), a touch lifted.
        case .steam: [Color(red: 0.11, green: 0.16, blue: 0.23), Color(red: 0.17, green: 0.30, blue: 0.40)]
        case .playnite: [Color(red: 0.35, green: 0.18, blue: 0.55), Color(red: 0.14, green: 0.07, blue: 0.28)]
        case .moonDeck: [Color(red: 0.16, green: 0.14, blue: 0.40), Color(red: 0.05, green: 0.04, blue: 0.15)]
        case .virtualDisplay: [Color(red: 0.05, green: 0.35, blue: 0.35), Color(red: 0.02, green: 0.13, blue: 0.16)]
        case .generic: [Color(red: 0.22, green: 0.24, blue: 0.30), Color(red: 0.09, green: 0.10, blue: 0.14)]
        }
    }
}

/// The Steam mark, drawn rather than bundled: a disc with the "piston" cut
/// out of it — a wheel at the upper right (ring + hub) joined by a rod to a
/// small wheel at the lower left. One colour (the current foreground style),
/// so it takes each tile's treatment: faint as the corner watermark, solid
/// white as the icon above the title.
struct SteamMark: View {
    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * r, y: c.y + y * r) }
            func disc(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: c.x + (x - radius) * r, y: c.y + (y - radius) * r,
                                       width: 2 * radius * r, height: 2 * radius * r))
            }
            func line(_ a: CGPoint, _ b: CGPoint) -> Path {
                var path = Path(); path.move(to: a); path.addLine(to: b); return path
            }
            let big = (x: 0.34, y: -0.26), small = (x: -0.50, y: 0.34)
            let ink = GraphicsContext.Shading.foreground

            // The badge.
            ctx.fill(disc(0, 0, 1), with: ink)

            // Cut the piston's clearance out of it.
            ctx.blendMode = .clear
            ctx.fill(disc(big.x, big.y, 0.43), with: ink)
            ctx.fill(disc(small.x, small.y, 0.27), with: ink)
            ctx.stroke(line(p(big.x, big.y), p(small.x, small.y)), with: ink,
                       style: StrokeStyle(lineWidth: 0.27 * r, lineCap: .round))

            // The piston: big wheel (ring + hub), rod, small wheel.
            ctx.blendMode = .normal
            ctx.stroke(disc(big.x, big.y, 0.31), with: ink, lineWidth: 0.11 * r)
            ctx.fill(disc(big.x, big.y, 0.17), with: ink)
            let dx = small.x - big.x, dy = small.y - big.y
            let len = (dx * dx + dy * dy).squareRoot()
            let rodStart = p(big.x + dx / len * 0.31, big.y + dy / len * 0.31)   // from the ring's edge
            ctx.stroke(line(rodStart, p(small.x, small.y)), with: ink,
                       style: StrokeStyle(lineWidth: 0.13 * r, lineCap: .round))
            ctx.fill(disc(small.x, small.y, 0.17), with: ink)
        }
        .accessibilityHidden(true)
    }
}
