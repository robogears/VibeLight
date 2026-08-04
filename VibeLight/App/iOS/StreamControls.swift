#if os(iOS)
import SwiftUI

/// The in-stream controls on the iPad: leave the stream, and raise the
/// on-screen keyboard.
///
/// They show themselves when a stream starts, then get out of the way — after
/// `visibleDuration` they slide off the right edge, because a game does not
/// want two buttons parked over it. Swiping in from the right edge brings them
/// back, tracking the finger rather than snapping, so it reads as pulling a
/// drawer out rather than triggering a shortcut.
///
/// Not shown when a TV is driving the video: there the iPad is already a
/// dedicated companion panel with its own controls, and nothing is covering
/// gameplay.
struct StreamControls: View {

    let onLeave: () -> Void
    @Binding var keyboardUp: Bool

    /// How long the controls linger at stream start (and after each reveal)
    /// before retiring. Long enough to notice and use, short enough not to sit
    /// over the first minute of play.
    private static let visibleDuration: Duration = .seconds(7)

    /// How far right the cluster travels to clear the screen: its own width
    /// plus the trailing padding, plus margin for the button's shadow.
    private static let hiddenOffset: CGFloat = 96

    /// Width of the invisible strip that catches the reveal swipe. Only present
    /// while the controls are hidden, and only in the top-right corner, so the
    /// dead zone it creates for touch-as-input is as small as it can be.
    private static let grabWidth: CGFloat = 32
    private static let grabHeight: CGFloat = 180

    @State private var revealed = true
    @State private var drag: CGFloat = 0
    @State private var hideTask: Task<Void, Never>?

    /// Live position: the resting place plus whatever the finger is doing,
    /// clamped so it can never be dragged past either end.
    private var offsetX: CGFloat {
        let base = revealed ? 0 : Self.hiddenOffset
        return min(max(base + drag, 0), Self.hiddenOffset)
    }

    /// Fades as it leaves rather than sliding out at full strength — a button
    /// disappearing off the edge at full opacity reads as a glitch.
    private var opacity: Double {
        1 - Double(offsetX / Self.hiddenOffset)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if !revealed { grabStrip }
            controls
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: revealed)
        .onAppear { scheduleHide() }
        .onDisappear { hideTask?.cancel() }
        // Keyboard up → keep the controls out; you need the ✕ and the keyboard
        // toggle exactly while typing, and having them retire mid-sentence
        // would be maddening.
        .onChange(of: keyboardUp) { _, up in
            if up { reveal(thenHide: false) } else { scheduleHide() }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            controlButton("xmark", label: "Leave the stream", action: onLeave)
            controlButton(keyboardUp ? "keyboard.chevron.compact.down" : "keyboard",
                          label: keyboardUp ? "Hide the keyboard" : "Show the keyboard") {
                keyboardUp.toggle()
            }
        }
        .padding(24)
        .offset(x: offsetX)
        .opacity(opacity)
        // Once off-screen it must stop taking touches, or an invisible button
        // keeps swallowing taps meant for the game.
        .allowsHitTesting(offsetX < Self.hiddenOffset / 2)
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    hideTask?.cancel()
                    drag = max(0, value.translation.width)   // rightward only
                }
                .onEnded { value in
                    let dismissed = value.translation.width > 40 || value.predictedEndTranslation.width > 100
                    drag = 0
                    if dismissed { hide() } else { reveal() }
                }
        )
    }

    /// The reveal target. Invisible, but a real hit area.
    private var grabStrip: some View {
        Color.clear
            .frame(width: Self.grabWidth, height: Self.grabHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        // Follow the finger leftward out of the hidden position.
                        drag = min(0, value.translation.width)
                    }
                    .onEnded { value in
                        let pulled = value.translation.width < -30 || value.predictedEndTranslation.width < -80
                        drag = 0
                        if pulled { reveal() }
                    }
            )
    }

    private func controlButton(_ symbol: String, label: String,
                               action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleHide()      // any use resets the clock
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.45), in: Circle())
        }
        .accessibilityLabel(label)
    }

    // MARK: - Show / hide

    private func reveal(thenHide: Bool = true) {
        revealed = true
        if thenHide { scheduleHide() } else { hideTask?.cancel() }
    }

    private func hide() {
        hideTask?.cancel()
        revealed = false
    }

    /// Restarts the retire countdown. Cancelling first is what makes repeated
    /// taps extend the window instead of stacking timers that fire in sequence.
    private func scheduleHide() {
        hideTask?.cancel()
        guard !keyboardUp else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: Self.visibleDuration)
            guard !Task.isCancelled, !keyboardUp else { return }
            revealed = false
        }
    }
}
#endif
