# VibeLight — design brief (`docs/DESIGN.md`, draft 26 Oct 2026)

This is the brief every visual change is checked against. Extend it; don't replace it. The owner's
global rules (`~/.claude/CLAUDE.md` › "UI/UX design") win over this file; this file wins over any
skill's defaults. Apple's HIG (the `apple-design` skill's `references/hig/*.md`) is the authority on
platform behaviour: read the page, cite it, never go from memory.

## 1. The product

VibeLight is a Steam Big Picture-style launcher for Moonlight game streaming. It owns everything
*around* the stream: pick a computer, pick a game, pick a quality preset, press A. On macOS the pixels
come from a bundled moonlight-qt helper; on iPad/iPhone the stream runs in-process; with a TV or
monitor attached the game plays on the TV while the iPad becomes a companion panel/trackpad.

It is deliberately a borderless, full-screen "10-foot" console UI with its own spatial focus engine
(macOS SwiftUI focus ignores game controllers). It is not a windowed Mac app and must never be
reviewed as one.

## 2. Who it's for

A controller-first couch gamer (the owner, and people like him). He has a Mac, an iPad
(13-inch, 2752×2064 @120 Hz) and sometimes a TV; his gaming PCs are usually asleep and one is
reached over Tailscale. He voice-dictates requests, describes outcomes (it should feel like Big Picture,
not like an ordinary application) and values polish over purity: buttery-smooth, controller-first, clear
keybinds, zero-setup onboarding. Taste: flat/cartoony over metallic, gentle fade/materialise over
snappy, "like the brand officially made it".

## 3. Screens and their single job

| Screen (file) | Single job | Signature element |
| --- | --- | --- |
| Home (`UI/HomeView.swift`) | Pick a game and press A | The games shelf + the 52 pt hero title of the focused game |
| Settings (`UI/SettingsView.swift`) | Adjust one value with ◀ ▶ without leaving the controller | The accent-filled focused row |
| Computers card (`UI/HostMenuCard.swift`) | Switch computer, add one by IP, pair by PIN | The PIN tiles |
| Overlay cards (`UI/OverlayViews.swift`, `UpdateCard`, `RelocateCard`) | One decision, Cancel focused first when destructive | The 360 pt card button stack |
| Setup wizard (`UI/OnboardingFlow.swift`) | Pick a look, pick a quality, learn about presets, jump in | The live blurred background that previews the theme |
| iPad stream (`App/iOS/StreamView.swift`, `StreamControls.swift`) | Play; get out with ✕ or the Start+Select+L1+R1 hold | The video, nothing else |
| TV companion panel (`UI/RootView.swift` › `ExternalDisplayPlaceholder`) | Tell you where VibeLight is and act as a trackpad; OLED-safe | The roaming accent glow on black |
| TV launcher (`UI/RootView.swift` › `ExternalDisplayContent`) | The same Home/Settings, readable from the couch | Super-sampled ≥2× render |

## 4. Real facts

- **Canvas.** The UI is authored on a landscape design canvas and scaled to the real window by
  `RootView.uiScale(for:)`. macOS: 1.0 from 1440×860 pt up to 2000 pt wide, shrinks below 1440×860,
  grows up to 2.5× on huge displays. iOS: fits the same 1440×860 canvas to the screen (after
  visual-plan item 1; before it, 1920×1080 × 1.25). The TV launcher uses its own 1440×810 canvas at
  ≥2× (`ExternalDisplayContent.tvDesign`). Every font and frame in the launcher is multiplied by
  the scale; the perf HUD and in-stream ✕ sit outside the canvas at 1×.
- **Smallest screens we support (landscape points):** iPad mini 1133×744, iPad 11-inch
  1180×820 / 1210×834, iPad 13-inch 1376×1032, iPhone SE 667×375, iPhone 15 852×393, Mac window
  down to about 1440×860 before it shrinks. iPhone is advertised but the layout cannot meet Apple's
  minimums there without a compact layout (recorded as a recommendation, not a quick fix).
- **Layout floor.** Below a 1000×860 canvas the fixed vertical stack on Home (header, hero, shelf,
  preset row, hint bar ≈ 800 pt) overflows. Any zoom feature must clamp to that floor.
- **Inputs.** Game controller (Xbox, PlayStation, Nintendo, generic; glyphs from `Input/InputGlyphs.swift`);
  keyboard and mouse/trackpad on macOS only; touch on iOS (the hint bar becomes tappable label pills
  when no controller is driving); a hardware keyboard on iOS only types into the stream. The focus
  engine (`Input/FocusEngine.swift`) is fed by controller and keyboard; hover and touch focus the same IDs.
- **Focus invariant.** `AppState.rebuildFocus()` emits focusable IDs; a view must render every ID it
  emits and no view may render an ID it doesn't emit, and never two views for one ID.
- **Platforms.** macOS 15+ (no sandbox), iOS/iPadOS 17+ (landscape only, sideloaded). Swift 6
  strict concurrency. Dark appearance is forced on iOS; the Mac UI is dark by design.

## 5. The approved design language (hard constraints)

Cited from `UI/Theme.swift` and the owner's approval (3 Jul 2026 "i really like the font and style",
7 Jul "way better" after moving flatter and slower).

