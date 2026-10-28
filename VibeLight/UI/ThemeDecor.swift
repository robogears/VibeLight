import SwiftUI

// Shapes and small pieces the themes share (Night Edition, Grid 72, Kabuki
// Cut). Default draws none of them.

/// A rectangle slanted like CSS `skewX(degrees)` about its centre — Kabuki
/// Cut's slab. Only the shape leans, so text set on it stays upright and the
/// hit area stays the upright frame.
struct SlantedRect: InsettableShape {
    var degrees: Double
    private var inset: CGFloat = 0

    init(_ degrees: Double) { self.degrees = degrees }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        // Negative degrees lean right: the top edge moves right, the bottom left.
        let dx = CGFloat(tan(degrees * .pi / 180)) * r.height / 2
        var p = Path()
        p.move(to: CGPoint(x: r.minX - dx, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - dx, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX + dx, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + dx, y: r.maxY))
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> SlantedRect {
        var shape = self
        shape.inset += amount
        return shape
    }
}

/// A polygon on unit coordinates (0…1 of the frame) — CSS `clip-path: polygon(…)`.
struct UnitPolygon: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        func at(_ u: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + u.x * rect.width, y: rect.minY + u.y * rect.height)
        }
        p.move(to: at(first))
        for u in points.dropFirst() { p.addLine(to: at(u)) }
        p.closeSubpath()
        return p
    }

    /// Kabuki Cut's torn paper behind a focused tile.
    static let jaggedCut = UnitPolygon(points: [
        CGPoint(x: 0, y: 0.04), CGPoint(x: 0.07, y: 0), CGPoint(x: 0.26, y: 0.03), CGPoint(x: 0.50, y: 0),
        CGPoint(x: 0.71, y: 0.04), CGPoint(x: 0.96, y: 0.01), CGPoint(x: 1, y: 0.22), CGPoint(x: 0.97, y: 0.46),
        CGPoint(x: 1, y: 0.71), CGPoint(x: 0.98, y: 1), CGPoint(x: 0.70, y: 0.97), CGPoint(x: 0.46, y: 1),
        CGPoint(x: 0.21, y: 0.96), CGPoint(x: 0.03, y: 1), CGPoint(x: 0, y: 0.76), CGPoint(x: 0.02, y: 0.50),
    ])
    /// The crimson wedge down the right of the Kabuki background.
    static let kabukiWedge = UnitPolygon(points: [
        CGPoint(x: 0.64, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0.82, y: 1),
    ])
    /// The white shard in the Kabuki background's bottom-left corner.
    static let kabukiShard = UnitPolygon(points: [
        CGPoint(x: 0, y: 0.86), CGPoint(x: 0.22, y: 1), CGPoint(x: 0, y: 1),
    ])
    /// The white wedge across the top of a Kabuki bespoke tile.
    static let bespokeWedge = UnitPolygon(points: [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 0.40), CGPoint(x: 0, y: 0.70),
    ])
    /// A Kabuki LIVE tile's lime corner: the spec's 135° gradient from 72 %,
    /// worked out on the 210 × 280 tile.
    static let liveCorner = UnitPolygon(points: [
        CGPoint(x: 1, y: 0.51), CGPoint(x: 1, y: 1), CGPoint(x: 0.34, y: 1),
    ])
}

/// Kabuki Cut's speed lines: forty thin rays in a ring around the focused
/// tile, turning once every 14 s. Drawn by the tile only when motion is
/// allowed.
struct SpeedLines: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let turn = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 14) / 14 * 2 * .pi
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let reach = hypot(size.width, size.height) / 2
                var rays = Path()
                for i in 0..<40 {
                    let a = Double(i) * 9 * .pi / 180 + turn
                    let b = a + 1.6 * .pi / 180
                    rays.move(to: c)
                    rays.addLine(to: CGPoint(x: c.x + reach * CGFloat(cos(a)), y: c.y + reach * CGFloat(sin(a))))
                    rays.addLine(to: CGPoint(x: c.x + reach * CGFloat(cos(b)), y: c.y + reach * CGFloat(sin(b))))
                    rays.closeSubpath()
                }
                // Lit only in a ring: clear to 42 % of the reach, brightest at 52 %, gone by 74 %.
                let ring = Gradient(stops: [
                    .init(color: .white.opacity(0), location: 0.42),
                    .init(color: .white.opacity(0.22), location: 0.52),
                    .init(color: .white.opacity(0), location: 0.74),
                ])
                ctx.fill(rays, with: .radialGradient(ring, center: c, startRadius: 0, endRadius: reach))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Night Edition's LIVE: a rubber stamp in the printed green — a double ring
/// on its own dark fill, so it holds over any art — tilted −10°. Longer words
/// (CLOSING, CLOSED on the still-running card) get an oblong stamp.
struct NightStamp: View {
    let text: String
    let color: Color

    var body: some View {
        let round = text.count <= 4
        let paper = Color(hex: 0x15130F)
        Text(text)
            .themeText(.liveBadge)
            .foregroundStyle(color)
            .padding(.horizontal, round ? 0 : 12)
            .frame(width: round ? 54 : nil, height: round ? 54 : 34)
            .background(paper.opacity(0.55), in: stampShape(round))
            .overlay { stampShape(round).strokeBorder(color, lineWidth: 2) }
            .overlay { stampShape(round).inset(by: 5).strokeBorder(color, lineWidth: 1) }
            .rotationEffect(.degrees(-10))
    }

    private func stampShape(_ round: Bool) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: round ? 27 : 6)
    }
}
