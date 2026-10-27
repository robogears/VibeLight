import SwiftUI

/// One game tile: box art (or bespoke design), console-style focus scale +
/// accent glow, mouse-hover parity with controller focus.
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

    var body: some View {
        VStack(spacing: Metrics.labelSpacing) {
            artworkView
                .frame(width: Metrics.art.width, height: Metrics.art.height)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(LiftGeometry.space)) }) {
                    lift?.artFrames[focusID] = $0
                }
                .overlay { if isLive { LiveShade() } }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            showFocus ? Theme.accent : isLive ? Color.green.opacity(0.75) : .white.opacity(0.08),
                            lineWidth: showFocus ? 3 : isLive ? 2 : 1
                        )
                }
                .overlay(alignment: .topLeading) {
                    if isLive { LiveBadge().padding(10) }
                }
                // Back from the still-running card: one green ring blooms out
                // of the tile the poster just flew into.
                .phaseAnimator(LandingBloom.allCases, trigger: state.tileBlooms[focusID, default: 0]) { art, phase in
                    art.overlay {
                        if !reduceMotion {
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.green, lineWidth: 3)
                                .scaleEffect(phase.scale)
                                .opacity(phase.opacity)
                                .allowsHitTesting(false)
                        }
                    }
                } animation: { phase in
                    phase == .fade ? Animation.easeOut(duration: 0.7) : Animation.easeOut(duration: 0.12)
                }
                .opacity(isLifted ? 0 : 1)
                .shadow(
                    color: showFocus ? Theme.accentGlow : .black.opacity(0.5),
                    radius: showFocus ? 24 : 10,
                    y: showFocus ? 6 : 4
                )

            Text(app.name)
                .font(.system(size: 15, weight: showFocus ? .bold : .medium, design: .rounded))
                .foregroundStyle(showFocus ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .frame(width: Metrics.art.width, height: Metrics.labelHeight)
        }
        .scaleEffect(showFocus ? 1.11 : 1.0)
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
/// ended the game.
struct LiveBadge: View {
    enum Mode { case live, closing, closed }
    var mode: Mode = .live

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(mode == .live ? Color.green : .white.opacity(mode == .closing ? 1 : 0.4))
                .frame(width: 8, height: 8)
                .opacity(mode == .live && dim ? 0.45 : 1)
                .shadow(color: .green.opacity(mode == .live ? 0.8 : 0), radius: 4)
            Text(mode == .live ? "LIVE" : mode == .closing ? "CLOSING" : "CLOSED")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(mode == .closed ? Theme.textSecondary : .white)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(mode == .live ? Color.green.opacity(0.5) : .white.opacity(0.3),
                                        lineWidth: 1))
        .accessibilityHidden(true)   // the tile itself says "Running now"
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
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
