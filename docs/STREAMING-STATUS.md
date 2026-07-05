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
6. Audio callbacks are allocation-free C with a lock-free ring; drop when full.

## Remaining roadmap (in rough priority)

- Touch-as-mouse/trackpad input (`LiSendTouchEvent` / relative mouse)
- HEVC/HDR (`supportedVideoFormats |= H265/H265_MAIN10`, HEVC path exists in
  `rebuildFormatDescription`, untested)
- iOS quit-on-app-exit (scenePhase → /cancel, mirror macOS "Quit Game on App Exit")
- Frame pacing / A-V sync polish; stats HUD could add host fps + loss %
