# VibeLight v0.1.10 — iPad → TV output + hardware keyboard passthrough

*This release's headline features are for **iPad / iPhone**. Stream to your big screen at full native resolution, with your iPad as a companion, and type on the host with a hardware keyboard.*

### 📺 Stream to your TV / monitor at native resolution
Plug your iPad into a TV or monitor and the game streams **there**, full-screen at the display's **native resolution** (1080p, 1440p, 4K — whatever the panel is), while your iPad becomes a **companion screen**. Auto-engages the moment a display is connected. *(Settings ▸ Video ▸ Use TV / Monitor, on by default.)*

- **The iPad is your controls + trackpad.** A calm "Playing on _the display_" panel that doubles as a trackpad — drag to move the host cursor.
- **The launcher lives on the big screen too** when you're not streaming, super-sampled so text and box art stay **crisp even on a 1× 1080p TV**.
- **OLED-safe.** The companion panel gently drifts so nothing burns in, and **fades to black after 30 seconds** of no touch (any touch wakes it) — no glowing rectangle while you play in the dark.
- **Perf HUD on both screens** — the stream stats mirror to the iPad *and* the TV.

### ⌨️ Hardware keyboard → host
A keyboard attached to your iPad (Magic Keyboard, Bluetooth, USB-C) now **types straight into the game or desktop** you're streaming — letters, arrows, function keys, and **Ctrl / Alt / ⌘ shortcuts**. Works whether the video is on the iPad or the TV. Held keys are released cleanly when you leave, so nothing sticks down in the game.

### 🎯 Leave-stream ring
The **Start + Select + L1 + R1** leave chord now shows a **2-second hold ring** (like the launcher's hold-to-quit) instead of firing instantly — deliberate, with clear feedback. The game keeps running on your PC.

### 🐛 Fixes
- **No more black screen on the TV when re-launching** a stream without unplugging — the shared video layer now re-attaches correctly every time.
- **Opened VibeLight *on* the TV by mistake?** (Stage Manager can launch it there.) It now shows a crisp "Open VibeLight on your iPad — it'll stream here automatically" card instead of a broken layout.
- Frozen last frame no longer lingers on the TV after a stream ends.

---
*Install (Mac): open the `.dmg` and drag VibeLight to Applications. Already on an earlier version? VibeLight offers this update in-app. (This release is iPad/iPhone-focused — the Mac app is unchanged from 0.1.9.)*
*Install (iPad/iPhone): build `VibeLight-iOS` from source with Xcode, or sideload via AltStore.*
