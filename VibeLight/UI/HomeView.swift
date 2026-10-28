import SwiftUI

/// The big-picture home screen: status header, hero title of the focused app,
/// the games shelf with the preset row directly beneath it, and the input
/// hint bar. Every piece dresses for the selected theme (Settings ▸ Themes);
/// the layout and focus ids are the same in all of them.
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
            VStack(alignment: .leading, spacing: Theme.current == .nightEdition ? 14 : 10) {
                if let app = state.focusedApp {
                    HeroTitle(name: app.name)
                        .id("hero-\(state.appKey(app))")
                        .transition(HeroTitle.transition)
                    BadgeRow(items: heroBadges(for: app))
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
        // Grid 72's index numeral, huge and faint behind the hero and shelf.
        .background(alignment: .topTrailing) {
            if Theme.current.isGrid {
                GridIndex()
                    .padding(.top, 88)
                    .padding(.trailing, 66)
                    .introReveal(state.intro.arrived(LaunchIntro.hero), y: 8)
            }
        }
        // Kabuki Cut's hit of white as the hero changes.
        .overlay {
            if Theme.current == .kabukiCut {
                KabukiFlash(key: state.focusedApp.map { state.appKey($0) })
            }
        }
    }

    /// The hero's badges: the stream's numbers, which preset they are, and
    /// RUNNING when this game is the one live on the PC.
    private func heroBadges(for app: StreamApp) -> [BadgeItem] {
        var items: [BadgeItem] = []
        if app.isHDRSupported && state.settings.hdr {
            items.append(BadgeItem(id: "hdr", text: "HDR"))
        }
        // Same friendly labels as the Settings rows ("1080p", "4K", raw W×H
        // for customs; whole-number Mbps).
        items.append(BadgeItem(id: "res", text: state.value(for: .resolution)))
        items.append(BadgeItem(id: "fps", text: "\(state.settings.fps) FPS"))
        items.append(BadgeItem(id: "rate", text: "\(state.settings.bitrateKbps / 1000) MBPS"))
        // Which preset those numbers are; orange once changed.
        if let preset = state.activePreset {
            let edited = state.isActivePresetEdited
            items.append(BadgeItem(id: "preset",
                                   text: edited ? "\(preset.name.uppercased()) · EDITED" : preset.name.uppercased(),
                                   kind: .preset(edited: edited)))
        }
        if let info = state.serverInfo, info.runningAppID == app.id {
            items.append(BadgeItem(id: "running", text: "RUNNING", kind: .running))
        }
        return items
    }
}

// MARK: - Hero

/// The focused game's name in the theme's voice, and its entrance: Default's
/// soft rise (the hero's transition); Night Edition's line set from beneath a
/// hairline that rules itself in; Grid 72's short slide; Kabuki Cut's crimson
/// slab that wipes in and the name that slams onto it. Reduce Motion: the
/// themes just change the name.
private struct HeroTitle: View {
    let name: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    /// Default keeps its fade-and-rise as the transition. The themes animate
    /// inside (so the entrance can be clipped and timed) and the name they
    /// replace leaves at once — the spec swaps the text, then animates the new.
    static var transition: AnyTransition {
        Theme.current == .default ? .opacity.combined(with: .offset(y: 8)) : .identity
    }

    private var shown: Bool { arrived || reduceMotion }

    var body: some View {
        switch Theme.current {
        case .default:
            Text(name)
                .font(.system(size: 52, weight: .black, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        case .nightEdition:
            Text(name)
                .themeText(.hero)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64, alignment: .bottomLeading)
                .offset(y: shown ? 0 : 49)
                .opacity(shown ? 1 : 0)
                .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32), value: shown)
                .padding(.bottom, 4)
                .clipped()   // after the offset: the line rises from under the rule
                .overlay(alignment: .bottomLeading) {
                    Rectangle()
                        .fill(Theme.ink.opacity(0.5))
                        .frame(height: 1)
                        .scaleEffect(x: shown ? 1 : 0, anchor: .leading)
                        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.38), value: shown)
                }
                .onAppear { arrived = true }
        case .grid72, .grid72Dark:
            Text(name)
                .themeText(.hero)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .offset(x: shown ? 0 : -16)
                .animation(.timingCurve(0.2, 0, 0, 1, duration: 0.18), value: shown)
                .onAppear { arrived = true }
        case .kabukiCut:
            Text(name)
                .themeText(.hero)
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(height: 60)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .padding(.leading, 18)
                .padding(.trailing, 26)
                // The slam: the name lands on the slab a beat after it wipes in.
                .scaleEffect(shown ? 1 : 1.35)
                .opacity(shown ? 1 : 0)
                .animation(.spring(response: 0.2, dampingFraction: 0.55).delay(0.07), value: shown)
                .background(Theme.accent)
                .background { Color.white.offset(x: 8, y: 8) }
                .scaleEffect(x: shown ? 1 : 0, y: 1, anchor: .leading)
                .animation(.timingCurve(0.2, 0, 0, 1, duration: 0.16), value: shown)
                .slanted(-8, pivot: 36)
                .onAppear { arrived = true }
        }
    }
}

/// One hero badge: what it says and what kind of fact it is.
struct BadgeItem: Identifiable {
    let id: String
    let text: String
    var kind: Badge.Kind = .spec
}

/// The hero's badges in the theme's arrangement: pills in a row (Default), one
/// printed line between dots (Night Edition), columns between ink rules (Grid
/// 72), slanted slabs (Kabuki Cut). Also on the starting card.
struct BadgeRow: View {
    let items: [BadgeItem]

