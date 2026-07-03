# Vibepollo Research Report

## (a) What it is / repo

- **Repo:** https://github.com/Nonary/Vibepollo (default branch `master`, ~630 stars, 126 releases, latest **v1.17.0**, 2026-06-24). Maintainer: Nonary. HEAD at research time: `48ad70f6b4c0c91cf31ae837b7005ef9a549c898` (2026-07-02).
- Fork lineage: **Sunshine → Apollo (ClassicOldSong) → Vibepollo (Nonary)**. Self-described as "an AI-enhanced version of Apollo"; ~99% AI-generated code (GPT-5.3-Codex). Explicitly a complementary fork, not a replacement; features unlikely to be backported upstream.
- Windows-focused (many features `#ifdef _WIN32`). Local shallow clone kept at `/private/tmp/claude-502/-Users-william-Documents-VibeLight/6c9f4d52-9eb7-4d9a-b5ce-79d440f26a6b/scratchpad/vibepollo` for further inspection.

## (b) Differences vs Apollo/Sunshine

- Display automation: anti-stuck safeguards for dummy plugs/virtual displays, Win11 24H2 fixes, layout restore after crash/reboot.
- **WGC (Windows Graphics Capture) as a service**, auto-switching capture methods (still captures login screen/UAC); captures frame-generated titles at full rate.
- **Bundled native virtual display driver** (SudoVDA kept as rollback); hybrid-GPU aware; auto-enables on headless hosts to avoid 503 capture errors. `serverinfo` advertises `VirtualDisplayCapable` / `VirtualDisplayDriverReady` (Apollo-style extension fields).
- **WebRTC browser streaming** at `/webrtc` page on the web UI port (signaling via REST + SSE, no WebSocket anywhere in src).
- **Playnite integration** (plugin in `plugins/playnite/`): auto-sync of recently played games, artwork, launch/terminate; web-API endpoints below.
- RTSS + NVIDIA Control Panel integration (frame cap matched to client FPS, V-Sync off), Lossless Scaling + NVIDIA Smooth Motion, DLSS/FSR framegen capture fixes.
- New Vue web UI (responsive), **session-based auth** (login + HttpOnly session cookie + refresh token), **scoped API tokens**, update notifications, session history DB.
- Inherited from Apollo: per-client permission system (PERM bitmask), per-client settings (display mode, virtual display mode/layout, config overrides, HDR profiles, 10-bit SDR preference), clipboard sync endpoints, server commands, input-only mode, OTP pairing.

## (c) API surface

### GameStream protocol (nvhttp) — HTTP 47989 / HTTPS 47984 (client-cert auth on 47984)
Registered in `src/nvhttp.cpp` (`start()`):
- `GET /serverinfo` (both HTTP+HTTPS). Extra fields beyond stock Sunshine: `Permission` (uint32 PERM bitmask of the calling client), `VirtualDisplayCapable`, `VirtualDisplayDriverReady`, `ServerCommand` elements (if perm), `currentgame`, `currentgameuuid`, `state` (`SUNSHINE_SERVER_BUSY`/`SUNSHINE_SERVER_FREE`), `appversion` = `7.1.431.-1`, `GfeVersion` = `3.23.0.74`, `HttpsPort`, `ExternalPort`, `mac`, `LocalIP`, `ServerCodecModeSupport`, `PairStatus`.
- `GET|POST /pair`, `GET|POST /unpair` (both HTTP+HTTPS)
- `GET /applist` (HTTPS) — XML; per-app nodes: `AppTitle`, `ID`, `UUID`, `IDX` (host-defined order index), `IsHdrSupported`. Requires client perm `list|view|launch` (`_all_actions`); otherwise returns a single fake app "Permission denied…" with ID 114514.
- `GET /appasset?appid=<id>` (HTTPS) — returns PNG box art (`proc.get_app_image(appid)`); requires `_all_actions` perm.
- `GET /launch` (HTTPS) — params `appid` and/or `appuuid`, `rikey`, `rikeyid`, `localAudioPlayMode` required. Needs `launch` perm (or `view` to join a running session). Launching special UUID `TERMINATE_APP_UUID` / terminate app id terminates the running app (returns 410 "App terminated.").
- `GET /resume`, `GET /cancel` (HTTPS). `/cancel` requires `launch` perm; terminates RTSP sessions and running app.
- Apollo/Artemis extensions: `GET|POST /actions/clipboard?type=text` (perms `clipboard_read`/`clipboard_set`, client must be in an active stream), `GET /bitrate` (setBitrate), `GET /api/abr/capabilities`.

