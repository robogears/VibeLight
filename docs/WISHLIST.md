# VibeLight — feature wishlist

Requested by William (2026-07-04). Not yet implemented (except where noted).

## In progress
- **In-app pairing / add computer by IP that actually works.** Generate our own
  client identity when Moonlight isn't installed, and implement the GameStream
  pairing handshake (PIN → host web UI) so a fresh user never needs the official
  Moonlight client. This also makes "just download VibeLight and it works" true.

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
