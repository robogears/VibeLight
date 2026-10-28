import SwiftUI

/// One game tile: box art (or bespoke design), console-style focus scale +
/// accent glow, mouse-hover parity with controller focus. The other themes
/// dress the same tile their own way (`TileDress`): Night Edition mounts it in
/// a vermilion frame, Grid 72 rules it in ink, Kabuki Cut cuts it out.
struct AppTileView: View {
    @Environment(AppState.self) private var state
    let app: StreamApp

    @State private var artwork: TileArtwork = .pending

    /// Fixed tile metrics, published so `AppShelf` can size its scroll view
    /// from them. A horizontal ScrollView expands to fill EVERY point of
    /// vertical space it is offered — left unconstrained it swallowed the
    /// whole home screen and pinned the preset row to the bottom no matter
    /// where the row sat in the stack.
    enum Metrics {
        static let art = CGSize(width: 210, height: 280)
        static let labelSpacing: CGFloat = 14
        static let labelHeight: CGFloat = 18          // one line of 15pt SF Rounded
        /// Headroom for the 1.11 focus scale and its accent glow.
        static let focusPadding: CGFloat = 40
        static var content: CGFloat { art.height + labelSpacing + labelHeight }
        static var shelf: CGFloat { content + focusPadding * 2 }
    }

    private var focusID: String { "app:\(state.appKey(app))" }
    private var isFocused: Bool { state.focus.focusedItemID == focusID }
    // During the launch deal-in the focus ring holds off until the shelf has
    // finished dealing, so it "lands" last. After the intro this equals isFocused.
    private var showFocus: Bool { isFocused && state.intro.focusReady }
    /// Running on the PC right now (it is also sorted to the far left — see
    /// `AppState.shelfPrecedes`). Same rule and green as the hero's RUNNING
    /// badge, so the two always agree.
    private var isLive: Bool { state.serverInfo?.runningAppID == app.id }
    /// Where this launcher keeps tile positions for the starting card.
    @Environment(\.liftGeometry) private var lift
    /// The starting card has lifted this tile's art out of the shelf (Poster
    /// Lift), or the still-running card holds it (Poster Rest), so the tile
    /// shows an empty slot where it was.
    private var isLifted: Bool {
        if case .sessionEnded(let ended) = state.overlay { return ended.id == app.id }
        return state.overlay == .sessionHUD && state.launchTarget?.id == app.id
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How much focus grows the tile: Default's 1.11, Kabuki Cut's 1.08 (not
    /// under Reduce Motion); Night Edition and Grid 72 never scale.
    private var focusScale: CGFloat {
        switch Theme.current {
        case .default: 1.11
        case .kabukiCut: reduceMotion ? 1 : 1.08
        case .nightEdition, .grid72, .grid72Dark: 1
        }
    }

    /// Kabuki Cut tilts the focused tile 2°; nothing else turns.
    private var tilt: Double {
        Theme.current == .kabukiCut && showFocus && !reduceMotion ? -2 : 0
    }

    /// The art's drop shadow: Default's glow when focused; Kabuki's soft black
    /// at rest (focus trades it for a hard crimson one); none on paper.
    private var shadow: (color: Color, radius: CGFloat, y: CGFloat) {
        switch Theme.current {
        case .default:
            (showFocus ? Theme.accentGlow : .black.opacity(0.5), showFocus ? 24 : 10, showFocus ? 6 : 4)
        case .kabukiCut:
            (showFocus ? .clear : .black.opacity(0.6), 10, 8)
        case .nightEdition, .grid72, .grid72Dark:
            (.clear, 0, 0)
        }
    }

    var body: some View {
        VStack(spacing: Metrics.labelSpacing) {
            artworkView
                .frame(width: Metrics.art.width, height: Metrics.art.height)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(LiftGeometry.space)) }) {
                    lift?.artFrames[focusID] = $0
                }
                .modifier(TileDress(focused: showFocus, live: isLive, reduceMotion: reduceMotion))
                // Back from the still-running card: one green ring blooms out
                // of the tile the poster just flew into.
                .phaseAnimator(LandingBloom.allCases, trigger: state.tileBlooms[focusID, default: 0]) { art, phase in
                    art.overlay {
                        if !reduceMotion {
                            Theme.plate(14)
                                .stroke(Theme.live, lineWidth: 3)
                                .scaleEffect(phase.scale)
                                .opacity(phase.opacity)
                                .allowsHitTesting(false)
                        }
                    }
                } animation: { phase in
                    phase == .fade ? Animation.easeOut(duration: 0.7) : Animation.easeOut(duration: 0.12)
                }
                .opacity(isLifted ? 0 : 1)
                .shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)

