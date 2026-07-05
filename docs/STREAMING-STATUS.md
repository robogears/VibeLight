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

Connection **establishes** every time (all RTSP stages complete). On-device logs
pinned down THREE real causes of the black screen — now fixed:

1. **4K120 @ 150 Mbps over a Tailscale relay** (`connect: … 3840x2160@120 150000kbps`).
   Impossible through DERP — IDR frames shatter into ~103 FEC shards, only ~26
   arrive → `lack of a successful video frame`. **Fix:** `relayCapped()` in
   `InProcessStreamEngine` caps non-LAN streams to ≤1080p / ≤60fps / ≤25 Mbps,
   applied to BOTH `/launch` mode and the stream config.
2. **`malloc: pointer being freed was not allocated` crash** — the connection
   relaunched repeatedly and moonlight-common-c is single-connection, so
   overlapping `LiStartConnection`/`LiStopConnection` double-freed (and scrambled
   the per-session AES keys → the 100% `Failed to decrypt audio packet`). **Fix:**
   all lifecycle calls serialized through one `LifecycleQueue` in
   `MoonlightSession.mm`; the engine fully stops the prior session before launching.
3. `encryptionFlags = ENCFLG_ALL` (matches moonlight-ios/qt) from the prior pass.

Host's real appVersion (from the connect log) = `7.1.431` — so encrypted control
is correct; no appVersion change needed.

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
