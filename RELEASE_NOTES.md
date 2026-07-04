# What's new in v0.1.2

## Automatic updates
- VibeLight now updates itself. On launch it checks GitHub for a newer release
  and offers a one-click **Update Now** — it downloads, verifies, swaps itself
  in, and relaunches. No more manual re-downloads after this version.
- Also available anytime under **Settings → About → Software Update**.

## A proper app icon
- A new **VL** app icon in VibeLight's own look — you'll see it in the Dock,
  Spotlight, and Finder.

## Full settings parity with Moonlight
- Settings are grouped into **Video / Audio / Input / Advanced / About** tabs
  (flip with L1/R1 or click), and now cover the full set of streaming options:
  YUV 4:4:4, mute host speakers, mute-when-inactive, remote-desktop mouse,
  swap mouse buttons, reverse scrolling, capture system keys, swap A/B & X/Y,
  background gamepad, keep-display-awake, performance stats, and more — each
  wired to the real stream setting.

## Manage your computers
- The top-right computer chip now opens a **computer manager**: switch between
  up to four PCs, **add a new one by IP address**, wake an asleep PC over the
  network, and remove ones you added.

## Nicer with a mouse
- The settings tabs and the on-screen hint bar are now clickable, with hover
  highlights — the whole UI works equally well by controller, keyboard, or mouse.

## Under the hood
- The self-updater was hardened after an adversarial security review: it pins
  downloads to GitHub (re-checked on every redirect), verifies the bundle
  before installing, and rolls back safely if anything fails mid-install.

---

# Install / update

- **Already on v0.1.2 or later?** Just click **Update Now** when VibeLight
  offers it (or Settings → About → Software Update). No download needed.
- **Fresh install (macOS, Apple Silicon):** download `VibeLight-0.1.2-arm64.zip`,
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

**Full Changelog**: https://github.com/robogears/VibeLight/compare/v0.1.1...v0.1.2
