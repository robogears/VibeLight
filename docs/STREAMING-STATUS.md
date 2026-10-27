# iOS streaming — status

**✅ SHIPPED & DEVICE-VERIFIED (2026-07-06):** in-process streaming on iPad works
end-to-end — video (native 2752×2064@120 over a Tailscale DERP relay), game
audio (Opus → RemoteIO), and controller input (full pad forwarding + the
Start+Select+LB+RB leave-stream chord — held ~1 s with a progress ring, like the
launcher's hold-to-quit). Perf HUD via Settings ▸ Advanced ▸ Performance
Stats. User settings pass through uncapped; a too-hot profile over a relay
shows up as FEC starvation (`X received < Y needed`) — lower the bitrate.

## Architecture (as landed)

- `VibeLight/Streaming/MoonlightSession.mm` — ObjC++ bridge around
  moonlight-common-c: `LiStartConnection` on a serial lifecycle queue (the
  library is single-connection; overlap = double-free), H.264 Annex-B→AVCC
  decode into `AVSampleBufferDisplayLayer`, Opus multistream → RemoteIO
  AudioUnit through a lock-free SPSC ring, controller snapshots via
  `LiSendMultiControllerEvent`.
- `VibeLight/App/iOS/InProcessStreamEngine.swift` — @MainActor engine behind
  the shared `StreamEngine` seam: /launch → session lifecycle → phase
  transitions, controller passthrough install/remove, perf-stats task,
  AVAudioSession playback category.
- `VibeLight/Input/ControllerManager.swift` — `streamForwarder` flips all pads
  between launcher navigation and raw stream passthrough.

## Hard-won invariants (do not regress)

1. **PICDATA buffer-list entries are RTP fragments, not NALUs.** Reassemble the
   full Annex-B stream, then convert by scanning for real start codes. Treating
   entries as NALUs corrupts every multi-packet frame → silent black screen.
2. **DrSubmit/ClLogMessage run on pool-less C threads** — every ObjC allocation
   there must sit inside `@autoreleasepool` or it leaks to jetsam (~minutes at
   high res).
3. **LiStartConnection/LiStopConnection must never overlap** — serialize through
   `LifecycleQueue`; the engine stops the old session before launching anew.
4. **`disconnect()` must transition phase itself** — after releasing
   session/proxy the termination callback can't reach us; without a local
   transition the UI freezes on `.streaming` over a dead stream.
5. **encryptionFlags = ENCFLG_NONE** with this host; requesting AV encryption
   broke audio decrypt + control (mbedcrypto CBC path is the suspect — revisit
   if a host *requires* encryption).
6. Audio callbacks are allocation-free C with a lock-free ring; drop NEW
   packets when the backlog exceeds ~60 ms (a full-only drop policy ratchets
   latency up after every jitter burst and never drains).
7. **Return DR_NEED_IDR from every submit failure path** (Limelight.h contract).
   DR_OK on an unprocessed IDR marks it consumed in the depacketizer and nothing
   ever re-requests a keyframe — black/corrupt until manual disconnect.
8. `stop()`'s teardown block must capture self STRONGLY (engine drops its ref
   immediately after; weak capture skips LiStopConnection). Remote termination
   also needs an explicit stop() — the callback alone leaves threads running.
9. Host busy (`currentgame != 0`) → `/resume`, never `/launch` (Sunshine rejects
   it). 22-finding parity audit vs moonlight-ios landed 2026-07-06 (91d3ca1).
10. **The ONE shared `displayLayer` re-parents between the iPad `DisplayLayerView`
    and the TV `DisplayHostView`; guard re-attach on TREE MEMBERSHIP
    (`display.superlayer !== layer`), never object identity.** `dismiss()` detaches
    the layer (`removeFromSuperlayer`) but leaves the host's `attached` ref dangling,
    so an identity guard (`attached === display`) skips `addSublayer` on the next
    launch → the TV goes BLACK on every stream RE-launch (fixed 2026-07-07). The
    layer is a lifetime `let`, so its `weak attached` cache never nils on its own.

## Platform behaviours that are NOT bugs

- **The PS/Home button needs two presses on iPadOS, by design.** PROVEN by
  iOS 18's Game Overlay stating it on screen, naming the app: *"Features in
  VibeLight may be designed to use 'PS Button'. To access this functionality
  instead of the Game Overlay, press [PS] twice."* The first press opens
  Apple's Game Overlay; the second reaches the app. There is no opt-out.
  `preferredSystemGestureState = .disabled` is still required (without it the
  button never arrives) but does not override the Overlay's claim on press one.
  Tried and reverted first: subscribing to the Home element directly; a
  minimum-hold latch on GUIDE; announcing pads as Xbox so Sunshine builds a
  virtual X360 pad instead of a DS4; and device logging, which could only see
  the presses that were DELIVERED, never the ones the system had taken. The
  in-stream cheat sheet now says "PS / Xbox button ×2" so users aren't sent
  hunting for a bug that isn't there.

