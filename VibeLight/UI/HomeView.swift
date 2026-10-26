import SwiftUI

/// The big-picture home screen: status header, hero title of the focused app,
/// the games shelf with the preset row directly beneath it, and the input
/// hint bar.
struct HomeView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        content
            // The launch deal-in plays the first time home appears (once per app
            // launch; a no-op after that — see LaunchIntro). Skipped during the
            // first-run setup wizard; `completeSetup` fires it right after.
            .onAppear { if !state.isOnboarding { state.intro.begin() } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderBar()
                .padding(.horizontal, 72)
                .padding(.top, 48)
                .introReveal(state.intro.arrived(LaunchIntro.header), y: -8)   // eases in from the top

            // Hero: the focused app's name writ large — the "what am I about
            // to play" moment.
            VStack(alignment: .leading, spacing: 10) {
                if let app = state.focusedApp {
                    Text(app.name)
                        .font(.system(size: 52, weight: .black, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .id("hero-\(state.appKey(app))")
                        .transition(.opacity.combined(with: .offset(y: 8)))
                    HStack(spacing: 12) {
                        if app.isHDRSupported && state.settings.hdr {
                            Badge(text: "HDR")
                        }
                        // Same friendly labels as the Settings rows ("1080p",
                        // "4K", raw W×H for customs; whole-number Mbps).
                        Badge(text: state.value(for: .resolution))
                        Badge(text: "\(state.settings.fps) FPS")
                        Badge(text: "\(state.settings.bitrateKbps / 1000) MBPS")
                        if let info = state.serverInfo, info.runningAppID == app.id {
                            Badge(text: "RUNNING", tint: .green)
                        }
                    }
                }
            }
            .frame(height: 110, alignment: .leading)
            .padding(.horizontal, 72)
            .animation(Theme.focusSpring, value: state.focus.focusedItemID)
            .introReveal(state.intro.arrived(LaunchIntro.hero), y: 8)

            AppShelf()
                .padding(.top, 18)

            // Two equal spacers float the preset row in the MIDDLE of the space
            // between the games and the hint bar, instead of letting it sink to
            // the bottom edge. One d-pad DOWN from a game either way.
            Spacer(minLength: 24)

            PresetRow()
                .padding(.horizontal, 72)
                .introReveal(state.intro.arrived(LaunchIntro.late), y: 6)

            Spacer(minLength: 24)

            HintBarView()
                .padding(.horizontal, 72)
                .padding(.bottom, 36)
                .introReveal(state.intro.arrived(LaunchIntro.late), y: 6)
        }
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 20) {
            Text("VIBELIGHT")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .tracking(6)
                .foregroundStyle(Theme.textPrimary.opacity(0.9))

            Spacer()

            if let host = state.selectedHost {
                HStack(spacing: 12) {
                    // Wake/power sits left of restart, only while the computer is
                    // wakeable. Shares canWakeSelectedHost with rebuildFocus so the
                    // header:power focus id is emitted iff this view is drawn.
                    if state.canWakeSelectedHost {
                        WakePCButton()
                    }
                    RestartPCButton()
                    HostChip(host: host)
                }
            } else {
                // Fresh user, no computers yet — the way in to add one.
                AddComputerButton()
            }

            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                    .monospacedDigit()
            }
        }
    }
}

/// The "Add Computer" affordance shown before any host exists. Focusable by
/// controller/keyboard (id "header:addhost") so first-run isn't pointer-only.
private struct AddComputerButton: View {
    @Environment(AppState.self) private var state
    private var isFocused: Bool { state.focus.focusedItemID == "header:addhost" }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
            Text("Add Computer")
                .font(.system(size: 15, weight: .bold, design: .rounded))
        }
        .foregroundStyle(Theme.onAccent)   // navy on the solid blue (UX-white-on-accent-contrast)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.accent, in: Capsule())
        .overlay { Capsule().strokeBorder(.white, lineWidth: isFocused ? 2 : 0) }
        .scaleEffect(isFocused ? 1.03 : 1.0)
        .contentShape(Capsule())
        .onTapGesture { state.openHostMenu() }
        .animation(Theme.focusSpring, value: isFocused)
    }
}

/// The top-right computer chip. Clicking it opens the computer manager
/// (switch computers / add one by IP); a chevron hints it's a menu.
private struct HostChip: View {
    @Environment(AppState.self) private var state
    let host: StreamHost
    @State private var hovering = false

