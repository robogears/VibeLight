# VibeLight v0.1.12 — Wake your PC from the couch, and a big reliability pass

*A practical release: a one-tap **Wake** button for a sleeping computer, plus a large under-the-hood hardening pass so your saved computers, your updates, and your streams are all a bit more bulletproof.*

### ⏻ Wake your computer from the home screen
The power button moved out of the computer menu and onto the **home screen, just left of Restart** — where it's actually useful:
- One tap sends a **Wake-on-LAN** to a sleeping PC over your network.
- It appears **only when the selected computer is asleep** (and you have its address saved), pulses **"Waking…"** while the machine boots, and disappears the moment it comes online — so you can see it working instead of wondering if anything happened.
- *(There's no remote power-off — nothing in the streaming protocol offers one — so "power" means turn on; **Restart** still covers reboots.)*

### 🛡️ A big reliability & security pass
Dozens of audited fixes across the app — the parts you'd actually feel:
- **Your saved computers can't vanish.** A single corrupt saved entry can no longer wipe your whole list of paired PCs (and the pairing certificates that go with them).
- **Safer updates.** The in-app updater now checks each download against a published checksum before it installs, and insists on the right build.
- **Steadier streaming on iPhone & iPad.** Game audio now hands back cleanly to Music/podcasts when a stream ends *or* fails to start, and a failed connection no longer leaves audio in a stuck state.
- Plus quiet hardening throughout pairing, host communication, and identity handling.

### 🎮 Friendlier first run
- On a brand-new install, the **"Add Computer" button is now reachable with a controller or keyboard** — no mouse required to get going.

---
*Install (Mac): open the `.dmg` and drag VibeLight to Applications. Already on an earlier version? VibeLight offers this update in-app.*
*Install (iPad / iPhone): build `VibeLight-iOS` from source with Xcode, or sideload via AltStore.*
