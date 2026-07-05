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
  **Caveat:** on-device pairing against a live host is unverified here (no device;
  the crypto pattern is probe-proven on macOS + compiles for iOS).

## Planned

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
