# VibeLight

**A Steam Big Picture-style, controller-first launcher for Moonlight game streaming on macOS.**

VibeLight is a native SwiftUI app that turns your Mac into a couch-friendly
streaming console: a gorgeous fullscreen library you drive entirely with a game
controller, with box art, hero titles, ambient glow, and one buttery spring
animation everywhere. Under the hood it drives a bundled, **chromeless fork of
moonlight-qt** — the same proven streaming engine you already trust — so you get
Moonlight's picture quality with none of its desktop-app rough edges.

## Why

Stock Moonlight is a fantastic streaming engine wrapped in a desktop UI that
falls apart on the couch:

- **You can't navigate it with a controller.** macOS game controllers don't
  drive SwiftUI/AppKit focus at all (that machinery is tvOS/UIKit-only), so
  Moonlight's Qt library, settings, and dialogs are effectively mouse-and-keyboard
  only. VibeLight ships its own spatial focus engine so every pixel is reachable
  from a gamepad.
- **There's no clear "quit the game" keybind.** Ending a stream in Moonlight
  disconnects but leaves the game running on the host, and the only real "quit"
  path is a modal dialog that can hang forever on failure. VibeLight gives you an
  obvious two-tier flow: *disconnect and keep playing*, or *quit the game
  completely* — both from the controller, both with on-screen feedback.
- **The chrome gets in the way.** Menus, a Dock icon, error dialogs, a Space-swipe
  animation on every launch. VibeLight's embedded engine is headless: no menus,
  no Dock icon, no hang-forever dialogs — just the game, in the same Space, with
  no swipe.

VibeLight is the shell Moonlight never had.

---

## Features

- **Controller-first big-picture UI.** A fullscreen, console-style library with
  box art, hero titles, ambient glow, and spring-animated focus. A custom spatial
  focus engine (43 unit tests) makes every shelf, tile, setting, and dialog fully
  navigable by controller — the thing macOS SwiftUI can't do on its own. The
  keyboard feeds the exact same engine.
- **Zero-setup pairing reuse.** VibeLight imports your existing Moonlight setup —
  hosts, apps, the client certificate/key, and your stream defaults — straight
  from `com.moonlight-stream.Moonlight.plist`. **No re-pairing, no new
  credentials, no configuration.** If Moonlight already talks to your PC, so does
  VibeLight.
- **Chromeless embedded streaming engine.** Streaming runs through
  `StreamHelper.app`, a headless fork of moonlight-qt bundled inside VibeLight. It
  shows no Moonlight UI, keeps no Dock icon (`LSUIElement` agent), never pops a
  blocking error dialog, and lands the stream in VibeLight's own Space (no
  Space-swipe animation) with automatic focus handoff.
- **Two-tier quit flow with hold chords + on-screen ring.**
  - **Hold Menu** (~1s) → *quit the remote game completely* — the keybind
    Moonlight never had. Executed as `GET /cancel` over mTLS, not the hang-prone
    CLI dialog.
  - **Hold B/○ on the home screen** (~1.5s) → *quit VibeLight itself.*
  - **Hold Start ~2s during a stream** → cleanly *disconnect* back into the
    resume / quit-completely menu, no keyboard required.
  - Every hold chord fills a **progress ring** so you can see it working, and a
    quick tap always falls through to the plain action (Back, Settings).
- **Controller / mouse input-mode switching.** The cursor vanishes on
  controller or keyboard input and returns the instant you move the mouse.
  On-screen hints adapt to Xbox / PlayStation / Nintendo / generic glyphs
  (respecting your System Settings controller remaps) and show real keycaps for
  keyboard chords.
- **Full Moonlight-parity settings, on a gamepad.** Tabbed settings (Video /
  Audio / Advanced / About) switched with L1/R1, every row adjustable with
  left/right: resolution, frame rate, bitrate, video codec (Auto / H.264 / HEVC /
  AV1), HDR, video decoder, audio (stereo / 5.1 / 7.1), V-Sync, frame pacing, and
  game optimizations. This finally exposes Moonlight's options to a controller.
- **In-app self-updater.** VibeLight checks GitHub Releases on launch and offers
  a one-click update from **Settings → About → Software Update**. It downloads the
  new build (pinned to GitHub over TLS), verifies the bundle's identity and
  code-signature, swaps itself over the running app, and relaunches — no App
  Store, no manual re-download.