    private var isFocused: Bool { state.focus.focusedItemID == "header:host" }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(state.hostOnline ? .green : .orange)
                .frame(width: 9, height: 9)
                .shadow(color: state.hostOnline ? .green.opacity(0.8) : .clear, radius: 5)
            Text(host.name)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            if let error = state.hostError {
                // A real error must never masquerade as "asleep" —
                // that hides pairing/TLS problems behind a wake hint.
                Text(error)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .frame(maxWidth: 420)
            } else if !state.hostOnline {
                Text(host.macAddress != nil ? "asleep" : "offline")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.white.opacity(hovering || isFocused ? 0.12 : 0.06), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Theme.accent, lineWidth: isFocused ? 2 : 0)
        }
        .scaleEffect(isFocused ? 1.03 : 1.0)
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture { state.openHostMenu() }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(Theme.focusSpring, value: isFocused)
    }
}

/// Header button, LEFT of restart: wake the selected computer over the network
/// (Wake-on-LAN). Shown only while the computer is asleep and has a stored MAC —
/// the one time a power-on is useful. Pulses while a wake is in flight so it
/// reads as working during the ~30–60 s the PC takes to boot. (There is no
/// remote power-OFF; see AppState.wakeSelectedHost.)
private struct WakePCButton: View {
    @Environment(AppState.self) private var state
    @State private var hovering = false

    private var isFocused: Bool { state.focus.focusedItemID == "header:power" }
    private var waking: Bool { state.wakingHostID != nil && state.wakingHostID == state.selectedHost?.id }

    var body: some View {
        Button { state.wakeSelectedHost() } label: {
            Image(systemName: "power")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(waking ? Theme.accent
                                 : (hovering || isFocused ? Theme.textPrimary : Theme.textSecondary))
                .frame(width: 38, height: 38)
                .background(.white.opacity(hovering || isFocused ? 0.12 : 0.06), in: Circle())
                .overlay {
                    Circle().strokeBorder(Theme.accent, lineWidth: isFocused ? 2 : 0)
                }
                .symbolEffect(.pulse, options: .repeating, isActive: waking)
                // The 38 pt circle stays the look; on iOS the padding authors a
                // 44 pt tap area, which the iPad canvas scale draws at 35–42 pt
                // (UX-ios-scale-shrinks-text-targets). The Mac keeps 38 pt.
                .padding(Theme.perPlatform(iOS: 3, macOS: 0))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .onHover { hovering = $0 }
        .help(waking ? "Waking…" : "Wake computer")
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(Theme.focusSpring, value: isFocused)
    }
}

/// Header button, left of the host chip: force-restart the selected PC via
/// MoonDeckBuddy. First use walks the user through pairing; after that it's a
/// one-tap confirm → reboot (no dialog on the PC).
private struct RestartPCButton: View {
    @Environment(AppState.self) private var state
    @State private var hovering = false

    private var isFocused: Bool { state.focus.focusedItemID == "header:restart" }

    var body: some View {
        Button { state.requestRestartPC() } label: {
            Image(systemName: "restart")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(hovering || isFocused ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 38, height: 38)
                .background(.white.opacity(hovering || isFocused ? 0.12 : 0.06), in: Circle())
                .overlay {
                    Circle().strokeBorder(Theme.accent, lineWidth: isFocused ? 2 : 0)
                }
                .padding(Theme.perPlatform(iOS: 3, macOS: 0))   // as Wake
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .onHover { hovering = $0 }
        .help("Restart PC")
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(Theme.focusSpring, value: isFocused)
    }
}

private struct Badge: View {
    let text: String
    var tint: Color = Theme.accent

    var body: some View {
        Text(text)
            .font(.system(size: Theme.labelSize(12), weight: .heavy, design: .rounded))
            .tracking(1.2)
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Shelf

private struct AppShelf: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 28) {
                    ForEach(Array(state.apps.enumerated()), id: \.element.id) { index, app in
                        AppTileView(app: app)
                            .id("app:\(state.appKey(app))")
                            .introReveal(state.intro.tileArrived(index))   // left→right cascade
                    }
                }
                .padding(.leading, 72)
                // End-rest padding: at max scroll the last tile parks at the
                // same margin the shelf leads with. (The old right-edge preset
                // rail — and the edge-dissolve mask that kept tiles from
                // sliding under it — is gone: the row lives below the shelf
                // now, so tiles bleed to the screen edge like a proper shelf.)
                .padding(.trailing, 72)
                .padding(.vertical, AppTileView.Metrics.focusPadding)
            }
            // Pin the shelf to its content. Unconstrained, a horizontal
            // ScrollView claims all the vertical space on offer, which pushed
            // everything below it to the bottom of the screen.
            .frame(height: AppTileView.Metrics.shelf)
            .onChange(of: state.focus.focusedItemID) { _, new in
                guard let new, new.hasPrefix("app:") else { return }
                withAnimation(Theme.focusSpring) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
    }
}

/// The preset row under the games shelf: pick which saved settings preset a
/// launch uses. One d-pad DOWN from the shelf (a real focus-engine section,
/// unlike the old right-edge rail's bolt-on focus), or click/tap a chip.
private struct PresetRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PRESETS")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .tracking(2)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                ForEach(0..<AppState.presetSlotCount, id: \.self) { slot in
                    PresetSlotChip(slot: slot)
                        // Equal flexible widths: six chips share the row and cap
                        // at the old rail's 252pt (room for the full
                        // "1440p · 120 fps · 100 Mbps" summary at 11 or 13 pt);
                        // on narrow screens they compress together instead of
                        // wrapping, and the summary shortens to fit.
                        .frame(maxWidth: 252)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One of the six fixed slots. Empty slots show a dashed, ghosted "Empty N";
/// filled slots show the name + summary. Active slot glows with a checkmark;
/// focused slot gets the white ring. Tap a filled slot to apply it; right-click
/// a filled slot to rename or clear it.
private struct PresetSlotChip: View {
    @Environment(AppState.self) private var state
    let slot: Int
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    private var focusID: String { "presetslot:\(slot)" }
    private var preset: StreamPreset? { state.presets[slot] }
    private var isFilled: Bool { preset != nil }
    private var isActive: Bool { state.activePresetSlot == slot }
    private var isFocused: Bool { state.focus.focusedItemID == focusID }
    private var lit: Bool { isActive || isFocused }
    /// Only the ACTIVE chip sits on the full-strength accent; a merely focused
    /// one is a 0.35 tint over the dark backdrop and keeps white ink.
    private var ink: Color { Theme.labelInk(onSolidAccent: isActive) }

