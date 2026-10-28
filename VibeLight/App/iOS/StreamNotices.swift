#if os(iOS)
import SwiftUI

/// What the stream says about itself, over the video on the iPad and on the
/// TV (the TV hosts it under Frame Trace — see VibeLightApp's stream overlay
/// builder): the Link Governor's pill ("Connection busy · 60 → 45 Mbps"),
/// "Rejoined", and the Rejoin card over the held last frame.
struct StreamNotices: View {
    @Environment(AppState.self) private var state
    /// False on the TV: its window takes no touches, so the card shows only
    /// the B hint there, not the Stop button.
    var interactive = true
    /// The pill stays off the iPad's companion panel once it has gone dark
    /// (the TV shows it).
    var showsPill = true

    var body: some View {
        GeometryReader { geo in
            // Authored at iPad points; a TV's points sit further away, so the
            // same look is scaled up there (like Frame Trace's `tv`).
            let k = max(1, min(geo.size.width / 1194, 1.6))
            ZStack {
                if let rejoin = state.session.rejoin {
                    RejoinCard(rejoin: rejoin, interactive: interactive) { state.session.stopRejoining() }
                        .scaleEffect(k)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.6))   // dims the held frame
                        .transition(.opacity)
                }
                if showsPill, state.session.rejoin == nil, let notice = state.session.streamNotice {
                    NoticePill(notice: notice)
                        .scaleEffect(k, anchor: .bottom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 44 * k)
                        .transition(.opacity.combined(with: .offset(y: 12)))
                        .id(notice.id)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.3), value: state.session.rejoin)
            .animation(.easeOut(duration: 0.3), value: state.session.streamNotice)
        }
        .ignoresSafeArea()
        .allowsHitTesting(state.session.rejoin != nil)   // otherwise every touch is the game's
    }
}

/// Bottom-centre, a few seconds: what the Link Governor just did, or that a
/// rejoin landed.
private struct NoticePill: View {
    let notice: InProcessStreamEngine.StreamNotice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.warn ? "wifi.exclamationmark" : "checkmark.circle.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(notice.warn ? Color.orange : Color.green)
            Text(notice.title)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text(notice.detail)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Theme.surface.opacity(0.94), in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1) }
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
    }
}

/// Over the held last frame while VibeLight rejoins a dropped stream.
private struct RejoinCard: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let rejoin: InProcessStreamEngine.Rejoin
    let interactive: Bool
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            spinner
            VStack(alignment: .leading, spacing: 6) {
                Text("Connection dropped")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Rejoining \(rejoin.app.name) · try \(rejoin.attempt) of \(InProcessStreamEngine.rejoinDelays.count)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    GlyphBadge(glyph: InputGlyphs.glyph(for: .back, style: state.effectiveGlyphStyle))
                    Text("Stop and see the still-running card")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, 4)
                if interactive {
                    Button(action: onStop) {
                        Text("Stop Rejoining")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                    .padding(.top, 6)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .background(Theme.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.1), lineWidth: 1) }
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("Stop Rejoining")) { onStop() }
    }

    /// A turning arc while it works; still under Reduce Motion.
    private var spinner: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let turn = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360 - 90))
            }
        }
        .frame(width: 52, height: 52)
        .accessibilityHidden(true)
    }
}
#endif
