# iOS streaming — status

**✅ SHIPPED & DEVICE-VERIFIED (2026-07-06):** in-process streaming on iPad works
end-to-end — video (native 2752×2064@120 over a Tailscale DERP relay), game
audio (Opus → RemoteIO), and controller input (full pad forwarding + the
Start+Select+LB+RB quit chord). Perf HUD via Settings ▸ Advanced ▸ Performance
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

## Remaining roadmap (in rough priority)

- Touch-as-mouse/trackpad input (`LiSendTouchEvent` / relative mouse)
- HEVC/HDR (`supportedVideoFormats |= H265/H265_MAIN10`, HEVC path exists in
  `rebuildFormatDescription`, untested)
- Rumble (ConnListenerRumble → GCController.haptics)
- Frame pacing / A-V sync polish; stats HUD could add host fps + loss %

Done since: keep-awake during stream (`refreshKeepAwake` — Auto-Lock killed an
8-minute session; gamepad input never resets the idle timer) and iOS
"Quit Game on App Exit" (scenePhase .background → teardown + /cancel in a UIKit
background task; also prevents host-side stale-session poisoning on relaunch).
