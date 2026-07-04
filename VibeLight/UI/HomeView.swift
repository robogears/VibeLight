import SwiftUI

/// The big-picture home screen: status header, hero title of the focused app,
/// the games shelf, and the input hint bar.
struct HomeView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        content
            .overlay(alignment: .trailing) {
                if !state.presets.isEmpty {
                    PresetRail()
                        .padding(.trailing, 40)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(Theme.focusSpring, value: state.presets.count)
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
                        Badge(text: "\(state.settings.fps) FPS")
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
                HostChip(host: host)
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
        .background(.white.opacity(hovering ? 0.12 : 0.06), in: Capsule())
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture { state.openHostMenu() }
        .animation(.easeOut(duration: 0.12), value: hovering)
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
                // Leave room on the right for the preset rail so tiles don't
                // scroll under it.
                .padding(.trailing, state.presets.isEmpty ? 72 : 260)
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
        VStack(alignment: .trailing, spacing: 12) {
            Text("PRESETS")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .tracking(2)
                .foregroundStyle(Theme.textSecondary)
            ForEach(state.presets) { preset in
                PresetChip(preset: preset)
            }
        }
        .frame(width: 210)
    }
}

private struct PresetChip: View {
    @Environment(AppState.self) private var state
    let preset: StreamPreset
    @State private var hovering = false

    private var isActive: Bool { state.activePresetID == preset.id }
    private var isFocused: Bool { state.focusedPresetID == preset.id }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(isActive || isFocused ? .white : Theme.textPrimary)
                Text(preset.summary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive || isFocused ? .white.opacity(0.85) : Theme.textSecondary)
            }
            Spacer(minLength: 4)
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(
            isActive ? Theme.accent
                     : (isFocused ? Theme.accent.opacity(0.35)
                        : Color.white.opacity(hovering && state.inputMode == .pointer ? 0.12 : 0.06)),
            in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isFocused ? .white.opacity(0.7) : .white.opacity(isActive ? 0.25 : 0.06),
                              lineWidth: isFocused ? 2.5 : 1)
        }
        .shadow(color: isActive ? Theme.accentGlow : .clear, radius: 14, y: 3)
        .scaleEffect(isFocused ? 1.03 : 1.0)
        .animation(Theme.focusSpring, value: isActive)
        .animation(Theme.focusSpring, value: isFocused)
        .onHover { hovering = $0 }
        .onTapGesture { state.applyPreset(preset.id) }
    }
}
