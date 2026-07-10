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
        case .gaslight:        GaslightBackground()
        case .searchlightCity: SearchlightCityBackground()
        case .swingingBulb:    SwingingBulbBackground()
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
    private let base      = Color.black                                   // pitch black
    private let voidCol   = Color.black
    private let starCol   = Color(red: 0.804, green: 0.847, blue: 0.941)  // #cdd8f0
    private let nebNavy   = Color(red: 0.173, green: 0.227, blue: 0.420)  // #2c3a6b
    private let nebViolet = Color(red: 0.227, green: 0.173, blue: 0.357)  // #3a2c5b

    private struct Star { let x: CGFloat; let y: CGFloat; let r: CGFloat; let phase: Double; let fast: Bool }
    private let stars: [Star]

    init() {
        var made: [Star] = []
        for i in 0..<340 {
            let x     = CGFloat(Self.frac(Double(i) * 0.61803398875 + 0.13))
            let y     = CGFloat(Self.frac(Double(i) * 0.41421356237 + 0.29))
            let r     = CGFloat(0.5 + Self.frac(Double(i) * 0.75487766624 + 0.5) * 1.6)
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
                    RadialGradient(colors: [nebNavy.opacity(0.08 * breathe),
                                            nebViolet.opacity(0.035 * breathe), .clear],
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
                            let alpha = 0.10 + 0.42 * tw   // brighter — stars pop on pitch black
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

// MARK: - The noir set

/// "Gaslight" — film-noir street corner: a lone streetlamp flickering warm
/// light over drizzle, a blocky skyline silhouette, a wet-street sheen. The
/// only motion is the gaslight's breathing flicker and the rain inside the
/// cone — monochrome silver-on-black with the bulb as the single warm hue.
struct GaslightBackground: View {
    private let skyTop    = Color(red: 0.020, green: 0.024, blue: 0.043)  // #05060b
    private let skyBottom = Color(red: 0.035, green: 0.043, blue: 0.071)  // #090b12
    private let building  = Color(red: 0.024, green: 0.031, blue: 0.063)  // #060810
    private let warm      = Color(red: 0.839, green: 0.808, blue: 0.698)  // #d6ceb2
    private let rainCol   = Color(red: 0.667, green: 0.714, blue: 0.816)  // #aab6d0

    private struct Drop { let x: CGFloat; let z: CGFloat; let phase: CGFloat }
    private let drops: [Drop]

    init() {
        var made: [Drop] = []
        for i in 0..<70 {
            // Cluster most drops around the lamp cone (x ≈ 0.28) — rain reads
            // where the light is; a few strays elsewhere keep it honest.
            let spread = Self.frac(Double(i) * 0.61803398875)
            let nearLamp = i % 4 != 0
            let x = nearLamp ? 0.28 + CGFloat(spread - 0.5) * 0.30
                             : CGFloat(spread)
            made.append(Drop(x: min(max(x, 0.02), 0.98),
                             z: CGFloat(0.5 + Self.frac(Double(i) * 0.41421356237) * 0.5),
                             phase: CGFloat(Self.frac(Double(i) * 0.75487766624))))
        }
        drops = made
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // Gaslight breathing: layered incommensurate sines, occasionally
            // dipping — never strobing (WCAG: stay far under 3 flashes/sec).
            let flicker = 0.86 + 0.09 * sin(t * 0.9) + 0.05 * sin(t * 2.3 + 1.7)
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let lampX = w * 0.28
                ZStack {
                    LinearGradient(colors: [skyTop, skyBottom], startPoint: .top, endPoint: .bottom)

                    // Skyline silhouette, right half.
                    SkylinePath(bases: [0.55, 0.30, 0.72, 0.18, 0.48, 0.62, 0.26, 0.52])
                        .fill(building)
                        .frame(width: w * 0.52, height: h * 0.36)
                        .position(x: w * 0.74, y: h * 0.70)

                    // Light cone (trapezoid) + post + bulb.
                    ConeShape()
                        .fill(LinearGradient(colors: [warm.opacity(0.16 * flicker),
                                                      warm.opacity(0.02), .clear],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: w * 0.30, height: h * 0.72)
                        .position(x: lampX, y: h * 0.52)
                    Rectangle().fill(Color(red: 0.05, green: 0.06, blue: 0.09))
                        .frame(width: 3, height: h * 0.76)
                        .position(x: lampX, y: h * 0.54)
                    Circle().fill(warm)
                        .frame(width: 7, height: 7)
                        .position(x: lampX, y: h * 0.165)
                        .shadow(color: warm.opacity(0.55 * flicker), radius: 12)

                    // Drizzle — heavier and brighter inside the cone.
                    Canvas { ctx, size in
                        guard size.width > 0, size.height > 0 else { return }
                        let fall = size.height * 0.55
                        var path = Path()
                        var conePath = Path()
                        for drop in drops {
                            let speed = 0.9 + Double(drop.z) * 0.9      // screens/sec-ish
                            let prog = CGFloat((t * speed + Double(drop.phase))
                                .truncatingRemainder(dividingBy: 1))
                            let x = drop.x * size.width + prog * 8
                            let y = size.height * 0.12 + prog * fall
                            let len = 8 + drop.z * 10
                            let inCone = abs(x - size.width * 0.28) < size.width * 0.11
                            var seg = Path()
                            seg.move(to: CGPoint(x: x, y: y))
                            seg.addLine(to: CGPoint(x: x - 1.5, y: y - len))
                            if inCone { conePath.addPath(seg) } else { path.addPath(seg) }
                        }
                        ctx.stroke(path, with: .color(rainCol.opacity(0.10)), lineWidth: 1)
                        ctx.stroke(conePath, with: .color(rainCol.opacity(0.26 * flicker)), lineWidth: 1)
                    }

                    // Wet-street sheen + vignette.
                    LinearGradient(colors: [rainCol.opacity(0.05), .clear],
                                   startPoint: .bottom, endPoint: .top)
                        .frame(height: h * 0.18)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    RadialGradient(colors: [.clear, Color.black.opacity(0.6)],
                                   center: .center,
                                   startRadius: min(w, h) * 0.3, endRadius: max(w, h) * 0.75)
                }
            }
        }
        .ignoresSafeArea()
    }

    private static func frac(_ v: Double) -> Double { v - v.rounded(.down) }
}

/// "Searchlight City" — two slow searchlight beams crossing over a blacked-out
/// skyline, a few window lights barely holding on. Beams rotate ±8–9° on long
/// incommensurate periods; everything else is static geometry.
struct SearchlightCityBackground: View {
    private let skyTop   = Color(red: 0.016, green: 0.020, blue: 0.039)  // #04050a
    private let skyLow   = Color(red: 0.031, green: 0.039, blue: 0.067)  // #080a11
    private let building = Color(red: 0.016, green: 0.024, blue: 0.047)  // #04060c
    private let beamCol  = Color(red: 0.769, green: 0.816, blue: 0.910)  // #c4d0e8
    private let warm     = Color(red: 0.839, green: 0.808, blue: 0.698)  // #d6ceb2

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let a1 = -21.5 + 8.5 * sin(t * 2 * .pi / 36)    // −30°…−13°
            let a2 = -158  - 8.0 * sin(t * 2 * .pi / 47)    // −150°…−166°
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    LinearGradient(colors: [skyTop, skyLow], startPoint: .top, endPoint: .bottom)

                    beam(width: w, angle: a1, phase: t)
                        .position(x: w * 0.30, y: h * 0.84)
                    beam(width: w, angle: a2, phase: t + 11)
                        .position(x: w * 0.68, y: h * 0.84)

                    SkylinePath(bases: [0.50, 0.20, 0.65, 0.10, 0.55, 0.32, 0.70, 0.16,
                                        0.44, 0.60, 0.24, 0.52])
                        .fill(building)
                        .frame(width: w, height: h * 0.22)
                        .position(x: w / 2, y: h * 0.89)

                    // Three window lights breathing on slow, offset periods.
                    ForEach(0..<3, id: \.self) { i in
                        windowLight(index: i, t: t, w: w, h: h)
                    }

                    RadialGradient(colors: [.clear, Color.black.opacity(0.55)],
                                   center: .center,
                                   startRadius: min(w, h) * 0.32, endRadius: max(w, h) * 0.72)
                }
            }
        }
        .ignoresSafeArea()
    }

    /// One breathing window light. Split out (with explicit types) — inlining
    /// this arithmetic in the ForEach blows the iOS type-checker's budget.
    private func windowLight(index: Int, t: Double, w: CGFloat, h: CGFloat) -> some View {
        let xs: [CGFloat] = [0.20, 0.52, 0.81]
        let periods: [Double] = [9.0, 13.0, 11.0]
        let phase: Double = t * 2 * .pi / periods[index] + Double(index) * 2.1
        let alpha: Double = 0.25 + 0.28 * (0.5 + 0.5 * sin(phase))
        return Circle().fill(warm)
            .frame(width: 3, height: 3)
            .position(x: w * xs[index], y: h * 0.90)
            .opacity(alpha)
    }

    /// One beam: a long gradient bar rotated around its base end.
    private func beam(width: CGFloat, angle: Double, phase: Double) -> some View {
        LinearGradient(colors: [beamCol.opacity(0.14), beamCol.opacity(0.04), .clear],
                       startPoint: .leading, endPoint: .trailing)
            .frame(width: width * 1.8, height: 26)
            .offset(x: width * 0.9)   // rotate around the LEFT end (the searchlight)
            .rotationEffect(.degrees(angle))
            .blendMode(.plusLighter)
    }
}

