# VibeLight v0.1.9 — iPad polish: PS button, rock-solid landscape, calmer sounds

### 🎮 The PS / Xbox button works in-stream (iPad & iPhone)
iOS reserves the PS/Home button (and Share/Options) for its own system gestures, so games never saw it. VibeLight now claims those buttons while streaming — **press the PS button in-game and Steam Big Picture / the PS overlay opens**, just like on Mac. The system gestures come back the moment you leave the stream.

### 🔄 Leave the stream the official Moonlight way
**Start + Select + L1 + R1** pressed together now exits the stream instantly on iPad — the exact combo the desktop Moonlight client (and the Mac app) uses. The game keeps running on your PC; the tap-✕ button still works too. (Replaces the previous hold-two-buttons gesture.)

### 📐 Landscape lock that actually locks
Newer iPadOS versions started ignoring the app's declared orientations, letting the UI rotate into a squished portrait layout. VibeLight now actively snaps itself back to landscape on every rotation — portrait is genuinely impossible.

### 🔊 Calmer, smarter menu sounds
- Scrolling the games shelf is now **silent** — sounds mark actions, not travel.
- The **Restart PC** button has its own "power-cycle" cue; hovering it (or the computer chip) gives a soft tick.
- **Settings are silent** except when you actually change a value.

### 📊 Full stream profile at a glance
- The home hero now shows **resolution and bitrate** next to FPS (e.g. `HDR · 1440p · 120 FPS · 100 MBPS`).
- Preset slots show their bitrate too (`1080p · 60 fps · 20 Mbps`), with a wider rail so it all fits.

### 📖 Shortcuts sheet rewritten
Per-platform now: iPad shows the four-button leave combo, tap-✕, the PS-button overlay tip, and touch controls; Mac keeps the Moonlight hotkeys. Both list the new d-pad-up shortcut to Restart PC / the computer switcher.

### 🐛 Also
- Audio-session setup failures are now logged (easier "no sound" debugging).
- Docs overhauled: the README finally tells the world about iPad/iPhone streaming.

---
*Install (Mac): open the `.dmg` and drag VibeLight to Applications. Already on an earlier version? VibeLight will offer this update in-app.*
*Install (iPad/iPhone): build `VibeLight-iOS` from source with Xcode, or sideload via AltStore.*
