import SwiftUI

/// The launcher background, selectable in Settings ▸ Themes. Rendered behind the
/// whole launcher by `LauncherContent`, so the choice applies everywhere the UI
/// shows (iPad, Mac, and the TV mirror).
struct AppBackground: View {
    let theme: BackgroundTheme

    var body: some View {
        switch theme {
        case .ambient:        AmbientBackground()
        case .livingGlass:    LivingGlassBackground()
        case .inkPool:        InkPoolBackground()
        case .nightfallSheen: NightfallSheenBackground()
        case .parallaxDeep:   ParallaxDeepBackground()
        case .constellation:  ConstellationBackground()
        case .diagonal:       DiagonalStripesBackground()
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
        .ignoresSafeArea()
    }
}

/// "Living Glass" — the flagship animated theme: dark navy with two dim blooms of
/// blue and violet drifting on slow, coprime sine orbits, like light migrating
/// through frosted glass. Corners stay pinned near-black so the frame never
/// brightens. Pure gradients (no per-frame blur) — the soft radial falloff IS the
/// bloom, so it stays cheap even at native iPad resolution.
struct LivingGlassBackground: View {
    private let base   = Color(red: 0.043, green: 0.051, blue: 0.078)  // #0b0d14
    private let blue   = Color(red: 0.110, green: 0.227, blue: 0.400)  // #1c3a66
    private let violet = Color(red: 0.141, green: 0.102, blue: 0.227)  // #241a3a

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let d = max(geo.size.width, geo.size.height)
                // Coprime periods (20/27/24/19 s) so the two blooms never sync.
                let bx = CGFloat(0.32 + 0.11 * sin(t * .pi * 2 / 20))
                let by = CGFloat(0.30 + 0.09 * cos(t * .pi * 2 / 27))
                let vx = CGFloat(0.70 + 0.10 * sin(t * .pi * 2 / 24 + 1.3))
                let vy = CGFloat(0.72 + 0.08 * cos(t * .pi * 2 / 19 + 0.6))
                ZStack {
                    base
                    RadialGradient(colors: [blue.opacity(0.60), .clear],
                                   center: UnitPoint(x: bx, y: by),
                                   startRadius: 0, endRadius: d * 0.72)
                        .blendMode(.plusLighter)
                    RadialGradient(colors: [violet.opacity(0.55), .clear],
                                   center: UnitPoint(x: vx, y: vy),
                                   startRadius: 0, endRadius: d * 0.78)
                        .blendMode(.plusLighter)
                    // Pin the corners near-black so the frame never brightens.
                    RadialGradient(colors: [.clear, base.opacity(0.92)],
                                   center: .center, startRadius: d * 0.32, endRadius: d * 0.90)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// "Ink Pool" — the calmest static theme: near-black charcoal lit by a single cool
/// light pooling off the top-left edge, heavy shadow everywhere else. No motion,
/// so it's genuinely zero-cost — the quiet backdrop behind a busy shelf.
struct InkPoolBackground: View {
    private let base   = Color(red: 0.039, green: 0.043, blue: 0.055)  // #0a0b0e
    private let shadow = Color(red: 0.024, green: 0.027, blue: 0.031)  // #060708
    private let pool   = Color(red: 0.102, green: 0.129, blue: 0.188)  // #1a2130

    var body: some View {
        GeometryReader { geo in
            let d = max(geo.size.width, geo.size.height)
            ZStack {
                base
                // Deepen the far edges first…
                RadialGradient(colors: [.clear, shadow.opacity(0.9)],
                               center: .center, startRadius: d * 0.2, endRadius: d * 0.95)
                // …then lay the cool light pool off the top-left corner on top.
                RadialGradient(colors: [pool, .clear],
                               center: UnitPoint(x: -0.05, y: -0.05),
                               startRadius: 0, endRadius: d * 1.05)
            }
        }
        .ignoresSafeArea()
    }
}

/// "Nightfall Sheen" — a single sheet of dusk: cool navy in the top-left bleeding
/// to a warm plum corner, like light leaving a room. Static; one linear wash, a
/// faint ember bleed in the far corner, and a soft vignette.
struct NightfallSheenBackground: View {
    private let top   = Color(red: 0.039, green: 0.051, blue: 0.090)  // #0a0d17
    private let mid   = Color(red: 0.067, green: 0.063, blue: 0.125)  // #111020
    private let warm  = Color(red: 0.102, green: 0.071, blue: 0.125)  // #1a1220
    private let ember = Color(red: 0.173, green: 0.110, blue: 0.180)  // #2c1c2e

    var body: some View {
        GeometryReader { geo in
            let d = max(geo.size.width, geo.size.height)
            ZStack {
                LinearGradient(colors: [top, mid, warm],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [ember.opacity(0.55), .clear],
                               center: UnitPoint(x: 1.0, y: 1.0),
                               startRadius: 0, endRadius: d * 0.62)
                    .blendMode(.plusLighter)
                RadialGradient(colors: [.clear, Color.black.opacity(0.32)],
                               center: UnitPoint(x: 0.5, y: 0.42),
                               startRadius: d * 0.3, endRadius: d * 0.88)
            }
        }
        .ignoresSafeArea()
    }
}

/// "Parallax Deep" — drifting through quiet space: a fixed star field on two
/// depth layers scrolling at different slow speeds (each star gently twinkling),
/// with a diffuse nebula glowing off one corner and breathing. The star array is
/// built ONCE (deterministically) and only its positions/alpha animate — cheap.
struct ParallaxDeepBackground: View {
    private let base      = Color(red: 0.027, green: 0.035, blue: 0.067)  // #070911
    private let voidCol   = Color(red: 0.016, green: 0.020, blue: 0.039)  // #04050a
    private let starCol   = Color(red: 0.804, green: 0.847, blue: 0.941)  // #cdd8f0
    private let nebNavy   = Color(red: 0.173, green: 0.227, blue: 0.420)  // #2c3a6b
    private let nebViolet = Color(red: 0.227, green: 0.173, blue: 0.357)  // #3a2c5b

    private struct Star { let x: CGFloat; let y: CGFloat; let r: CGFloat; let phase: Double; let fast: Bool }
    private let stars: [Star]

    init() {
        var made: [Star] = []
        for i in 0..<110 {
            let x     = CGFloat(Self.frac(Double(i) * 0.61803398875 + 0.13))
            let y     = CGFloat(Self.frac(Double(i) * 0.41421356237 + 0.29))
            let r     = CGFloat(0.6 + Self.frac(Double(i) * 0.75487766624 + 0.5) * 1.3)
            let phase = Self.frac(Double(i) * 0.31830988618) * 2 * .pi
            let fast  = Self.frac(Double(i) * 0.9) > 0.55
            made.append(Star(x: x, y: y, r: r, phase: phase, fast: fast))
        }
        stars = made
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let d = max(geo.size.width, geo.size.height)
                let breathe = 0.55 + 0.45 * (0.5 + 0.5 * sin(t * .pi * 2 / 18))
                ZStack {
                    base
                    RadialGradient(colors: [nebNavy.opacity(0.16 * breathe),
                                            nebViolet.opacity(0.07 * breathe), .clear],
                                   center: UnitPoint(x: 0.8, y: 0.18),
                                   startRadius: 0, endRadius: d * 0.85)
                        .blendMode(.plusLighter)
                    Canvas { ctx, size in
                        let w = size.width, h = size.height
                        guard w > 0, h > 0 else { return }
                        for star in stars {
                            let speed: CGFloat = star.fast ? 7 : 2.6
                            // Wrap the drift at the view width so it stays continuous
                            // (no periodic pop) — px is taken mod w anyway.
                            let drift = CGFloat((t * Double(speed)).truncatingRemainder(dividingBy: Double(w)))
                            var px = (star.x * w + drift).truncatingRemainder(dividingBy: w)
                            if px < 0 { px += w }
                            let py = star.y * h
                            let tw = 0.5 + 0.5 * sin(t * 1.1 + star.phase)
                            let alpha = 0.05 + 0.12 * tw
                            let rect = CGRect(x: px - star.r / 2, y: py - star.r / 2,
                                              width: star.r, height: star.r)
                            ctx.fill(Path(ellipseIn: rect), with: .color(starCol.opacity(alpha)))
                        }
                    }
                    // Deep, dark corners so the frame never lifts.
                    RadialGradient(colors: [.clear, voidCol.opacity(0.9)],
                                   center: .center, startRadius: d * 0.32, endRadius: d * 0.98)
                }
            }
        }
        .ignoresSafeArea()
    }