### Web UI REST API — HTTPS port 47990 (`confighttp`, PORT = base 47989 + 1)
Auth (`src/http_auth.cpp`): `Authorization: Basic <user:pass>`, `Authorization: Bearer <api-token>` (scoped), or `Session <token>` (normally via HttpOnly cookie). State-changing verbs need CSRF token **only for browser requests**; requests without `Origin`/`Referer` headers (curl/native apps) are exempt. API tokens valid for any `/api/*` route except `/api/auth/*`.

Key routes (registered in `src/confighttp.cpp` ~line 5425+):
- Apps: `GET /api/apps` (returns raw apps.json plus `current_app` = running app UUID, `host_uuid`, `host_name`), `POST /api/apps` (save), `POST /api/apps/reorder`, `POST /api/apps/delete`, `DELETE /api/apps/{uuid}` and `DELETE /api/apps/{index}`, `POST /api/apps/launch` (JSON body `{"uuid": "..."}`), `POST /api/apps/close` (no body; terminates running app), `POST /api/apps/purge_autosync`, `POST /api/apps/rtx_hdr/live` (Win).
- Artwork: `GET /api/apps/{uuid}/cover` (serves cover image, correct MIME, `Cache-Control: private, max-age=300`), `GET /api/apps/{uuid}/icon` (Playnite icon PNG), legacy `GET /api/covers/{index}`, `POST /api/covers/upload` and per-uuid cover upload (accepts `{"url": "https://images.igdb.com/..."}"` restricted to images.igdb.com, or `{"data": base64}`).
- Session/state: `GET /api/session/status` → `{activeSessions, appRunning, appName, paused, status}`; `GET /api/rtsp/sessions`; `GET /api/webrtc/sessions`; `GET /api/host/stats` (live CPU/GPU/RAM/VRAM/temps); `GET /api/host/info`.
- Session history: `GET /api/history/sessions?limit=&offset=`, `GET /api/history/sessions/active`, `GET|DELETE /api/history/sessions/{uuid}`.
- Clients: `GET /api/clients/list`, `POST /api/clients/update` (per-client: `name`, `display_mode`, `output_name_override`, `always_use_virtual_display`, `virtual_display_mode`, `virtual_display_layout`, `config_overrides`, `prefer_10bit_sdr`, `enable_legacy_ordering`, `allow_client_commands`, `perm` bitmask, `do`/`undo` cmds, `hdr_profile`), `POST /api/clients/unpair`, `POST /api/clients/unpair-all`, `POST /api/clients/disconnect` (body `{"uuid": ...}`), `GET /api/clients/hdr-profiles` (Win).
- Pairing: `POST /api/pin` (body `{"pin": "...", "name": "..."}`), `POST /api/otp` (body `{"passphrase": ">=4 chars", "deviceName": ...}` → one-time PIN valid 3 min).
- Config: `GET|POST|PATCH /api/config`, `GET /api/configLocale`, `GET /api/metadata`, `POST /api/password`, `POST /api/restart`, `POST /api/quit`, `GET /api/logs`, `GET /api/logs/export` (Win, ZIP).
- Auth/session: `POST /api/auth/login`, `POST /api/auth/refresh`, `POST /api/auth/logout`, `GET /api/auth/status`, `GET /api/auth/sessions`, `DELETE /api/auth/sessions/{id}`.
- API tokens: `POST /api/token` (body `{"scopes":[{"path":"/api/apps","methods":["GET"]}]}` → `{"token": "..."}` shown once), `GET /api/tokens`, `GET /api/token/routes`, `DELETE /api/token/{hash}`, `GET /api/csrf-token`.
- WebRTC signaling (REST+SSE, no WebSocket): `POST|GET /api/webrtc/sessions`, `GET|DELETE /api/webrtc/sessions/{id}`, `POST .../offer`, `GET .../answer`, `GET|POST .../ice`, `GET .../ice/stream` (Content-Type `text/event-stream`), `GET /api/webrtc/cert`.
- Playnite (Win): `GET /api/playnite/status|games|categories`, `POST /api/playnite/install|uninstall|force_sync|launch`.
- Displays/health (Win): `GET /api/display-devices?detail=full`, `GET /api/framegen/edid-refresh`, `GET /api/health/vigem`, `GET /api/health/vulkan-hdr-layer` (+`/register`), `GET /api/health/crashdump` (+`/dismiss`), `POST /api/display/export_golden`, `GET /api/display/golden_status`, `DELETE /api/display/golden`, `GET /api/vigembus/status`, `POST /api/vigembus/install`.
- Docs: `docs/api.md` in-repo documents the REST API, CSRF and token model.