    var body: some View {
        switch Theme.current {
        case .default:
            HStack(spacing: 12) {
                ForEach(items) { Badge(text: $0.text, kind: $0.kind) }
            }
        case .nightEdition:
            HStack(spacing: 0) {
                ForEach(items) { item in
                    if item.id != items.first?.id {
                        Text("·")
                            .themeText(.badge)
                            .foregroundStyle(Theme.ink.opacity(0.4))
                            .padding(.horizontal, 10)
                    }
                    Badge(text: item.text, kind: item.kind)
                }
            }
        case .grid72, .grid72Dark:
            HStack(spacing: 0) {
                ForEach(items) { item in
                    let first = item.id == items.first?.id
                    if !first {
                        Rectangle().fill(Theme.ink).frame(width: 1.5, height: 15)
                    }
                    Badge(text: item.text, kind: item.kind)
                        .padding(.leading, first ? 0 : 14)
                        .padding(.trailing, 14)
                }
            }
            .padding(.top, 2)
        case .kabukiCut:
            HStack(spacing: 10) {
                ForEach(items) { Badge(text: $0.text, kind: $0.kind) }
            }
            .padding(.leading, 4)
        }
    }
}

struct Badge: View {   // also on the starting card (PosterLiftCard)
    /// What the badge says about the stream: a number, which preset, or that
    /// the game is running.
    enum Kind: Equatable {
        case spec
        case preset(edited: Bool)
        case running
    }

    let text: String
    var kind: Kind = .spec