            caption
        }
        .scaleEffect(showFocus ? focusScale : 1.0)
        .rotationEffect(.degrees(tilt))
        // Kabuki's focused tile throws speed lines over its neighbours.
        .zIndex(showFocus && Theme.current == .kabukiCut ? 1 : 0)
        .animation(Theme.focusSpring, value: showFocus)
        .onHover { hovering in
            // Hover only steals focus in pointer mode — otherwise tiles
            // scrolling under a parked cursor would fight the controller.
            if hovering && state.inputMode == .pointer {
                state.focus.focus(itemID: focusID)
            }
        }
        .onTapGesture { state.pointerSelect(focusID) }
        .accessibilityValue(isLive ? Text("Running now") : Text(""))
        .task(id: taskKey) {
            artwork = await state.artwork.artwork(
                for: app, host: state.selectedHost ?? placeholderHost, address: state.hostAddress
            )
        }
    }

    /// The name under the art. Focused: Default goes bold and bright; Night
    /// Edition flips to an italic serif after a vermilion dash; Grid 72 turns
    /// red; Kabuki Cut sets it on a slanted crimson slab.
    @ViewBuilder private var caption: some View {
        switch Theme.current {
        case .default:
            Text(app.name)
                .font(.system(size: 15, weight: showFocus ? .bold : .medium, design: .rounded))
                .foregroundStyle(showFocus ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .frame(width: Metrics.art.width, height: Metrics.labelHeight)
        case .nightEdition:
            Group {
                if showFocus {
                    (Text("— ").foregroundStyle(Theme.accent) + Text(app.name).foregroundStyle(Theme.textPrimary))
                        .themeText(.tileCaptionFocused)
                } else {
                    Text(app.name)
                        .themeText(.tileCaption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .lineLimit(1)
            .frame(width: Metrics.art.width, height: Metrics.labelHeight)
        case .grid72, .grid72Dark:
            Text(app.name)
                .themeText(showFocus ? .tileCaptionFocused : .tileCaption)
                .foregroundStyle(showFocus ? Theme.accentText : Theme.textSecondary)
                .lineLimit(1)
                .frame(width: Metrics.art.width, height: Metrics.labelHeight)
        case .kabukiCut:
            Text(app.name)
                .themeText(.tileCaption)
                .foregroundStyle(showFocus ? Color.white : Theme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, showFocus ? 12 : 0)
                .background { if showFocus { Theme.accent } }
                .slanted(showFocus ? Theme.slant : 0, pivot: 11)
                .frame(width: Metrics.art.width, height: Metrics.labelHeight)
        }
    }

    /// Refetch artwork when the host address appears (host woke up).
    private var taskKey: String { "\(focusID)|\(state.hostAddress ?? "-")" }

    @ViewBuilder
    private var artworkView: some View {
        switch artwork {
        case .image(let url):
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    BespokeTileView(kind: .generic, title: app.name)
                }
            }
        case .bespoke(let kind):
            BespokeTileView(kind: kind, title: app.name)
        case .pending:
            ZStack {
                Theme.surface
                ProgressView().controlSize(.small)
            }
        }
    }

    /// `task` needs a host even in the impossible no-host case; never rendered.
    private var placeholderHost: StreamHost {
        StreamHost(id: "none", name: "", localAddress: nil, localPort: 0,
                   remoteAddress: nil, remotePort: 0, manualAddress: nil,
                   manualPort: 0, macAddress: nil, serverCertPEM: nil, apps: [])
    }
}

/// A tile's art dressed for the theme: its frame, its LIVE treatment, and
/// what focus does to it.
private struct TileDress: ViewModifier {
    let focused: Bool
    let live: Bool
    let reduceMotion: Bool

    @ViewBuilder func body(content: Content) -> some View {
        switch Theme.current {
        case .default:
            content
                .overlay { if live { LiveShade() } }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            focused ? Theme.accent : live ? Color.green.opacity(0.75) : .white.opacity(0.08),
                            lineWidth: focused ? 3 : live ? 2 : 1
                        )
                }
                .overlay(alignment: .topLeading) {
                    if live { LiveBadge().padding(10) }
                }
        case .nightEdition:
            // Printed with 2 pt corners and an ivory keyline, a touch
            // desaturated so the page reads as one print run; LIVE is an
            // inner green rule and the stamp, never a wash.
            content
                .saturation(focused ? 1 : 0.88)
                .contrast(focused ? 1.06 : 1.04)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay {
                    if live { RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.live, lineWidth: 3) }
                }
                .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.ink.opacity(0.28), lineWidth: 1) }
                .overlay(alignment: .topLeading) {
                    if live { LiveBadge().padding(12) }
                }
                // Focus mounts the print: 6 pt of paper, then a vermilion frame.
                .background {
                    if focused { RoundedRectangle(cornerRadius: 8).fill(Theme.background).padding(-6) }
                }
                .overlay {
                    if focused {
                        RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.accent, lineWidth: 3).padding(-9)
                    }
                }
        case .grid72, .grid72Dark:
            // Square, a 1.5 pt ink keyline, no shadow. Focus adds a keyline 8 pt
            // outside the art (the red bar under it is the shelf's).
            content
                .clipShape(Rectangle())
                .overlay { Rectangle().strokeBorder(Theme.ink, lineWidth: 1.5) }
                .overlay(alignment: .topLeading) {
                    if live { LiveBadge() }
                }
                .overlay {
                    if focused { Rectangle().strokeBorder(Theme.ink, lineWidth: 1).padding(-9) }
                }
        case .kabukiCut:
            // No frame at rest: the shapes are the frame. Focus snaps a white
            // jagged cut-out in behind the art with a hard crimson offset
            // shadow, and speed lines turn around it (not under Reduce Motion).
            content
                .overlay {
                    if live { UnitPolygon.liveCorner.fill(Theme.live.opacity(0.9)) }
                }
                .clipShape(Rectangle())
                .overlay(alignment: .topLeading) {
                    if live { LiveBadge().offset(x: -6, y: 12) }
                }
                .background {
                    if focused { Rectangle().fill(Theme.accent).offset(x: 7, y: 7) }
                }
                .background {
                    if focused {
                        UnitPolygon.jaggedCut
                            .fill(Color.white)
                            .padding(-12)
                            .transition(reduceMotion ? AnyTransition.identity
                                                     : AnyTransition.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .background {
                    if focused && !reduceMotion {
                        SpeedLines()
                            .padding(-70)
                            .transition(.opacity)
                    }
                }
        }
    }
}

