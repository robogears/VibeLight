import SwiftUI

/// Hand-designed tiles for utility apps (Desktop, Steam, Playnite…) where
/// host box art is either the lying 130×180 placeholder or meaningless.
/// These should look BETTER than generic box art, not like fallbacks. Each
/// theme draws its own: Night Edition's section card, Grid 72's flat plate,
/// Kabuki Cut's black card under a white wedge. They are drawn on the 210 pt
/// shelf tile and scale with it (the starting card's poster is bigger).
struct BespokeTileView: View {
    let kind: TileArtwork.BespokeTile
    let title: String

    var body: some View {
        switch Theme.current {
        case .default:             defaultTile
        case .nightEdition:        nightCard
        case .grid72, .grid72Dark: gridPlate
        case .kabukiCut:           kabukiCard
        }
    }

    private var defaultTile: some View {
        ZStack {
            LinearGradient(
                colors: palette,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if kind == .steam {
                steamBackdrop
            } else {
                // Subtle large glyph anchored off-corner for depth.
                mark(size: 96)
                    .foregroundStyle(.white.opacity(0.14))
                    .offset(x: 34, y: -30)
                    .rotationEffect(.degrees(-8))
            }

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

    /// Night Edition: a section card — the theme's surface under a vermilion
    /// top rule, a huge faint italic initial, then the icon and an uppercase
    /// title.
    private var nightCard: some View {
        GeometryReader { geo in
            let k = geo.size.width / 210
            ZStack(alignment: .topLeading) {
                Theme.surface
                Text(initial)
                    .font(ThemeFace.frauncesBlackItalic.font(170 * k))
                    .foregroundStyle(Theme.ink.opacity(0.1))
                    .fixedSize()
                    .offset(x: 10 * k, y: -10 * k)
                Rectangle()
                    .fill(Theme.accent)
                    .frame(height: 4 * k)
                VStack(alignment: .leading, spacing: 8 * k) {
                    mark(size: 28 * k)
                        .foregroundStyle(Theme.textPrimary)
                    Text(title)
                        .font(ThemeFace.plexBold.font(17 * k))
                        .tracking(0.34 * k)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(16 * k)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    /// Grid 72: a flat solid plate, its glyph in white at 30 %, an uppercase
    /// title. No gradient, no icon.
    private var gridPlate: some View {
        GeometryReader { geo in
            let k = geo.size.width / 210
            ZStack {
                plate
                mark(size: 92 * k)
                    .foregroundStyle(.white.opacity(0.3))
                    .offset(y: -20 * k)
                Text(title)
                    .font(ThemeFace.archivoExtraBold.font(15 * k))
                    .tracking(1.5 * k)
                    .textCase(.uppercase)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(14 * k)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    /// Kabuki Cut: black, a white diagonal wedge across the top carrying the
    /// glyph (and a halftone fading in toward its edge), the title on a
    /// slanted red slab.
    private var kabukiCard: some View {
        GeometryReader { geo in
            let k = geo.size.width / 210
            ZStack(alignment: .topLeading) {
                Color.black
                UnitPolygon.bespokeWedge.fill(Color.white)
                BespokeHalftone(scale: k)
                mark(size: 84 * k)
                    .foregroundStyle(Color.black)
                    .frame(width: 110 * k, height: 110 * k)
                    .rotationEffect(.degrees(-6))
                    .offset(x: 18 * k, y: 18 * k)
                Text(title)
                    .font(ThemeFace.delaGothic.font(17 * k))
                    .textCase(.uppercase)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 6 * k)
                    .padding(.horizontal, 10 * k)
                    .padding(.bottom, 3 * k)
                    .background(Theme.accent)
                    .slanted(-8, pivot: 14 * k)
                    .padding(14 * k)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    /// Night Edition's big initial: the title's first letter.
    private var initial: String { title.first.map { String($0).uppercased() } ?? "" }

    /// Grid 72's plates: each app's colour, flat.
    private var plate: Color {
        switch kind {
        case .desktop: Color(hex: 0x111111)
        case .steam: Color(hex: 0x1B2838)
        case .playnite: Color(hex: 0x4B2A80)
        case .moonDeck: Color(hex: 0x22265A)
        case .virtualDisplay: Color(hex: 0x0D4D4D)
        case .generic: Color(hex: 0x3A3D45)
        }
    }

    /// Steam's watermark: the real mark, big and upright, bleeding off the
    /// top-right corner over a soft Steam-blue (#66C0F4) glow. Sized from the
    /// tile, so the shelf tile and the larger starting-card poster match.
    private var steamBackdrop: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let centre = UnitPoint(x: 0.714, y: 0.279)
            ZStack {
                RadialGradient(colors: [Color(red: 0.40, green: 0.75, blue: 0.96).opacity(0.28), .clear],
                               center: centre, startRadius: 0.05 * w, endRadius: 0.72 * w)
                SteamMark()
                    .foregroundStyle(.white.opacity(0.11))
                    .frame(width: 0.95 * w, height: 0.95 * w)
                    .position(x: centre.x * w, y: centre.y * h)
            }
        }
        .clipped()
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
        // Steam's own client colours: #171A21 → #1B2838 → #2A475E.
        case .steam: [Color(red: 0.090, green: 0.102, blue: 0.129), Color(red: 0.106, green: 0.157, blue: 0.220),
                      Color(red: 0.165, green: 0.278, blue: 0.369)]
        case .playnite: [Color(red: 0.35, green: 0.18, blue: 0.55), Color(red: 0.14, green: 0.07, blue: 0.28)]
        case .moonDeck: [Color(red: 0.16, green: 0.14, blue: 0.40), Color(red: 0.05, green: 0.04, blue: 0.15)]
        case .virtualDisplay: [Color(red: 0.05, green: 0.35, blue: 0.35), Color(red: 0.02, green: 0.13, blue: 0.16)]
        case .generic: [Color(red: 0.22, green: 0.24, blue: 0.30), Color(red: 0.09, green: 0.10, blue: 0.14)]
        }
    }
}

/// The halftone on a Kabuki bespoke tile's white wedge: black dots on a 7 pt
/// grid, fading in toward the wedge's lower edge (the spec's 160° mask).
private struct BespokeHalftone: View {
    let scale: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let step = 7 * scale, r = 1.4 * scale
            guard w > 0, h > 0, step > 1 else { return }
            let length = w * 0.342 + h * 0.94
            // Ten strengths, one path each, instead of a fill per dot.
            var levels = [Path](repeating: Path(), count: 10)
            var y = step / 2
            while y < h * 0.7 {
                var x = step / 2
                while x < w {
                    if y < h * (0.7 - 0.3 * x / w) {   // inside the wedge
                        let t = (x * 0.342 + y * 0.94) / length
                        let level = Int((min(max((t - 0.4) / 0.6, 0), 1) * 10).rounded())
                        if level > 0 {
                            levels[level - 1].addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                        }
                    }
                    x += step
                }
                y += step
            }
            for (i, dots) in levels.enumerated() where !dots.isEmpty {
                ctx.fill(dots, with: .color(.black.opacity(0.5 * Double(i + 1) / 10)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The Steam mark — Valve's logo as Simple Icons publishes it (CC0 path data,
/// sourced from Steam's branding page), on a 24 × 24 grid: a disc with the
/// piston cut out of it. Filled with the foreground style like an SF Symbol,
/// so the tile tints it: faint as the watermark, solid white as the icon.
/// Non-zero winding, as in the SVG — that is what leaves the rings hollow.
struct SteamMark: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * unit, y: rect.midY - 12 * unit)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * unit, y: origin.y + y * unit)
        }
        var path = Path()
        path.move(to: p(11.979, 0))
        path.addCurve(to: p(0.022, 11.037), control1: p(5.678, 0), control2: p(0.511, 4.86))
        path.addLine(to: p(6.454, 13.695))
        path.addCurve(to: p(8.366, 13.105), control1: p(6.999, 13.324), control2: p(7.657, 13.105))
        path.addCurve(to: p(8.554, 13.111), control1: p(8.429, 13.105), control2: p(8.491, 13.109))
        path.addLine(to: p(11.415, 8.969))
        path.addLine(to: p(11.415, 8.91))
        path.addCurve(to: p(15.939, 4.386), control1: p(11.415, 6.415), control2: p(13.443, 4.386))
        path.addCurve(to: p(20.463, 8.913), control1: p(18.433, 4.386), control2: p(20.463, 6.417))
        path.addCurve(to: p(15.939, 13.438), control1: p(20.463, 11.409), control2: p(18.433, 13.438))
        path.addLine(to: p(15.834, 13.438))
        path.addLine(to: p(11.758, 16.349))
        path.addCurve(to: p(11.762, 16.508), control1: p(11.758, 16.401), control2: p(11.762, 16.454))
        path.addCurve(to: p(8.372, 19.904), control1: p(11.762, 18.383), control2: p(10.247, 19.904))
        path.addCurve(to: p(5.041, 17.177), control1: p(6.737, 19.904), control2: p(5.356, 18.731))
        path.addLine(to: p(0.436, 15.27))
        path.addCurve(to: p(11.979, 24), control1: p(1.862, 20.307), control2: p(6.486, 24))
        path.addCurve(to: p(23.978, 12), control1: p(18.606, 24), control2: p(23.978, 18.627))
        path.addCurve(to: p(11.979, 0), control1: p(23.978, 5.373), control2: p(18.605, 0))
        path.closeSubpath()
        path.move(to: p(7.54, 18.21))
        path.addLine(to: p(6.067, 17.6))
        path.addCurve(to: p(7.381, 18.85), control1: p(6.329, 18.143), control2: p(6.781, 18.599))
        path.addCurve(to: p(10.713, 17.475), control1: p(8.678, 19.389), control2: p(10.174, 18.774))
        path.addCurve(to: p(10.718, 15.526), control1: p(10.976, 16.845), control2: p(10.977, 16.156))
        path.addCurve(to: p(9.341, 14.143), control1: p(10.459, 14.896), control2: p(9.968, 14.405))
        path.addCurve(to: p(7.463, 14.113), control1: p(8.717, 13.883), control2: p(8.051, 13.894))
        path.addLine(to: p(8.986, 14.743))
        path.addCurve(to: p(9.995, 17.198), control1: p(9.942, 15.143), control2: p(10.395, 16.243))
        path.addCurve(to: p(7.541, 18.21), control1: p(9.598, 18.155), control2: p(8.498, 18.608))
        path.addLine(to: p(7.54, 18.21))
        path.closeSubpath()
        path.move(to: p(18.955, 8.907))
        path.addCurve(to: p(15.94, 5.892), control1: p(18.955, 7.245), control2: p(17.602, 5.892))
        path.addCurve(to: p(12.925, 8.907), control1: p(14.275, 5.892), control2: p(12.925, 7.245))
        path.addCurve(to: p(15.94, 11.922), control1: p(12.925, 10.572), control2: p(14.275, 11.922))
        path.addCurve(to: p(18.955, 8.907), control1: p(17.603, 11.922), control2: p(18.955, 10.572))
        path.closeSubpath()
        path.move(to: p(13.682, 8.902))
        path.addCurve(to: p(15.947, 6.636), control1: p(13.682, 7.65), control2: p(14.695, 6.636))
        path.addCurve(to: p(18.213, 8.902), control1: p(17.196, 6.636), control2: p(18.213, 7.65))
        path.addCurve(to: p(15.947, 11.167), control1: p(18.213, 10.153), control2: p(17.196, 11.167))
        path.addCurve(to: p(13.682, 8.902), control1: p(14.694, 11.167), control2: p(13.682, 10.153))
        path.closeSubpath()
        return path
    }
}
