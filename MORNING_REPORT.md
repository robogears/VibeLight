# Overnight Run — Morning Report

Branch: `OvernightCodingRun` (forked from v0.1.11). Status legend: ✅ done · 🔬 researched/partial · ⏭ deferred.

## Summary

**All 11 items landed** (10 fully implemented + 1 verified-with-scope-decision), every
change compiled on BOTH platforms (the missing iOS platform was downloaded mid-run so
iOS finally builds on this Mac), and a 3-reviewer adversarial pass audited the whole
diff — its 9 findings (one of them a real high-severity regression in my own first
attempt at item 10) are all fixed. Runtime verification needs your device/hosts — the
checklist is below. Highlights: standalone Mac pairing root-caused to a helper
identity mismatch and fixed with zero fork changes; WoL was doubly broken (weak send
strategy AND in-app-paired hosts never stored a MAC at all); two controllers now
genuinely reach the host as two pads, announced with their real families so a
DualSense becomes a virtual DS4; and the phantom cursor traced to our own absolute
touch surface forwarding stray palm touches as warp+click.

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

### 3) iPad keyboard pops up uninvited — ✅ fixed
**Root cause:** the host menu's add-by-IP `TextField` is the launcher's only
first-responder-capable control; iPadOS auto-directs keyboard focus into it when the
card appears, and the app's custom FocusEngine never resigns it (the two focus systems
were completely disjoint), so the keyboard popped on open and stayed through D-pad
moves. **Fix:** the field is now *disabled* (cannot become first responder → no
keyboard, guaranteed) until explicitly tapped; the tap also aligns the focus engine;
moving focus off the add row re-arms the gate and dismisses the keyboard.

### 4) Controller-type passthrough — ✅ implemented (type reporting; motion/touchpad deferred)
Verified against moonlight-common-c + Sunshine + Apollo source: `LiSendControllerArrivalEvent`
must be a slot's FIRST packet, and with Sunshine/Apollo's default `gamepad=auto`,
reporting `LI_CTYPE_PS` alone makes the host create a **virtual DS4** (PlayStation
glyphs + features in games). Each pad is now announced with its real family — Xbox /
PlayStation (DualShock + DualSense) / Nintendo — mapped from the `GCExtendedGamepad`
subclass with a productCategory fallback. Capabilities stay minimal + honest (analog
triggers only): we don't forward rumble/motion/touchpad events yet, and advertising a
touchpad we don't drive would invite Steam Input's touchpad-as-mouse behavior — the
phantom-cursor trap (see item 5). **Deferred:** motion sensors (host-solicited via
`ConnListenerSetMotionEventState`), DualSense touchpad forwarding, rumble — all natural
follow-ups once rumble lands (already on the roadmap).

### 5) Phantom mouse cursor — ✅ root-caused + fixed (default changed, opt-out added)
**Research verdict (high confidence):** Sunshine injects every client mouse packet via
Win32 `SendInput`, and games (Steam BPM, Apex) re-show the cursor on the very first
mouse event. Our exposure: the ENTIRE iPad screen is an always-live **absolute** touch
surface during streams — a stray palm/grip touch warps the host cursor mid-screen AND
left-clicks (touch → absolute-mouse fallback). The TV-companion trackpad panel is the
same surface, so a resting finger while playing on the TV = cursor mid-match. **Fix:**
while an extended gamepad is connected, touch forwarding is suppressed (stray touches
send nothing). New setting **Input ▸ Touch With Controller** (default Off) restores the
old behavior for anyone who wants pad + touch simultaneously. Touch-only sessions are
unchanged.

### 6) Halve leave-chord hold time — ✅ 2.0 s → 1.0 s
(grace trimmed 0.2 → 0.15 s so the ring appears promptly; ring auto-syncs.)

### 7) Fade-to-black stream exit — ✅ implemented
While the chord is held, a black scrim over the stream tracks the ring (the screen
sinks toward black as you hold); at fire the fade pins fully black through teardown,
and the stream overlay's removal is now actually animated (the old `.transition` had no
animation bound, hence the jump cut) — the launcher fades back in over ~0.45 s.

### 8) Instant quit-popup dismiss + default focus — ✅ fixed
The card now dismisses on the SAME press ( the ~1 s `/cancel` round-trip used to hold
it open → double-press → accidental resume), and **Quit Stream Completely is the
default-focused button** on the session-ended card (was Resume — the double-press
would resume!).

### 9) Restart-PC rising SFX — ✅ fixed (was miswired)
The `.restart` cue was playing when *opening* the confirm dialog (which isn't a
restart) and NEVER on the actual restart commit. It now plays only on the two real
restart triggers, and the motif is a clearly rising four-note climb (G4→C5→E5→A5).

### 10) App-quit ends host stream — ✅ verified (already-correct behavior kept)
Coverage matrix (research-verified against Apple docs + Sunshine source):
- **macOS ⌘Q / menu quit mid-stream:** covered (applicationShouldTerminate → /cancel, 7 s budget).
- **iOS home-swipe / app-switch / foreground swipe-kill while STREAMING:** covered —
  the background transition runs first, our handler fires /cancel in a background task
  (2.5 s budget, inside both the ~30 s background and ~5 s termination watchdogs).
- **Important scope decision (an adversarial reviewer caught my first attempt
  over-reaching):** iOS backgrounding is app-*switching*, not quitting — broadening the
  predicate to "host is busy" would have /cancelled games this device merely *sees*
  running (another client's session! or a game deliberately kept playing via
  disconnect-keep-playing). The guard stays scoped to streams this device is running
  right now. The virtual-controller half of the ask is guaranteed host-side regardless.