- **Wake-on-LAN.** Hosts are often asleep; VibeLight sends a magic packet
  (broadcast **and** unicast, so it works over Tailscale/VPN where broadcast
  doesn't reach) to wake the gaming PC from the couch.
- **Smart artwork.** Box art is fetched and cached per host/app. The host lies
  about missing art (it returns a 130×180 placeholder with a 200 OK), so VibeLight
  hash-detects the placeholder and renders **bespoke designed tiles** for Desktop,
  Steam Big Picture, Playnite, MoonDeckStream, and Virtual Display instead of a
  broken image.

---

## Requirements

- **Apple Silicon Mac** (arm64) running **macOS 15 (Sequoia) or later**.
- **[Moonlight](https://moonlight-stream.org)** installed and **already paired
  with your host once.** VibeLight imports that pairing — it does not pair on its
  own (v1). If you can stream in Moonlight, you're ready.
- A **Sunshine-family host** on your gaming PC: **Sunshine**, **Apollo**, or
  **Vibepollo**. VibeLight talks the GameStream API these expose.

---

## Install

VibeLight is distributed as a direct download (it's a GPL-based project, so it
will never be on the Mac App Store — see [Licensing](#licensing)).

1. Download the latest **`VibeLight-x.y.z-arm64.zip`** from
   [GitHub Releases](https://github.com/robogears/VibeLight/releases).
2. Unzip it and drag **VibeLight.app** into your **Applications** folder.
3. **First launch:** because the app is ad-hoc signed and not notarized (no paid
   Developer ID), macOS Gatekeeper will block it the first time. Either
   **right-click → Open**, or open it once and then approve it under **System
   Settings → Privacy & Security → Open Anyway**.
4. **On your first stream,** macOS may ask to allow **VibeLight Stream** on the
   local network — click **Allow**.

The artwork cache lives in `~/Library/Caches/com.vibelight.app/`.

### Updates

VibeLight keeps itself current:

- It **checks GitHub Releases on launch** and surfaces a card when a newer
  version is available.
- You can check on demand any time from **Settings → About → Software Update**.
- Choosing to update downloads the new `-arm64.zip`, verifies it (correct bundle
  identity + intact `codesign` seal + not older than promised), swaps the running
  bundle, re-signs it ad-hoc, and relaunches. On a dev/translocated build that
  can't self-install, it falls back to opening the release page in your browser.

---

## Controls

Everything is reachable from a controller; the keyboard drives the identical
navigation events. Face-button letters follow your controller family (the table
uses Xbox names).

| Action | Controller | Keyboard |
| --- | --- | --- |
| Move focus | D-pad / Left stick | Arrow keys |
| Select / launch | **A** | Return / Enter |
| Back | **B** (tap) | Esc |
| Options (context) | **X** | Space |
| Details | **Y** | Tab |
| Previous / next section | **L1** / **R1** | — |
| Open Settings | **Menu** (tap) | ⌘, |
| Settings tabs (Video/Audio/Advanced/About) | **L1** / **R1** | — |
| **Quit the game completely** | **Hold Menu** (~1s, fills ring) | ⌘⇧Q |
| **Quit VibeLight** (home screen) | **Hold B/○** (~1.5s, fills ring) | ⌘Q |
| **Disconnect** (in-stream → resume/quit menu) | **Hold Start** (~2s) | — |

Notes:

- **Disconnect vs. quit** is the core distinction: disconnecting (SIGTERM to the
  local client, or the in-stream **Hold Start** chord) leaves the game running on
  the host so you can resume later; **quitting completely** (**Hold Menu** / ⌘⇧Q)
  actually terminates the remote game via the host's `/cancel`.
- Hold chords only arm where they're meaningful (e.g. hold-B-to-quit only on the
  home screen with no overlay) — otherwise the button is just its plain action.
- Glyphs and labels auto-adapt to Xbox / PlayStation / Nintendo / generic pads,
  and honor remaps done in **System Settings → Game Controllers**.

---

## Architecture

VibeLight is a **shell + engine split**, decided after deep research (see
`docs/research/` and `docs/plans/`) and documented in `CLAUDE.md`.

### Shell + engine split

- **VibeLight owns the entire out-of-stream experience** — the library, focus,
  settings, artwork, host reconciliation, and the session lifecycle.
- **`StreamHelper.app` owns the pixels.** It's a chromeless, headless fork of
  moonlight-qt embedded at `VibeLight.app/Contents/Helpers/StreamHelper.app`,
  launched as a child process. VibeLight drives it over a machine-readable
  **`@VL` stdout protocol** (`@VL STARTED`, `@VL FAILED reason="…"`, etc.) instead
  of scraping logs or fighting modal dialogs, and it always exits with a
  deterministic code. The process boundary is strictly CLI args + stdout/stdin +
  signals + exit code — never a linked library (this is load-bearing for
  licensing).
- `resolveStreamBinary()` prefers the **embedded** helper, then a local **fork
  dev build**, then falls back to **stock Moonlight** (which still works, just
  with chrome).

### Host protocol

VibeLight (v1) talks **only to the GameStream API** the Sunshine/Apollo/Vibepollo
host exposes:

- **HTTPS on port 47984 with mTLS**, reusing the client certificate/key imported
  from Moonlight's plist — **zero new credentials, zero re-pairing.** The host's
  self-signed cert is byte-exact pinned (stronger than CA trust for this
  protocol; ATS is disabled so the pinning delegate can run).
- **Remote state truth = `/serverinfo` polling** (`state` + `currentgame`). The
  child process is only a liveness signal — its exit codes lie (error paths show
  a dialog then exit 0), so watchdogs reconcile against host truth.
- **Quit completely = `GET /cancel`** over 47984, parsing the XML status.
- Pre-launch **reconcile**: host busy with the same app → resume; busy with a
  different app → `/cancel`, poll until free, then launch. App names may carry
  zero-width padding from the host — VibeLight strips it for display but passes
  the raw padded name verbatim to the engine at launch.

### Custom spatial focus engine

macOS SwiftUI/AppKit focus ignores game controllers entirely, so VibeLight brings
its own: index-based navigation within shelves, geometry-based across sections,
fed identically by controller and keyboard. It's the reason the whole app is
controller-navigable — and it's covered by 43 unit tests.

### Module layout

```
VibeLight/
  App/     entry point, app delegate, borderless big-picture window, AppState
  Core/    models, contracts, Moonlight config import, client identity,
           host API (mTLS), stream session manager, updater, wake-on-LAN  (no UI)
  Input/   controller manager, keyboard routing, spatial focus engine, input glyphs
  UI/      theme, screens, components — consumes Core/Input only through
           Core/Contracts.swift
```

VibeLight uses a borderless, screen-sized `canBecomeKey` window (not native
fullscreen — native fullscreen puts the app in its own Space and triggers a slow
swipe animation on every stream handoff), and deliberately leaves
`GCController.shouldMonitorBackgroundEvents = false` so that foreground-only input
delivery *is* the controller arbitration between the launcher and the stream.

---

## Building from source

Swift 6 strict concurrency is on; the deployment target is macOS 15+. There is no
sandbox (VibeLight execs the stream helper and reads Moonlight's plist).

### The app

```bash
xcodegen generate            # project.yml is the source of truth (never edit the pbxproj)
xcodebuild -project VibeLight.xcodeproj -scheme VibeLight -configuration Debug build

# Or, Release into /Applications (also embeds the helper):
./scripts/install-app.sh
```

### The streaming helper (the fork)

The chromeless engine lives in a **separate GPLv3 repository**:
[**robogears/vibelight-moonlight-helper**](https://github.com/robogears/vibelight-moonlight-helper).
Build it with the Qt toolchain:

```bash
git clone https://github.com/robogears/vibelight-moonlight-helper
cd vibelight-moonlight-helper
git submodule update --init --recursive
python3 setup-deps.py                         # MANDATORY before qmake

export PATH="$(brew --prefix qt)/bin:$PATH"   # brew install qt
qmake moonlight-qt.pro
make -j"$(sysctl -n hw.logicalcpu)" release   # → app/Moonlight.app
```

Then embed a relocatable, ad-hoc-signed copy into VibeLight:

```bash
./scripts/embed-helper.sh /Applications/VibeLight.app
```

`embed-helper.sh` runs `macdeployqt` to fold the Qt/SDL2/FFmpeg frameworks and
QML runtime into the copy (so it launches anywhere, not just on the build
machine), strips extended attributes, and signs inside-out into
`Contents/Helpers/StreamHelper.app`. `install-app.sh` calls it automatically after
a Release build, and warns (rather than fails) if the fork isn't built — VibeLight
then falls back to the dev build or stock Moonlight.

---

## Licensing

VibeLight's own Swift code and the streaming engine are kept deliberately
separate:

- **The streaming engine is a GPLv3 fork of moonlight-qt** (which statically links
  moonlight-common-c, also GPLv3 — so the whole helper is one GPLv3 work). Its
  source, and a log of exactly what the fork changes, live in the public repo
  [robogears/vibelight-moonlight-helper](https://github.com/robogears/vibelight-moonlight-helper).
- It is **embedded as a separate helper process** and communicates with VibeLight
  strictly at arm's length — CLI arguments, the `@VL` stdout/stdin protocol,
  signals, and exit codes. VibeLight never links or `dlopen`s any moonlight code.
  This process boundary is what keeps VibeLight's own SwiftUI code separate from
  the GPL (FSF "mere aggregation / separate programs communicating at arm's
  length").
- Distribution is **Developer-ID-style direct download** (GitHub Releases),
  **never the Mac App Store** — GPLv3's terms are fundamentally incompatible with
  the App Store's usage rules (the VLC precedent).

### Credits

VibeLight stands on the shoulders of:

- [**moonlight-qt**](https://github.com/moonlight-stream/moonlight-qt) and
  **moonlight-common-c** (GPLv3) — the streaming engine and protocol.
- **Sunshine / Apollo / Vibepollo** — the GameStream hosts.
- **SDL2** (zlib), **FFmpeg** (LGPL), and the other libraries the engine
  depends on (Opus, libplacebo, qmdnsengine, h264bitstream).

---

## Status / roadmap

VibeLight is an **early but working** project (v0.1.x) — it streams end-to-end
today, with the full big-picture UI, controller navigation, zero-setup pairing
reuse, the embedded chromeless engine, and the in-app updater all functional.

Deferred / not yet shipped:

- **Notarization** — needs a paid Apple Developer ID (hence the first-launch
  "Open Anyway"). Code-signing is already ad-hoc and structured for a clean
  Developer-ID + notarization drop-in later.
- **The Vibepollo REST tier** (port 47990, Basic/Bearer auth) — a v2 optional
  layer on top of the current GameStream-only client.
- **SteamGridDB artwork** — a v2, optional, user-supplied-key feature (a key is
  never shipped).
