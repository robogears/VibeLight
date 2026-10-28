import SwiftUI

/// The launcher background: the selected theme's own (Settings ▸ Themes ▸
/// Theme). Default always draws Parallax Deep — the Background picker that
/// once chose among ten is gone. Rendered behind the whole launcher by
/// `LauncherContent`, so it applies everywhere the UI shows (iPad, Mac, and the
/// TV mirror).
struct AppBackground: View {
    let theme: AppTheme
    /// How big the patterns draw: 1 on the launcher's canvas; a theme preview
    /// card passes its width over the canvas width so it reads as a miniature.
    var scale: CGFloat = 1

    /// The backdrops there are.
    enum Backdrop: Equatable {
        case parallaxDeep, nightPaper, gridPaper, gridInk, kabuki
    }

    /// Which backdrop a theme draws — Default's is always Parallax Deep.
    nonisolated static func backdrop(for theme: AppTheme) -> Backdrop {
        switch theme {
        case .default:      .parallaxDeep
        case .nightEdition: .nightPaper
        case .grid72:       .gridPaper
        case .grid72Dark:   .gridInk
        case .kabukiCut:    .kabuki
        }
    }

    var body: some View {
        switch Self.backdrop(for: theme) {
        case .parallaxDeep: ParallaxDeepBackground()
        case .nightPaper:   NightPaperBackground(scale: scale)
        case .gridPaper:    GridPaperBackground(palette: .grid72, lineWidth: 1, scale: scale)
        case .gridInk:      GridPaperBackground(palette: .grid72Dark, lineWidth: 1.5, scale: scale)
        case .kabuki:       KabukiBackground(scale: scale)
        }
    }
}

extension AppTheme {
    /// Whether the theme's background moves — the "Static"/"Animated" tag on
    /// its preview card. Grid 72's only life is the focus index.
    var hasAnimatedBackground: Bool { !isGrid }
}

/// "Parallax Deep" — drifting through quiet space: a fixed star field on two
/// depth layers scrolling at different slow speeds (each star gently twinkling),
/// with a diffuse nebula glowing off one corner and breathing. The star array is
/// built ONCE (deterministically) and only its positions/alpha animate — cheap.
/// The Default theme's background, always.
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

// MARK: - Night Edition

/// Night Edition's page: black paper with a fine warm grain, one band of window
/// light crossing it every 40 s, and a soft vignette. Reduce Motion stops the
/// band where it stands; the grain stays.
struct NightPaperBackground: View {
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let paper = Color(hex: 0x15130F)
    private let light = Color(hex: 0xFFECC8)

    var body: some View {
        ZStack {
            paper
            PaperGrain(scale: scale)
                .opacity(0.16)
                .blendMode(.screen)
            GeometryReader { geo in
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
                    windowLight(Self.bandProgress(at: timeline.date.timeIntervalSinceReferenceDate),
                                in: geo.size)
                }
            }
            EllipticalGradient(stops: [.init(color: .clear, location: 0.5),
                                       .init(color: .black.opacity(0.45), location: 1)],
                               center: UnitPoint(x: 0.5, y: 0.4),
                               startRadiusFraction: 0, endRadiusFraction: 0.75)
        }
        .ignoresSafeArea()
    }

    /// Where the light is, 0 (just off the left edge) … 1 (just off the right):
    /// across the page and back, 40 s each way, eased at both ends.
    nonisolated static func bandProgress(at time: TimeInterval) -> Double {
        let leg = 40.0
        let phase = time.truncatingRemainder(dividingBy: 2 * leg) / leg   // 0..<2
        let x = phase <= 1 ? phase : 2 - phase
        return x * x * (3 - 2 * x)
    }

    /// The band: 0.8 widths of soft light, brightest in the middle, leaning
    /// 10° off vertical like light through a tall window.
    private func windowLight(_ progress: Double, in size: CGSize) -> some View {
        let centre = -0.2 + 1.4 * progress                      // in widths
        let lean = size.height > 0 ? 0.4 * size.width * 0.174 / size.height : 0
        return LinearGradient(stops: [.init(color: light.opacity(0), location: 0),
                                      .init(color: light.opacity(0.07), location: 0.4),
                                      .init(color: light.opacity(0.10), location: 0.5),
                                      .init(color: light.opacity(0.07), location: 0.6),
                                      .init(color: light.opacity(0), location: 1)],
                              startPoint: UnitPoint(x: centre - 0.394, y: 0.5 - lean),
                              endPoint: UnitPoint(x: centre + 0.394, y: 0.5 + lean))
    }
}

