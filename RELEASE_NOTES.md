# VibeLight v0.2.0 — VibeLight stands on its own

*VibeLight no longer shares anything with Moonlight. It has its own identity, its own computer list, and its own settings — so installing, resetting or deleting Moonlight can't change VibeLight underneath you. **This is a clean break: you'll pair your computers once more.***

### ⚠️ Read this first — you'll re-pair your computers
Until now VibeLight quietly reused Moonlight's pairing file. It worked, but it meant your computers and your pairing lived inside another app's data, and anything that touched Moonlight could break VibeLight without warning.

That link is now cut, which means **after updating:**
- Computers that came from Moonlight **won't be listed** — add them again with **Computers ▸ Add computer by IP address**.
- Pairing happens **in VibeLight** (enter the PIN on your PC). You never need to open Moonlight again — and pairing there won't help, because VibeLight now has its own identity.
- Your presets, theme and settings are untouched.

*A one-time chore, and after it VibeLight is genuinely self-contained.*

### 🔗 Completely separate from Moonlight
- VibeLight generates and keeps **its own client identity**, stored with VibeLight.
- Its **computers, apps and stream settings** are its own — nothing is read from, or written to, Moonlight's preferences.
- The bundled streaming helper got the same treatment, so the two apps no longer trade data behind the scenes.
- Moonlight can be uninstalled with no effect on VibeLight. You don't need it installed at all.

### 💬 Errors that tell you the truth
- A computer that's **awake but not answering** no longer shows as "asleep" — you get *"isn't answering — restart Sunshine/Vibepollo on the PC"*, and VibeLight stops offering to wake a machine that's already on.
- **"Not paired"** now says what to do about it, in VibeLight, instead of sending you to Moonlight.
- A computer whose **security certificate changed** is called out specifically — that usually means its streaming software was reinstalled, but it can also mean a different machine is answering on that address.

### 🎯 Streaming reliability
- **Starting a game no longer times out too early.** Launching does real work on the PC (spinning up the encoder, sometimes creating a display), which could take longer than VibeLight was willing to wait — so it gave up while the PC carried on and started streaming to nobody. Launches now get room to breathe, and a launch that *does* fail cleans up after itself instead of leaving a stuck session that broke the next attempt.
- **Computers added by IP now learn their real identity** from the PC, which fixes a case where the streaming helper refused to connect to a computer it had been given.

---
*Install (Mac): open the `.dmg` and drag VibeLight to Applications. Already on an earlier version? VibeLight offers this update in-app.*
*Install (iPad / iPhone): build `VibeLight-iOS` from source with Xcode, or sideload via AltStore.*
