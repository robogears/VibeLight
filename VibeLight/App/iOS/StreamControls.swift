#if os(iOS)
import SwiftUI

/// The in-stream controls on the iPad: leave the stream, raise the on-screen
/// keyboard, stats, Task View, and Quit Game (StreamQuitGameButton).
///
/// They show themselves when a stream starts, then get out of the way — after
/// `visibleDuration` they slide off the right edge, because a game does not
/// want buttons parked over it. A faint pill stays at the top-right edge where
/// they went; a swipe LEFT from there pulls them back out. Only a swipe: a tap
/// in that corner belongs to the game (owner: tapping by the grey line
/// "can't do it, and sometimes the menu opens"). The pill takes no touches;
/// StreamView tells a pull from a tap and bumps `pulls`.
///
/// With VoiceOver, Switch Control or AssistiveTouch running they never retire
/// (a timed control is one those users can lose), and "Leave the Stream" is an
/// accessibility action on the whole cluster so it exists even while hidden.
/// Under Reduce Motion they fade in place instead of sliding.
///
/// Not shown when a TV is driving the video: there the iPad is already a
/// dedicated companion panel with its own controls, and nothing is covering
/// gameplay.
struct StreamControls: View {

    let onLeave: () -> Void
    @Binding var keyboardUp: Bool
    /// Performance Stats for this stream (owner: an on/off button beside the
    /// keyboard and ✕). Lit while on.
    let statsOn: Bool
    let onToggleStats: () -> Void
    /// Win+Tab: Windows' Task View (owner: an Alt+Tab button beside stats).
    let onTaskView: () -> Void
    /// Bumped each time a swipe from the corner asks for the controls.
    let pulls: Int
    /// Tells StreamView whether the controls are tucked (so the corner pulls).
    let onTucked: (Bool) -> Void

    /// How long the controls linger at stream start (and after each reveal)
    /// before retiring. Long enough to notice and use, short enough not to sit
    /// over the first minute of play.
    private static let visibleDuration: Duration = .seconds(7)

    /// How far right the cluster travels to clear the screen: its own width
    /// plus the trailing padding, plus margin for the button's shadow.
    private static let hiddenOffset: CGFloat = 96

    @State private var revealed = true
    @State private var drag: CGFloat = 0
    @State private var hideTask: Task<Void, Never>?

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    /// Assistive tech is driving: the controls stay put, as they do while the
    /// keyboard is up. AssistiveTouch has no environment value, so it is read
    /// directly.
    private var assistiveTechActive: Bool {
        voiceOver || switchControl || UIAccessibility.isAssistiveTouchRunning
    }

    /// Live position: the resting place plus whatever the finger is doing,
    /// clamped so it can never be dragged past either end.
    private var offsetX: CGFloat {
        guard !reduceMotion else { return 0 }   // fade in place, never slide
        let base = revealed ? 0 : Self.hiddenOffset
        return min(max(base + drag, 0), Self.hiddenOffset)
    }

    /// Fades as it leaves rather than sliding out at full strength — a button
    /// disappearing off the edge at full opacity reads as a glitch.
    private var opacity: Double {
        if reduceMotion { return revealed ? 1 : 0 }
        return 1 - Double(offsetX / Self.hiddenOffset)
    }