- **Not fixable client-side (documented):** iOS *suspended* swipe-kill and jetsam are
  SIGKILL with no callback (Apple-confirmed). Host-side safety net: Sunshine's
  `ping_timeout` (10 s) tears down the stream session, which **frees the virtual
  controllers** automatically — but the game keeps running until a /cancel. macOS
  force-quit similarly orphans the helper (a parent-death watch in the helper fork is
  the fix — logged as follow-up, out of tonight's repo scope).

### 11) Multi-controller — ✅ implemented
**Root cause:** the engine elected ONE pad and dropped the rest, and the ObjC layer
hardcoded `controllerNumber=0, mask=0x1` — every pad collapsed into player 1. Now:
per-pad slot allocator (slots 0–3, GFE-safe cap; keyed on GCController identity —
playerIndex/ordering are unreliable per Apple), per-slot arrival events with real
types (item 4), per-event `LiSendMultiControllerEvent(slot, liveMask, …)`, and on
disconnect the freed slot sends a final zeroed event with its mask bit cleared — the
protocol signal that makes the host destroy that virtual pad. Mirrors
moonlight-ios's reference implementation. macOS unaffected (the helper does its own
SDL pad handling).

## Post-review hardening (adversarial pass over the whole diff)

A 3-reviewer adversarial workflow audited every change; 9 findings, all addressed:
1. **(high)** my first ON-10 broadening would have /cancelled other clients' games on
   any app-switch → reverted to the correct narrow guard (see item 10).
2. Fade-to-black pin was wiped synchronously by `cancelQuitHold()` during teardown
   (the fade would never have shown) → cancel is now a no-op after completion.
3. In 2-player play, player 2's inputs cancelled player 1's leave-chord hold every
   frame → only the *holding* pad's deviating input aborts the hold.
4. The touch gate could swallow a touch's `.up` if a controller connected mid-gesture
   → stuck left-click on the host; in-flight touches now always deliver their release.
5. Quit-mash after instant dismiss walked focus into Restart PC (select → confirm →
   reboot!) → focus parks on the harmless host chip instead.
6. Companion panel still advertised "this screen is a trackpad" while the gate
   suppressed it → copy is now honest and points at the setting.
7. Mouse hover over a host row killed IP-typing mid-word → the keyboard gate only
   re-arms on D-pad/keyboard focus moves, not pointer hover.
8. iOS broadcast sends likely EPERM without Apple's multicast entitlement (pre-existing;
   NOT added — it would break sideload signing). iOS wake leans on unicast + the new
   DNS-resolved paths; documented below.
9. Restart-cue could ring while a restart was already in flight → gated.

## Build verification

- **macOS:** built clean after every batch (5 green builds through the night).
- **iOS:** the iOS 26.5 platform was missing from this Mac's Xcode entirely (why every
  iOS build failed early on) — downloaded it (~8.5 GB) and the full iOS app now
  **builds clean** with all of tonight's changes, on the iPad Pro 13″ (M5) simulator.
- Runtime testing was impossible overnight (hosts asleep, no device) — the items below
  list what to exercise on-device.

## What to test on-device in the morning

1. **Standalone pairing (ON-1):** on the second Mac, delete
   `~/Library/Preferences/com.moonlight-stream.Moonlight.plist` (it holds the helper's
   orphan cert), launch VibeLight, pair, stream — should work with no Moonlight
   installed. (Existing broken installs self-heal with one re-pair even without
   deleting.)
2. **Two controllers on the iPad (ON-11):** both should appear on the host; unplug one
   mid-game — its virtual pad should vanish, the other keeps playing.
3. **DualSense (ON-4):** with Vibepollo's `gamepad=auto`, games should show PlayStation
   glyphs (virtual DS4).
4. **Leave chord (ON-6/7):** ~1 s hold, screen sinks to black as the ring fills, fades
   into the launcher — no jump cut.
5. **Phantom cursor (ON-5):** palm on the iPad mid-controller-game should do nothing;
   Settings ▸ Input ▸ Touch With Controller = On restores the old behavior.
6. **Keyboard (ON-3):** host menu opens with no keyboard; tap the IP field to type.
7. **WoL (ON-2):** wake an asleep host from Mac + iPad; in-app-paired hosts gain the
   Wake option after one refresh (MAC now learned from serverinfo).

## Open questions for William

- **iOS broadcast WoL:** broadcasts likely need Apple's multicast entitlement (an
  application to Apple; sideload profiles can't carry it unapproved). Unicast +
  DNS-resolved addresses work today. Want me to draft the entitlement request?
- **Trackpad while a controller is connected (TV setup):** currently suppressed by
  default (that's the phantom-cursor fix) with the Settings ▸ Input toggle to restore.
  If you'd rather the companion trackpad stay live and only the direct-stream surface
  be gated, that's a two-line change — your call after you feel it.
- **Rumble / motion / DualSense touchpad passthrough (ON-4 stretch):** all feasible per
  the research (host-solicited motion via `ConnListenerSetMotionEventState`, touchpad
  via `LiSendControllerTouchEvent` gated on `LI_FF_CONTROLLER_TOUCH_EVENTS`) — natural
  next session; rumble was already on the roadmap.
- **Helper-fork follow-ups (separate repo):** parent-death watch so a macOS force-quit
  can't orphan StreamHelper; optionally halve the in-helper Start-hold disconnect (2 s)
  to match the iOS chord.
- `requiredSetupVersion` is still 11 (unchanged tonight — no wizard re-show).