- **Colour — one accent, used only for selection, primary actions and status.**
  `Theme.background` = (0.05, 0.06, 0.09) #0D0F17 near-black navy, never pure black in the launcher
  (pure black only on the OLED companion panel). `Theme.surface` = (0.10, 0.11, 0.16) #1A1C29 for
  cards (at 0.95) and rows (at 0.6). `Theme.accent` = (0.35, 0.62, 1.0) #599EFF carries every
  glow, focus fill and ring; `Theme.accentGlow` = accent at 0.55 for shadows. `Theme.textPrimary`
  white; `Theme.textSecondary` white at 0.6 (7.2:1 on the background). `Theme.onAccent` =
  (0.04, 0.08, 0.16) #0A1429 is the label colour on accent fills, chosen by
  `Theme.labelInk(onSolidAccent:)`: navy on full and near-solid (≥ 0.85) fills — always for small
  text (6.8:1 on the full accent; white there is only 2.7:1); white may stay on a 0.85–0.9 fill only
  for large text (the 18–19 pt bold Settings and setup quality rows, ~3.5:1); light tints (0.35–0.4,
  e.g. a merely focused preset chip) keep white. Hairline borders are white at 0.06–0.14;
  `Theme.hairline(_:_:)` lifts them to ≥ 0.35 under Increase Contrast.
- **Semantic colours, never decorative.** Green = online/running/success. Orange = error or warning
  text and its triangle. Red (`Color.red` at 0.85–0.9) = exactly one thing: the final, irreversible
  action (quit the game, restart the PC, clear a preset, forget a computer) — both the button fill
  when focused and the quit ring; it also marks the menu item that leads only to that step (the
  preset menu's Clear). Nothing else is red (the one "my favourite" theme flag is the
  owner's own joke; leave it).
- **Type — SF Rounded for everything with personality, SF Pro for body.** Wordmark "VIBELIGHT"
  22 pt black, tracking 6; "SETTINGS" 30 pt black, tracking 6; card titles 26–28 pt black; hero
  52 pt black; buttons 17 pt bold rounded; hint labels 13 pt semibold rounded; body/captions
  13–16 pt medium (default design). Authored floor: 13 pt (so the smallest iPad still renders
  ≥ 10.2 pt at Default and ≥ 11 pt at Large). No light/thin weights anywhere.
- **Shape.** Cards radius 24, buttons/rows 13–14, chips are capsules, tiles 210×280 art with a
  14 pt gap to a one-line label. Flat fills, one hairline, no bevels, no gradients except the bespoke
  flat tile gradients and the companion glow.
- **Motion — one spring.** `Theme.focusSpring` = spring(response 0.28, dampingFraction 0.72) for
  every focus change; focus shows as the accent fill/ring plus a small scale (1.02–1.07, never on
  hover alone). Screen changes use the same spring; overlays ease-out 0.18 s; the stream fades in
  0.45 s; the companion dims over 0.8 s. The launch intro's slow materialise (response ~0.85) is the
  one deliberate exception. Hover changes brightness only (white 0.06 → 0.12/0.14); nothing tilts,
  zooms or drifts on hover. Reduce Motion: fades replace slides, scale effects go to 1.0.
- **Sound and haptics.** Synthesised ticks in `UI/MenuSFX.swift` (move/select/back), a restart
  motif, a launch swell, the setup quack (`Resources/quack.mp3`); haptics mirror them. They are
  feedback, never the only carrier of meaning, and can be turned off (Settings ▸ Audio ▸ Menu Sounds).
- **Copy.** Plain words that say what happens ("Forget Computer", "Use the iPad Instead"); controls
  and card titles in title-style capitalisation, sentence case elsewhere; errors say what went wrong
  and what to do next; empty screens invite the next action and give it a button.

## 6. What must never happen

- A restyle: new font, new palette, second accent, new animation curve, metallic/glass surfaces.
- Hover zoom or drift. Light may react (brightness), position may not.
- Text below 13 pt authored, touch targets below 44 pt authored, white on `Theme.accent`.
- Slop patterns: gradient heroes, cream+serif+terracotta, near-black + neon, Inter/Space Grotesk,
  emoji section markers, everything centred, the same card-and-shadow on everything, 01/02/03
  numbering, lorem ipsum, "Submit".
- A focusable ID with no view, a view with an ID nobody emits, or two views for one ID.
- Private network details (IPs, hostnames, MACs) in copy, screenshots or docs that get committed.
- Changing something the owner set by hand (an order, a word, a colour) without asking.

## 7. How to extend this document

Add a row to §3 for a new screen, a line to §5 only when a constant is added to `Theme`, and a
bullet to §6 when a review finds a new way to break the look. Record departures from a HIG page in
the decisions log with the page and heading, and keep them one switch away from undoing.
