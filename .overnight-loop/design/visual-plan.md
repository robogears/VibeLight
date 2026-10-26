# VibeLight — build plan for the 13 visual fixes (design lead, 26 Oct 2026)

Owner, 26 Oct 2026, after the 13 changes were explained: **"do everything"**.

Read `DESIGN.md` (same folder) first; it is the brief these specs are checked against. All line
numbers below are from the current tree at commit `82f0626` (UI files unchanged since the audit's
`8c51dc7`). Repo: `~/Developer/VibeLight`. `MARKETING_VERSION` is already `0.2.2`
locally (GitHub has 0.2.1) — **do not bump again**.

Contrast arithmetic (WCAG relative luminance, sRGB): L(accent #599EFF) = 0.338, L(navy #0A1429) =
0.0074, L(background) = 0.0050, L(surface) = 0.0120, L(white) = 1.0. Ratio = (L₁+0.05)/(L₂+0.05).
White on accent = 1.05/0.388 = **2.70:1**. Navy on accent = 0.388/0.0574 = **6.77:1**.

## 0. Shared rules for every implementer

- Match the file's existing style (comment density, naming). Smallest correct change. No refactors.
- Every new focusable ID is emitted in exactly one `rebuildFocus()` branch and rendered by exactly
  one view, under the same gate (the `canWakeSelectedHost` pattern at `AppState.swift:219` /
  `HomeView.swift:95` / `AppState.swift:1640`).
- Every new control: controller (focus engine), keyboard on Mac (same events), touch/mouse (tap routes
  through `state.pointerSelect(id)` or `state.route(event)`), VoiceOver (`accessibilityLabel`, traits).
- Reduce Motion (`@Environment(\.accessibilityReduceMotion)`): no new slides or scales; fades only.
  Increase Contrast (`@Environment(\.colorSchemeContrast) == .increased`): hairlines ≥ 0.35 white,
  secondary text ≥ 0.75 white, nothing conveyed by faintness alone.
- Tests: pure rules get a unit test in `VibeLightTests` (macOS target) that fails without the change.
  UI wiring that tests can't execute gets a source pin scoped to the one function body, reported as
  "checked by source only".
- **Never run the macOS app to look at it** (it takes over the owner's screen as a borderless key
  window). Real pixels come from the iOS Simulator (§ 15) — the SwiftUI views are shared, so the
  Simulator proves the shared code; Mac-only behaviours (hover, keyboard glyphs) are source-checked
  and go to the owner as live checks.
- Shared docs (`RELEASE_NOTES.md`, `README.md`, `docs/STREAMING-STATUS.md`, `AIKnowledge.md`): don't
  edit; hand back the exact sentences.

## 1. Batches (by shared files; Mediums first)

| Batch | Branch | Items | Files touched | Merge order |
| --- | --- | --- | --- | --- |
| **1A** | `visual/scale` | **#1 Interface scale & targets (M21, Medium)** | `UI/RootView.swift` (uiScale only), `Core/Models.swift`, `App/AppState.swift` (SettingsRow), `UI/HomeView.swift`, `UI/SettingsView.swift`, `UI/HostMenuCard.swift`, `UI/OverlayViews.swift` (one line), `UI/OnboardingFlow.swift` (MiniPresetChip, chevrons), `UI/AppBackground.swift` (tags), `UI/HintBarView.swift` (padding), new `VibeLightTests/UIScaleTests.swift` | 1st |
| **1B** | `visual/tv-companion` | **#2 TV dead end (M19, Medium)**, #11 companion readout (M109) | `UI/RootView.swift` (overlay gate + `ExternalDisplayPlaceholder`), `App/AppState.swift` (one func), `Input/ControllerManager.swift` (one computed property), `App/iOS/ExternalDisplay.swift` (debug hook only) | 2nd (RootView hunks are far from 1A's) |
| **2C** | `visual/accent-labels` | #4 white-on-accent (M20), #5 destructive consistency (M64), #6 hover zoom (M108) | `UI/Theme.swift`, `UI/OverlayViews.swift`, `UI/HomeView.swift`, `UI/HostMenuCard.swift`, `UI/SettingsView.swift`, `UI/OnboardingFlow.swift` (MiniPresetChip, OnboardingButton), `UI/RootView.swift` (companion secondary text under Increase Contrast), `UI/HintBarView.swift` (touch-pill border) | after 1A+1B |
| **2D** | `visual/stream-controls` | #3 hidden stream controls (M71) | `App/iOS/StreamControls.swift` only | parallel with 2C |
| **2E** | `visual/keyboard-glyphs` | #8 keyboard hints show pad glyphs (M102) | `Input/ControllerManager.swift`, new `VibeLightTests/GlyphStyleRuleTests.swift` | parallel with 2C (touches a different region than 1B's one-liner; rebase on 1B) |
| **2F** | `visual/menu-sounds` | #12 menu sounds toggle (M107) | `Core/Models.swift`, `App/AppState.swift` (SettingsRow + sfx gate), `UI/MenuSFX.swift` | parallel with 2C (rebase on 1A's Models/SettingsRow change) |
| **2G** | `visual/ios-icon` | #13 iOS icon margin (M97) | `VibeLight/Assets.xcassets/AppIcon.appiconset/` only | parallel |
| **3H** | `visual/home-empty-banner` | #9 host banner (M65), #10 empty Home (M66) | `UI/HomeView.swift`, `UI/HostMenuCard.swift`, `App/AppState.swift`, `UI/HintBarView.swift` (hints list) | after batch 2 |
| **3I** | `visual/onboarding-hints` | #7 onboarding hint glyphs (M67) | `UI/OnboardingFlow.swift`, `UI/HintBarView.swift` (HintChip visibility + one static helper) | after 3H (both touch HintBarView, different regions) |

Each batch: implement → reviewer → skeptic → polish → bounded last review → full macOS test suite +
iOS Simulator build on the merged tree → commit (`visual: <item> — <ID>`).

---

## 2. Item #1 — Interface scale, text floor and touch targets (`UX-ios-scale-shrinks-text-targets-8462e247`, Medium) — batch 1A

**Problem.** On iPad/iPhone the whole 1920×1080 canvas is shrunk (0.90× on the owner's 13-inch iPad,
0.74× on an iPad mini, 0.45× on iPhone), so 10–12 pt labels render at 5–10 pt and 34 pt arrows at
15–30 pt, below Apple's 11 pt / 28 pt minimums, and nothing lets text get bigger.

**HIG.** `typography.md › Ensuring legibility`: "iOS, iPadOS | 17 pt | 11 pt".
`accessibility.md › Mobility`: "iOS, iPadOS | 44x44 pt | 28x28 pt". `accessibility.md › Vision`:
"Ideally, give people the option to enlarge text by at least 200 percent … either through custom UI,
or by adopting Dynamic Type." `designing-for-games.md › Look stunning on every display`: "uses at
least the recommended minimum text size in each platform."

**Design decision (three parts, all three ship).**

### 1(a) iOS fits the Mac's proven 1440×860 canvas instead of 1920×1080 × 1.25

`RootView.swift:211–227`. Rename `macDesignMin` → `designMin` (same value, now both platforms) and make
the iOS branch `let fit = min(size.width / designMin.width, size.height / designMin.height); return
min(max(fit, 0.3), 1.6)`. Delete the "zoom 1.25×" comment. Effect: 13-inch iPad 0.896 → **0.956**,
11-inch Pro 0.788 → **0.840**, 11-inch Air 0.768 → **0.819**, mini 0.738 → **0.787**, iPhone 15
0.455 → 0.457 (no real change; see Recommendations). The canvas becomes 1440 wide on every iPad
(1440×1080 on the 13-inch, 1440×945 on the mini) — exactly the canvas a 1440-pt Mac window already
lays out, so nothing new has to flex. The TV canvas (`ExternalDisplayContent.tvDesign`, 1440×810)
is untouched.

### 1(b) An "Interface Size" setting — Default / Large — clamped to the layout floor

- `Core/Models.swift`: add `enum InterfaceSize: String, Codable, CaseIterable, Sendable { case
  `default`, large }` with `var factor: CGFloat { self == .large ? 1.25 : 1.0 }` and `var label:
  String { "Default" / "Large" }`. Add `var interfaceSize: InterfaceSize` to `StreamSettings`
  (init default `.default`; decode with the existing `enumValue(.interfaceSize, f.interfaceSize)`
  helper at `Models.swift:229`, so old settings files still read).
- `App/AppState.swift:2393`: add `case interfaceSize` to `SettingsRow`; title `"Interface Size"`;
  `value(for:)` → `settings.interfaceSize.label`; `adjust(row:forward:)` → `settings.interfaceSize =
  Self.cycle(...)`; Themes tab rows (`:2483`) → `[.background, .interfaceSize]`. Available on both
  platforms. (Settings persist through the existing `settings.didSet`.)
- `RootView.swift`: `uiScale(for:interfaceSize:platform:)`:

  ```swift
  static let designMin   = CGSize(width: 1440, height: 860)   // the canvas the layout is authored for
  static let canvasFloor = CGSize(width: 1000, height: 860)   // below this Home's fixed stack overflows
  static func uiScale(for size: CGSize, interfaceSize: InterfaceSize = .default,
                      platform: Platform = .current) -> CGFloat {
      let base = baseScale(for: size, platform: platform)      // today's rule, 1440×860 on iOS
      let canvas = CGSize(width: size.width / base, height: size.height / base)
      let cap = min(canvas.width / canvasFloor.width, canvas.height / canvasFloor.height)
      return base * min(interfaceSize.factor, max(cap, 1))
  }
  ```
  `Platform` is a tiny `enum { case macOS, iOS; static var current }` so the macOS test target can
  exercise the iOS branch. `RootView.body` passes `state.settings.interfaceSize`.
- Resulting scales (Default → Large): 13-inch 0.956 → **1.195**; 11-inch Pro 0.840 → 0.969 (cap
  1.153 by height); 11-inch Air 0.819 → 0.952; mini 0.787 → 0.865 (cap 1.099); iPhone 15 0.457 → 0.457
  (cap 1.0 — the 860-pt floor is already the screen); Mac 1920×1080 1.0 → 1.25; Mac 1440×900 window
  1.0 → 1.047. Large is honest about this: it's "as large as the layout allows", never a broken promise.
- `VibeLightTests/UIScaleTests.swift`: table test of the numbers above (±0.005), plus "Large never
  produces a canvas narrower than 1000 or shorter than 860", plus "Default on iOS equals the 1440×860 fit".

### 1(c) Authored floor 13 pt for text, 44 pt for touch targets

Every change is a number only; nothing else about these views moves.

| File:line | Today | New | Rendered on mini (Default/Large) |
| --- | --- | --- | --- |
| `HomeView.swift:365` preset summary | 11 pt medium | **13 pt** medium | 10.2 / 11.2 |
| `HomeView.swift:375` hidden spacer line | 11 | **13** (keeps chip heights equal) | — |
| `HomeView.swift:259` hero `Badge` | 12 heavy | **13** heavy | 10.2 / 11.2 |
| `SettingsView.swift:89` "PRESETS" tab label | 10 heavy | **13** heavy | 10.2 / 11.2 |
| `SettingsView.swift:228, 247` ◀ ▶ frames | 34×34 | **44×44** (glyph stays 13 pt) | 34.6 / 38 |
| `HostMenuCard.swift:148` host status | 12 medium | **13** medium | |
| `HostMenuCard.swift:240` pairing URL line | 12 medium | **13** medium | |
| `HostMenuCard.swift:101–102` "Add" pill padding | v 8 | **v 10** (≈35 pt tall) | 27.5 / 30 |
| `HostMenuCard.swift:166–169` trash glyph button | no frame | add `.frame(width: 44, height: 44).contentShape(Rectangle())` | 34.6 |
| `OverlayViews.swift:235` "Press any button to close" | 12 | **13** | |
| `OnboardingFlow.swift:311` MiniPresetChip label | 11 medium | **13** medium; chip `:315` 96×60 → **112×64** | |
| `OnboardingFlow.swift:256` quality ◀ ▶ frames | 36 | **44** | |
| `AppBackground.swift:586, 597` theme-card tags | 10 bold | **13** bold | |
| `HintBarView.swift:11` keycap text | 12 heavy | **13** heavy | |
| `HintBarView.swift:61` touch pill vertical padding | 11 | **13** (≈44 pt tall) | 34.6 / 38 |
| `HintBarView.swift:74` glyph-mode chip padding | v 5 | **v 8** | |
| `HomeView.swift:208, 238` Wake / Restart buttons | 38 circle = hit | keep the 38 circle; wrap the label in `.padding(3)` + `.contentShape(Circle())` → 44 hit | 34.6 |

Not changed: `RootView.swift:99` perf HUD 12 pt mono (outside the scaled canvas, 1×);
`HostChip` chevron 11 pt bold (an icon); the companion's 12 pt readout (removed by item #11).

**What stays.** Every font family, weight, tracking, colour, radius and spring. The 1920-wide hero
layout. The TV canvas. Mac at 1440–2000 pt renders at exactly 1.0 as today.

**Controller / keyboard / touch / VoiceOver.** The new row behaves like every other value row
(◀ ▶, tappable chevrons, focus id `setting:interfaceSize` emitted by the existing
`settingsTab.rows.map(\.focusID)` at `AppState.swift:1670`). Nothing else changes.

**Reduce Motion / Increase Contrast.** Not affected (a scale is a layout value, not an animation).

**Acceptance.** On an iPad mini Simulator at Default, the Home screen fits with no clipping, the
preset summaries are readable and the Settings ◀ ▶ hit area is visibly larger than the chevron. At
Large the whole UI is ~10 % bigger on the mini and ~25 % bigger on the 13-inch, still with no
clipping of the header, preset row or hint bar. On the owner's 13-inch iPad at Default the UI is
6.7 % larger than today (owner live check: "does Home still feel right?").

**Pixel check (§ 15).** Screenshots: `iPad mini (A17 Pro)`, `iPad Pro 11-inch (M5)`,
`iPad Pro 13-inch (M5)`, `iPhone 17` — Home with the fake host (`VL_FAKE_HOST=asleep`), Settings ▸
Themes (Interface Size row), Settings ▸ Video, the Computers card; each at Default and Large.
Confirm with `xcrun simctl io … screenshot` and read the PNGs. Look for: nothing clipped at the
right edge of the header, the preset row's six chips all visible, the hint bar above the home
indicator.

---

## 3. Item #2 — TV attached, no controller: a way out (`UX-tv-attached-touch-dead-end-72aad067`, Medium) — batch 1B

**Problem.** The moment a TV connects, the launcher moves to the TV and the iPad shows a black panel
that swallows every touch and only says "use your controller" — with no controller you can't do
anything until you unplug.

**HIG.** `game-controls.md › Physical controllers`: "If you support game controllers, try to make
sure there's a fallback for using the platform's default interaction method." `accessibility.md ›
Mobility`: "if you use a swipe gesture to dismiss a view, also make a button available".

**Change — two layers.**

1. **Gate: the companion panel only takes the iPad over when a gamepad can drive the TV.**
   `Input/ControllerManager.swift`: add `var hasGamepad: Bool { connectedControllers.contains {
   $0.extendedGamepad != nil } }` (observable through `connectedControllers`). `RootView.swift:71–79`:
   ```swift
   let companionIdle = state.settings.externalDisplay && ExternalDisplay.shared.isConnected
                       && idle && state.controller.hasGamepad
   if companionIdle { ExternalDisplayPlaceholder(streaming: false, onUseIPad: { state.useIPadInsteadOfTV() }) … }
   ```
   and `.animation(.easeInOut(duration: 0.25), value: companionIdle)`. With no gamepad the launcher
   stays on the iPad (touch works) **and** the TV keeps mirroring it — `ExternalDisplay` already
   renders `ExternalDisplayContent` on the TV regardless of the setting, so "mirror" costs nothing.
   When a pad connects, the panel appears; when it disconnects (battery), the panel goes and the
   launcher is back under your finger. The streaming path (`onTV`, `isStreamCovering`,
   `StreamControls`) is untouched: a touch-only user still streams to the TV and uses the iPad as a
   trackpad with the existing ✕ at `RootView.swift:124`.
2. **A tappable way out on the panel itself.** `ExternalDisplayPlaceholder` gets `var onUseIPad:
   (() -> Void)? = nil`. When `!streaming`, after the secondary line (`:357–363`), add 28 pt of top
   padding then:
   - Button label **"Use the iPad Instead"** — 15 pt bold rounded, `Theme.textPrimary`, padding
     horizontal 22 / vertical 12, background `.white.opacity(0.10)` in a `Capsule()`, 1 pt
     `.white.opacity(0.14)` border, `.buttonStyle(.plain)`, `.accessibilityLabel("Use the iPad
     Instead")`, `.accessibilityHint("Turns off Use TV / Monitor.")`. No accent fill: the accent is
     for primary actions and this is the escape hatch.
   - Under it, 8 pt gap: `"Turns off Use TV / Monitor (Settings ▸ Video)."` 13 pt medium
     `Theme.textSecondary`.
   - `App/AppState.swift`: `func useIPadInsteadOfTV() { settings.externalDisplay = false;
     sfx.play(.select) }` next to `adjust`. (The setting persists via `didSet`; the existing
     Settings ▸ Video ▸ Use TV / Monitor row turns it back on.)
   The panel's `allowsHitTesting(!streaming)` stays `true` while idle, so everything else is still
   consumed; the Button inside receives its own tap. The button drifts with the OLED content
   (`:371`) — intended.
3. Copy on the idle panel stays `"Use your controller to navigate on the big screen."` — it is now
   always true when shown.

**Focus IDs.** None: the panel is touch-only by construction (the TV owns the focus engine while
a pad drives). Do not add an ID.

**Reduce Motion.** The panel's 0.25 s cross-fade is already a fade. **Increase Contrast.** The button
border goes to `.white.opacity(0.35)` and the secondary line to `Theme.textPrimary.opacity(0.85)`
(item #4's `Theme.hairline` helper; if 1B lands before 2C, inline the ternary and let 2C replace it).

**What stays.** The TV takes the launcher automatically whenever a controller is present (the
owner's loved behaviour). The streaming companion/trackpad. The glow, the drift, the 22 pt title.

**Acceptance.** Simulator with `VL_FAKE_TV=1` and no pad: the normal Home screen is on the iPad.
With `VL_FAKE_TV=1 VL_FAKE_PAD=1`: the black panel with "VibeLight is on Living Room TV", the
controller line, the "Use the iPad Instead" pill; tapping it fades to Home; Settings ▸ Video shows
Use TV / Monitor = Off. **Owner live checks (device):** (1) wired TV, no controller → launcher stays
on the iPad and mirrors; (2) connect a pad → panel appears; disconnect → it goes; (3) AirPlay
mirroring with and without a pad (unverified path — report what happens).

**Debug instruments (see § 15).** `VL_FAKE_TV`, `VL_FAKE_PAD`.

---

## 4. Item #3 — In-stream controls: a visible, accessible way back (`UX-stream-controls-hidden-reveal-cb058b27`) — batch 2D

**Problem.** After 7 s the ✕ and keyboard buttons slide off; the only way back is an invisible
32×180 pt strip at the top-right edge, which VoiceOver/Switch Control can't reach.

**HIG.** `gestures.md › Custom gestures`: a custom gesture must be "Discoverable … Not the only way to
perform an important action". `accessibility.md › Cognitive`: "Minimize use of time-boxed interface
elements." `accessibility.md › Mobility`: "Offer alternatives to gestures."

**Change (`App/iOS/StreamControls.swift` only).**
1. **A grab handle that is always visible while hidden.** Inside `grabStrip` (`:98–114`) overlay,
   aligned `.topTrailing`: `Capsule().fill(.white.opacity(0.5)).frame(width: 4, height: 44)
   .shadow(color: .black.opacity(0.5), radius: 2).padding(.top, 24).padding(.trailing, 6)` — its
   centre (y = 46) lines up with where the ✕ sits when revealed (24 pt padding + 44 pt button), so
   the pill reads as "the buttons are tucked in here". White at 0.5 on black = 5.3:1; over bright
   game video the 2 pt black shadow keeps the edge. The hit area stays the 32×180 strip.
2. **Tap, not just swipe, reveals.** Add `.onTapGesture { reveal() }` to the strip alongside the
   existing drag (tap = simplest gesture; swipe remains the shortcut).
3. **Assistive tech never loses the buttons.** `@Environment(\.accessibilityVoiceOverEnabled)`,
   `@Environment(\.accessibilitySwitchControlEnabled)`; `private var assistiveTechActive: Bool {
   voiceOver || switchControl || UIAccessibility.isAssistiveTouchRunning }`. `scheduleHide()`
   returns early when it is true (controls stay, as they do while the keyboard is up). Strip:
   `.accessibilityElement()`, `.accessibilityLabel("Show stream controls")`,
   `.accessibilityAddTraits(.isButton)`, `.accessibilityAction { reveal() }`. The outer `ZStack`:
   `.accessibilityAction(named: Text("Leave the Stream")) { onLeave() }` so the action exists even
   while hidden.
4. **Reduce Motion.** `@Environment(\.accessibilityReduceMotion)`: when on, `offsetX` is always 0
   and the cluster hides by `opacity` alone with `.easeInOut(duration: 0.2)` instead of the 0.38 s
   spring slide.

**What stays.** The 7 s auto-hide (owner's design, commit `d6b1bda`), the drawer-pull drag, the
44 pt black-circle buttons, the Shortcuts card line "Swipe in ← … swipe from the top-right edge"
(add after it in the same `keyRow`: "or tap the handle" — `OverlayViews.swift:217`, batch 2C owns
that file; hand the sentence back).

**Acceptance.** Simulator can't stream, so: source check + a `StreamControls` render is not
possible without a stream. **Owner live check:** start a stream, wait 7 s → a faint 4 pt pill at the
top-right edge; tap it → the buttons slide back; with VoiceOver on, the buttons never hide and the
rotor lists "Leave the Stream". **Owner's eye:** is the pill acceptable over gameplay? (If not, the
one-switch fallback is `.white.opacity(0.35)` = 3.0:1, still visible.)

---

## 5. Item #4 — Labels on the accent fill (`UX-white-on-accent-contrast-af29f979`) — batch 2C

**Problem.** Highlighted buttons, chips, the selected tab and the focused computer row paint white
on `Theme.accent`: 2.70:1, under Apple's 3:1 for bold text; secondary lines on it are 2.25–2.36:1;
Increase Contrast changes nothing.

**HIG.** `accessibility.md › Vision`: "All | Bold | 3:1" and "If your app doesn't provide this minimum
contrast by default, ensure it at least provides a higher contrast color scheme when the system
setting Increase Contrast is turned on." `color.md › Best practices`: "supply … an increased
contrast option for each variant".

**Conflict with the design language, resolved.** The finding's option (b) — a deeper blue fill under
text — would change the colour of every focused element; the accent *is* the approved look. Option
(a) keeps the accent pixel-for-pixel and changes only the ink on it, to the navy the setup wizard's
Continue button already uses (`OnboardingFlow.swift:381`). That is an extension, not a restyle.

**The one new Theme token.** `UI/Theme.swift`:
```swift
/// Ink on a full-strength `accent` fill (6.8:1). White on the accent is 2.7:1 — under the 3:1
/// bold minimum — so every label, glyph and secondary line that sits on `Theme.accent` uses this.
static let onAccent = Color(red: 0.04, green: 0.08, blue: 0.16)   // #0A1429
```
Arithmetic: L = 0.2126·lin(0.04) + 0.7152·lin(0.08) + 0.0722·lin(0.16) = 0.00065 + 0.0050 + 0.00158
= 0.0074; (0.338+0.05)/(0.0074+0.05) = **6.77:1**. At 0.85 opacity over the accent: **5.36:1**; at
0.8: **4.88:1**. On the number badge (white 0.22 over accent): **8.55:1** (white there is 2.14:1).

Plus one helper (not a colour): `static func hairline(_ base: Double, _ contrast: ColorSchemeContrast)
-> Color { .white.opacity(contrast == .increased ? max(base, 0.35) : base) }`.

**Sites (white → `Theme.onAccent` wherever the fill is full-strength `Theme.accent`):**

| File:line | Today | New |
| --- | --- | --- |
| `OverlayViews.swift:306` OverlayButton label | `isFocused ? .white : …` | `isFocused ? (destructive ? .white : Theme.onAccent) : …` — white stays on red (4.36:1 on the 0.85 red over the card) |
| `HomeView.swift:128` AddComputerButton | `.white` | `Theme.onAccent` |
| `HomeView.swift:353` chip number | `lit ? .white` | `lit ? Theme.onAccent` |
| `HomeView.swift:360` chip name | `lit ? .white` | `lit ? Theme.onAccent` |
| `HomeView.swift:366` chip summary | `lit ? .white.opacity(0.85)` | `lit ? Theme.onAccent.opacity(0.85)` |
| `HomeView.swift:383` active checkmark | `.white` | `Theme.onAccent` |
| `HostMenuCard.swift:100` "Add" pill text | `.white` when focused | `Theme.onAccent` |
| `HostMenuCard.swift:146, 149, 157, 168` focused HostRow name / status / check / trash | white, white 0.8, white, white 0.85 | `Theme.onAccent`, `.opacity(0.8)`, plain, `.opacity(0.85)` |
| `HostMenuCard.swift:234` PIN digits | `.white` | `Theme.onAccent` (5.75:1 on the 0.9 tile vs 3.18:1 — passes either way; change for consistency) |
| `SettingsView.swift:120` selected TabChip | `.white` | `Theme.onAccent` |
| `OnboardingFlow.swift:309, 312` MiniPresetChip highlighted | white / white 0.9 | `Theme.onAccent` / `.opacity(0.9)` |
| `OnboardingFlow.swift:381` OnboardingButton | literal `Color(red: 0.04, …)` | `Theme.onAccent` (same value; now one source) |

**Left as white, on purpose (they already pass):** the focused Settings row and onboarding quality
row (accent at 0.85 over the row tint = 3.49:1 for the 19 pt text, 3.14:1 for the bold chevrons —
`SettingsView.swift:215, 227, 235, 245`; `OnboardingFlow.swift:228, 233, 255`); the focused
PresetSlotChip at `accent.opacity(0.35)` (text stays `Theme.textPrimary`, > 7:1). Mixing is fine:
solid fills get navy ink, tinted rows keep white — one rule in `DESIGN.md §5`.

**Increase Contrast** (`@Environment(\.colorSchemeContrast) private var contrast` in each view):
`OverlayViews.swift:318` border 0.08 → `Theme.hairline(0.08, contrast)`; `HostMenuCard.swift:182`
0.06; `HomeView.swift:431` chip borders 0.08/0.14 and `:398` empty-chip opacity `0.6` → `1.0` when
increased; `SettingsView.swift:263` 0.06 and `:120` unselected tab text `Theme.textSecondary` →
`Theme.textPrimary.opacity(0.85)` when increased; `HintBarView.swift:63` pill border 0.12;
`RootView.swift:363` companion secondary → `Theme.textPrimary.opacity(0.85)` when increased.

**What stays.** The accent, the glow, the 1.04 focus scale, the white 0.35 focus ring, every size.

**Controller/keyboard/touch.** Unchanged (colour only). **VoiceOver (while you're in the file):**
`OverlayButton` (`OverlayViews.swift:285`) is a tap-gesture `HStack`, not a `Button`, and nothing in
`OverlayViews.swift`, `HomeView.swift` or `HintBarView.swift` carries an accessibility modifier
today (grep confirms). Add to `OverlayButton.body`: `.accessibilityElement(children: .combine)`,
`.accessibilityAddTraits(.isButton)`, `.accessibilityAction { state.pointerSelect(id) }`, and
`.accessibilityAddTraits(.isSelected)` when `isFocused`. Items #2 and #10 rely on this.
**Reduce Motion.** N/A.

**Acceptance.** Simulator, Computers card open with the fake host: the focused row is accent-filled
with navy text; the "Add" pill likewise. Home: the active preset chip. Settings: the selected tab.
Then `xcrun simctl ui booted increase_contrast enabled` → card borders and the empty preset chips
are clearly brighter. **Owner's eye (named live check):** "navy ink on the blue, like the setup
Continue button — keep?" The revert is one line (`onAccent = .white`).

Test: `ThemeContrastTests` computes the WCAG ratio of `onAccent` on `accent` from the constants and
asserts ≥ 4.5; and `hairline(0.08, .increased) == 0.35`.

---

## 6. Item #5 — The last destructive button is always red (`UX-destructive-styling-inconsistent-6cda93bb`) — batch 2C

**Problem.** "Clear Preset" and "Forget Computer" — the buttons that actually delete — turn blue
when focused; the menu's non-final "Clear" turns red.

**HIG.** `color.md › Best practices`: "Avoid using the same color to mean different things. Use color
consistently throughout your interface".

**Change.** `OverlayViews.swift:386` → `OverlayButton(id: "clearpreset:yes", title: "Clear Preset",
symbol: "trash.fill", destructive: true)`; `:421` → `… title: "Forget Computer", symbol:
"trash.fill", destructive: true)`. Keep `slotmenu:clear` red (`:447`): a menu item that opens a
destructive flow is red on this platform too (the native `.contextMenu` at `HomeView.swift:417`
uses `role: .destructive`). Rule for `DESIGN.md §5`: red = the irreversible step *and* the item that
leads only to it. Focus order is untouched (Cancel/"Keep It" first, `AppState.swift:1591–1595`).

**What stays.** Copy, symbols, order, white text on red (4.36:1).
**Acceptance.** Simulator: right-click/long-press has no menu on iOS, so use a controller… instead:
Home → focus a filled preset → X/"Rename / Clear" chip → "Clear" → the confirm card: d-pad down
onto "Clear Preset" shows a red fill. Source pin: the two `destructive: true` arguments inside
`ConfirmClearPresetCard.body` and `ConfirmRemoveHostCard.body`.

---

## 7. Item #6 — No hover zoom (`UX-hover-zoom-settings-tabs-f4c267b0`) — batch 2C

**Problem.** Settings tabs grow 3 % under the mouse; card buttons have a 2 % hover branch.

**HIG.** `motion.md › Providing feedback`: "In apps, generally avoid adding motion to UI interactions
that occur frequently." Owner's rule: "nothing tilts, zooms or drifts on hover (light may react,
position may not)".

**Change.** `SettingsView.swift:132`: delete the `.scaleEffect(...)` line (the background change at
`:124–128` is the hover feedback). `OverlayViews.swift:320`: `.scaleEffect(isFocused ? 1.04 : 1.0)`;
the `hoverActive` scale branch goes (its background/border brightening at `:313, :318` stays).
Add a one-line comment at each: "Hover brightens; only focus scales (owner rule: nothing zooms on hover)."

**What stays.** The focus scales (1.02–1.07) — they are selection feedback, and on the Mac a hover
*focuses* a card button (`:323–325`), so a hovered button still grows to 1.04 as the controller's
focus would. **Owner to confirm** that hover-focus → focus-scale is what he means by "light may
react"; if not, the follow-up is to skip `focus.focus(itemID:)` on hover for OverlayButton only.

**Reduce Motion.** Not changed here (focus scale under Reduce Motion is a recorded leftover).
**Acceptance.** Mac-only behaviour: checked by source (pin the absence of `scaleEffect` in
`TabChip.body` and the exact `scaleEffect(isFocused ? 1.04 : 1.0)` in `OverlayButton.body`). Owner
live check: hover a Settings tab — it brightens, doesn't grow.

---

## 8. Item #7 — Setup wizard hints show the real buttons (`UX-onboarding-hints-generic-glyphs-128fcac0`) — batch 3I

**Problem.** The wizard's hint bar shows a generic ‹ and → while the rest of the app shows Ⓐ/Ⓑ,
Cross/Circle or ⏎/⎋; on touch it should be plain tappable pills like the main hint bar.

**HIG.** `game-controls.md › Physical controllers`: "Be sure to use the connected controller's labeling
scheme when referring to controls or displaying related content in your interface." and "Prefer
using symbols, not text, to refer to game controller elements."

**Change.** One shared implementation, no drift:
- `HintBarView.swift:27`: drop `private` from `HintChip` (it stays in the file). Add `static func
  touchPresentation(_ state: AppState) -> Bool` on `HintBarView` holding the body of `touchButtons`
  (`:117–123`); `touchButtons` calls it.
- `OnboardingFlow.swift:414–450` `OnboardingHints`: replace `hint(...)` with:
  ```swift
  let touch = HintBarView.touchPresentation(state)
  HStack(spacing: touch ? 12 : 26) {
      if step != .theme { HintChip(event: .back, label: "Back", touch: touch) }
      if !touch && (step == .theme || step == .quality) {
          HintChip(event: .move(.left), label: "Change", touch: false).allowsHitTesting(false)
      }
      HintChip(event: .select, label: step == .finish ? "Jump in" : "Continue", touch: touch)
  }
  .padding(.horizontal, 22).padding(.vertical, 12)
  .background(.black.opacity(0.35), in: Capsule())
  ```
  Routing already works: a chip tap calls `state.route(event)`, and `route` hands every event to
  `routeOnboarding` while a step is active (`.select` → `advanceOnboarding`, `.back` →
  `backOnboarding`, `AppState.swift:1855–1884`). "Change" shows the d-pad/arrow-keys glyph and is
  not tappable (as today); in touch mode it is dropped (touch users tap the cards directly).
  Glyphs come from `InputGlyphs.glyph(for:style: state.effectiveGlyphStyle)` → Ⓐ/Ⓑ on Xbox,
  Cross/Circle on PlayStation, B/A on Nintendo, ⏎/⎋ on the keyboard — live, exactly as Home.
- Delete the private `hint(_:_:action:)` helper.

**Focus IDs.** None (the wizard routes by step, not by focus id). **VoiceOver.** HintChip's touch pill
is a `Text` with a tap gesture; add `.accessibilityAddTraits(.isButton)` to the touch branch in
`HintChip.chrome` (benefits the main hint bar too).

**What stays.** Copy ("Back", "Change", "Continue", "Jump in"), the black 0.35 capsule, pips, the
unskippable flow. (Leftover for the owner: "Jump in" is the one two-word button not in title-style —
`buttons.md › Content`: "Using title-style capitalization" — ask before changing a word he may have chosen.)

**Acceptance.** Fresh Simulator (`xcrun simctl erase`) → the wizard → the theme step shows "Back"-less,
"Continue" as a tappable pill (no controller); with `VL_FAKE_PAD=xbox` the bar shows Ⓑ Back ·
dpad Change · Ⓐ Continue. Mac keyboard look: source-checked (the `.keyboard` table yields "escape" /
"arrowkeys" / "return").

---

## 9. Item #8 — Keyboard use shows keyboard hints (`QOL-keyboard-hints-show-pad-glyphs-4222cb10`) — batch 2E

**Problem.** On the Mac, with a pad plugged in (even just charging), keyboard navigation keeps
showing Ⓐ/Ⓑ and hides the ⌘, / ⌘⇧Q keycaps.

**HIG.** `game-controls.md › Physical controllers`: "If there are multiple controllers connected, use
labels and glyphs that match the one that the player is actively using."

**Change (`Input/ControllerManager.swift`).** Remember which device produced the last directed input:
- `enum DirectedSource: Sendable { case pad, keyboard }`; `private var lastDirectedSource:
  DirectedSource = .pad` (observable, stored).
- `glyphStyle` (`:41`, `private(set) var glyphStyle: ControllerGlyphStyle = .keyboard`) becomes
  computed: `var glyphStyle: ControllerGlyphStyle { Self.effectiveGlyphStyle(lastSource:
  lastDirectedSource, controllerStyle: activeController.map(ControllerGlyphStyle.init(controller:))) }`
  with a **pure** static rule in the same file: `static func effectiveGlyphStyle(lastSource:
  DirectedSource, controllerStyle: ControllerGlyphStyle?) -> ControllerGlyphStyle` → `.keyboard`
  when `lastSource == .keyboard` or `controllerStyle == nil`; else `controllerStyle`.
  `updateGlyphStyle()` (`:287–289`) and its two callers go; `GCControllerDidBecomeCurrent` (`:230`)
  sets `lastDirectedSource = .pad` instead.
- `emit(_:)` (`:182`) gains `from source: DirectedSource`. Pad call sites pass `.pad`: `:360, :392,
  :397, :425, :494, :531`. Keyboard call sites pass `.keyboard`: `:684, :713, :717` (all inside
  `handleKeyDown`, `:673`). The keyboard quit holds start in `handleFlagsChanged` (`:642`) without
  `emit`; set `lastDirectedSource = .keyboard` there when a hold begins. `onInputActivity(.directed)`
  unchanged, so `AppState.effectiveGlyphStyle` (`:299`) keeps working: `.pointer` → keyboard glyphs,
  `.directed` → `controller.glyphStyle`, which now follows the last device.
- Test `GlyphStyleRuleTests`: (pad, xbox) → xbox; (keyboard, xbox) → keyboard; (pad, nil) → keyboard.

**What stays.** Glyph tables, hint bar layout, the cheat sheet. **Acceptance.** Mac-only; unit test +
source. Owner live check: pad attached, press an arrow key → the hint bar swaps to ⏎ / ⎋ / "⌘ ,";
press A on the pad → back to Ⓐ/Ⓑ.

---

## 10. Item #9 — The computer banner stops cutting messages off (`UX-host-banner-truncates-7b235bc6`) — batch 3H

**Problem.** Problems with the selected computer show as one orange line capped at 420 pt; the
150-character "saved computers couldn't be read" message loses its reassuring half; "Restarting X…"
(normal progress) wears the error orange.

**HIG.** `typography.md › Supporting Dynamic Type`: "Avoid truncating text … unless people can open a
separate view to read the rest of the content." `color.md › Best practices` (same colour, one
meaning). `progress-indicators.md › Desktop`: "Prefer an activity indicator (spinner) to communicate
the status of a background operation or when space is constrained."

**Change.**
1. `AppState.swift`: add `private(set) var hostNotice: String?` under `hostError` (`:106`). At
   `:1133` set `hostNotice = "Restarting \(host.name)…"` and `hostError = nil`. Clear `hostNotice`
   wherever `hostError` is cleared on a successful refresh (`:1334`). Delete the dead assignment at
   `:382` ("No computers yet — open the computer menu…") — item #10 replaces it with a real empty state.
2. Rewrite `:795–796` so the key point comes first and it fits two lines: `"Some saved computers
   couldn't be read. Nothing was deleted — the original list is kept, and your other computers still
   work."` (122 characters).
3. `HomeView.swift:158–170` HostChip:
   ```swift
   if let notice = state.hostNotice {
       HStack(spacing: 6) {
           ProgressView().controlSize(.mini).tint(Theme.textSecondary)
           Text(notice).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
       }
   } else if let error = state.hostError {
       Text(error).font(.system(size: 13, weight: .medium)).foregroundStyle(.orange)
           .lineLimit(2).multilineTextAlignment(.leading)
           .fixedSize(horizontal: false, vertical: true)
           .frame(maxWidth: 420, alignment: .leading)
   } else if !state.hostOnline { … unchanged … }
   ```
4. `HostMenuCard.swift:50–57`: after the "N of 4" line, `if let error = state.hostError { Text(error)
   .font(.system(size: 13, weight: .medium)).foregroundStyle(.orange).multilineTextAlignment(.center)
   .frame(maxWidth: 420) }` — the "separate view to read the rest", and it is the card the chip opens.

**What stays.** The chip's capsule, the green/orange dot, "asleep"/"offline", the 420 pt cap (now
two lines ≈ 130 characters), the header's single row (a two-line chip grows the header by ~16 pt;
the HStack is centre-aligned so the wordmark and clock stay put).

**Acceptance.** `VL_FAKE_HOST_ERROR=long` → the chip shows both sentences on two lines, nothing
ends in "…"; the Computers card repeats it in full. `VL_FAKE_HOST_ERROR=restarting` → grey
"Restarting Gaming PC…" with a mini spinner, no orange. Test: a pure test that the rewritten message
is ≤ 130 characters and starts with "Some saved computers couldn't be read."

---

## 11. Item #10 — An empty Home that says what to do (`UX-empty-home-no-invitation-7607e663`) — batch 3H

**Problem.** With no computers (every new user after setup) the shelf and hero are blank and the only
way in is a small pill in the corner; a sleeping PC with no saved list is an empty shelf with no
explanation; the hint bar offers "Play" with nothing to play.

**HIG.** `writing.md › Best practices`: "Provide clear next steps on any blank screens … guide people on
actions they can take, and give them a button or link to do so if possible." `layout.md › Visual
hierarchy`: "place the most important items near the top and leading side".

**Change.**
1. `HomeView.swift` — new `private struct EmptyShelfPanel: View`, rendered by `AppShelf` **instead
   of** the `ScrollView` when `state.apps.isEmpty`, in the same `.frame(height:
   AppTileView.Metrics.shelf)`, leading-aligned with `.padding(.leading, 72)` (the shelf's own lead):
   a `RoundedRectangle(cornerRadius: 13)` filled `Theme.surface.opacity(0.6)` with a 1 pt
   `.white.opacity(0.08)` border, padding 28, width = 360 + 56 = 416, vertically centred in the
   shelf frame. Contents, `VStack(alignment: .leading, spacing: 10)`:
   - SF Symbol 28 pt semibold in `Theme.accent` (`desktopcomputer` for add/pair, `moon.zzz.fill`
     asleep, `power` offline, `exclamationmark.triangle.fill` not responding — in `.orange`,
     `square.grid.2x2` no games),
   - title 22 pt bold rounded `Theme.textPrimary`, body 15 pt medium `Theme.textSecondary`,
   - then (8 pt gap) an `OverlayButton` — the existing card-button style, `OverlayViews.swift:285`,
     already internal — or a `ProgressView` while waking.
   Cases and copy (title / body / button):

   | State | Title | Body | Button (id) |
   | --- | --- | --- | --- |
   | no host | "Add your gaming PC" | "Its games will show up here." | "Add Computer" (`header:addhost`) |
   | host not paired | "⟨Name⟩ isn't paired yet" | "Pair it to see its games." | "Pair Computer" (`shelf:pair`) |
   | asleep, wakeable | "⟨Name⟩ is asleep" | "Wake it to load your games." | "Wake Computer" (`shelf:wake`) |
   | waking | "Waking ⟨Name⟩…" | "This usually takes 30–60 seconds." | spinner, no button |
   | offline, no MAC | "⟨Name⟩ is offline" | "Turn it on to load your games." | none |
   | not responding | "⟨Name⟩ isn't responding" | "Restart its streaming service on the PC." | none |
   | online, 0 apps | "No games on ⟨Name⟩ yet" | "Add them in Sunshine, Apollo or Vibepollo on the PC — they show up here." | none |
2. **Focus ids — one view per id.** The header's small `AddComputerButton` (`HomeView.swift:101–104`)
   is **removed** in the no-host state; the panel's button carries `header:addhost`, which
   `rebuildFocus` already emits (`AppState.swift:1646–1648`) and `routeHome` already handles
   (`:1958`). Two new ids, both in the "apps" section:
   ```swift
   sections.append(FocusSection(id: "apps", kind: .shelf,
       itemIDs: apps.isEmpty ? emptyShelfIDs : apps.map { "app:\(appKey($0))" }))
   ```
   with `var emptyShelfIDs: [String]` (single source of truth, used by `HomeView` to decide which
   button to draw): `["shelf:pair"]` when `selectedHost?.isPaired == false`; `["shelf:wake"]` when
   `canWakeSelectedHost && wakingHostID == nil`; else `[]`. `routeHome` `.select`: `"shelf:wake"` →
   `wakeSelectedHost()`, `"shelf:pair"` → `openHostMenu()` (the row there starts pairing).
   `wakeSelectedHost()` (`AppState.swift:1520`) sets `wakingHostID = host.id` at `:1523` and clears
   it in the timeout task at `:1528` **without** rebuilding focus (grep confirms no `rebuildFocus()`
   between `:1512` and `:1545`). Add `rebuildFocus()` after both assignments, and after the clear at
   `:1337` (host woke) — otherwise the engine holds `shelf:wake` while the panel draws a spinner,
   breaking the "never hold an id nothing renders" invariant.
   Order: header → apps (the panel button) → presets, so d-pad DOWN from the header lands on the
   button and DOWN again on the presets.
3. `HintBarView.swift:155–160`: the first home hint becomes focus-aware: id `header:addhost` or
   `shelf:pair` → `("select", .select, "Add Computer")` / `"Pair Computer"`; `shelf:wake` → `"Wake
   Computer"`; otherwise `("select", .select, state.apps.isEmpty ? nil : "Play")` (a nil label drops
   the pill on touch and shows the bare glyph with a pad — never a dangling "Play").

**What stays.** The hero area (blank when nothing is focused), the shelf metrics, the header's
Wake/Restart/host chip when a host exists, `OverlayButton` itself.

**Controller/keyboard/touch/VoiceOver.** The panel button is an `OverlayButton`: focus ring/fill,
A/Return, tap via `pointerSelect`; VoiceOver reads it as a button once batch 2C's accessibility
modifiers on `OverlayButton` have merged (item #4) — 3H runs after 2C, so no hand-back needed.

**Reduce Motion.** The panel appears with the shelf's existing intro reveal; no new motion.

**Acceptance.** Fresh Simulator after the wizard: Home shows the "Add your gaming PC" panel at the
left of the shelf area with a big "Add Computer" button, no pill top-right, the hint bar reads
"Add Computer · Settings · Shortcuts · Hold to Quit Game". `VL_FAKE_HOST=asleep` → the asleep
panel with "Wake Computer"; `VL_FAKE_HOST=unpaired` → "Pair Computer"; `VL_FAKE_HOST=online-empty`
→ the "No games" panel and no button. Unit test on the pure `emptyShelfIDs` rule (4 cases) and on
the hint label rule. **Owner's eye:** the panel's look on his iPad (quiet card, one accent button).

---

## 12. Item #11 — Companion panel loses the pixel readout (`UX-companion-geometry-readout-ed0a4d5c`) — batch 1B

**Problem.** "3840×2160 px · 1920×1080 pt @2× · UI 2×" in 12 pt grey (3.9:1) on the companion panel —
engineering text the user can't act on.

**HIG.** `accessibility.md › Vision`: "Up to 17 pts | All | 4.5:1". Jargon: reviewer judgment, and
`DESIGN.md §5` "Copy: plain words".

**Change.** `RootView.swift:364–369`: delete the `if let geometry …` block. `ExternalDisplay.swift`
keeps `geometrySummary` and the `NSLog` at `:100` (it was added for tuning, commit `4e7fc6f`; the log
still carries it). **Owner to confirm** (he asked for the numbers once): if he wants them back, the
place is the Performance Stats HUD as one line "TV 3840×2160", not the companion panel.

**What stays.** Everything else on the panel. **Acceptance.** `VL_FAKE_TV=1 VL_FAKE_PAD=1` screenshot:
title, one secondary line, the new button (item #2), no monospaced line.

---

## 13. Item #12 — Menu sounds can be turned off (`UX-menu-sounds-no-toggle-d3cf475c`) — batch 2F

**HIG.** `accessibility.md › Cognitive`: "consider global settings that let people opt out of
auto-playing all audio". `designing-for-games.md › Welcome everyone`: "give players the ability to
customize parameters like … sound balance." `settings.md › General settings`: "Put general,
infrequently changed settings in your custom settings area."

**Change.**
- `Core/Models.swift` `StreamSettings`: `var menuSounds: Bool` (init default `true`; decode
  `decodeIfPresent … ?? f.menuSounds`).
- `UI/MenuSFX.swift`: `var isEnabled = true`; first line of `play(_:)`: `guard isEnabled else { return }`
  (covers ticks, chimes, restart, launch swell and the quack; haptics are untouched — the HIG asks
  for haptics *alongside* sound, and a person muting sound keeps the tactile tick).
- `App/AppState.swift`: `SettingsRow.menuSounds`, title **"Menu Sounds"**, value On/Off, `adjust` →
  toggle; Audio tab rows (`:2466`) → `[.audio, .muteHostSpeakers, .muteOnFocusLoss, .menuSounds]`
  (stream audio first, the launcher's own sound last). In `settings.didSet` and at the end of `init`:
  `sfx.isEnabled = settings.menuSounds`. Both platforms (on iOS it adds to the silent switch; cheap
  and consistent).

**Copy.** Row "Menu Sounds" — On / Off. **Focus id** `setting:menuSounds` via the existing rows map.
**What stays.** Every sound, every level. **Acceptance.** Settings ▸ Audio shows the row last; Off →
no tick on focus moves (owner live check; the Simulator plays audio but the implementer can't hear
it — source-check `play` and add a unit test that `MenuSFX().isEnabled = false` makes `play` return
before scheduling: expose a `@MainActor var scheduledCount` under `#if DEBUG`).

---

## 14. Item #13 — iOS icon without the transparent frame (`QOL-ios-icon-transparent-margin-f607c51f`) — batch 2G

**HIG.** `app-icons.md › Icon shape`: "For iOS, iPadOS, and macOS icons, provide square layers so the
system can apply rounded corners. Providing layers with pre-defined masking negatively impacts …
makes edges look jagged." `app-icons.md › Layer design`: "If you do import a background layer, make
sure it's full-bleed and opaque."

**Change.** Produce `icon_ios_1024.png` from the existing `icon_512x512@2x.png` (1024², ~100 px
transparent margin on each side) with a Swift/CoreGraphics script in the scratchpad (not committed):
1. Sample the artwork's edge colour at (512,101), (512,922), (101,512), (922,512). Equal → solid
   background; else build a top→bottom linear gradient from the top and bottom samples.
2. Fill a 1024×1024 opaque canvas (`kCGImageAlphaNoneSkipLast`) with that background.
3. Draw the source cropped to its opaque bounds (≈ 100…924) scaled to 1024×1024 on top. The Mac
   tile's rounded corners now fall under iOS's own mask, and whatever peeks out is the same
   background colour, so no black slivers.
4. Point the iOS slot (`Contents.json:13`) at the new file; the ten Mac entries stay exactly as they are.

**What stays.** The Mac icon (its margin is correct on macOS), the artwork itself.
**Acceptance.** `xcrun simctl io booted screenshot` of the iPad Home Screen after install: the
VibeLight tile fills its rounded square edge to edge with no dark frame. **Owner's eye:** the icon on
his real iPad (only he can judge the artwork reads right at 1024 full-bleed; nothing else changes).

---

## 15. Checking the real pixels (without touching the owner's Mac app)

**Prerequisites.** `ThirdParty/` (gitignored) is present in the main checkout — the iOS libraries are
already built. A fix-lane worktree links `ThirdParty/ios` and `ThirdParty/moonlight-common-c` to the
main checkout's copies (excluded from commits). If it is ever missing, run `scripts/ios/build-deps.sh`
once (it reads the helper checkout beside the repo). Then `xcodegen generate` (never edit the pbxproj).
*(Orchestrator correction, 26 Oct: the design lead's original note said ThirdParty/ was absent; it was
checked and is present.)*
No `Local.xcconfig` is needed for the Simulator.

**Build and run (own DerivedData per branch).**
```
xcodebuild -project VibeLight.xcodeproj -scheme VibeLight-iOS -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPad mini (A17 Pro)' -derivedDataPath <scratch>/dd-<branch> build
xcrun simctl boot "iPad mini (A17 Pro)"           # also: "iPad Pro 11-inch (M5)", "iPad Pro 13-inch (M5)", "iPhone 17"
xcrun simctl install booted <scratch>/dd-<branch>/Build/Products/Debug-iphonesimulator/VibeLight.app
SIMCTL_CHILD_VL_FAKE_HOST=asleep xcrun simctl launch booted com.vibelight.ios
xcrun simctl io booted screenshot <scratch>/shots/<device>-<screen>-<variant>.png
xcrun simctl ui booted increase_contrast enabled    # and: appearance dark (already forced)
xcrun simctl erase <udid>                            # fresh first run → the setup wizard
```
Read every PNG back (the Read tool shows images). Drive taps with the iOS Simulator tool if the
harness provides it (`control` → tap/screenshot); otherwise use the `VL_DEBUG_SCREEN` instrument.

**Debug instruments** (new file `VibeLight/App/DebugInstruments.swift`, whole body under `#if DEBUG`,
read once from `ProcessInfo.processInfo.environment`, applied at the end of `AppState.init` /
`ExternalDisplay.init`; documented in `docs/DESIGN.md` under "Checking the real pixels"):

| Variable | Effect |
| --- | --- |
| `VL_FAKE_TV=1` | `ExternalDisplay.shared` reports `isConnected = true`, `name = "Living Room TV"` with no window (debug setter) |
| `VL_FAKE_PAD=xbox|ps|generic` | `ControllerManager.hasGamepad` returns true and `glyphStyle` the named family (no real pad in the Simulator) |
| `VL_FAKE_HOST=asleep|offline|unpaired|online-empty|notresponding` | Seeds one synthetic selected host "Gaming PC" (MAC present for `asleep`), suppresses network refresh for it |
| `VL_FAKE_HOST_ERROR=long|restarting` | Sets the 122-character persist message, or `hostNotice = "Restarting Gaming PC…"` |
| `VL_DEBUG_SCREEN=settings|hosts|onboarding` | Opens that screen/overlay after launch |

These never ship in Release, read nothing private, and touch no real host.

**Mac-only behaviours** (hover, keyboard glyphs, Increase Contrast on macOS): source check + unit
test of the pure rule, then the owner's live check. Do not build an off-screen Mac renderer that
constructs `AppState()` — its `init` resolves the real identity under Application Support and
persists settings, which must not happen from a test process on the owner's machine.

---

## 16. Owner's eye — named live checks (taste calls, per the operating manual)

1. **#4 navy ink on the blue** (every focused button, chip, selected tab, PIN digits). One-line revert.
2. **#1 iPad at the new scale** (6.7 % larger at Default on the 13-inch) and the feel of "Large".
3. **#3 the 4 pt grab pill** over gameplay after the controls retire.
4. **#2 TV hand-off now waits for a controller**; AirPlay behaviour to report.
5. **#10 the empty-Home panel** look.
6. **#11 the removed pixel readout** (he asked for it on 7 Jul; it lives in the log now).
7. **#13 the full-bleed iPad icon.**
8. **#6** whether hover → focus → 1.04 scale on card buttons counts as "light reacting".
9. Leftover word: "Jump in" → "Jump In" (title-style) — ask, don't change.

## 17. Recommendations (not built; the reason)

- **iPhone.** Even at Large the scale stays 0.457 on an iPhone 15 (the 860-pt canvas floor is the
  screen). Meeting 11 pt / 28 pt there needs a compact Home layout (hero over a single-row shelf,
  presets in a sheet) — a new screen, outside "visual fixes". Until then README's iPhone claim should
  read "runs on iPhone; designed for iPad".
- **Reduce Motion for focus scale.** `Theme.focusSpring` and the 1.02–1.07 scales ignore Reduce
  Motion everywhere (HIG asks to reduce "zooming, scaling"). One follow-up: a `Theme.focusScale(_:
  reduceMotion:)` helper returning 1.0 when on, applied at the ~10 `scaleEffect(isFocused …)` sites.
- **Interface Size on the TV launcher** (`ExternalDisplayContent.tvDesign`) was left alone; if the
  owner wants couch-size text on the TV too, apply the same factor there after a device check.
