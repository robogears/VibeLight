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
            Image(systemName: symbol)
                .font(.system(size: 96, weight: .bold))
                .foregroundStyle(.white.opacity(0.14))
                .offset(x: 34, y: -30)
                .rotationEffect(.degrees(-8))

            VStack {
                Spacer()
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: symbol)
                            .font(.system(size: 28, weight: .semibold))
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
        case .steam: [Color(red: 0.10, green: 0.17, blue: 0.35), Color(red: 0.04, green: 0.35, blue: 0.55)]
        case .playnite: [Color(red: 0.35, green: 0.18, blue: 0.55), Color(red: 0.14, green: 0.07, blue: 0.28)]
        case .moonDeck: [Color(red: 0.16, green: 0.14, blue: 0.40), Color(red: 0.05, green: 0.04, blue: 0.15)]
        case .virtualDisplay: [Color(red: 0.05, green: 0.35, blue: 0.35), Color(red: 0.02, green: 0.13, blue: 0.16)]
        case .generic: [Color(red: 0.22, green: 0.24, blue: 0.30), Color(red: 0.09, green: 0.10, blue: 0.14)]
        }
    }
}