    private static func frac(_ v: Double) -> Double { v - v.rounded(.down) }
}

/// "Constellation" — a gentle web of light: ~40 fixed nodes drifting a few points
/// on slow sine orbits, hairline links fading in as nearby pairs cross a distance
/// threshold. Everything dims toward the edges (center falloff) so the frame stays
/// dark. One Canvas pass.
struct ConstellationBackground: View {
    private let base = Color(red: 0.031, green: 0.043, blue: 0.075)  // #080b13
    private let node = Color(red: 0.357, green: 0.616, blue: 1.0)    // #5b9dff

    private struct Node { let x: CGFloat; let y: CGFloat; let phase: Double; let freq: Double }
    private let nodes: [Node]

    init() {
        var made: [Node] = []
        for i in 0..<42 {
            let x     = CGFloat(Self.frac(Double(i) * 0.61803398875 + 0.11))
            let y     = CGFloat(Self.frac(Double(i) * 0.41421356237 + 0.67))
            let phase = Self.frac(Double(i) * 0.31830988618) * 2 * .pi
            let freq  = 2 * .pi / (22 + Self.frac(Double(i) * 0.27) * 9)  // 22–31 s periods
            made.append(Node(x: x, y: y, phase: phase, freq: freq))
        }
        nodes = made
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                base
                Canvas { ctx, size in
                    let w = size.width, h = size.height
                    guard w > 0, h > 0 else { return }
                    let cx = w / 2, cy = h / 2
                    let maxD = max(hypot(w, h) / 2, 1)
                    let amp = min(w, h) * 0.022   // scale node drift to the view so links actually cross
                    var pts: [(x: CGFloat, y: CGFloat, fall: CGFloat)] = []
                    pts.reserveCapacity(nodes.count)
                    for n in nodes {
                        let nx = n.x * w + CGFloat(sin(t * n.freq + n.phase)) * amp
                        let ny = n.y * h + CGFloat(cos(t * n.freq * 0.9 + n.phase)) * amp
                        let fall = max(0, 1 - hypot(nx - cx, ny - cy) / maxD)
                        pts.append((nx, ny, fall))
                    }
                    let thresh = min(w, h) * 0.24
                    for i in 0..<pts.count {
                        for j in (i + 1)..<pts.count {
                            let dist = hypot(pts[i].x - pts[j].x, pts[i].y - pts[j].y)
                            if dist < thresh {
                                let strength = Double((1 - dist / thresh) * min(pts[i].fall, pts[j].fall))
                                let alpha = strength * 0.11
                                if alpha > 0.004 {
                                    var path = Path()
                                    path.move(to: CGPoint(x: pts[i].x, y: pts[i].y))
                                    path.addLine(to: CGPoint(x: pts[j].x, y: pts[j].y))
                                    ctx.stroke(path, with: .color(node.opacity(alpha)), lineWidth: 0.6)
                                }
                            }
                        }
                    }
                    for p in pts {
                        let alpha = 0.03 + 0.12 * Double(p.fall)
                        let r: CGFloat = 1.7
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                                 with: .color(node.opacity(alpha)))
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    private static func frac(_ v: Double) -> Double { v - v.rounded(.down) }
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
                // A small tag so the static/animated split is legible at a glance.
                .overlay(alignment: .topTrailing) {
                    Text(theme.isAnimated ? "Animated" : "Static")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.4), in: Capsule())
                        .padding(8)
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
