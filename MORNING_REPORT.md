# Overnight Run — Morning Report

Branch: `OvernightCodingRun` (forked from v0.1.11). Status legend: ✅ done · 🔬 researched/partial · ⏭ deferred.

## Summary

(filled in at the end of the run)

## Item-by-item

### 1) Standalone Mac pairing — ✅ root-caused + fixed
**Root cause (confirmed in code, not speculation):** the StreamHelper (our moonlight-qt
fork) deliberately reads its client identity from Moonlight's preferences domain
(`com.moonlight-stream.Moonlight.plist`, QSettings keys `certificate` / `key`) — that's
the zero-setup reuse story (fork FORK-CHANGES.md, M4). On a Mac that never had
Moonlight, that domain is empty: VibeLight pairs with its OWN generated cert
(`~/Library/Application Support/VibeLight/identity/`), while the helper mints a
*different* fresh cert on first stream. The host has never seen the helper's cert, so
the CLI fails with exactly the message the user saw: *"Computer has not been paired.
Please open Moonlight to pair before streaming."*

**Fix:** `IdentityStore.resolve()` (macOS) now mirrors VibeLight's own generated
identity into the Moonlight preferences domain (only when that domain has no
certificate — a real Moonlight identity is never overwritten). Launcher and helper now
present one cert, so in-app pairing works standalone. A later real-Moonlight install
reads the same plist and inherits the pairing.

**Host discovery on a fresh Mac is NOT a problem:** the fork CLI's `ComputerSeeker`
calls `addNewHostManually(<address we pass on the CLI>)`, so the helper self-adds the
host and, with the unified cert, serverinfo reports `PairStatus=1` → streams.

**Self-heal note for the already-broken Mac:** that machine's Moonlight domain already
contains the helper's orphan cert. On next VibeLight launch, VibeLight *imports* that
cert (Moonlight-identity-wins priority), the host shows unpaired → re-pair once via
PIN → consistent forever after.

### 2) Wake-on-LAN reliability — ✅ hardened
Old implementation: one burst, global broadcast :9/:7 + unicast :9; hostnames silently
skipped (`inet_pton` only). Rewritten to mirror moonlight-qt's `NvComputer::wake()`:
- **Addresses:** global broadcast + every interface's IPv4 **subnet broadcast**
  (routers that drop 255.255.255.255 usually deliver these; also fixes expired-ARP
  unicast) + all known host addresses with **DNS resolution** for hostnames.
- **Ports:** 9 + 47009 (Moonlight Internet Hosting Tool) + GFE/Sunshine service ports
  offset by base port (47998/47999/48000/48002/48010).
- **Bursts:** 3 full bursts 300 ms apart, off the main thread (`Task.detached`) so DNS
  can't stall the UI.
Caveat noted: iOS may EPERM on broadcast sends without the multicast entitlement —
unicast + subnet paths still fire (same as before; no regression).

### 3) iPad keyboard pops up uninvited — (in progress)

### 4) Controller-type passthrough — (in progress)

### 5) Phantom mouse cursor — (in progress)

### 6) Halve leave-chord hold time — (in progress)

### 7) Fade-to-black stream exit — (in progress)

### 8) Instant quit-popup dismiss + default focus — (in progress)

### 9) Restart-PC rising SFX — (in progress)

### 10) App-quit ends host stream — (in progress)

### 11) Multi-controller — (in progress)

## Open questions for William

(collected through the night)
