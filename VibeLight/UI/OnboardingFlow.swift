import SwiftUI

/// The first-run setup wizard — a full-screen, unskippable flow shown once
/// (until `hasCompletedSetup`) and re-triggerable from Settings ▸ Restart Setup.
/// A cinematic welcome, then a few single-decision screens (theme → stream
/// quality → presets teaser → all set). Controller + keyboard route through
/// `AppState.routeOnboarding`; touch/click uses the buttons directly. Every step
/// arrives pre-selected on a sensible default, so the fast path is "look, go".
struct OnboardingFlow: View {
    @Environment(AppState.self) private var state
    let step: OnboardingStep

    var body: some View {
        ZStack {
            // Live, blurred background that morphs as the user picks a theme —
            // it previews the product the whole time. Heavier blur on welcome.
            AppBackground(theme: state.appTheme)
                .blur(radius: bigMoment ? 42 : 16)
                .overlay(Theme.veil.opacity(bigMoment ? 0.42 : 0.5))
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: state.appTheme)
                .animation(.easeInOut(duration: 0.6), value: step)

            content
                // The theme picker runs edge-to-edge like Settings ▸ Themes; every
                // other step stays in a comfortable centered column.
                .frame(maxWidth: step == .theme ? .infinity : 980)
                .padding(.horizontal, 40)
                .id(step)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.96)),
                    removal: .opacity))

            // Persistent chrome: progress pips up top, hint bar at the bottom —
            // hidden on the full-screen cinematic beats (welcome + finale).
            VStack {
                if !bigMoment {
                    OnboardingPips(step: step).padding(.top, 44)
                }
                Spacer()
                if !bigMoment {
                    OnboardingHints(step: step).padding(.bottom, 40)
                }
            }
            .ignoresSafeArea(.keyboard)
        }
        .ignoresSafeArea()
        // A light page on Grid 72, as the launcher is (LauncherContent).
        .environment(\.colorScheme, Theme.palette.isLight ? .light : .dark)
        .animation(Theme.focusSpring, value: step)   // step→step transitions
    }

    /// Welcome + finale are full-screen cinematic beats: no pips, no hint bar,
    /// heavier blur.
    private var bigMoment: Bool { step == .welcome || step == .finale }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .theme:   ThemeStep()
        case .quality: QualityStep()
        case .presets: PresetsStep()
        case .finish:  FinishStep()
        case .finale:  FinaleStep()
        }
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var started = false

    var body: some View {
        VStack(spacing: 16) {
            Text("VibeLight")
                .font(Theme.display(72))
                .foregroundStyle(Theme.textPrimary)
                .shadow(color: Theme.accentGlow, radius: 30)
            Text("Thanks for downloading.")
                .font(Theme.ui(24, .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .scaleEffect(shown ? 1 : (reduceMotion ? 1 : 0.92))
        .opacity(shown ? 1 : 0)
        .blur(radius: shown ? 0 : (reduceMotion ? 0 : 8))
        .onAppear {
            guard !started else { return }   // onAppear can fire twice — run once
            started = true
            // Idempotent per session: Welcome is re-entered by pressing Back
            // from Theme, and re-snapshotting there flipped onboardingHadPresets
            // AFTER the wizard seeded the first preset — silently skipping the Quality
            // and Presets steps on the way forward.
            state.beginOnboardingSessionIfNeeded()
            Task { @MainActor in
                // Let the background breathe on its own first — a beat of calm
                // before anything appears.
                try? await Task.sleep(for: .seconds(1.0))
                guard state.onboardingStep == .welcome else { return }
                state.playQuack()   // 🦆 hello — lands with the wordmark
                withAnimation(LaunchIntro.reveal) { shown = true }
                // Hold the greeting a beat longer, then hand off. The step change
                // itself animates (Theme.focusSpring) so it reads as a pop-forward.
                try? await Task.sleep(for: .seconds(3.8))
                if state.onboardingStep == .welcome { state.advanceOnboarding() }
            }
        }
    }
}

// MARK: - Finale

/// The cinematic hand-off after "Jump in": the blurred background holds, the
/// VibeLight wordmark reveals front-and-center with a warm swell, slowly fades
/// out, then ~1s of quiet anticipation before the launcher deals itself in
/// (`completeSetup` → the launch intro). Non-interactive.
private struct FinaleStep: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var faded = false
    @State private var started = false

    var body: some View {
        Text("VibeLight")
            .font(Theme.display(80))
            .foregroundStyle(Theme.textPrimary)
            .shadow(color: Theme.accentGlow, radius: 40)
            .scaleEffect(shown ? 1 : (reduceMotion ? 1 : 0.9))
            .opacity(faded ? 0 : (shown ? 1 : 0))
            .blur(radius: shown ? 0 : (reduceMotion ? 0 : 12))
            .onAppear(perform: runFinale)
    }

    private func runFinale() {
        guard !started else { return }   // onAppear can fire twice — run once
        started = true
        state.playLaunchCue()                                    // the cool swell
        withAnimation(.easeOut(duration: 0.8)) { shown = true }  // reveal, front-and-center
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.6))            // hold on the mark (1s longer)
            withAnimation(.easeInOut(duration: 0.8)) { faded = true }   // slow fade out
            try? await Task.sleep(for: .seconds(1.8))            // finish fade + ~1s of nothing
            state.completeSetup()                               // → the launcher deals in
        }
    }
}

