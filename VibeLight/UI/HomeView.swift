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
                        // Which preset those numbers are; orange once changed.
                        if let preset = state.activePreset {
                            Badge(text: state.isActivePresetEdited ? "\(preset.name.uppercased()) · EDITED"
                                                                   : preset.name.uppercased(),
                                  tint: state.isActivePresetEdited ? .orange : .white)
                        }
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
            }
            // No computer yet: the way in is the empty shelf's big Add Computer
            // button (it carries `header:addhost`), not a pill up here — one
            // view per focus id (UX-empty-home-no-invitation).

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
                .fill(state.selectedHostDot.color)
                .frame(width: 9, height: 9)
                .shadow(color: state.hostOnline ? .green.opacity(0.8) : .clear, radius: 5)
            Text(host.name)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
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
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .notice(let notice):
                // Normal progress (a restart) — neutral, with a spinner.
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Theme.textSecondary)
                    Text(notice)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            case .status(let status):
                Text(status)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            case nil:
                EmptyView()
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

struct Badge: View {   // also on the starting card (PosterLiftCard)
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
                .foregroundStyle(shelf == .notResponding || shelf == .problem ? Color.orange : Theme.accent)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.system(size: 15, weight: .medium))
                // A saved-computers warning is orange, as everywhere else
                // (DESIGN.md › Semantic colours); the normal invitation is not.
                .foregroundStyle(isWarning ? Color.orange
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
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(Theme.hairline(0.08, contrast), lineWidth: 1)
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
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .tracking(2)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                ForEach(state.presets) { preset in
                    PresetChip(preset: preset)
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
            .animation(Theme.focusSpring, value: state.presetRowFocusIDs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One saved preset. Loaded = solid accent + check + glow. Loaded but changed
/// since = "edited": an accent ring, an orange dot, and the change itself in
/// place of the summary ("Edited · 80 → 60 Mbps") — A keeps it, Options ▸
/// Revert drops it. Focus is the white ring. Tap = A; right-click / long-press
/// = rename, revert, delete.
private struct PresetChip: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let preset: StreamPreset
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

    private func summaryLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Theme.labelSize(11), weight: .medium))
            .foregroundStyle(solid || isFocused ? ink.opacity(0.85) : Theme.textSecondary)
            .lineLimit(1)
    }

    /// "Edited · 80 → 60 Mbps", "+1" when more than one thing changed.
    private var changeLine: String {
        let changes = state.activePresetChanges
        guard let first = changes.first else { return "Edited" }
        return changes.count > 1 ? "Edited · \(first) +\(changes.count - 1)" : "Edited · \(first)"
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(solid || isFocused ? ink : Theme.textPrimary)
                    .lineLimit(1)
                if edited {
                    Text(changeLine)
                        .font(.system(size: Theme.labelSize(11), weight: .bold))
                        .foregroundStyle(Color.orange)
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
                    .foregroundStyle(Theme.onAccent)
            } else if edited {
                Circle().fill(Color.orange).frame(width: 8, height: 8)
                    .shadow(color: .orange.opacity(0.8), radius: 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .contentShape(Rectangle())
        .background(fill, in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(border, lineWidth: isFocused ? 2.5 : 1)
        }
        .shadow(color: solid ? Theme.accentGlow : .clear, radius: 12, y: 3)
        .scaleEffect(isFocused && !reduceMotion ? 1.03 : 1.0)
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(isFocused ? Theme.textPrimary : Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.presets.isEmpty ? "Save your setup as a preset" : "Save current")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(isFocused ? Theme.textPrimary : Theme.textPrimary.opacity(0.85))
                    .lineLimit(1)
                Text(StreamPreset.summary(of: state.settings))
                    .font(.system(size: Theme.labelSize(11), weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .contentShape(Rectangle())
        .background(isFocused ? Theme.accent.opacity(0.25) : Color.white.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(isFocused ? Color.white.opacity(0.7) : Theme.hairline(0.2, contrast),
                              style: StrokeStyle(lineWidth: isFocused ? 2.5 : 1, dash: [4, 3]))
        }
        .scaleEffect(isFocused && !reduceMotion ? 1.03 : 1.0)
        .animation(Theme.focusSpring, value: isFocused)
        .onHover { over in
            if over && state.inputMode == .pointer { state.focus.focus(itemID: focusID) }
        }
        .onTapGesture { state.pointerSelect(focusID) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

extension AppState.HostDot {
    /// One mapping for the header chip and the Computers card, so the two dots
    /// always agree.
    var color: Color {
        switch self {
        case .online: .green
        case .unreachable: .red
        case .attention: .orange
        }
    }
}

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
