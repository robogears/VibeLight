# Building a Big Picture-style controller-navigable SwiftUI app on macOS 15+ — research findings

## (b) THE CRITICAL QUESTION FIRST: SwiftUI focus + game controllers on macOS

**Answer: No. On macOS, game controllers do NOT drive the SwiftUI/AppKit focus system. You must build your own navigation layer.**

Evidence trail:
- Apple's "Focus-based navigation" article is a **UIKit** doc: "Navigate the interface of your UIKit app using a remote, game controller, or keyboard." The remote/game-controller focus movement is implemented by **UIFocusSystem**, which exists on tvOS/iOS/Mac Catalyst — **there is no focus engine in AppKit that consumes GameController events**. (https://developer.apple.com/documentation/uikit/focus-based-navigation)
- On macOS, SwiftUI focus (`@FocusState`, `.focusable()`, `.focusSection()`, `.onMoveCommand`) is driven by the **keyboard** (Tab / arrow keys) only. The WWDC23 "SwiftUI cookbook for focus" session covers macOS focus exclusively in keyboard terms; controller-driven focus is only demonstrated for tvOS. (https://developer.apple.com/videos/play/wwdc2023/10162/)
- The GameController framework on macOS delivers input **only through your own handlers** (`valueChangedHandler`, `GCDevicePhysicalInput`); nothing is translated into responder-chain or focus events. Community projects that map controllers to UI on macOS (e.g. github.com/NSEvent/xbox-controller-mapper) do it by synthesizing keyboard/mouse CGEvents — proof there is no native path.
- tvOS behaves the way you'd hope (focus engine listens to remotes AND controllers) but that machinery is UIKit-on-tvOS-only. macOS `.focusable()` has an extra gotcha: Tab-reachability of custom focusable views depends on the user's "Keyboard navigation" system setting, so even keyboard-only focus is unreliable for a console UI.

**Two viable strategies:**
1. **Custom spatial focus engine (recommended).** Own the "focused item" as app state (plain `@Observable` model, not `@FocusState`). Controllers, keyboard, and mouse all feed the same engine. Fully deterministic, animatable, testable.
2. **Hybrid keyboard-synthesis hack:** translate GCController d-pad into synthetic arrow-key `NSEvent`s posted to your own app (`NSApp.postEvent(_:atStart:)` / `NSApp.sendEvent(_:)` — no Accessibility permission needed when posting only to your own app) and let `.onMoveCommand`/`.focusable()` react. Works, but you inherit macOS keyboard-focus quirks (keyboard-navigation setting, focus rings, unpredictable geometry decisions). Only worth it for quick prototypes.

## (a) GameController framework — concrete API surface (all available macOS 11+, fine for macOS 15/Swift 6)

**Discovery / lifecycle**
- `GCController.controllers()` — currently connected controllers.
- Notifications: `.GCControllerDidConnect`, `.GCControllerDidDisconnect`, `.GCControllerDidBecomeCurrent`, `.GCControllerDidStopBeingCurrent` (post on main thread; `notification.object` is the `GCController`).
- `GCController.current` — most recently used controller; track this to decide which controller's glyphs to show.
- `GCController.startWirelessControllerDiscovery(completionHandler:)` / `stopWirelessControllerDiscovery()` — only needed for older MFi pairing flows; Xbox/DualSense pair via System Settings Bluetooth and just show up.
- `controller.handlerQueue` — DispatchQueue for handlers, defaults to main. For Swift 6 strict concurrency keep it on `.main` and hop into your `@MainActor` engine; `GCController` is not Sendable.

**Reading input (classic API)**
- `controller.extendedGamepad: GCExtendedGamepad?` — all modern pads (Xbox, DualSense, DualShock 4, MFi) expose this profile.
- Profile-wide: `extendedGamepad.valueChangedHandler = { (gamepad: GCExtendedGamepad, element: GCControllerElement) in ... }`
- Per element: `dpad.valueChangedHandler = { (dpad: GCControllerDirectionPad, xValue: Float, yValue: Float) in }`; `buttonA.pressedChangedHandler = { (button: GCControllerButtonInput, value: Float, pressed: Bool) in }`; `leftThumbstick.valueChangedHandler` same signature as dpad.
- Elements on `GCExtendedGamepad`: `buttonA/buttonB/buttonX/buttonY`, `dpad`, `leftThumbstick`, `rightThumbstick`, `leftShoulder/rightShoulder`, `leftTrigger/rightTrigger` (analog `value`), `buttonMenu`, `buttonOptions?`, `buttonHome?`, `leftThumbstickButton?`, `rightThumbstickButton?`.
- Generic access: `controller.physicalInputProfile.buttons[GCInputButtonA]`, `.dpads[GCInputDirectionPad]`, etc. (`GCPhysicalInputProfile`, macOS 11+). Note element nesting: a dpad contributes 4 child buttons + 2 axes into the merged `buttons`/`axes` dictionaries.
- Modern alternative (WWDC22, macOS 13+): `controller.input` (`GCDevicePhysicalInput`) with `elementValueDidChangeHandler` or `nextInputState()` polling — nice for a game loop; the handler API above is simpler for a launcher.

**D-pad + thumbstick directional navigation with key repeat**
- There is **no built-in key-repeat** in GameController. Standard pattern: on direction engaged → `move(dir)` immediately, start a repeat timer (initial delay ~0.4–0.5 s, then ~0.08–0.12 s per repeat); cancel on release/direction change. Implement with `DispatchSourceTimer` or a cancellable `Task` with `Task.sleep` on `@MainActor`.
- Thumbstick needs **hysteresis**: engage at |value| ≥ ~0.6, release at ≤ ~0.4, and pick the dominant axis to avoid diagonal jitter. Treat dpad and left-stick as one logical directional source (whichever fired last wins).
- Consume both dpad and left thumbstick; ignore right stick or use it for fast-scroll.

**Controller identification for button glyphs**
- `GCDevice.productCategory: String` with constants: `GCProductCategoryXboxOne`, `GCProductCategoryDualSense`, `GCProductCategoryDualShock4`, `GCProductCategoryMFi`, `GCProductCategoryArcadeStick`, `GCProductCategoryHID`, plus keyboard/mouse/remote categories (`GCProductCategoryKeyboard`, `GCProductCategoryMouse`, Siri-remote variants).
- Per-element glyphs: `GCControllerElement.sfSymbolsName: String?` (respects user remapping done in System Settings > Game Controllers) and `unmappedSfSymbolsName`; text names via `localizedName` / `unmappedLocalizedName`. E.g. DualSense buttonA → "xmark.circle" (Cross), Xbox buttonA → "a.circle". **Pitfall:** `sfSymbolsName` can return nil (observed when the dpad is remapped to an analog stick) — always fall back to a productCategory-keyed static glyph table.
- `controller.vendorName`, `controller.battery` (`GCDeviceBattery.batteryLevel/batteryState`) for a status HUD; `controller.light` (`GCDeviceLight.color`) to tint a DualSense light bar.

**Haptics**
- `controller.haptics: GCDeviceHaptics?` → `createEngine(withLocality: GCHapticsLocality)` returns a **CHHapticEngine** whose patterns play on the controller's actuators. Localities: `.default`, `.all`, `.handles`, `.leftHandle`, `.rightHandle`, `.triggers`, `.leftTrigger`, `.rightTrigger`; check `supportedLocalities`.
- Must `try engine.start()` before playing; build `CHHapticPattern` (transient event, intensity/sharpness params) → `makePlayer(with:)`. Use a short transient tick on focus move and a stronger one on select. **Pitfalls:** engine is invalid after controller disconnect (recreate on reconnect); CoreHaptics engines auto-stop on idle/reset — set `resetHandler` and restart lazily; Xbox One BT pads on macOS often report no haptics support (check `controller.haptics != nil`).

## (c) Recommended custom spatial focus architecture

1. **Focus model** (`@MainActor @Observable final class FocusEngine`): `focusedID: AnyHashable?`, a registry `[(id, frame: CGRect, sectionID, onActivate)]`, `move(_ dir: Direction)`, `activate()`, `goBack()`. All input sources (controller, `.onMoveCommand`, `onKeyPress`, mouse hover) call the same methods.
2. **Frame registration** — two good mechanisms:
   - `onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("focusRoot")) }) { engine.updateFrame(id, $0) }` on each tile (available/back-deployed macOS 13+; ideal on macOS 15). Root container gets `.coordinateSpace(name: "focusRoot")`.
   - Or classic `anchorPreference(key:value:.bounds)` collecting `[FocusableAnchor]`, resolved once at the root via `GeometryProxy[anchor]` in `overlayPreferenceValue` — anchors auto-track scrolling, which is their main advantage. Deregister in `onDisappear`; with `LazyVGrid/LazyHStack` offscreen tiles vanish from the registry, so directional search must fall back to section-level targets (see 4).
3. **Directional nearest-neighbor search** (tvOS-like): filter candidates strictly in the direction of travel from the focused frame's center/edge; score = distance along primary axis + ~2–3× orthogonal misalignment penalty; prefer candidates whose orthogonal extent overlaps the current frame. Keep per-row/segment "focus memory" (remember last focused column when leaving a shelf, restore on re-entry) — this is what makes it feel like Big Picture/tvOS.
4. **Sections/shelves**: model rows ("Recent", "All apps", nav bar) as sections with their own ordered IDs. Left/right moves within a section by index (no geometry needed → immune to lazy-view recycling); up/down moves between sections using geometry or fixed order. This hybrid (index-based within shelf, spatial between shelves) is more robust than pure geometry with lazy stacks.
5. **Scroll-into-view**: wrap shelves in `ScrollViewReader`, tag tiles with `.id(id)`, and on focus change `withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }`. Or macOS 14+: `.scrollTargetLayout()` + `.scrollPosition(id: $binding, anchor: .center)`. Disable scroll bounce/indicators (`.scrollIndicators(.hidden)`) for a console look.
6. **Keyboard parity for free**: root view `.focusable().focusEffectDisabled()` + `.onMoveCommand { engine.move($0.direction) }` + `.onKeyPress(.return)` / `.onKeyPress(.escape)` (macOS 14+) so arrow keys/Enter drive the same engine while debugging without a pad.

## (d) Fullscreen console-like presentation

- **Two routes:** (1) native fullscreen: `window.collectionBehavior.insert(.fullScreenPrimary)`; `window.toggleFullScreen(nil)` — gives you a dedicated Space, menu bar auto-hides, system managed. (2) **borderless takeover window (recommended for a launcher)**: `styleMask = [.borderless]`, `setFrame(screen.frame)`, `window.level = .mainMenu + 1` (or `.screenSaver` for absolute top), `isMovable = false`, `backgroundColor = .black`.
- **Why borderless wins here:** native fullscreen puts VibeLight in its own Space; moonlight-qt's stream window (another process, usually also fullscreen) lives in a different Space, so every launch/return triggers the macOS Space-swipe animation. A borderless screen-sized window stays on the normal Space — the Moonlight window simply appears over it and your launcher is instantly there when the stream ends. **Critical pitfall:** a borderless `NSWindow` cannot become key by default — subclass and override `canBecomeKey`/`canBecomeMain` to return `true`, else keyboard input is dead.
- **Menu bar / Dock:** `NSApp.presentationOptions = [.hideDock, .hideMenuBar]` (documented constraint: `hideMenuBar` REQUIRES `hideDock`; `autoHideMenuBar` requires `hideDock` or `autoHideDock`; violations raise `NSInvalidArgumentException`). Other useful flags: `.disableProcessSwitching`, `.disableForceQuit`, `.disableCursorLocationAssistance` (kiosk-ish; probably skip so Cmd-Tab still works). Apply on `NSApplication.didBecomeActiveNotification`, restore `[]` on `willResignActiveNotification` so the Mac behaves normally while the stream runs.
- **SwiftUI scene plumbing (macOS 15):** `Window("VibeLight", id: "main") { ... }` with `.windowStyle(.hiddenTitleBar)` — or `.windowStyle(.plain)` (macOS 15.0+) for zero chrome — plus `.windowResizability(.contentSize)`, `.windowLevel(.floating)` (macOS 15+ scene modifier). Grab the underlying `NSWindow` via an `NSViewRepresentable` that reads `view.window` (or `NSApp.windows`) to set collectionBehavior/canBecomeKey subclass tweaks — SwiftUI still doesn't expose those directly.
- **Prevent display sleep:** `let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Big Picture mode")`, later `endActivity(activity)`. (IOKit equivalent: `IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep, ...)` — not needed unless you want per-display control.) End it while the stream runs — Moonlight holds its own assertion.
- **Cursor:** `NSCursor.setHiddenUntilMouseMoves(true)` on controller activity.

## (e) Buttery animation patterns

- Focus highlight: on the focused tile, `scaleEffect(isFocused ? 1.12 : 1.0)` + white/accent border + `shadow(color: .accent.opacity(0.6), radius: isFocused ? 24 : 0)` glow, animated with `.animation(.snappy(duration: 0.22), value: isFocused)` or `withAnimation(.spring(response: 0.32, dampingFraction: 0.75))` from the engine's move method. Spring presets `.snappy/.smooth/.bouncy` and `.spring(duration:bounce:)` are macOS 14+.
- **Moving selection ring** (Big Picture signature): draw one ring/glow view with `matchedGeometryEffect(id: "focusRing", in: ns)` sourced from the focused tile so it glides between tiles instead of cross-fading. `.geometryGroup()` (macOS 14+) fixes jitter when scaling parent+child together.
- Hero transition tile→detail page: `matchedGeometryEffect(id: app.id, in: ns)` on box art in both views; `.transition(.blurReplace)` (macOS 15) for page swaps; `.contentTransition(.numericText())` for counters.
- Ambient background: blurred box art of the focused game, `.blur(radius: 60)` + dark gradient overlay + `.background(.ultraThinMaterial)` panels; crossfade on focus change with `.animation(.smooth(duration: 0.6))`. Parallax: offset the background by a small multiplier of the focused item's index/position. `KeyframeAnimator`/`PhaseAnimator` (macOS 14+) for idle "breathing" effects; `TimelineView` for continuous ambient motion.
- Respect `@Environment(\.accessibilityReduceMotion)` to swap springs for opacity fades.

## (f) Foreground/background behavior around the Moonlight stream

- Default on macOS 11.3+: `GCController.shouldMonitorBackgroundEvents == false` → **the framework stops forwarding ALL controller input the moment your app is not frontmost, and resumes automatically when you're frontmost again** (before 11.3 the default was `true`). iOS/tvOS ignore the property. No user permission is required for the property itself (system-wide event *synthesis* is what needs Accessibility permission — you don't need that).
- **For VibeLight this default is exactly what you want:** when moonlight-qt's window takes over, its SDL gamepad handling owns the controller and your launcher goes deaf; when the stream ends and your window becomes key again, your handlers fire again with zero work. Do NOT set `shouldMonitorBackgroundEvents = true` — you'd react to in-game button presses behind the stream.
- **Pitfalls:**
  - Release events for buttons held across the foreground→background transition are not delivered; on `NSApplication.didBecomeActiveNotification` reset all held-direction state and cancel repeat timers, else you get a stuck auto-repeat.
  - macOS 15.4 shipped a regression where `shouldMonitorBackgroundEvents = true` silently reverted to false (Apple confirmed unintentional; fixed in 15.5) — more reason not to depend on background monitoring.
  - An SDL commit notes that enabling background events before the first `GCControllerDidConnect` notification crashed on macOS for MFi controllers — set such flags (if ever) only after connect.
  - Also observe `.GCControllerDidBecomeCurrent` on refocus: the user may have switched controllers mid-stream.
  - Two processes reading the same controller is fine on macOS (GameController framework + Moonlight's SDL/HID coexist); foreground policy is what arbitrates.

## Recommended approach (synthesis)

1. Borderless key-capable `NSWindow` sized to the screen, `level = .mainMenu + 1`, `presentationOptions = [.hideDock, .hideMenuBar]` while active; SwiftUI `Window` scene with `.windowStyle(.hiddenTitleBar)`/`.plain` hosting the UI. Skip native fullscreen Spaces.
2. `ControllerManager` (`@MainActor`): observes connect/disconnect/current notifications, wires `extendedGamepad` per-element handlers on `handlerQueue = .main`, normalizes dpad+left-stick into a `DirectionalInput` stream with hysteresis + key-repeat, exposes `productCategory`-aware glyph provider via `sfSymbolsName` with static fallback table, and a `HapticsPlayer` around `haptics?.createEngine(withLocality: .default)`.
3. `FocusEngine` (`@Observable`): section-aware registry (index-based within shelves, geometry between sections via `onGeometryChange` frames), focus memory, `move/activate/back`; ScrollViewReader keeps the focused tile centered. Keyboard feeds the same engine via `.onMoveCommand`/`.onKeyPress`.
4. Never touch `@FocusState`/system focus for the grid — controllers can't drive it on macOS.
5. `ProcessInfo.beginActivity(.idleDisplaySleepDisabled)` while the launcher is the active surface; drop it during streams. Leave `shouldMonitorBackgroundEvents` at false; reset input state on app-active notifications.