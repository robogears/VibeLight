# VibeLight — feature wishlist

Requested by William (2026-07-04). Not yet implemented (except where noted).

## Done
- ✅ **In-app pairing / add computer by IP.** Own-identity generation + the full
  GameStream pairing handshake (PIN → host web UI). Crypto unit-tested; the live
  end-to-end handshake still needs a test against an awake host.
- ✅ **(4) Escapable fullscreen** for VibeLight's own UI — traffic lights reveal
  on hover at the top-left.
- ✅ **(5) Custom + native resolution** — native auto-detected in the cycle;
  select the Resolution row to type an arbitrary WxH.
- ✅ **(1) Settings presets** — save current settings as a preset; right-side
  home rail to pick the active one.
- ✅ **(6) Stream-entry flash** — mitigated (Dock no longer un-hidden during the
  handoff, on both the launcher and helper sides); needs live confirmation.
- ✅ **(3) UI scales with resolution.** A root scaler lays the big-picture UI
  out in a virtual canvas and scales it to fill the screen: **exactly 1.0
  (identity, zero change) on any Mac ≤ 2000 pt wide**, scaling UP only on large
  4K/5K displays where fixed-size elements looked tiny, and scaling the full
  design to fit on iPhone/iPad. Verified: iOS simulator now fits the whole
  layout (one-line wordmark + button + full hint bar, vs. the old cramped
  wrap); macOS 4K upscale builds + launches (pixel capture blocked by
  screen-recording permission, but the scale≠1 path is proven via iOS).
- ✅ **(2) iPadOS + iPhone support — Phase 1 (launcher, no streaming yet).**
  The whole shared shell now builds and runs on iOS 17+ / iPadOS: host browsing,
  in-app GameStream pairing, app list, box art, settings, and full controller +
  focus-engine navigation. Verified: builds for the iOS 27 simulator, launches,
  and renders the big-picture UI (empty-state "Add Computer" shown). Streaming
  itself is behind a `StreamEngine` seam and **disabled on iOS** (`launch()`
  shows "not supported on iOS yet") — real streaming needs the in-process
  moonlight-common-c engine (Phases 2–5, see `docs/plans/ios-support-plan.md`).
  The macOS build is byte-for-byte behaviorally unchanged (openssl identity path
  kept; iOS uses SecKeyCreateRandomKey + swift-certificates + a keychain-assembled
  SecIdentity). GPLv3 = the iOS app can't ship on the App Store; sideload/AltStore.
  **iOS identity crypto is now runtime-verified in the simulator** (an
  `IOSIdentityTests` XCTest proves key generation → SecIdentity assembly → RSA
  signing → cert CN → PEM stability). This surfaced that iOS pairing REQUIRES a
  `keychain-access-groups` entitlement (added) + code-signing — without it the
  born-in-keychain identity silently fails. On device, real provisioning supplies
  the team-prefixed group. Still unverified: the live network handshake against an
  awake host (no device + hosts asleep) — same caveat the macOS pairing carries.

## Planned

0. **Force-restart PC button** (requested 2026-07-05, important). A "Restart PC"
   control to the **left of the host chip** in the home header that restarts the
   Windows host with **no Windows-side confirmation dialog**. Needs a confirm step
   *inside VibeLight* (it's destructive), then fire-and-forget.

   **Chosen mechanism: MoonDeckBuddy** (github.com/FrogTheFrog/moondeck-buddy) —
   the user already restarts their PC from the Steam Deck via it, so it's a
   proven, dialog-free path. The user installs MoonDeckBuddy separately; VibeLight
   just talks to its REST API:
   - Transport: **HTTPS only**, default port **59999** (user-configurable), self-
     signed cert baked into the app (`moondeck_cert.pem`, shared across installs)
     → URLSession must pin/trust that cert with hostname-check off.
   - Restart: `POST https://HOST:59999/restartHost` body `{"delay": 5}` (1–30 s),
     header `Authorization: basic <base64(clientId)>` → `{"result": true}`.
   - Auth = a client-chosen UUID `clientId` in the paired-clients set. One-time
     **PIN pairing**: `POST /pair {"id", "hashed_id": base64(clientId+pin)}`, user
     types the PIN into the MoonDeckBuddy pop-up on the PC; poll
     `GET /pairingState/<clientId>`. Mirrors our existing add-by-PIN model.
   - Liveness: `GET /apiVersion` (unauth, must == 8). Sibling power endpoints:
     `/shutdownHost`, `/suspendHost`, `/abortHostStateChange`.
   - Store `clientId` in the Keychain (the Basic header IS the whole credential).

   Rejected alternatives (see git history): Apollo/Vibepollo **server commands**
   run over the RTSP control stream (mid-stream only) + need the Artemis common-c
   fork; a launched shutdown "app" fires a stream that dies instantly; 47990
   `/api/restart` restarts the Sunshine *service*, not the PC.

1. **Settings presets on the home screen.**
   - User custom-configures settings, then saves them as a preset (Preset 1–4 or
     named) from within Settings ("Save as preset").
   - On the home screen, to the RIGHT of the app tiles (Desktop, Steam Big
     Picture, …), the user picks the active preset (e.g. "4K 60", "1080p 120").
   - The selected preset needs an obvious, unmistakable "this is the one that
     will be used" look.
   - Presets are user-defined, NOT hardcoded defaults.

2. **iPadOS + iPhone support.** The app should run on iPad and iPhone too, not
   just macOS.

3. **UI scales with resolution.** At 1440p/4K the UI currently shrinks; it should
   scale to match the screen so it looks the same size at any resolution.

4. **Windowed / non-locked fullscreen for VibeLight's own UI** (NOT the stream).
   - Launch into fullscreen as now, but let the user reveal the macOS traffic-
     light buttons by moving the mouse to the top, so they can minimize / close /
     reach settings without needing Cmd-Tab.
   - "Headless fullscreen" that's escapable from the top-left.

5. **Custom + native resolution in Settings.**
   - Let the user type a custom resolution.
   - Auto-detect the display's native resolution and offer it as a pickable
     option (important on iPad with non-standard resolutions). If native is
     higher than the current selection, it appears further along the list.

## Minor / investigate (non-blocking)
- **Stream-entry overlay flash:** when a stream starts, Moonlight's lower overlay
  menu (the bar with all the buttons) flashes for ~1s before the stream appears.
  Find the cause in the fork and suppress it if possible.