// MARK: - Theme

private struct ThemeStep: View {
    @Environment(AppState.self) private var state

    var body: some View {
        OnboardingStepScaffold(
            title: "Pick your look",
            subtitle: "Change it anytime in Settings ▸ Themes.",
            primary: "Continue"
        ) {
            // Scrolls so every theme fits; the selected card is kept centered as
            // the controller/keyboard cycles (◀ ▶), and touch can swipe freely.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 26) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            ThemeCard(theme: theme, selected: state.appTheme == theme, width: 240)
                                .id(theme)
                                .onTapGesture { state.appTheme = theme }
                        }
                    }
                    .padding(.horizontal, 60)
                    .padding(.vertical, 24)
                }
                .onChange(of: state.appTheme) { _, theme in
                    withAnimation(Theme.focusSpring) { proxy.scrollTo(theme, anchor: .center) }
                }
                .onAppear { proxy.scrollTo(state.appTheme, anchor: .center) }
            }
        }
    }
}

// MARK: - Quality

private struct QualityStep: View {
    @Environment(AppState.self) private var state

    var body: some View {
        OnboardingStepScaffold(
            title: "Set your stream quality",
            subtitle: "You can fine-tune these anytime in Settings ▸ Video.",
            primary: "Continue"
        ) {
            VStack(spacing: 12) {
                ForEach(Array(state.onboardingQualityRows.enumerated()), id: \.element.rawValue) { i, row in
                    OnboardingQualityRow(row: row, focused: state.onboardingQualityFocus == i)
                        .onTapGesture { state.focusOnboardingQuality(i) }
                }
                Text(bitrateHint)
                    .font(Theme.ui(14, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 6)
                    .animation(Theme.focusSpring, value: state.settings.bitrateKbps)
            }
            .frame(maxWidth: 620)
        }
    }

    private var bitrateHint: String {
        switch state.settings.bitrateKbps / 1000 {
        case ..<20:   "Light — best for weaker or capped connections."
        case 20..<60: "Balanced — great for most home networks."
        default:      "High — best quality; needs a strong, fast link."
        }
    }
}

private struct OnboardingQualityRow: View {
    @Environment(AppState.self) private var state
    let row: AppState.SettingsRow
    let focused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text(row.title)
                .font(Theme.ui(18, .semibold))
                .foregroundStyle(focused ? Theme.onAccentLarge : Theme.textPrimary)
            Spacer()
            chevron("chevron.left") { state.adjust(row: row, forward: false) }
            Text(state.value(for: row))
                .font(Theme.ui(18, .bold))
                .foregroundStyle(focused ? Theme.onAccentLarge : Theme.accentText)
                .monospacedDigit()
                .frame(minWidth: 130)
                .contentTransition(.numericText())
            chevron("chevron.right") { state.adjust(row: row, forward: true) }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .background(focused ? Theme.accent.opacity(0.85) : Theme.surface.opacity(0.6),
                    in: Theme.plate(14))
        .overlay {
            Theme.plate(14)
                .strokeBorder(Theme.ink.opacity(focused ? 0.3 : 0.06), lineWidth: 1)
        }
        .animation(Theme.focusSpring, value: focused)
        .animation(Theme.focusSpring, value: state.value(for: row))
    }