    var body: some View {
        switch Theme.current {
        case .default:
            Text(text)
                .font(.system(size: Theme.labelSize(12), weight: .heavy, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        case .nightEdition:
            // Printed words; RUNNING carries its green dot after it.
            HStack(spacing: 7) {
                Text(text).themeText(.badge).foregroundStyle(words)
                if kind == .running {
                    Circle().fill(Theme.live).frame(width: 7, height: 7)
                }
            }
        case .grid72, .grid72Dark:
            Text(text).themeText(.badge).foregroundStyle(words)
        case .kabukiCut:
            Text(text)
                .themeText(.badge)
                .foregroundStyle(slab == .black ? Color.white : Color.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background { SlantedRect(Theme.slant).fill(slab) }
                .overlay {
                    if case .preset(let edited) = kind {
                        SlantedRect(Theme.slant).strokeBorder(edited ? Theme.edited : Theme.accent, lineWidth: 2)
                    }
                }
        }
    }

    /// Default's pill colour: the accent for numbers, white for the preset
    /// (orange once edited), green for RUNNING.
    private var tint: Color {
        switch kind {
        case .spec: Theme.accent
        case .preset(let edited): edited ? Theme.edited : Theme.textPrimary
        case .running: Theme.live
        }
    }

    /// The printed themes' word colour: quiet numbers (ink on Grid 72), the
    /// accent's text cut for the preset, green for RUNNING.
    private var words: Color {
        switch kind {
        case .spec: Theme.current.isGrid ? Theme.textPrimary : Theme.textSecondary
        case .preset(let edited): edited ? Theme.editedText : Theme.accentText
        case .running: Theme.liveText
        }
    }

    /// Kabuki's slab: white for numbers, black for the preset, lime for RUNNING.
    private var slab: Color {
        switch kind {
        case .spec: .white
        case .preset: .black
        case .running: Theme.live
        }
    }
}

/// Grid 72's index: which game is focused, of how many, set huge and faint at
/// the top right. It flips with focus — the screen's only ambient life.
private struct GridIndex: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var number: Int? {
        guard let app = state.focusedApp,
              let index = state.apps.firstIndex(where: { $0.id == app.id }) else { return nil }
        return index + 1
    }

    var body: some View {
        if let number {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(twoDigits(number))
                    .font(ThemeFace.archivoExpandedBlack.font(300))
                    .tracking(-12)
                    .foregroundStyle(Theme.palette.isLight ? Color(hex: 0xE4E3DE) : Theme.ink.opacity(0.06))
                    .contentTransition(.numericText(value: Double(number)))
                Text("/" + twoDigits(state.apps.count))
                    .font(ThemeFace.archivoExpandedBlack.font(90))
                    .foregroundStyle(Theme.palette.isLight ? Color(hex: 0xD9D8D2) : Theme.ink.opacity(0.1))
            }
            .monospacedDigit()
            .animation(reduceMotion ? nil : Theme.focusSpring, value: number)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Kabuki Cut's hit: one 140 ms frame of white at 50 % when the hero changes.
/// Never more than about twice a second however fast focus moves (WCAG 2.3.1
/// allows three flashes), and never under Reduce Motion.
private struct KabukiFlash: View {
    let key: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hits = 0
    @State private var last = Date.distantPast

    var body: some View {
        Color.white
            .phaseAnimator(FlashPhase.allCases, trigger: hits) { flash, phase in
                flash.opacity(phase.strength)
            } animation: { phase in
                phase == .lit ? Animation.linear(duration: 0.02) : Animation.easeOut(duration: 0.14)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
            .onChange(of: key) { _, new in
                guard new != nil, !reduceMotion, Date().timeIntervalSince(last) > 0.4 else { return }
                last = Date()
                hits += 1
            }
    }

    private enum FlashPhase: CaseIterable {
        case rest, lit, fade
        var strength: Double { self == .lit ? 0.5 : 0 }
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 20) {
            Wordmark()

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
            }
            // No computer yet: the way in is the empty shelf's big Add Computer
            // button (it carries `header:addhost`), not a pill up here — one
            // view per focus id (UX-empty-home-no-invitation).

            HeaderClock()
        }
        // Night Edition's masthead rule: two hairlines under the header.
        .overlay(alignment: .bottom) {
            if Theme.current == .nightEdition {
                VStack(spacing: 2) {
                    Rectangle().frame(height: 1)
                    Rectangle().frame(height: 1)
                }
                .foregroundStyle(Theme.ink.opacity(0.55))
                .offset(y: 8)
                .allowsHitTesting(false)
            }
        }
    }
}

/// The masthead: Default's tracked SF Rounded; Night Edition's Fraunces; Grid
/// 72's expanded capitals after a red square; Kabuki Cut's V in a slanted
/// crimson block.
private struct Wordmark: View {
    var body: some View {
        switch Theme.current {
        case .default:
            Text("VIBELIGHT")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .tracking(6)
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
        case .nightEdition:
            Text("VIBELIGHT")
                .themeText(.wordmark)
                .foregroundStyle(Theme.textPrimary)
        case .grid72, .grid72Dark:
            HStack(spacing: 12) {
                Rectangle().fill(Theme.accent).frame(width: 12, height: 12)
                Text("VIBELIGHT")
                    .themeText(.wordmark)
                    .foregroundStyle(Theme.textPrimary)
            }
        case .kabukiCut:
            HStack(spacing: 6) {
                Text("V")
                    .themeText(.wordmark)
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent)
                    .slanted(Theme.slant, pivot: 17)
                Text("IBELIGHT")
                    .themeText(.wordmark)
                    .foregroundStyle(Theme.textPrimary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("VibeLight")
        }
    }
}

/// The header clock. Grid 72's is a railway clock — it shows seconds; Kabuki
/// Cut's casts a hard crimson shadow.
private struct HeaderClock: View {
    var body: some View {
        switch Theme.current {
        case .default:
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                    .monospacedDigit()
            }
        case .grid72, .grid72Dark:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, format: .dateTime.hour().minute().second())
                    .themeText(.clock)
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
            }
        case .nightEdition, .kabukiCut:
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .themeText(.clock)
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                    .shadow(color: Theme.current == .kabukiCut ? Theme.accent : .clear, radius: 0, x: 3, y: 3)
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
    /// Kabuki Cut's chip is a white slab (crimson when focused), so its words
    /// are dark on it.
    private var onSlab: Bool { Theme.current == .kabukiCut }
    private var ink: Color { onSlab ? (isFocused ? .white : .black) : Theme.textPrimary }
    private var inkSecondary: Color {
        onSlab ? (isFocused ? .white.opacity(0.85) : .black.opacity(0.62)) : Theme.textSecondary
    }
    private var inkWarning: Color { onSlab ? (isFocused ? .white : Color(hex: 0xA34700)) : Theme.warning }

    var body: some View {
        HStack(spacing: 10) {
            dot
            Text(host.name)
                .themeText(.hostName)
                .foregroundStyle(ink)
            // A real error must never masquerade as "asleep" — that hides
            // pairing/TLS problems behind a wake hint (AppState.hostBanner).
            switch state.hostBanner {
            case .error(let error):
                // Two lines, never "…": the full text is also in the Computers
                // card this chip opens (UX-host-banner-truncates).
                // WidthCap, not .frame(maxWidth: 420): that frame always grows
                // to 420 when there's room, so a short "is offline" left a long
                // empty bar after it. The chip now ends where the text ends.
                WidthCap(max: 420) {
                    Text(AppState.chipBannerText(error, hostName: host.name))
                        .font(Theme.ui(13, .medium, design: .default))
                        .foregroundStyle(inkWarning)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .notice(let notice):
                // Normal progress (a restart) — neutral, with a spinner.
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(inkSecondary)
                    Text(notice)
                        .font(Theme.ui(13, .medium, design: .default))
                        .foregroundStyle(inkSecondary)
                }
            case .status(let status):
                Text(status)
                    .font(Theme.ui(13, .medium, design: .default))
                    .foregroundStyle(inkSecondary)
            case nil:
                EmptyView()
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(inkSecondary)
        }
        .modifier(HostChipChrome(isFocused: isFocused, hovering: hovering))
        .onHover { hovering = $0 }
        .onTapGesture { state.openHostMenu() }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(Theme.focusSpring, value: isFocused)
    }

    /// The status dot: round in Default and Night Edition, square in Grid 72
    /// and Kabuki Cut. On Kabuki's white slab the theme's lime would vanish,
    /// so its colours are deeper there.
    @ViewBuilder private var dot: some View {
        switch Theme.current {
        case .default:
            Circle()
                .fill(state.selectedHostDot.color)
                .frame(width: 9, height: 9)
                .shadow(color: state.hostOnline ? .green.opacity(0.8) : .clear, radius: 5)
        case .nightEdition:
            Circle()
                .fill(state.selectedHostDot.color)
                .frame(width: 9, height: 9)
        case .grid72, .grid72Dark:
            Rectangle()
                .fill(state.selectedHostDot.color)
                .frame(width: 9, height: 9)
        case .kabukiCut:
            Rectangle()
                .fill(slabDot)
                .frame(width: 9, height: 9)
        }
    }

    private var slabDot: Color {
        if isFocused { return .white }
        switch state.selectedHostDot {
        case .online: return Color(hex: 0x2F7D00)
        case .unreachable: return Theme.accent
        case .attention: return Color(hex: 0xC25E00)
        }
    }
}

/// The host chip's plate: Default's pill; Night Edition's bare words (a 2 pt
/// frame when focused); Grid 72's ink-ruled box; Kabuki Cut's slanted white
/// slab that turns crimson when focused.
private struct HostChipChrome: ViewModifier {
    let isFocused: Bool
    let hovering: Bool

    @ViewBuilder func body(content: Content) -> some View {
        switch Theme.current {
        case .default:
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.white.opacity(hovering || isFocused ? 0.12 : 0.06), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Theme.accent, lineWidth: isFocused ? 2 : 0)
                }
                .scaleEffect(isFocused ? 1.03 : 1.0)
                .contentShape(Capsule())
        case .nightEdition:
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Theme.ink.opacity(hovering ? 0.06 : 0), in: Theme.plate(2))
                .overlay {
                    Theme.plate(2).strokeBorder(Theme.accent, lineWidth: isFocused ? 2 : 0)
                }
                .contentShape(Rectangle())
        case .grid72, .grid72Dark:
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Theme.ink.opacity(hovering ? 0.06 : 0), in: Rectangle())
                .overlay {
                    Rectangle().strokeBorder(isFocused ? Theme.accent : Theme.ink, lineWidth: isFocused ? 2.5 : 1.5)
                }
                .contentShape(Rectangle())
        case .kabukiCut:
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background {
                    SlantedRect(Theme.slant).fill(isFocused ? Theme.accent : Color.white.opacity(hovering ? 0.88 : 1))
                }
                .scaleEffect(isFocused ? 1.03 : 1.0)
                .contentShape(Rectangle())
        }
    }
}

