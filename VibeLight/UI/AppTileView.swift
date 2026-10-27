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

    var body: some View {
        VStack(spacing: Metrics.labelSpacing) {
            artworkView
                .frame(width: Metrics.art.width, height: Metrics.art.height)
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

/// "● LIVE" on the running tile. The dot breathes slowly; under Reduce Motion
/// it holds still.
private struct LiveBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
                .opacity(dim ? 0.45 : 1)
                .shadow(color: .green.opacity(0.8), radius: 4)
            Text("LIVE")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(.green.opacity(0.5), lineWidth: 1))
        .accessibilityHidden(true)   // the tile itself says "Running now"
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
        }
    }
}