## Remaining roadmap (in rough priority)

- HEVC/HDR (`supportedVideoFormats |= H265/H265_MAIN10`, HEVC path exists in
  `rebuildFormatDescription`, untested)
- Rumble (ConnListenerRumble → GCController.haptics)
- Frame pacing / A-V sync polish; stats HUD could add host fps + loss %

Done since: **external display / TV output** (`App/iOS/ExternalDisplay.swift` —
device-verified). When a TV/monitor is attached, the stream renders on it at the
display's NATIVE resolution while the iPad keeps controls + acts as a trackpad.
The idle LAUNCHER UI on the TV is super-sampled to ≥2× (`launcherRenderScale` +
`ExternalLauncherHost`): old 1080p TVs report `displayScale` 1.0, so a fixed-canvas
`scaleEffect` would rasterize at 1× and UPSCALE to the panel → blurry text. Forcing
≥2× (trait override + `\.displayScale` env + layer `contentsScale`, all at the same
target) rasterizes at 2× and DOWNSAMPLES → crisp. Stream video is unaffected (native
pixel res, separate root VC). KEY LESSON: needs a real `UIWindowScene` — the legacy `UIWindow.screen=` API no
longer renders on external screens, and iOS only creates the external scene when
`UIApplicationSupportsMultipleScenes: true` is in the Info.plist (with
`UIRequiresFullScreen` still true so no Split View). Setting: Settings ▸ Video ▸
Use TV / Monitor (default on, auto-engages). Something stock moonlight-ios can't
do (their issue #634, open since 2024).

### iPadOS 27 external-display compatibility (27 October 2026)

Starting with iPadOS 27, the system supplies the noninteractive TV scene only
after the app registers a scene accessory. `ExternalDisplayAccessoryView`,
mounted on the main iPad interface outside launcher/stream transitions, owns
the registration and unregisters it when dismantled. Its scene delegate feeds
the existing `ExternalDisplay` renderer. iPadOS 17–26 keep the automatic scene
path. See [Apple's registration guidance](https://developer.apple.com/documentation/UIKit/presenting-content-on-a-connected-display?changes=_3).

Verification: 261 Mac tests and 34 iOS tests passed, including registration
lifetime/cleanup and a main-interface wiring regression that fails when the
registration is removed. On 27 October 2026 the owner confirmed the wired TV
mode was "working great" on iPadOS 27 with version 0.2.3 installed. Separate
results were not reported for every stream start/leave/relaunch and
unplug/reconnect scenario; those remain useful checks after future changes.

Also done: touch-as-input (native LiSendTouchEvent + absolute-mouse fallback
with double-tap deadzone; Settings ▸ Input ▸ Touch Control), keep-awake during
stream (`refreshKeepAwake` — Auto-Lock killed an 8-minute session; gamepad
input never resets the idle timer), iOS "Quit Game on App Exit"
(scenePhase .background → teardown + /cancel in a UIKit background task; also
prevents host-side stale-session poisoning on relaunch), and PS/Home-button
delivery in-stream (disable system gestures on the pad while streaming).

## QoL roadmap (from deep-research, ranked by demand × solo-app feasibility)

1. Clipboard sync (client↔host text) — most-reacted open moonlight-qt issue;
   Apollo/Vibepollo has the host side, reverse the wire format from Artemis.
2. Client-driven virtual display (host makes a display matching the client) —
   Apollo's headline differentiator; VibeLight already sends res/fps in /launch.
3. "Match current display" auto stream-mode (macOS side; iOS already native).
4. iOS keyboard — ✅ HARDWARE passthrough DONE (`Input/KeyboardMap.swift`,
   `ControllerManager.keyboardForwarder`, `MoonlightSession.sendKeyboardEvent`:
   GCKeyboard raw keys → Windows VK codes via LiSendKeyboardEvent while
   streaming; held keys released on leave). ✅ On-screen keyboard DONE too
   (`App/iOS/StreamKeyboard.swift`: the iPad's own system keyboard raised over
   the stream, each keystroke sent to the host; nothing is buffered).
5. ✅ iPad → external display at native res — DONE (above).
6. In-stream touch-mode switcher (direct / trackpad / off, mid-session).
7. Surface Apollo per-client tier (permissions, input-only, connect/disconnect
   commands like auto-pause).
8. Custom on-screen buttons (keyboard commands as tappable buttons).
- Microphone passthrough: high demand but blocked on unmerged host PRs — watch.