/// The header's round buttons (Wake, Restart): Default's soft circle, Night
/// Edition's ruled ring, Grid 72's ink square, Kabuki Cut's slanted white block.
private struct HeaderButtonChrome: ViewModifier {
    let isFocused: Bool
    let hovering: Bool

    @ViewBuilder func body(content: Content) -> some View {
        switch Theme.current {
        case .default:
            content
                .frame(width: 38, height: 38)
                .background(.white.opacity(hovering || isFocused ? 0.12 : 0.06), in: Circle())
                .overlay {
                    Circle().strokeBorder(Theme.accent, lineWidth: isFocused ? 2 : 0)
                }
        case .nightEdition:
            content
                .frame(width: 38, height: 38)
                .background(Theme.ink.opacity(hovering ? 0.06 : 0), in: Circle())
                .overlay {
                    Circle().strokeBorder(isFocused ? Theme.accent : Theme.ink.opacity(0.5),
                                          lineWidth: isFocused ? 2 : 1)
                }
        case .grid72, .grid72Dark:
            content
                .frame(width: 38, height: 38)
                .background(Theme.ink.opacity(hovering ? 0.06 : 0), in: Rectangle())
                .overlay {
                    Rectangle().strokeBorder(isFocused ? Theme.accent : Theme.ink, lineWidth: isFocused ? 2.5 : 1.5)
                }
        case .kabukiCut:
            content
                .frame(width: 38, height: 38)
                .background {
                    SlantedRect(Theme.slant).fill(isFocused ? Theme.accent : Color.white.opacity(hovering ? 0.88 : 1))
                }
        }
    }

    /// The glyph on that chrome: the accent while a wake is under way, then
    /// Default's dim-until-hovered grey, ink on the printed themes, and black
    /// (white when focused) on Kabuki's slab.
    static func glyph(focused: Bool, hovering: Bool, busy: Bool = false) -> Color {
        switch Theme.current {
        case .default:
            busy ? Theme.accent : (hovering || focused ? Theme.textPrimary : Theme.textSecondary)
        case .kabukiCut:
            focused ? .white : (busy ? Theme.accent : .black)
        case .nightEdition, .grid72, .grid72Dark:
            busy ? Theme.accentText : Theme.textPrimary
        }
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
                .foregroundStyle(HeaderButtonChrome.glyph(focused: isFocused, hovering: hovering, busy: waking))
                .modifier(HeaderButtonChrome(isFocused: isFocused, hovering: hovering))
                .symbolEffect(.pulse, options: .repeating, isActive: waking)
                // The 38 pt button stays the look; on iOS the padding authors a
                // 44 pt tap area, which the iPad canvas scale draws at 35–42 pt
                // (UX-ios-scale-shrinks-text-targets). The Mac keeps 38 pt.
                .padding(Theme.perPlatform(iOS: 3, macOS: 0))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isFocused ? Theme.focusScale(1.06) : 1.0)
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
                .foregroundStyle(HeaderButtonChrome.glyph(focused: isFocused, hovering: hovering))
                .modifier(HeaderButtonChrome(isFocused: isFocused, hovering: hovering))
                .padding(Theme.perPlatform(iOS: 3, macOS: 0))   // as Wake
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isFocused ? Theme.focusScale(1.06) : 1.0)
        .onHover { hovering = $0 }
        .help("Restart PC")
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(Theme.focusSpring, value: isFocused)
    }
}

// MARK: - Shelf

private struct AppShelf: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let empty = state.emptyShelf {
            // Nothing to show: say why and offer the next step, in the shelf's
            // own frame so the preset row below doesn't move.
            EmptyShelfPanel(shelf: empty)
                .padding(.leading, 72)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: AppTileView.Metrics.shelf)
                .introReveal(state.intro.tileArrived(0))
        } else if #available(iOS 18, macOS 15, *) {
            ShelfScroller()
        } else {
            LegacyShelfScroller()
        }
    }
}

/// The games row's contents, shared by both scrollers.
private struct ShelfTiles: View {
    @Environment(AppState.self) private var state

    var body: some View {
        LazyHStack(alignment: .top, spacing: ShelfScroll.spacing) {
            ForEach(Array(state.apps.enumerated()), id: \.element.id) { index, app in
                AppTileView(app: app)
                    .id("app:\(state.appKey(app))")
                    .introReveal(state.intro.tileArrived(index))   // left→right cascade
            }
        }
        .padding(.leading, ShelfScroll.leading)
        // End-rest padding: at max scroll the last tile parks at the same
        // margin the shelf leads with. (The old right-edge preset rail — and
        // the edge-dissolve mask that kept tiles from sliding under it — is
        // gone: the row lives below the shelf now, so tiles bleed to the
        // screen edge like a proper shelf.)
        .padding(.trailing, ShelfScroll.trailing)
        .padding(.vertical, AppTileView.Metrics.focusPadding)
        // Grid 72's focus is one red bar that slides along the row.
        .overlay(alignment: .topLeading) {
            if Theme.current.isGrid { GridFocusBar() }
        }
    }
}

