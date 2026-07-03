import SwiftUI

/// One game tile: box art (or bespoke design), console-style focus scale +
/// accent glow, mouse-hover parity with controller focus.
struct AppTileView: View {
    @Environment(AppState.self) private var state
    let app: StreamApp

    @State private var artwork: TileArtwork = .pending

    private var focusID: String { "app:\(state.appKey(app))" }
    private var isFocused: Bool { state.focus.focusedItemID == focusID }

    var body: some View {
        VStack(spacing: 14) {
            artworkView
                .frame(width: 210, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            isFocused ? Theme.accent : .white.opacity(0.08),
                            lineWidth: isFocused ? 3 : 1
                        )
                }
                .shadow(
                    color: isFocused ? Theme.accentGlow : .black.opacity(0.5),
                    radius: isFocused ? 24 : 10,
                    y: isFocused ? 6 : 4
                )

            Text(app.name)
                .font(.system(size: 15, weight: isFocused ? .bold : .medium, design: .rounded))
                .foregroundStyle(isFocused ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .frame(width: 210)
        }
        .scaleEffect(isFocused ? 1.11 : 1.0)
        .animation(Theme.focusSpring, value: isFocused)
        .onHover { hovering in
            if hovering { state.focus.focus(itemID: focusID) }
        }
        .onTapGesture { state.route(.select) }
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
