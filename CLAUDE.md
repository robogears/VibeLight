# VibeLight

A native macOS big-picture launcher for Moonlight game streaming. Steam Big
Picture-style fullscreen UI, full controller navigation, clear keybinds — a
gorgeous shell that drives the proven moonlight-qt streaming engine underneath.

## Build

```bash
xcodegen generate            # project.yml is the source of truth (never edit pbxproj)
xcodebuild -project VibeLight.xcodeproj -scheme VibeLight -configuration Debug build
```

Swift 6 strict concurrency is ON. macOS 15+ deployment target. No sandbox
(we exec Moonlight's binary and read its plist).

## Architecture (decided after deep research — see docs/research/)

**Shell + engine split**: VibeLight owns the entire out-of-stream experience;
`/Applications/Moonlight.app/Contents/MacOS/Moonlight stream …` owns the pixels.

**Host protocol** (Vibepollo host = Sunshine → Apollo → Vibepollo fork):
- v1 talks ONLY to the GameStream API: HTTPS 47984 with mTLS using the client
  cert/key reused from `~/Library/Preferences/com.moonlight-stream.Moonlight.plist`.
  Zero new credentials, zero re-pairing.
- The Vibepollo REST API on 47990 (Basic/Bearer auth) is a v2 optional tier.
- Errors arrive as XML `<root status_code="401">` over a *successful* TLS
  handshake — always parse the attribute, never expect TLS-level rejection.
- Vibepollo hides busy state on plain HTTP 47989 — real state requires 47984.
- Send a `uniqueid` query param on every request or `PairStatus` reads 0.
- One connection per request (`Connection: close`); server closes after each response.

**Load-bearing invariants:**
1. App names from the host may carry zero-width padding (U+200B/U+200C binary
   index prefixes, `zwpad.h`). Strip for display/matching; NEVER persist as
   identity; pad width changes when app count crosses a power of 2.
2. Launch = atomic operation: fresh `/applist` → resolve by UUID/ID → pass that
   response's raw padded name verbatim to the CLI.
3. "Quit game completely" = `GET /cancel` over 47984 (parse XML status). The
   `moonlight quit` CLI action hangs forever on a GUI dialog on failure — only
   a last-resort fallback behind a 15s watchdog + SIGKILL.
4. Remote state truth = serverinfo polling (`state` + `currentgame`); the CLI
   child process is only a liveness signal (its exit codes lie — error paths
   show modal dialogs then exit 0).
5. Pre-launch reconcile: host busy with same app → `resume` (just stream);
   busy with different app → `/cancel`, poll until free, then launch.
6. SIGTERM on the stream process does NOT stop the remote game — that's how
   "disconnect but keep playing" works; full quit goes through `/cancel`.

**UI/input:**
- Custom spatial focus engine is mandatory — macOS SwiftUI focus ignores game
  controllers entirely (that's tvOS-only). Index-based navigation within
  shelves, geometry-based across sections. Keyboard feeds the same engine.
- Borderless screen-sized `canBecomeKey` window, NOT native fullScreen (native
  fullscreen puts us in a Space → slow swipe animation on every stream handoff).
- `GCController.shouldMonitorBackgroundEvents` stays false: foreground-only
  delivery IS the controller arbitration between launcher and stream.
- Reset all input repeat state on `didBecomeActiveNotification` — releases are
  dropped while backgrounded (runaway-repeat bug otherwise).
- One focus spring animation everywhere: `Theme.focusSpring`.

**Artwork:**
- Cache: `~/Library/Caches/<bundle>/boxart/<hostUUID>/<appUUID|appID>.png`.
- The host lies: missing art = 200 OK with a 130×180 `box.png` placeholder
  (sha256 `d9164ebd…`). Hash-detect and render bespoke tiles instead.
- Bespoke designed tiles for: Desktop, Steam Big Picture, Playnite,
  MoonDeckStream, Virtual Display.
- SteamGridDB = v2, optional, user-supplied key only (never ship a key).

## Layout

- `VibeLight/App/` — entry point, app delegate, window management
- `VibeLight/Core/` — models, contracts, config import, identity, host API,
  session manager, wake-on-LAN (no UI imports)
- `VibeLight/Input/` — controller manager, keyboard routing, focus engine
- `VibeLight/UI/` — theme, screens, components (consumes Core/Input only
  through contracts in `Core/Contracts.swift`)

## User's setup (test environment)

- Hosts: "UAE Server" (Tailscale 100.126.190.18, paired, 5 apps, WoL MAC
  stored) and "william_server" (192.168.50.212, saved but NOT paired).
- Moonlight 6.1.0 at `/Applications/Moonlight.app`. Settings: 1080p@144,
  87.5 Mbps, HDR on.
- Hosts are often asleep — handle offline gracefully, offer wake-on-LAN.