/// Grid 72's focus: a 6 pt red bar along the bottom edge of the focused tile's
/// art, sliding from tile to tile in 180 ms (120 ms under Reduce Motion). One
/// view for the whole row, as in the spec, so it travels rather than blinks.
private struct GridFocusBar: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var focusedIndex: Int? {
        guard let id = state.focus.focusedItemID, id.hasPrefix("app:") else { return nil }
        return state.apps.firstIndex { "app:\(state.appKey($0))" == id }
    }

    var body: some View {
        if let index = focusedIndex, state.intro.focusReady {
            Rectangle()
                .fill(Theme.accent)
                .frame(width: ShelfScroll.tile, height: 6)
                .offset(x: ShelfScroll.leading + CGFloat(index) * (ShelfScroll.tile + ShelfScroll.spacing),
                        y: AppTileView.Metrics.focusPadding + AppTileView.Metrics.art.height - 2)
                .animation(reduceMotion ? .easeOut(duration: 0.12) : Theme.focusSpring, value: index)
                .allowsHitTesting(false)
        }
    }
}

/// The shelf, scrolled to EXACT offsets. `scrollTo(id, anchor:)` with a
/// computed anchor still jumped a whole tile on the first move (owner's
/// screenshot: one step right put Desktop half off the left edge), so the
/// row no longer asks SwiftUI to line anything up: it reads the scroll
/// view's real width, content and offset, and sets the offset itself.
@available(iOS 18, macOS 15, *)
private struct ShelfScroller: View {
    @Environment(AppState.self) private var state
    @State private var position = ScrollPosition(edge: .leading)
    @State private var geometry = ShelfScroll.Geometry()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ShelfTiles()
        }
        .scrollPosition($position)
        // Pin the shelf to its content. Unconstrained, a horizontal
        // ScrollView claims all the vertical space on offer, which pushed
        // everything below it to the bottom of the screen.
        .frame(height: AppTileView.Metrics.shelf)
        // Live, including where a swipe or trackpad left it.
        .onScrollGeometryChange(for: ShelfScroll.Geometry.self) { g in
            ShelfScroll.Geometry(offset: g.contentOffset.x, viewport: g.containerSize.width,
                                 content: g.contentSize.width)
        } action: { _, new in
            geometry = new
        }
        .onChange(of: state.focus.focusedItemID) { _, new in
            guard let new, new.hasPrefix("app:"),
                  let index = state.apps.firstIndex(where: { "app:\(state.appKey($0))" == new })
            else { return }
            let x = ShelfScroll.offset(index: index, from: geometry)
            guard abs(x - geometry.offset) > 0.5 else { return }   // already on screen: hold still
            withAnimation(Theme.focusSpring) { position.scrollTo(x: x) }
        }
    }
}

/// iOS 17 has no exact-offset scrolling, so it keeps the anchor route — with
/// the same "only when it must" rule, from where it last put the row.
private struct LegacyShelfScroller: View {
    @Environment(AppState.self) private var state
    @State private var geometry = ShelfScroll.Geometry()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                ShelfTiles()
            }
            .frame(height: AppTileView.Metrics.shelf)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { geometry.viewport = $0 }
            .onChange(of: state.focus.focusedItemID) { _, new in
                guard let new, new.hasPrefix("app:"), geometry.viewport > 0,
                      let index = state.apps.firstIndex(where: { "app:\(state.appKey($0))" == new })
                else { return }
                geometry.content = ShelfScroll.contentWidth(count: state.apps.count)
                let x = ShelfScroll.offset(index: index, from: geometry)
                guard abs(x - geometry.offset) > 0.5 else { return }
                geometry.offset = x
                withAnimation(Theme.focusSpring) {
                    proxy.scrollTo(new, anchor: ShelfScroll.anchor(index: index, offset: x,
                                                                   viewport: geometry.viewport))
                }
            }
        }
    }
}

/// Where the games row scrolls when focus lands on a tile (owner: hold still
/// "until it really needs to change"). Nothing moves while the selected tile
/// — and a peek of the one beyond it — is already on screen; past that the
/// row moves just far enough, one tile per step, and never past either end.
/// Pure, so the rule is tested; sizes mirror `ShelfTiles`' layout.
enum ShelfScroll {
    static let leading: CGFloat = 72
    static let trailing: CGFloat = 72
    static let spacing: CGFloat = 28
    static var tile: CGFloat { AppTileView.Metrics.art.width }
    /// Room kept beside the selected tile: the shelf's own margin plus about
    /// half a neighbouring tile, so you can see there's more that way.
    static var margin: CGFloat { leading + tile / 2 }

    /// The scroll view as the row last saw it.
    struct Geometry: Equatable {
        var offset: CGFloat = 0     // content offset (x)
        var viewport: CGFloat = 0   // visible width
        var content: CGFloat = 0    // full row width
    }

    static func contentWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return leading + CGFloat(count) * tile + CGFloat(count - 1) * spacing + trailing
    }

    /// The offset for focus on tile `index`, starting from where the row is.
    static func offset(index: Int, from g: Geometry) -> CGFloat {
        guard g.viewport > 0 else { return g.offset }
        let left = leading + CGFloat(index) * (tile + spacing)
        let right = left + tile
        var x = g.offset
        if left - margin < x { x = left - margin }                      // going left: just enough
        if right + margin > x + g.viewport { x = right + margin - g.viewport }   // going right
        return min(max(x, 0), max(0, g.content - g.viewport))
    }

    /// The `scrollTo` anchor that puts tile `index` exactly where `offset`
    /// leaves it. `scrollTo(id, anchor: a)` lines up the point at fraction
    /// `a.x` of the tile with the same fraction of the viewport, so the
    /// tile's left edge lands at `a.x × (viewport − tile)`.
    static func anchor(index: Int, offset: CGFloat, viewport: CGFloat) -> UnitPoint {
        let left = leading + CGFloat(index) * (tile + spacing) - offset
        let room = viewport - tile
        guard room > 0 else { return .center }
        return UnitPoint(x: min(max(left / room, 0), 1), y: 0.5)
    }
}

