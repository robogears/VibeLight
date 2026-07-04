# What's new in v0.1.4

## The self-updater actually self-installs now
- Fixed the updater showing **"Open Release Page"** instead of **"Update Now"**.
  When macOS runs a freshly-downloaded app from a read-only quarantine location
  (App Translocation), VibeLight now installs the update straight to
  **/Applications** and relaunches from there — no manual re-download.
- New two-step flow, exactly as it should be: **Update Now → download 0–100% →
  Restart Now → relaunches into the new version.** You choose when it restarts.

> Note: this fix lives *in* v0.1.4, so an older v0.1.2/v0.1.3 install still needs
> one manual download to get here. From v0.1.4 onward, updates are one click.

---

# Install / update

- **On v0.1.4 or later?** Click **Update Now** when offered (or Settings → About
  → Software Update), then **Restart Now** when it finishes. No download needed.
- **Fresh install (macOS, Apple Silicon):** download `VibeLight-0.1.4-arm64.zip`,
  unzip, and drag **VibeLight.app** to Applications. First launch on macOS 15+:
  right-click → Open, or approve it under **System Settings → Privacy & Security
  → Open Anyway** (the app is not notarized).
- On first stream, macOS may ask to allow **VibeLight Stream** on the local
  network — click Allow.

## Requirements

- Apple Silicon Mac, macOS 15 or later.
- [Moonlight](https://moonlight-stream.org) installed and already paired with
  your host once (VibeLight imports that pairing).
- A Sunshine-family host (Sunshine / Apollo / Vibepollo) on the gaming PC.

---

**Full Changelog**: https://github.com/robogears/VibeLight/compare/v0.1.3...v0.1.4
