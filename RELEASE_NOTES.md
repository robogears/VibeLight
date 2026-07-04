# What's new in v0.1.1

The first release of VibeLight: a Steam Big Picture-style, controller-first
launcher for Moonlight game streaming on macOS.

## Big-picture streaming, zero setup
- Reuses your existing Moonlight pairing — hosts, certificates, and settings
  import automatically. No re-pairing, no configuration.
- Fullscreen console-style library with box art, hero titles, ambient glow,
  and buttery spring-animated focus — fully navigable by controller.
- Streams through a bundled, chromeless Moonlight engine: no Moonlight menus,
  no dock icon, no hang-forever error dialogs — just the game.

## Couch-grade controls
- Full controller navigation everywhere, including tabbed settings (L1/R1)
  that finally expose Moonlight's options to a gamepad.
- **Hold Menu** → quit the remote game completely (the keybind Moonlight never
  had). **Hold B/○ on home** → quit VibeLight. Both show a fill-ring so you
  can see the hold working.
- **Hold Start ~2s during a stream** → cleanly disconnect back into the
  resume / quit-completely menu. No keyboard required, ever.
- Cursor vanishes on controller input and returns on mouse movement; hints
  adapt to Xbox / PlayStation / Nintendo glyphs.

## Under the hood
- Custom spatial focus engine (43 unit tests) — macOS SwiftUI can't drive
  focus from game controllers, so VibeLight brings its own.
- Talks the Sunshine/Apollo/Vibepollo GameStream API directly over mTLS with
  byte-exact certificate pinning; host truth via serverinfo polling.
- The streaming engine is a GPLv3 fork of moonlight-qt, embedded as
  `StreamHelper.app` and driven over a machine-readable status protocol.
  Source: https://github.com/robogears/vibelight-moonlight-helper (commit c1557e5).

---

# Install / update

- **macOS (Apple Silicon):** download `VibeLight-0.1.1-arm64.zip`, unzip, and
  drag **VibeLight.app** to Applications. First launch on macOS 15+: right-click
  → Open, or approve it under **System Settings → Privacy & Security → Open
  Anyway** (the app is not notarized).
- On first stream, macOS may ask to allow **VibeLight Stream** on the local
  network — click Allow.

Artwork cache lives in `~/Library/Caches/com.vibelight.app/`.

## Requirements

- Apple Silicon Mac, macOS 15 or later.
- [Moonlight](https://moonlight-stream.org) installed and already paired with
  your host once (VibeLight imports that pairing).
- A Sunshine-family host (Sunshine / Apollo / Vibepollo) on the gaming PC.

---

**Full Changelog**: https://github.com/robogears/VibeLight/commits/v0.1.1
