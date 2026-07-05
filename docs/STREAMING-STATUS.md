# iPad streaming + goal status (resume checkpoint)

_Last updated by the streaming debug session. All code below is committed and
builds green (macOS + iOS-sim, 89 tests). Remaining work is on-device
verification only — which needs the iPad in hand + the host awake._

## The four goal items

| # | Item | Code state | Verified on device? |
|---|------|-----------|---------------------|
| 1 | Streaming video on iPad | Full pipeline built (connect → H.264 decode → screen) | ❌ — connects, but last test = black screen (see below) |
| 2 | MoonDeckBuddy pairing | Fixed: reads `{"state":"Paired"}` string (v7+v8); tested in unit tests | ❌ |
| 3 | Bottom-left touch buttons | Coded: touch-mode label buttons in the hint bar | ❌ |
| 4 | Portrait lock | Coded: `UIApplicationDelegateAdaptor` forces landscape | ❌ |

## Streaming — where it actually stands

Connection **establishes** against the host (all RTSP stages complete). Last
on-device test showed a **black screen** with these log signatures:
- `Failed to decrypt audio packet` on every packet
- `Waiting for IDR frame` forever / `Unrecoverable frame … 26 received < 103 needed`
- `Failed to send ENet control packet` / control stream disconnect

Diagnosis (from reading vendored common-c + moonlight-ios/qt): the non-standard
`ENCFLG_AUDIO` flag created an inconsistent encryption negotiation. **Fix applied:
`encryptionFlags = ENCFLG_ALL`** (what the reference clients use) + a connect-time
log line.

## To resume — do this on the iPad (host awake)

1. Rebuild (accept Xcode's "reload project" prompt), tap an app.
2. Paste back:
   - the `[VibeLight] connect: appVersion=… enc=… …` line (reveals the host's real
     appVersion — control-stream encryption hinges on it), and
   - whether `Failed to decrypt audio packet` and `Waiting for IDR frame` cleared.

That single output decides the next lever:
- **Audio still fails to decrypt** → key/version issue; check the logged appVersion
  vs the hardcoded `"7.1.431.0"` fallback in `InProcessStreamEngine.launch`.
- **Audio fixed but video still starves** (`26 < 103`) → it's bandwidth over the
  **Tailscale relay**; lower the bitrate (Settings ▸ Video) so IDR frames fit.

## Key files
- `VibeLight/Streaming/MoonlightSession.mm` — LiStartConnection + H.264 decoder
- `VibeLight/App/iOS/InProcessStreamEngine.swift` — launch/keys/engine (appVersion here)
- `VibeLight/App/iOS/StreamView.swift`, `UI/RootView.swift` — the on-screen layer
- Next: Phase 4 = audio (Opus→AVAudioEngine) + input (GCController→LiSendControllerEvent)
