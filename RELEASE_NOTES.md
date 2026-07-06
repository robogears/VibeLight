# VibeLight v0.1.8 — iPad & iPhone streaming

### 📱 Stream on your iPad or iPhone — the headline
The iOS app now **actually streams**: full video (up to your display's native resolution at 120 fps), **game audio**, and **controller support**, powered by a built-in streaming engine — no other apps needed. Plus:
- **Touch the stream to control the PC** — taps click, drags move the cursor, real multi-touch passthrough on supported hosts. Toggle in **Settings ▸ Input ▸ Touch Control** (on by default).
- **Hold Select + R1 for 4 seconds** to leave the stream (a progress ring shows the hold), or tap the on-screen ✕. The game keeps running on the PC.
- A **performance HUD** (Settings ▸ Advanced ▸ Performance Stats): live resolution, fps, bitrate, network latency, host encode time, and dropped frames.
- The screen stays awake while streaming, and **Quit Game on App Exit** now works on iOS too.
- GPL note: iOS installs are sideload-only (Xcode / AltStore) — not on the App Store.

### 🔀 Switch streams without backing out
Launching a game while another is already streaming now offers **"Switch to …"** — VibeLight closes the running app on the PC and starts the new one in one step. (Both platforms.)

### 🔊 Menu sounds
The launcher now sounds like a console: a soft tick as focus moves, a bright confirm on select, a gentle tone on back. On iPhone/iPad the silent switch mutes them.

### 🎮 Controller & UI polish
- Press **up** from the games shelf to reach the **Restart PC** button and the **computer chip** with your controller.
- Settings values now have **tappable ◀ ▶ arrows** — easy to adjust by touch or mouse; redundant hint chips removed.
- Rotating loading quips while a stream starts (*"Convincing your PC it's a console…"*).
- Quit hint now reads **Hold to Quit Application** on Mac (removed on iOS, where apps don't self-quit).

### 🐛 Fixes & stability
- Fixed the app being killed by iOS when exiting with a slow host ("random crash" reports — the `0x8BADF00D` watchdog).
- 22 streaming-engine fixes from a deep audit against the reference Moonlight client: black-screen recovery after network hiccups, audio staying in sync (no more creeping delay), audio recovering after phone calls/Siri, smoother rides through network jitter, controller hot-unplug no longer leaving buttons stuck in-game, double-click support on non-touch hosts, and more.
- MoonDeckBuddy restart now works with older MoonDeckBuddy versions (and says clearly when an update is needed).
- Audio setup problems are now logged instead of failing silently.

---
*Install (Mac): open the `.dmg` and drag VibeLight to Applications. Already on an earlier version? VibeLight will offer this update in-app.*
*Install (iPad/iPhone): build `VibeLight-iOS` from source with Xcode, or sideload via AltStore.*