## (d) Box art storage/serving

- Cover resolution (`resolve_cover_path_for_uuid`, src/confighttp.cpp:213): reads `apps.json` (`config::stream.file_apps`), takes the app's `image-path`; tries it absolute, then relative to config dir, then assets dir, then `covers/` under appdata. Fallbacks: `<appdata>/covers/<uuid>.{png,jpg,jpeg,webp}`, then `<appdata>/covers/playnite_<playnite-id>.png`, finally default `assets/box.png`. On Windows, `platf::appdata()` = `<install dir>\config`, so covers live at `<install dir>\config\covers\`.
- Served via `GET /api/apps/{uuid}/cover` on 47990 (auth required) and via GameStream `GET /appasset?appid=<id>` on 47984 (client-cert; always `image/png` content type there).

## (e) moonlight-qt 6.x compatibility

- Fully Moonlight-compatible: reports `appversion 7.1.431.-1` / `GfeVersion 3.23.0.74` exactly like Sunshine, so moonlight-qt (incl. 6.x, latest 6.1.0) treats it as a Sunshine-family host. Standard pairing, applist, launch/resume/cancel semantics preserved. README: "still letting you use the regular Moonlight-compatible streaming path".
- Extra applist/serverinfo fields (`UUID`, `IDX`, `Permission`, `VirtualDisplay*`) are ignored by stock moonlight-qt; only Apollo's Artemis clients use them.
- moonlight-qt's client cert/key (from its plist on macOS) works unchanged for 47984 HTTPS and stream launch — Vibepollo keeps the same cert-pinning pairing model.
- Permission caveat: first-ever paired client gets `PERM::_all`; every later paired client gets `PERM::_default = view | list` (NO launch, NO input) until an admin raises perms in the web UI (`POST /api/clients/update` with `perm`). A low-perm client gets 403 on `/launch` and a fake "Permission denied" applist entry.
- Comment in applist code: the special "Terminate" fake app entry is only injected when input-only mode is enabled; "Otherwise, Moonlight handles terminate/resume UI without needing a fake app entry".

## (f) Zero-width characters in app names — CONFIRMED, mechanism identified

- File `src/zwpad.h` (inherited from Apollo, same file there): namespace `zwpad`, uses **U+200B (ZERO WIDTH SPACE) as binary '0'** and **U+200C (ZERO WIDTH NON-JOINER) as binary '1'**. `pad_for_ordering(text, padBits, index)` prepends a fixed-width big-endian binary encoding of the app's index as invisible chars, so alphabetical sorting in Moonlight clients reproduces the host-configured app order (U+200B sorts before U+200C). `pad_width_for_count(count)` = `bit_width(count-1)`, min 1.
- Applied in `src/nvhttp.cpp` applist (~line 2512): `enable_legacy_ordering = config::sunshine.legacy_ordering && named_cert_p->enable_legacy_ordering;` then `app_name = zwpad::pad_for_ordering(app.name, bits, i)`.
- `"​​​Desktop"` = 3 pad bits (5–8 visible apps) with Desktop at index 0.
- Config key: `legacy_ordering` in sunshine.conf — default `false` in both current Vibepollo and current Apollo master, but per-client `enable_legacy_ordering` defaults `true`; the user's host evidently has global `legacy_ordering` enabled (or runs an older build where it defaulted on). It is called "legacy" because Artemis/newer clients use the `IDX` field instead.
- **Implication for VibeLight:** strip leading U+200B/U+200C from `AppTitle` for display; never match apps by name — use `ID`/`UUID` (both present in Vibepollo applist XML). Alternatively sort by `IDX`.