/// What the games shelf shows when it has nothing to show — a new user with no
/// computer, a PC that's asleep or unpaired, or one with no games — with the
/// one button that moves things forward (UX-empty-home-no-invitation). Which
/// button is drawn comes from `AppState.emptyShelfFocusIDs`, the same ids
/// rebuildFocus emits.
private struct EmptyShelfPanel: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast
    let shelf: AppState.EmptyShelf

    private var name: String { state.selectedHost?.name ?? "Your computer" }

    private var symbol: String {
        switch shelf {
        case .noComputer, .notPaired, .checking: "desktopcomputer"
        case .asleep, .waking: "moon.zzz.fill"
        case .offline: "power"
        case .notResponding, .problem: "exclamationmark.triangle.fill"
        case .noGames: "square.grid.2x2"
        }
    }

    private var title: String {
        switch shelf {
        case .noComputer: "Add your gaming PC"
        // A computer that WAS paired (certificate changed, or it now refuses
        // us) needs pairing again — "isn't paired yet" would be wrong.
        case .notPaired: state.selectedHost?.isPaired == true ? "Pair \(name) again" : "\(name) isn't paired yet"
        case .checking: "Looking for \(name)…"
        case .asleep: "\(name) is asleep"
        case .waking: "Waking \(name)…"
        case .offline: "\(name) is offline"
        case .notResponding: "\(name) is offline"
        case .problem: "Couldn't load games from \(name)"
        case .noGames: "No games on \(name) yet"
        }
    }

    private var message: String {
        switch shelf {
        // A saved-computers warning has nowhere else to show with no
        // computer selected (the header chip isn't drawn).
        case .noComputer: state.hostError ?? "Its games will show up here."
        case .notPaired: "Pair it to see its games."
        case .checking: "Checking whether it's awake."
        case .asleep: "Wake it to load your games."
        case .waking: "This usually takes 30–60 seconds."
        case .offline: "Turn it on to load your games."
        case .notResponding: "Restart its streaming service on the PC."
        case .problem: "What went wrong is shown beside its name at the top."
        case .noGames: "Add them in Sunshine, Apollo or Vibepollo on the PC — they show up here."
        }
    }

    private var isWarning: Bool { shelf == .noComputer && state.hostError != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(shelf == .notResponding || shelf == .problem ? Theme.warning : Theme.accent)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.ui(22, .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Theme.ui(15, .medium, design: .default))
                // A saved-computers warning is orange, as everywhere else
                // (DESIGN.md › Semantic colours); the normal invitation is not.
                .foregroundStyle(isWarning ? Theme.warning
                                 : contrast == .increased ? Theme.textPrimary.opacity(0.85) : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if shelf == .noComputer {
                OverlayButton(id: "header:addhost", title: "Add Computer", symbol: "plus.circle.fill")
                    .padding(.top, 8)
            } else if shelf == .waking || shelf == .checking {
                ProgressView()
                    .padding(.top, 8)
            } else {
                ForEach(AppState.emptyShelfFocusIDs(shelf), id: \.self) { id in
                    OverlayButton(id: id,
                                  title: id == "shelf:pair" ? "Pair Computer" : "Wake Computer",
                                  symbol: id == "shelf:pair" ? "link" : "power")
                        .padding(.top, 8)
                }
            }
        }
        .padding(28)
        .frame(width: 416, alignment: .leading)
        .background(Theme.surface.opacity(0.6), in: Theme.plate(13))
        .overlay {
            Theme.plate(13)
                .strokeBorder(Theme.current.isGrid ? Theme.ink : Theme.hairline(0.08, contrast),
                              lineWidth: Theme.current.isGrid ? 1.5 : 1)
        }
    }
}