    /// Once hidden it must stop taking touches, or an invisible button keeps
    /// swallowing taps meant for the game.
    private var takesTouches: Bool {
        reduceMotion ? revealed : offsetX < Self.hiddenOffset / 2
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if !revealed { grabStrip }
            controls
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2)
                                : .spring(response: 0.38, dampingFraction: 0.86),
                   value: revealed)
        // Reachable from the rotor / Switch Control menu even while the
        // buttons are tucked away.
        .accessibilityAction(named: Text("Leave the Stream")) { onLeave() }
        .onAppear { scheduleHide(); onTucked(!revealed) }
        .onDisappear { hideTask?.cancel(); onTucked(false) }
        .onChange(of: revealed) { _, shown in onTucked(!shown) }
        .onChange(of: pulls) { _, _ in reveal() }
        // Keyboard up → keep the controls out; you need the ✕ and the keyboard
        // toggle exactly while typing, and having them retire mid-sentence
        // would be maddening.
        .onChange(of: keyboardUp) { _, up in
            if up { reveal(thenHide: false) } else { scheduleHide() }
        }
        // VoiceOver or Switch Control turned on mid-stream → bring the
        // buttons back and keep them; turned off → the normal clock resumes.
        .onChange(of: assistiveTechActive) { _, active in
            if active { reveal(thenHide: false) } else { scheduleHide() }
        }
    }

    private var controls: some View {
        // Trailing: Quit Game's "tap again" label opens to the left of its circle.
        VStack(alignment: .trailing, spacing: 12) {
            controlButton("xmark", label: "Leave the stream", action: onLeave)
            controlButton(keyboardUp ? "keyboard.chevron.compact.down" : "keyboard",
                          label: keyboardUp ? "Hide the keyboard" : "Show the keyboard") {
                keyboardUp.toggle()
            }
            controlButton("speedometer", label: "Performance stats", isOn: statsOn,
                          action: onToggleStats)
            controlButton("rectangle.on.rectangle", label: "Task View (Windows key + Tab)",
                          action: onTaskView)
            StreamQuitGameButton(diameter: 44) { scheduleHide() }
        }
        .padding(24)
        .offset(x: offsetX)
        .opacity(opacity)
        .allowsHitTesting(takesTouches)
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

    /// Where the controls went: a faint pill (like Slide Over's). Its centre
    /// (24 pt down + half of 44) lines up with where the ✕ sits when revealed,
    /// so it reads as "the buttons are tucked in here". White 0.5 on black is
    /// 5.3:1; the black shadow keeps its edge over bright video. That ratio
    /// only holds over dark frames — over snow or sky it is near 1:1 — so under
    /// Increase Contrast the pill goes near-solid and gains a black outline,
    /// and never depends on faintness to be seen. It takes no touches (taps
    /// there are the game's); StreamView watches that corner for the swipe.
    private var grabStrip: some View {
        Capsule()
            .fill(.white.opacity(contrast == .increased ? 0.85 : 0.5))
            .overlay {
                if contrast == .increased {
                    Capsule().stroke(.black, lineWidth: 1)
                }
            }
            .frame(width: 4, height: 44)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .padding(.top, 24)
            .padding(.trailing, 6)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Show stream controls")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { reveal() }
    }

    /// `isOn` (on/off buttons only) lights the circle in the accent colour.
    private func controlButton(_ symbol: String, label: String, isOn: Bool? = nil,
                               action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleHide()      // any use resets the clock
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(isOn == true ? Theme.onAccent : .white)
                .frame(width: 44, height: 44)
                .background(isOn == true ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.black.opacity(0.45)),
                            in: Circle())
        }
        .accessibilityLabel(label)
        .accessibilityValue(isOn.map { $0 ? "On" : "Off" } ?? "")
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
        guard !keyboardUp, !assistiveTechActive else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: Self.visibleDuration)
            guard !Task.isCancelled, !keyboardUp else { return }
            revealed = false
        }
    }
}
/// In-stream Quit Game (owner): the game AND the stream, through VibeLight
/// Helper — the same as the still-running card's Quit Stream and Game. A tap
/// arms it for 3 s: it turns red and names the game the helper sees; a second
/// tap quits. Greyed with no helper, or no game running. `diameter` 44 over
/// the game; much bigger on the TV companion panel (owner).
struct StreamQuitGameButton: View {
    @Environment(AppState.self) private var state
    var diameter: CGFloat = 44
    /// Any use (StreamControls: resets its retire clock).
    var onUse: () -> Void = {}

    private var game: String? { state.canQuitGame ? state.helperGame?.title : nil }

    var body: some View {
        HStack(spacing: diameter * 0.25) {
            if state.quitGameArmed, let game {
                Text("Tap again to quit \(game)")
                    .font(.system(size: diameter * 0.32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, diameter * 0.3)
                    .padding(.vertical, diameter * 0.18)
                    .background(Color.red.opacity(0.9), in: Capsule())
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                    .accessibilityHidden(true)   // the button's own label says it
            }
            Button {
                onUse()
                state.tapQuitGameInStream()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: diameter * 0.36, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: diameter, height: diameter)
                    .background(state.quitGameArmed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.black.opacity(0.45)),
                                in: Circle())
            }
            .disabled(game == nil)
            .opacity(game == nil ? 0.4 : 1)
            .accessibilityLabel(game.map { state.quitGameArmed ? "Confirm: quit \($0) and the stream"
                                                               : "Quit \($0) and the stream" }
                                ?? "Quit Game, no game running")
        }
        .animation(.easeOut(duration: 0.2), value: state.quitGameArmed)
    }
}
#endif