    private func chevron(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(focused ? Theme.onAccentLarge : Theme.ink.opacity(0.6))
                .frame(width: Theme.perPlatform(iOS: 44, macOS: 36),
                       height: Theme.perPlatform(iOS: 44, macOS: 36))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Presets teaser

private struct PresetsStep: View {
    @Environment(AppState.self) private var state

    var body: some View {
        OnboardingStepScaffold(
            title: "Your first preset",
            subtitle: "We saved your setup as \u{201C}\(presetName)\u{201D} — presets keep quality profiles a button away.",
            primary: "Continue"
        ) {
            VStack(spacing: 22) {
                HStack(spacing: 14) {
                    MiniPresetChip(title: presetName, label: presetLabel, highlighted: true)
                    MiniPresetChip(title: "+", label: "Save more")
                }
                VStack(spacing: 6) {
                    Text("On the home screen, your presets sit right under your games — press ▼ to load one.")
                    Text("Change a setting and the preset shows what changed: A keeps it, or revert it.")
                }
                .font(Theme.ui(16, .medium))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            }
            // Seed the first preset from the res/fps/bitrate they just chose,
            // named after them (only when they have no presets — which is the
            // only time this step shows).
            .onAppear { state.seedFirstPresetIfEmpty() }
        }
    }

    private var presetName: String { state.presets.first?.name ?? state.suggestedPresetNames().first ?? "" }

    private var presetLabel: String {
        "\(state.value(for: .resolution)) · \(state.settings.fps) fps"
    }
}

private struct MiniPresetChip: View {
    let title: String
    var label: String
    var highlighted = false

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(Theme.ui(15, .bold))
                .foregroundStyle(highlighted ? Theme.onAccent : Theme.textSecondary)
                .lineLimit(1)
            Text(label)
                .font(Theme.ui(Theme.labelSize(11), .medium))
                .foregroundStyle(highlighted ? Theme.onAccent.opacity(0.9) : Theme.textSecondary.opacity(0.6))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: Theme.perPlatform(iOS: 112, macOS: 96),
               minHeight: Theme.perPlatform(iOS: 64, macOS: 60))
        .background(highlighted ? Theme.accent.opacity(0.85) : Theme.surface.opacity(0.6),
                    in: Theme.plate(12))
        .overlay {
            Theme.plate(12)
                .strokeBorder(highlighted ? Theme.accent : Theme.ink.opacity(0.12),
                              style: StrokeStyle(lineWidth: highlighted ? 2 : 1, dash: highlighted ? [] : [4, 3]))
        }
        .shadow(color: highlighted ? Theme.accentGlow : .clear, radius: 14)
    }
}

// MARK: - Finish

private struct FinishStep: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 26) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.accent)
            Text("You're all set")
                .font(Theme.display(44))
                .foregroundStyle(Theme.textPrimary)
            OnboardingButton(title: "Jump in", prominent: true) { state.advanceOnboarding() }
                .padding(.top, 6)
        }
    }
}

// MARK: - Shared chrome

/// Title + subtitle + a body + a prominent primary button (touch), centered.
private struct OnboardingStepScaffold<Body: View>: View {
    @Environment(AppState.self) private var state
    let title: String
    let subtitle: String
    let primary: String
    @ViewBuilder var content: Body

    var body: some View {
        VStack(spacing: 20) {
            Text(title)
                .font(Theme.display(40))
                .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
                .font(Theme.ui(18, .medium))
                .foregroundStyle(Theme.textSecondary)
            content
                .padding(.vertical, 14)
            OnboardingButton(title: primary, prominent: true) { state.advanceOnboarding() }
        }
        .multilineTextAlignment(.center)
    }
}

private struct OnboardingButton: View {
    let title: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.ui(18, .bold))
                .foregroundStyle(prominent ? Theme.onAccent : Theme.textPrimary)
                .padding(.horizontal, 34)
                .padding(.vertical, 14)
                .background(prominent ? Theme.accent : Theme.surface.opacity(0.7),
                            in: Theme.pill)
                .shadow(color: prominent ? Theme.accentGlow : .clear, radius: 18, y: 4)
        }
        .buttonStyle(.plain)
    }
}

/// Progress dots for the content steps actually shown (skipped steps drop out).
private struct OnboardingPips: View {
    @Environment(AppState.self) private var state
    let step: OnboardingStep
    private var steps: [OnboardingStep] {
        [.theme, .quality, .presets, .finish].filter { !state.shouldSkipStep($0) }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(steps, id: \.rawValue) { s in
                Theme.pill
                    .fill(s == step ? Theme.accent : Theme.ink.opacity(0.18))
                    .frame(width: s == step ? 26 : 8, height: 8)
                    .animation(Theme.focusSpring, value: step)
            }
        }
    }
}

/// The persistent hint bar — controller glyphs, and tappable on touch (it drives
/// the same routing as a controller). No "skip": the flow is unskippable.
private struct OnboardingHints: View {
    @Environment(AppState.self) private var state
    let step: OnboardingStep

    /// The main hint bar's chips: the connected controller's own buttons
    /// (Ⓐ/Ⓑ, Cross/Circle, ⏎/⎋ on a keyboard), or plain tappable pills on
    /// touch. A tap routes through `state.route`, which hands it to the wizard
    /// (UX-onboarding-hints-generic-glyphs).
    var body: some View {
        let touch = HintBarView.touchPresentation(state)
        HStack(spacing: touch ? 12 : 26) {
            if step != .theme {   // Back exists on every step after the first content step
                HintChip(event: .back, label: "Back", touch: touch)
            }
            // Touch users tap the cards directly, so the d-pad hint drops out.
            if !touch && (step == .theme || step == .quality) {
                HintChip(event: .move(.left), label: "Change", touch: false)
                    .allowsHitTesting(false)
                    .accessibilityRemoveTraits(.isButton)   // a hint, not a control
            }
            HintChip(event: .select, label: step == .finish ? "Jump in" : "Continue", touch: touch)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(Theme.veil.opacity(0.35), in: Theme.pill)
    }
}