    private func summaryLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Theme.labelSize(11), weight: .medium))
            .foregroundStyle(lit ? ink.opacity(0.85) : Theme.textSecondary)
            .lineLimit(1)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(slot + 1)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(lit ? ink : (isFilled ? Theme.accent : Theme.textSecondary))
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(lit ? 0.22 : (isFilled ? 0.1 : 0.05)), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(preset?.name ?? "Empty")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(isFilled ? (lit ? ink : Theme.textPrimary)
                                     : Theme.textSecondary.opacity(0.7))
                    .lineLimit(1)
                if let preset {
                    // The first form that fits, so a narrow chip shows
                    // "1080p · 144 fps" instead of "1080p · 144 fps · 8…".
                    ViewThatFits(in: .horizontal) {
                        summaryLine(preset.summary)
                        summaryLine(preset.shortSummary)
                        summaryLine(preset.resolutionLabel)
                    }
                } else {
                    // Invisible second line: keeps EMPTY chips the exact height
                    // of filled ones. Chips now sit side by side, where a
                    // filled chip's summary line otherwise makes it ~7pt taller
                    // and the row's edges visibly wobble (fine in the old
                    // vertical rail, where heights never shared an edge).
                    Text(" ")
                        .font(.system(size: Theme.labelSize(11), weight: .medium))
                        .hidden()
                }
            }
            Spacer(minLength: 4)
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.onAccent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .contentShape(Rectangle())
        .background(fill, in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(border, style: StrokeStyle(lineWidth: isFocused ? 2.5 : 1,
                                                         dash: isFilled ? [] : [4, 3]))
        }
        .shadow(color: isActive ? Theme.accentGlow : .clear, radius: 12, y: 3)
        .scaleEffect(isFocused ? 1.03 : 1.0)
        // Increase Contrast: an empty slot isn't conveyed by faintness alone.
        .opacity(isFilled || isFocused || contrast == .increased ? 1 : 0.6)
        .animation(Theme.focusSpring, value: isActive)
        .animation(Theme.focusSpring, value: isFocused)
        .animation(Theme.focusSpring, value: isFilled)
        .onHover { over in
            hovering = over
            // Hover-focus parity with the app tiles: pointer and controller
            // share one focus truth (and the same guard against a parked
            // cursor fighting the d-pad).
            if over && state.inputMode == .pointer {
                state.focus.focus(itemID: focusID)
            }
        }
        // Route through pointerSelect so a click focuses the chip and then
        // behaves exactly like pressing A on it (applies when filled).
        .onTapGesture { state.pointerSelect(focusID) }
        .contextMenu {
            if isFilled {
                Button { state.openRename(slot) } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) { state.requestClearSlot(slot) } label: { Label("Clear", systemImage: "trash") }
            }
        }
    }

    private var fill: AnyShapeStyle {
        if isActive { return AnyShapeStyle(Theme.accent) }
        if isFocused { return AnyShapeStyle(Theme.accent.opacity(0.35)) }
        if isFilled { return AnyShapeStyle(Color.white.opacity(hovering && state.inputMode == .pointer ? 0.12 : 0.07)) }
        return AnyShapeStyle(Color.white.opacity(0.03))
    }
    private var border: Color {
        if isFocused { return .white.opacity(0.7) }
        if isActive { return .white.opacity(0.25) }
        return Theme.hairline(isFilled ? 0.08 : 0.14, contrast)
    }
}
