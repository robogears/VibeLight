# VibeLight

A native macOS + iOS/iPadOS big-picture launcher for Moonlight game streaming.
Steam Big Picture-style fullscreen UI, full controller navigation, touch-first
fallbacks, clear keybinds. On macOS it drives the proven moonlight-qt engine as
a helper subprocess; on iOS it streams **in-process** via moonlight-common-c
(video + audio + controller + touch — shipped and device-verified in v0.1.8).

## Build

```bash
xcodegen generate            # project.yml is the source of truth (never edit pbxproj)
xcodebuild -project VibeLight.xcodeproj -scheme VibeLight -configuration Debug build       # macOS
xcodebuild -project VibeLight.xcodeproj -scheme VibeLight-iOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build                                      # iOS
```

Schemes: **VibeLight** (macOS), **VibeLight-Dev** (coexisting dev build —
dormant; don't build/install it unless asked), **VibeLight-iOS** (iPhone/iPad).
Plus **MoonlightCore**, a static-lib target compiling the vendored
moonlight-common-c C core for iOS.

- iOS **device** builds need a team: copy `Local.xcconfig.example` →
  `Local.xcconfig` (gitignored) and set `DEVELOPMENT_TEAM`. `Signing.xcconfig`
  (committed) optionally-includes it, so the Team ID stays out of this public
  repo AND survives `xcodegen generate`. The Simulator builds without it.
- iOS **dependencies** are vendored by `scripts/ios/build-deps.sh` into
  `ThirdParty/` (gitignored): moonlight-common-c sources (copied from the
  helper fork checkout) + `mbedcrypto.xcframework` and `opus.xcframework`
  (device arm64 + universal simulator slices). Run it once before the first
  iOS build; mbedTLS's TLS layer does NOT build for iOS — only the `mbedcrypto`
  target is used.
- Finder sometimes drops numbered `Info 2.plist` duplicates into `VibeLight/`;
  they break the build with ghost pbxproj references. They're gitignored —
  delete any strays and regenerate.

Swift 6 strict concurrency is ON everywhere. macOS 15+ / iOS 17+ targets. No
sandbox on macOS (we exec the stream helper and read Moonlight's plist).

**macOS streaming helper**: our moonlight-qt fork at
`~/Documents/vibelight-moonlight-helper` (chromeless, headless `@VL` protocol,
LSUIElement agent — see its FORK-CHANGES.md). Build it with
`git submodule update --init --recursive && python3 setup-deps.py` (MANDATORY
before qmake), then `export PATH="$(brew --prefix qt)/bin:$PATH" && qmake
moonlight-qt.pro && make release`. `scripts/embed-helper.sh` macdeployqt's a
copy into `VibeLight.app/Contents/Helpers/StreamHelper.app` (relocatable,
ad-hoc signed); `resolveStreamBinary()` prefers embedded → fork dev build →
stock Moonlight. Notarization needs a paid Developer ID (not configured);
GPL fork = never MAS.

## Ship / release (no CI — local Path B)

Releases are cut locally and published to GitHub Releases; the macOS app
self-updates from `releases/latest`. Do NOT auto-install builds to
/Applications — William updates through the in-app updater.

1. Bump `MARKETING_VERSION` in `project.yml` (3 places), rewrite
   `RELEASE_NOTES.md` (whole file = the release body), commit, tag `vX.Y.Z`.
2. Release build → stage a copy → `scripts/embed-helper.sh` → assets:
   `VibeLight-X.Y.Z-arm64.zip` (updater consumes this, in-place swap) +
   `VibeLight-X.Y.Z-arm64.dmg` (`scripts/make-dmg.sh`, first install) + both
   `.sha256` sidecars. Asset names are an updater contract.
3. `gh release create --draft --verify-tag --notes-file RELEASE_NOTES.md …`,
   verify body+assets, publish with `--latest` only when asked.

iOS has no release artifact (GPLv3 = sideload/AltStore/Xcode only).

## Architecture (decided after deep research — see docs/research/)

**Shell + engine split**: VibeLight owns the entire out-of-stream experience.
The pixels are owned by a per-platform `StreamEngine` (seam in
`Core/Contracts.swift`): macOS = `StreamSessionManager` spawning the helper
subprocess; iOS = `InProcessStreamEngine` driving moonlight-common-c inside the
app process. `PlatformChrome` is the second seam (macOS `WindowCoordinator`,
iOS `iOSPlatformChrome`).

**Host protocol** (Vibepollo host = Sunshine → Apollo → Vibepollo fork):
- v1 talks ONLY to the GameStream API: HTTPS 47984 with mTLS. The client identity
  is either **reused** from `~/Library/Preferences/com.moonlight-stream.Moonlight.plist`
  (zero-setup for existing Moonlight users, no re-pairing) OR, for a user without
  Moonlight, **VibeLight's own generated identity** — and VibeLight can **pair a
  new host in-app** (add-by-IP → PIN, the full 5-phase NvPairingManager handshake:
  `Core/IdentityStore`, `HostPairing`, `GameStreamCrypto`, `UI/HostMenuCard`). So
  Moonlight is no longer required to add a computer. On iOS the identity is
  born-in-keychain (`Core/iOSIdentity.swift`, `SecKeyCreateRandomKey` +
  swift-certificates; needs the `keychain-access-groups` entitlement).
- The Vibepollo REST API on 47990 (Basic/Bearer auth) is a v2 optional tier.
- Errors arrive as XML `<root status_code="401">` over a *successful* TLS
  handshake — always parse the attribute, never expect TLS-level rejection.
- Vibepollo hides busy state on plain HTTP 47989 — real state requires 47984.
- Send a `uniqueid` query param on every request or `PairStatus` reads 0.
- One connection per request (`Connection: close`); server closes after each response.
- TLS trust: GameStream certs are self-signed BY DESIGN; ATS is fully disabled
  (`NSAllowsArbitraryLoads`) and `HostAPIClient` byte-pins the pairing leaf on
  every request instead. Do NOT add `NSAllowsLocalNetworking` — its presence
  makes Apple IGNORE `NSAllowsArbitraryLoads` (verified on device).

**MoonDeckBuddy** (`Core/MoonDeckBuddyClient.swift`): optional Restart-PC tier —
HTTPS :59999, Basic auth = base64(clientId), TOFU cert pinning, PIN pairing.
`pairState` arrives as a **string** ("Paired"/"Pairing"/"NotPaired") on v7 AND
v8; restart = `POST /restartHost {"delay": 1-30}`, with fallbacks for older
buddies. See the header comments for the version-compat matrix.

**Load-bearing invariants (macOS helper path):**
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
   busy with different app → `/cancel`, poll until free, then launch. The UI
   layer additionally prompts "Switch to X?" before launching over a running app.
6. SIGTERM on the stream process does NOT stop the remote game — that's how
   "disconnect but keep playing" works; full quit goes through `/cancel`.

**Load-bearing invariants (iOS in-process engine)** — full list with rationale
in `docs/STREAMING-STATUS.md`; the ones that WILL regress if forgotten:
- moonlight-common-c is single-connection: LiStartConnection/LiStopConnection
  are serialized on one queue; `stop()` captures self strongly; remote
  termination still needs an explicit stop.
- Depacketizer PICDATA buffer entries are RTP **fragments**, not NALUs —
  reassemble Annex-B, then convert to AVCC by scanning real start codes.
- Return `DR_NEED_IDR` from every decode-failure path (DR_OK on an unprocessed
  IDR = black screen forever); decode/audio callbacks run on pool-less C
  threads — every ObjC allocation needs `@autoreleasepool` (jetsam otherwise).
- Audio ring drops NEW packets past ~60 ms backlog (latency ratchets otherwise);
  `encryptionFlags = ENCFLG_NONE` with this host (mbedcrypto CBC suspect).
- Host busy (`currentgame != 0`) → `/resume`, never `/launch`.
- iOS termination path must finish < 5 s or iOS SIGKILLs (0x8BADF00D):
  the quit-on-exit /cancel runs with a 2.5 s budget inside a background task.

**UI/input:**
- Custom spatial focus engine is mandatory — macOS SwiftUI focus ignores game
  controllers entirely (that's tvOS-only). Index-based navigation within
  shelves, ordinal across top-to-bottom sections. Keyboard feeds the same
  engine; touch/mouse hover focuses the same IDs. Never emit focusable IDs
  that no view renders.
- Borderless screen-sized `canBecomeKey` window, NOT native fullScreen (native
  fullscreen puts us in a Space → slow swipe animation on every stream handoff).
- `GCController.shouldMonitorBackgroundEvents` stays false: foreground-only
  delivery IS the controller arbitration between launcher and stream (macOS).
  On iOS, `ControllerManager.streamForwarder` flips ALL pads into raw
  passthrough while streaming (launcher hears nothing), and back.
- Reset all input repeat state on `didBecomeActiveNotification` — releases are
  dropped while backgrounded (runaway-repeat bug otherwise).
- One focus spring animation everywhere: `Theme.focusSpring`. Menu SFX
  (`UI/MenuSFX.swift`, synthesized PCM — no assets) tick alongside haptics.
- iOS is landscape-only (Info.plist + `UIApplicationDelegateAdaptor`); the
  hint bar becomes tappable label buttons when no controller is driving.

**Artwork:**
- Cache: `~/Library/Caches/<bundle>/boxart/<hostUUID>/<appUUID|appID>.png`.
- The host lies: missing art = 200 OK with a 130×180 `box.png` placeholder
  (sha256 `d9164ebd…`). Hash-detect and render bespoke tiles instead.
- Bespoke designed tiles for: Desktop, Steam Big Picture, Playnite,
  MoonDeckStream, Virtual Display.
- SteamGridDB = v2, optional, user-supplied key only (never ship a key).

## Layout

- `VibeLight/App/` — entry point, app delegate, window management, `AppState`
  (the composition root: all routing/overlays/settings)
- `VibeLight/App/iOS/` — iOS shell: `VibeLightApp` (scene + orientation lock +
  scenePhase), `InProcessStreamEngine` (launch → LiStartConnection lifecycle,
  controller/touch forwarding, perf stats, keep-awake), `StreamView`
  (display layer + touch surface), `iOSPlatformChrome`
- `VibeLight/Streaming/` — `MoonlightSession` (ObjC++ bridge over
  moonlight-common-c: connection lifecycle, H.264 → AVSampleBufferDisplayLayer,
  Opus → RemoteIO AudioUnit, input events; iOS targets only)
- `VibeLight/Core/` — models, contracts, config import, identity (macOS reuse +
  iOS keychain), host API + pairing + crypto, session manager (macOS),
  MoonDeckBuddy, wake-on-LAN, update service (no UI imports)
- `VibeLight/Input/` — controller manager (navigation + stream passthrough +
  haptics), keyboard routing, focus engine
- `VibeLight/UI/` — theme, screens, components, menu SFX (consumes Core/Input
  only through contracts in `Core/Contracts.swift`)
- `ThirdParty/` (gitignored, vendored by `scripts/ios/build-deps.sh`) —
  moonlight-common-c sources + iOS xcframeworks
- `docs/STREAMING-STATUS.md` — iOS streaming architecture + hard-won invariants
- `~/Documents/moonlight-ios-reference` — read-only clone of moonlight-ios for
  parity reference (not part of this repo)

## iOS / iPadOS (streaming SHIPPED in v0.1.8)

VibeLight builds for iOS 17+ (`VibeLight-iOS`). Shared Core/Input/UI compile on
both platforms behind the two `Core/Contracts.swift` seams (`StreamEngine`,
`PlatformChrome`). Convention: AppKit/`Process`/macOS-only code is under
`#if os(macOS)`. **Streaming is real on iOS**: in-process moonlight-common-c
(H.264 to native res @ 120fps, Opus audio, full controller passthrough with a
held Start+Select+LB+RB leave chord that shows a 2 s progress ring, touch-as-input
with native passthrough + mouse fallback, Moonlight-parity perf HUD, keep-awake,
quit-on-exit). **External display / TV output (SHIPPED, device-verified & loved):**
when a TV/monitor is attached (`App/iOS/ExternalDisplay.swift`, a real
`UIWindowScene`) the game streams to it at the display's NATIVE resolution while
the iPad becomes a companion — an OLED-safe "Playing on X" panel that doubles as a
trackpad and fades to black after 30 s idle (any touch wakes it). The idle launcher
also renders ON the TV, super-sampled to ≥2× so it's crisp even on 1× 1080p panels
(see `docs/STREAMING-STATUS.md`). Perf HUD mirrors to both iPad and TV. Setting:
Video ▸ Use TV / Monitor (default on, auto-engages). Remaining
roadmap lives in `docs/STREAMING-STATUS.md` (HEVC/HDR, rumble, frame pacing).
`DisabledStreamEngine` remains only as the contracts stub for platforms without
an engine. GPLv3 = no App Store; sideload via Xcode/AltStore.

## User's setup (test environment)

Concrete host addresses, hostnames, and WoL MACs live in `CLAUDE.local.md`
(gitignored — never commit real network details to this public repo). General
notes that are safe to share:

- Two saved hosts: one paired over a Tailscale tailnet (WoL MAC stored), one
  saved on the LAN but not yet paired. Tailscale traffic is DERP-relayed —
  high bitrates show up as FEC starvation, not client bugs.
- Moonlight 6.1.0 at `/Applications/Moonlight.app`. Test device: iPad
  (2752×2064@120).
- Hosts are often asleep — handle offline gracefully, offer wake-on-LAN.