/// The paper's grain: a 220 pt tile of warm specks, made once in code (no
/// image asset), repeated across the page.
private struct PaperGrain: View {
    var scale: CGFloat

    var body: some View {
        if let tile = PaperGrainTile.image {
            Image(decorative: tile, scale: 1 / max(scale, 0.05))
                .resizable(resizingMode: .tile)
        }
    }
}

@MainActor
private enum PaperGrainTile {
    static let image: CGImage? = make()

    /// Deterministic noise: mostly faint specks, a few brighter, in Night
    /// Edition's warm white (premultiplied RGBA).
    private static func make() -> CGImage? {
        let side = 220
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt32 = 0x9E37_79B9
        for i in 0..<(side * side) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let n = Double(seed >> 8) / Double(1 << 24)   // 0..<1
            let a = n * n * 0.5
            bytes[i * 4 + 0] = UInt8(255 * a)
            bytes[i * 4 + 1] = UInt8(255 * 0.96 * a)
            bytes[i * 4 + 2] = UInt8(255 * 0.86 * a)
            bytes[i * 4 + 3] = UInt8(255 * a)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: - Grid 72

/// Grid 72's page, and its ink inversion: paper ruled into the app's own 72 pt
/// margin, with crop marks in the corners. Nothing moves — the focus index on
/// Home (and the seconds clock) is the only life, which is the point.
struct GridPaperBackground: View {
    let palette: ThemePalette
    /// 1 pt on paper; 1.5 pt on the dark inversion, where thin light lines shimmer.
    let lineWidth: CGFloat
    var scale: CGFloat = 1

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.background))
            let step = 72 * scale
            let line = lineWidth * max(scale, 0.5)
            guard step > 1 else { return }
            var grid = Path()
            var x: CGFloat = 0
            while x <= size.width {
                grid.addRect(CGRect(x: x, y: 0, width: line, height: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                grid.addRect(CGRect(x: 0, y: y, width: size.width, height: line))
                y += step
            }
            ctx.fill(grid, with: .color(palette.isLight ? Color(hex: 0xCFCEC8).opacity(0.55)
                                                        : palette.ink.opacity(0.07)))
            // Crop marks: an L at each corner, 24 pt in, arms pointing inward.
            let inset = 24 * scale, arm = 24 * scale, mark = max(line, scale)
            var marks = Path()
            for right in [false, true] {
                for bottom in [false, true] {
                    let cx = right ? size.width - inset : inset
                    let cy = bottom ? size.height - inset : inset
                    marks.addRect(CGRect(x: right ? cx - arm : cx, y: bottom ? cy - mark : cy,
                                         width: arm, height: mark))
                    marks.addRect(CGRect(x: right ? cx - mark : cx, y: bottom ? cy - arm : cy,
                                         width: mark, height: arm))
                }
            }
            ctx.fill(marks, with: .color(palette.ink))
        }
        .ignoresSafeArea()
    }
}

// MARK: - Kabuki Cut

/// Kabuki Cut's backdrop: black, a crimson wedge down the right with halftone
/// fading off its inner edge, thin diagonal stripes drifting over everything,
/// and a white shard in the bottom-left corner. Reduce Motion stops the
/// stripes and drops the halftone; the cuts remain.
struct KabukiBackground: View {
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color(hex: 0x0B0B0C)
            UnitPolygon.kabukiWedge.fill(Color(hex: 0xE5102E))
            if !reduceMotion { KabukiHalftone(scale: scale) }
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
                KabukiStripes(scale: scale,
                              drift: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
            }
            UnitPolygon.kabukiShard.fill(Color.white.opacity(0.9))
        }
        .ignoresSafeArea()
    }
}

/// White hairline stripes at −32°, 30 pt apart, crawling 36 pt every 14 s.
private struct KabukiStripes: View {
    let scale: CGFloat
    let drift: TimeInterval