/// The preset row under the games shelf — "Live Loadout" (owner's pick, Oct
/// 2026). One chip per saved preset, "+" last when the live settings aren't
/// saved anywhere. One d-pad DOWN from the shelf, or click/tap a chip.
private struct PresetRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PRESETS")
                .themeText(.sectionLabel)
                // Quiet in Default and Night Edition; ink on Grid 72, white on Kabuki.
                .foregroundStyle(Theme.current.isGrid || Theme.current == .kabukiCut
                                 ? Theme.textPrimary : Theme.textSecondary)
            HStack(spacing: 10) {
                ForEach(Array(state.presets.enumerated()), id: \.element.id) { index, preset in
                    PresetChip(preset: preset, number: index + 1)
                        // Equal flexible widths that cap at 252 pt (room for the
                        // full "1440p · 120 fps · 100 Mbps" summary); on narrow
                        // screens they compress together and the summary
                        // shortens to fit.
                        .frame(maxWidth: 252)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
                if state.offersSaveCurrentPreset {
                    SavePresetChip()
                        .frame(maxWidth: 252)
                        .transition(.opacity)
                }
            }
            // Kabuki's slanted chips lean left at the bottom; this keeps the
            // first one off the margin.
            .padding(.leading, Theme.current == .kabukiCut ? 8 : 0)
            .animation(Theme.focusSpring, value: state.presetRowFocusIDs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One saved preset. Loaded = solid accent + check + glow. Loaded but changed
/// since = "edited": an accent ring, an orange dot, and the change itself in
/// place of the summary ("Edited · 80 → 60 Mbps") — A keeps it, Options ▸
/// Revert drops it. Focus is the white ring. Tap = A; right-click / long-press
/// = rename, revert, delete. The other themes keep those states in their own
/// dress (see `chrome`).
private struct PresetChip: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let preset: StreamPreset
    /// Its place in the row, from 1 — Grid 72 prints it ("01").
    let number: Int
    @State private var hovering = false

    private var focusID: String { "preset:\(preset.id)" }
    private var isLoaded: Bool { state.activePresetID == preset.id }
    private var edited: Bool { isLoaded && state.isActivePresetEdited }
    /// Only the loaded, unchanged preset is a solid accent fill.
    private var solid: Bool { isLoaded && !edited }
    private var isFocused: Bool { state.focus.focusedItemID == focusID }
    /// Only the solid chip sits on the full-strength accent; a merely focused
    /// one is a 0.35 tint over the dark backdrop and keeps white ink.
    private var ink: Color { Theme.labelInk(onSolidAccent: solid) }

    /// The name's colour. Default as above; the solid chip in the other
    /// themes is the accent (Night Edition), ink (Grid 72) or white (Kabuki).
    private var nameInk: Color {
        switch Theme.current {
        case .default: solid || isFocused ? ink : Theme.textPrimary
        case .nightEdition: solid ? Theme.onAccent : Theme.textPrimary
        case .grid72, .grid72Dark: solid ? Theme.background : Theme.textPrimary
        case .kabukiCut: solid ? .black : (isFocused ? .white : Theme.textPrimary)
        }
    }

    private var summaryInk: Color {
        switch Theme.current {
        case .default: solid || isFocused ? ink.opacity(0.85) : Theme.textSecondary
        case .nightEdition: solid ? Theme.onAccent : Theme.textSecondary   // full ink: 4.7:1 on the fill
        case .grid72, .grid72Dark: solid ? Theme.background.opacity(0.8) : Theme.textSecondary
        case .kabukiCut: solid ? Color(hex: 0x333333) : (isFocused ? .white.opacity(0.85) : Theme.textSecondary)
        }
    }

    private func summaryLine(_ text: String) -> some View {
        Text(text)
            .themeText(.chipSummary)
            .foregroundStyle(summaryInk)
            .lineLimit(1)
    }

    /// "Edited · 80 → 60 Mbps", "+1" when more than one thing changed.
    private var changeLine: String {
        let changes = state.activePresetChanges
        guard let first = changes.first else { return "Edited" }
        return changes.count > 1 ? "Edited · \(first) +\(changes.count - 1)" : "Edited · \(first)"
    }

    var body: some View {
        chrome(
            HStack(spacing: 10) {
                if Theme.current.isGrid {
                    Text(twoDigits(number))
                        .font(ThemeFace.archivoNarrowBold.font(Theme.labelSize(11)))
                        .tracking(0.66)
                        .foregroundStyle(solid ? Theme.accent : Theme.accentText)
                        .monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .themeText(.chipName)
                        .foregroundStyle(nameInk)
                        .lineLimit(1)
                    if edited {
                        Text(changeLine)
                            .themeText(.chipEdited)
                            .foregroundStyle(Theme.editedText)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    } else {
                        // The first form that fits, so a narrow chip shows
                        // "1080p · 144 fps" instead of "1080p · 144 fps · 8…".
                        ViewThatFits(in: .horizontal) {
                            summaryLine(preset.summary)
                            summaryLine(preset.shortSummary)
                            summaryLine(preset.resolutionLabel)
                        }
                    }
                }
                Spacer(minLength: 4)
                if solid {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.current == .default || Theme.current == .nightEdition
                                         ? Theme.onAccent : Theme.accent)
                } else if edited {
                    editedDot
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .contentShape(Rectangle())
        )
        .animation(Theme.focusSpring, value: solid)
        .animation(Theme.focusSpring, value: edited)
        .animation(Theme.focusSpring, value: isFocused)
        .animation(.easeInOut(duration: 0.25), value: state.activePresetChanges)
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
        // behaves exactly like pressing A on it.
        .onTapGesture { state.pointerSelect(focusID) }
        .contextMenu {
            if edited {
                Button { state.updateActivePreset() } label: { Label("Update with These Settings", systemImage: "square.and.arrow.down") }
                Button { state.revertActivePreset() } label: { Label("Revert Changes", systemImage: "arrow.uturn.backward") }
            }
            Button { state.openPresetNameCard(.rename(preset.id)) } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { state.deletePreset(preset.id) } label: { Label("Delete", systemImage: "trash") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(solid ? Text("Loaded") : edited ? Text("Loaded, edited: \(changeLine)") : Text(""))
    }

    /// The edited marker: Default's glowing orange dot; a plain dot on Night
    /// Edition; a square on Grid 72 and Kabuki Cut.
    @ViewBuilder private var editedDot: some View {
        switch Theme.current {
        case .default:
            Circle().fill(Color.orange).frame(width: 8, height: 8)
                .shadow(color: .orange.opacity(0.8), radius: 4)
        case .nightEdition:
            Circle().fill(Theme.edited).frame(width: 8, height: 8)
        case .grid72, .grid72Dark, .kabukiCut:
            Rectangle().fill(Theme.edited).frame(width: 8, height: 8)
        }
    }

    /// The chip's plate, per theme. Default: the fill and ring below, a glow
    /// when loaded, a small lift when focused. Night Edition: a printed 2 pt
    /// box (vermilion when loaded, a vermilion rule when edited), focus an
    /// ivory frame outside it. Grid 72: an ink-ruled box (solid ink when
    /// loaded, red rule when edited), focus a keyline outside and a red bar
    /// under it. Kabuki Cut: a slanted black slab with a white rule (white
    /// with a crimson shadow when loaded, a crimson rule when edited), focus
    /// crimson and a little bigger.
    @ViewBuilder private func chrome(_ chip: some View) -> some View {
        switch Theme.current {
        case .default:
            chip
                .background(fill, in: RoundedRectangle(cornerRadius: 13))
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .strokeBorder(border, lineWidth: isFocused ? 2.5 : 1)
                }
                .shadow(color: solid ? Theme.accentGlow : .clear, radius: 12, y: 3)
                .scaleEffect(isFocused && !reduceMotion ? 1.03 : 1.0)
        case .nightEdition:
            chip
                .background(solid ? Theme.accent : Theme.ink.opacity(hovering ? 0.05 : 0),
                            in: RoundedRectangle(cornerRadius: 2))
                .overlay {
                    if !solid {
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(edited ? Theme.accent : Theme.hairline(0.3, contrast),
                                          lineWidth: edited ? 2 : 1)
                    }
                }
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Theme.textPrimary, lineWidth: 2)
                            .padding(-5)
                    }
                }
        case .grid72, .grid72Dark:
            chip
                .background(solid ? Theme.ink : Theme.surface, in: Rectangle())
                .overlay {
                    if !solid {
                        Rectangle().strokeBorder(edited ? Theme.accent : Theme.ink, lineWidth: edited ? 2.5 : 1.5)
                    }
                }
                .overlay {
                    if isFocused {
                        Rectangle().strokeBorder(Theme.ink, lineWidth: 1).padding(-6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if isFocused {
                        Rectangle().fill(Theme.accent).frame(height: 4).offset(y: 12)
                    }
                }
        case .kabukiCut:
            chip
                .background {
                    SlantedRect(-12).fill(solid ? Color.white : (isFocused ? Theme.accent : Color.black))
                }
                .overlay {
                    SlantedRect(-12)
                        .strokeBorder(edited || (solid && isFocused) ? Theme.accent : Color.white,
                                      lineWidth: edited || (solid && isFocused) ? 3 : 2)
                }
                .background {
                    if solid { SlantedRect(-12).fill(Theme.accent).offset(x: 6, y: 6) }
                }
                .scaleEffect(isFocused && !reduceMotion ? 1.04 : 1.0)
        }
    }

    private var fill: AnyShapeStyle {
        if solid { return AnyShapeStyle(Theme.accent) }
        if isFocused { return AnyShapeStyle(Theme.accent.opacity(0.35)) }
        if edited { return AnyShapeStyle(Theme.accent.opacity(0.08)) }
        return AnyShapeStyle(Color.white.opacity(hovering && state.inputMode == .pointer ? 0.12 : 0.07))
    }
    private var border: Color {
        if isFocused { return .white.opacity(0.7) }
        if edited { return Theme.accent }
        if solid { return .white.opacity(0.25) }
        return Theme.hairline(0.08, contrast)
    }
}

/// "+": the live settings aren't saved as any preset. A names them (with
/// suggestions) and saves. With no presets at all it's the row's invitation.
private struct SavePresetChip: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let focusID = "preset:add"
    private var isFocused: Bool { state.focus.focusedItemID == focusID }
    /// Kabuki's focused "+" is a crimson slab, so its words go white.
    private var onCrimson: Bool { isFocused && Theme.current == .kabukiCut }

    var body: some View {
        chrome(
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Theme.current == .default
                                     ? (isFocused ? Theme.textPrimary : Theme.accent)
                                     : (onCrimson ? Color.white : Theme.textPrimary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.presets.isEmpty ? "Save your setup as a preset" : "Save current")
                        .themeText(.chipName)
                        .foregroundStyle(onCrimson ? Color.white
                                         : isFocused ? Theme.textPrimary : Theme.textPrimary.opacity(0.85))
                        .lineLimit(1)
                    Text(StreamPreset.summary(of: state.settings))
                        .themeText(.chipSummary)
                        .foregroundStyle(onCrimson ? Color.white.opacity(0.85) : Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .contentShape(Rectangle())
        )
        .animation(Theme.focusSpring, value: isFocused)
        .onHover { over in
            if over && state.inputMode == .pointer { state.focus.focus(itemID: focusID) }
        }
        .onTapGesture { state.pointerSelect(focusID) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// A dashed (Night Edition: dotted) outline in every theme; focus as on
    /// the preset chips beside it.
    @ViewBuilder private func chrome(_ chip: some View) -> some View {
        switch Theme.current {
        case .default:
            chip
                .background(isFocused ? Theme.accent.opacity(0.25) : Color.white.opacity(0.03),
                            in: RoundedRectangle(cornerRadius: 13))
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .strokeBorder(isFocused ? Color.white.opacity(0.7) : Theme.hairline(0.2, contrast),
                                      style: StrokeStyle(lineWidth: isFocused ? 2.5 : 1, dash: [4, 3]))
                }
                .scaleEffect(isFocused && !reduceMotion ? 1.03 : 1.0)
        case .nightEdition:
            chip
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Theme.hairline(0.45, contrast),
                                      style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 3]))
                }
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Theme.textPrimary, lineWidth: 2)
                            .padding(-5)
                    }
                }
        case .grid72, .grid72Dark:
            chip
                .overlay {
                    Rectangle().strokeBorder(Theme.ink, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
                .overlay {
                    if isFocused {
                        Rectangle().strokeBorder(Theme.ink, lineWidth: 1).padding(-6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if isFocused {
                        Rectangle().fill(Theme.accent).frame(height: 4).offset(y: 12)
                    }
                }
        case .kabukiCut:
            chip
                .background {
                    if isFocused { SlantedRect(-12).fill(Theme.accent) }
                }
                .overlay {
                    SlantedRect(-12).strokeBorder(Color.white, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
                .scaleEffect(isFocused && !reduceMotion ? 1.04 : 1.0)
        }
    }
}

extension AppState.HostDot {
    /// One mapping for the header chip and the Computers card, so the two dots
    /// always agree.
    var color: Color {
        switch self {
        case .online: Theme.live
        case .unreachable: .red
        case .attention: Theme.warning
        }
    }
}

/// "03", "12": Grid 72 prints its counts with two digits.
func twoDigits(_ n: Int) -> String { n >= 0 && n < 10 ? "0\(n)" : "\(n)" }

/// Caps a view's width WITHOUT stretching it: proposes at most `max` and then
/// takes the child's own size. `.frame(maxWidth:)` instead grows to the cap
/// whenever the parent offers more, which padded short text out to the full
/// width inside its capsule.
private struct WidthCap: Layout {
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = proposal.width.map { Swift.min($0, max) } ?? max
        return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
