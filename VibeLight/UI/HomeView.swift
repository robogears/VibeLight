import SwiftUI

/// The big-picture home screen: status header, hero title of the focused app,
/// the games shelf, and the input hint bar.
struct HomeView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        content
            // The six preset slots always live on the right edge, vertically
            // centered.
            .overlay(alignment: .trailing) {
                PresetRail()
                    .padding(.trailing, 40)
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderBar()
                .padding(.horizontal, 72)
                .padding(.top, 48)

            Spacer(minLength: 0)

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

            AppShelf()
                .padding(.top, 18)

            Spacer(minLength: 0)

            HintBarView()
                .padding(.horizontal, 72)
                .padding(.bottom, 36)
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
                    RestartPCButton()
                    HostChip(host: host)
                }
            } else {
                // Fresh user, no computers yet — the way in to add one.
                Button { state.openHostMenu() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Computer")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
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
            .font(.system(size: 12, weight: .heavy, design: .rounded))
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
                    ForEach(state.apps) { app in
                        AppTileView(app: app)
                            .id("app:\(state.appKey(app))")
                    }
                }
                .padding(.leading, 72)
                // Leave room on the right for the always-present preset rail so
                // tiles don't scroll under it.
                .padding(.trailing, 260)
                .padding(.vertical, 40) // headroom for the focus scale/glow
            }
            .onChange(of: state.focus.focusedItemID) { _, new in
                guard let new, new.hasPrefix("app:") else { return }
                withAnimation(Theme.focusSpring) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
    }
}

/// The right-side preset rail: pick which saved settings preset a launch uses.
/// Reached by pressing right off the end of the app shelf (or clicking).
private struct PresetRail: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            Text("PRESETS")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .tracking(2)
                .foregroundStyle(Theme.textSecondary)
            ForEach(0..<AppState.presetSlotCount, id: \.self) { slot in
                PresetSlotChip(slot: slot)
            }
        }
        .frame(width: 252)   // fits the full "1440p · 120 fps · 100 Mbps" summary
    }
}

/// One of the six fixed slots. Empty slots show a dashed, ghosted "Empty N";
/// filled slots show the name + summary. Active slot glows with a checkmark;
/// focused slot gets the white ring. Tap a filled slot to apply it; right-click
/// a filled slot to rename or clear it.
private struct PresetSlotChip: View {
    @Environment(AppState.self) private var state
    let slot: Int
    @State private var hovering = false

    private var preset: StreamPreset? { state.presets[slot] }
    private var isFilled: Bool { preset != nil }
    private var isActive: Bool { state.activePresetSlot == slot }
    private var isFocused: Bool { state.focusedPresetSlot == slot }
    private var lit: Bool { isActive || isFocused }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(slot + 1)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(lit ? .white : (isFilled ? Theme.accent : Theme.textSecondary))
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(lit ? 0.22 : (isFilled ? 0.1 : 0.05)), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(preset?.name ?? "Empty")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(isFilled ? (lit ? .white : Theme.textPrimary)
                                     : Theme.textSecondary.opacity(0.7))
                    .lineLimit(1)
                if let preset {
                    Text(preset.summary)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(lit ? .white.opacity(0.85) : Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
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
        .opacity(isFilled || isFocused ? 1 : 0.6)
        .animation(Theme.focusSpring, value: isActive)
        .animation(Theme.focusSpring, value: isFocused)
        .animation(Theme.focusSpring, value: isFilled)
        .onHover { hovering = $0 }
        .onTapGesture { if isFilled { state.applySlot(slot) } }
        .contextMenu {
            if isFilled {
                Button { state.openRename(slot) } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) { state.clearSlot(slot) } label: { Label("Clear", systemImage: "trash") }
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
        return .white.opacity(isFilled ? 0.08 : 0.14)
    }
}