/// "Swinging Bulb" — the interrogation-room icon: a bare bulb on a cord swaying
/// gently, its light pool shifting in counter-phase across the dark, one moth
/// circling. The pendulum is a single sine; everything scales with it.
struct SwingingBulbBackground: View {
    private let base = Color(red: 0.016, green: 0.020, blue: 0.035)      // #040509
    private let warm = Color(red: 0.910, green: 0.863, blue: 0.722)      // #e8dcb8

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let swing = sin(t * 2 * .pi / 5.6)               // −1…1, 5.6 s period
            let angle = swing * 8.5                          // degrees
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let cordLen = h * 0.30
                let rad = angle * .pi / 180
                let bulbX = w / 2 + CGFloat(sin(rad)) * cordLen
                let bulbY = h * -0.02 + CGFloat(cos(rad)) * cordLen
                ZStack {
                    base

                    // Light pool sweeps opposite the bulb, slightly delayed feel.
                    RadialGradient(colors: [warm.opacity(0.12), warm.opacity(0.035), .clear],
                                   center: .center,
                                   startRadius: 0, endRadius: min(w, h) * 0.75)
                        .frame(width: w * 1.6, height: h * 1.6)
                        .position(x: w / 2 - CGFloat(swing) * w * 0.06, y: h * 0.62)

                    // Cord + bulb.
                    Path { p in
                        p.move(to: CGPoint(x: w / 2, y: h * -0.02))
                        p.addLine(to: CGPoint(x: bulbX, y: bulbY))
                    }
                    .stroke(Color(red: 0.10, green: 0.11, blue: 0.15), lineWidth: 2)
                    Circle()
                        .fill(RadialGradient(colors: [warm, warm.opacity(0.55),
                                                      Color(red: 0.23, green: 0.22, blue: 0.19)],
                                             center: UnitPoint(x: 0.5, y: 0.38),
                                             startRadius: 0, endRadius: 9))
                        .frame(width: 15, height: 15)
                        .position(x: bulbX, y: bulbY)
                        .shadow(color: warm.opacity(0.4), radius: 16)

                    // One moth: a slow orbit around the bulb + a faster bob.
                    let mothA = t * 2 * .pi / 7
                    let mothR = min(w, h) * 0.055
                    Circle().fill(warm.opacity(0.55))
                        .frame(width: 3.5, height: 3.5)
                        .position(x: bulbX + CGFloat(cos(mothA)) * mothR,
                                  y: bulbY + 14 + CGFloat(sin(mothA)) * mothR * 0.6
                                     + CGFloat(sin(t * 2 * .pi / 1.9)) * 7)

                    RadialGradient(colors: [.clear, Color.black.opacity(0.65)],
                                   center: UnitPoint(x: 0.5, y: 0.4),
                                   startRadius: min(w, h) * 0.3, endRadius: max(w, h) * 0.8)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Blocky noir skyline: rectangles of varying height from a normalized base
/// list. Deterministic; built once per body evaluation (cheap — a dozen rects).
private struct SkylinePath: Shape {
    let bases: [CGFloat]   // 0…1 heights, one per building

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard !bases.isEmpty else { return p }
        let bw = rect.width / CGFloat(bases.count)
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for (i, b) in bases.enumerated() {
            let x = rect.minX + CGFloat(i) * bw
            let top = rect.maxY - rect.height * b
            p.addLine(to: CGPoint(x: x, y: top))
            p.addLine(to: CGPoint(x: x + bw, y: top))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Streetlamp light cone: a narrow-topped trapezoid.
private struct ConeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX - rect.width * 0.05, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX + rect.width * 0.05, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
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
                // A little red "my favourite" flag on Parallax Deep — same chip style.
                .overlay(alignment: .bottomLeading) {
                    if theme == .parallaxDeep {
                        Text("my favourite")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.4), in: Capsule())
                            .padding(8)
                    }
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