/// The live tile's shading: a green wash rising from the bottom of the art —
/// enough to read as "this one is on" from the couch, faint enough that the
/// box art still reads.
private struct LiveShade: View {
    var body: some View {
        LinearGradient(colors: [.green.opacity(0), .green.opacity(0.10), .green.opacity(0.32)],
                       startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
    }
}

/// The landing bloom's steps: invisible at rest, a ring that flashes in on
/// the tile, then grows and fades out.
private enum LandingBloom: CaseIterable {
    case rest, flash, fade
    var scale: CGFloat { self == .fade ? 1.15 : 1 }
    var opacity: Double { self == .flash ? 1 : 0 }
}

/// "● LIVE" on the running tile (and on the still-running card's poster).
/// The dot breathes slowly; under Reduce Motion it holds still. On the card
/// it also reads CLOSING while Quit is held and CLOSED once the PC has
/// ended the game. Night Edition prints it as a rubber stamp, Grid 72 as a
/// corner tag, Kabuki Cut as a slanted lime slab with a star.
struct LiveBadge: View {
    enum Mode { case live, closing, closed }
    var mode: Mode = .live

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    private var word: String { mode == .live ? "LIVE" : mode == .closing ? "CLOSING" : "CLOSED" }

    var body: some View {
        themed
            .accessibilityHidden(true)   // the tile itself says "Running now"
            .onAppear {
                guard !reduceMotion, Theme.current == .default else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
            }
    }

    @ViewBuilder private var themed: some View {
        switch Theme.current {
        case .default:
            HStack(spacing: 6) {
                Circle()
                    .fill(mode == .live ? Color.green : .white.opacity(mode == .closing ? 1 : 0.4))
                    .frame(width: 8, height: 8)
                    .opacity(mode == .live && dim ? 0.45 : 1)
                    .shadow(color: .green.opacity(mode == .live ? 0.8 : 0), radius: 4)
                Text(word)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(mode == .closed ? Theme.textSecondary : .white)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().strokeBorder(mode == .live ? Color.green.opacity(0.5) : .white.opacity(0.3),
                                            lineWidth: 1))
        case .nightEdition:
            NightStamp(text: word,
                       color: mode == .live ? Theme.live : mode == .closing ? Theme.textPrimary : Theme.textSecondary)
        case .grid72, .grid72Dark:
            // White on the deeper green on paper; dark on the bright green of
            // the inversion — either way a word, not just a colour.
            Text(word)
                .themeText(.liveBadge)
                .foregroundStyle(Theme.palette.isLight ? Color.white : Color(hex: 0x111111))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(gridFill)
        case .kabukiCut:
            HStack(spacing: 4) {
                Text("★").font(.system(size: 12, weight: .black))
                Text(word).themeText(.liveBadge)
            }
            .foregroundStyle(Color.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                SlantedRect(Theme.slant)
                    .fill(mode == .live ? Theme.live : mode == .closing ? Color.white : Color(hex: 0x8A8A8A))
            }
        }
    }

    private var gridFill: Color {
        switch mode {
        case .live: Theme.palette.isLight ? Theme.liveText : Theme.live
        case .closing: Theme.palette.isLight ? Theme.accentText : Theme.textPrimary
        case .closed: Theme.textSecondary
        }
    }
}

/// Where each tile's art sits in its launcher, so the starting card can lift
/// the pressed tile out of the shelf (Poster Lift). One per launcher — the
/// iPad's and the TV's lay out differently. Written on every layout and never
/// observed: tile positions must not re-render anything.
@MainActor
final class LiftGeometry {
    static let space = "vibelight.launcher"
    var artFrames: [String: CGRect] = [:]
}

extension EnvironmentValues {
    @Entry var liftGeometry: LiftGeometry? = nil
}