    var body: some View {
        Canvas { ctx, size in
            let gap = 30 * scale
            guard gap > 0.5 else { return }
            let offset = CGFloat((drift * 36 / 14).truncatingRemainder(dividingBy: 30)) * scale
            let reach = hypot(size.width, size.height)
            var c = ctx
            c.translateBy(x: size.width / 2, y: size.height / 2)
            c.rotate(by: .degrees(-32))
            var bands = Path()
            var y = -(reach / gap).rounded(.up) * gap + offset
            while y < reach {
                bands.addRect(CGRect(x: -reach, y: y, width: 2 * reach, height: 2 * scale))
                y += gap
            }
            c.fill(bands, with: .color(.white.opacity(0.055)))
        }
        .allowsHitTesting(false)
    }
}

/// Halftone dots printed over the wedge, strongest at its inner edge and gone
/// a little way in (the spec's 100° mask, 20 % → 70 % of the screen). Static.
private struct KabukiHalftone: View {
    let scale: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let step = 8 * scale, r = 1.6 * scale
            guard w > 0, h > 0, step > 1 else { return }
            let length = w * 0.985 + h * 0.174
            // Ten strengths, one path each, instead of a fill per dot.
            var levels = [Path](repeating: Path(), count: 10)
            var y = step / 2
            while y < h {
                let left = w * (0.64 + 0.18 * y / h)   // the wedge's inner edge
                var x = (max(left - step / 2, 0) / step).rounded(.up) * step + step / 2
                while x < w {
                    let t = (x * 0.985 + y * 0.174) / length
                    let level = Int((min(max(1 - (t - 0.2) / 0.5, 0), 1) * 10).rounded())
                    if level > 0 {
                        levels[level - 1].addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                    }
                    x += step
                }
                y += step
            }
            for (i, dots) in levels.enumerated() where !dots.isEmpty {
                ctx.fill(dots, with: .color(.black.opacity(0.6 * Double(i + 1) / 10)))
            }
        }
        .clipShape(UnitPolygon.kabukiWedge)
        .allowsHitTesting(false)
    }
}

// MARK: - Theme picker card

/// One theme as a card: a live miniature of its background with its name in
/// its own display face over a stroke of its accent, and the name below.
/// Reused by the setup wizard and Settings ▸ Themes so the choice is
/// something you SEE.
struct ThemeCard: View {
    let theme: AppTheme
    var selected: Bool = false
    var width: CGFloat = 220

    var body: some View {
        VStack(spacing: 10) {
            AppBackground(theme: theme, scale: width / RootView.designMin.width)
                .allowsHitTesting(false)
                .frame(width: width, height: width * 9 / 16)
                .overlay(alignment: .bottomLeading) { sample.padding(12) }
                .clipShape(Theme.plate(14))
                .overlay {
                    Theme.plate(14)
                        .strokeBorder(selected ? Theme.accent : Theme.ink.opacity(0.1),
                                      lineWidth: selected ? 3 : 1)
                }
                // A small tag so the still/moving split is legible at a glance.
                .overlay(alignment: .topTrailing) {
                    chip(theme.hasAnimatedBackground ? "Animated" : "Static", ink: .white.opacity(0.92))
                }
                // The owner's red "my favourite" flag, on Parallax Deep — now
                // Default's background — in the same chip style.
                .overlay(alignment: .topLeading) {
                    if theme == .default { chip("my favourite", ink: .red) }
                }
                .shadow(color: selected ? Theme.accentGlow : Theme.restShadow(0.4),
                        radius: selected ? 20 : 8, y: 5)
            Text(theme.title)
                .font(Theme.ui(16, selected ? .bold : .medium))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
        }
        .scaleEffect(selected ? Theme.focusScale(1.04) : 1.0)
        .animation(Theme.focusSpring, value: selected)
        // The whole card is clickable — the thumbnail itself is hit-test-off, so
        // without this a mouse click on the preview (most of the card) misses.
        .contentShape(Rectangle())
    }

    /// The theme's voice in miniature: the wordmark in its display face and
    /// ink, over one stroke of its accent — in ITS colours, whatever the
    /// current theme is.
    private var sample: some View {
        let palette = theme.palette
        return VStack(alignment: .leading, spacing: 5) {
            Text("VIBELIGHT")
                .font(theme.displayFont(width * 0.085))
                .foregroundStyle(palette.textPrimary)
            Rectangle()
                .fill(palette.accent)
                .frame(width: width * 0.16, height: 3)
        }
    }

    private func chip(_ text: String, ink: Color) -> some View {
        Text(text)
            .font(Theme.ui(Theme.labelSize(10), .bold))
            .foregroundStyle(ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.4), in: Capsule())
            .padding(8)
    }
}
