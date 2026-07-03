# Box Art Strategy Research for VibeLight (Moonlight-family launcher)

## (a) Sunshine / Apollo / Vibepollo `/appasset` endpoint

**Protocol.** `GET https://<host>:47984/appasset?appid=<id>` — registered ONLY on the nvhttp **HTTPS** server (`https_server.resource["^/appasset$"]["GET"]`, Sunshine `src/nvhttp.cpp` ~line 1365; Vibepollo `src/nvhttp.cpp` line 3692). That means the request must present the paired client certificate (the same cert/key VibeLight imports from moonlight-qt's plist). It is NOT available on plain HTTP 47989. moonlight-qt's `NvHTTP::getBoxArt()` sends `appasset?uniqueid=...&uuid=...&appid=N&AssetType=2&AssetIdx=0`; the `AssetType/AssetIdx` args are GFE legacy and ignored by Sunshine-family hosts — only `appid` matters.

**Response.** Always `Content-Type: image/png`, raw PNG bytes streamed from a file on the host. No ETag, no Cache-Control, no Last-Modified — zero HTTP cache validators. On Vibepollo the handler additionally checks per-client permissions (`has_client_perm(... PERM::_all_actions)`); an un-permissioned client gets 401.

**Host-side resolution (`proc_t::get_app_image` → `validate_app_image_path`, identical logic in Sunshine/Apollo/Vibepollo `src/process.cpp`):**
1. Look up app by id; take its `image-path` field from apps.json / the app config.
2. Empty path → return `DEFAULT_APP_IMAGE_PATH` = `SUNSHINE_ASSETS_DIR "/box.png"` (defined in `src/process.h`).
3. Extension must be `.png` (case-insensitive) — anything else → default box.png. File must also pass an 8-byte PNG signature check → otherwise default.
4. Relative paths resolve against the host's assets dir; legacy literal `"./assets/steam.png"` is remapped to the installed `steam.png`.

**Stock host images (from Vibepollo `src_assets/common/assets/`, same family as Apollo):**
- `box.png` — the "no art" placeholder: **130×180 px**, sha256 `d9164ebd069b5f735eb8efc557801778498da37f572ef70e3d35604739e6c613`
- `desktop.png`, `desktop-alt.png`, `steam.png`, `virtual_desktop.png`, `input_only.png`, `terminate.png`, `template.png` — all **600×800 px** (3:4). sha256s: desktop `477c3fbc…7577761`, steam `ed59b134…3d3108`, desktop-alt `d78b2200…30b1418`, virtual_desktop `8ebcf836…f1a9398`, input_only `c8ec969c…2435673`, terminate `411dc675…1979300`, template `87a2b8fa…0180640`
- `playnite_boxart.png` — **600×900 px** (2:3), sha256 `15997479…a93d5ec`

Default apps.json ships `Desktop` with `"image-path": "desktop.png"` and `Steam Big Picture` with `"image-path": "steam.png"` — so those two return *real* (if generic) art, not box.png.

**Placeholder detection:** hash the downloaded bytes and compare against the box.png sha256 (or check dimensions == 130×180). Optionally treat the other stock-asset hashes as "generic host art, OK to replace with SGDB art".

**Vibepollo Playnite cover sync.** Vibepollo apps carry `playnite-id` and `uuid` fields. `get_cover_png_for_playnite_game()` (`src/platform/windows/playnite_integration.cpp` line 1346) converts the Playnite library's box art to PNG (96 dpi, `platf::img::convert_to_png_96dpi`) into `<appdata>/covers/playnite_<id>.png`, re-converting when the source is newer; the web API (`confighttp_playnite.cpp: enhance_app_with_playnite_cover`) injects that path as the app's `image-path`. Net effect: Playnite-synced games served over `/appasset` have **real cover art** (typically Playnite's ~600×900 vertical covers, re-encoded PNG).

**App-ID stability gotcha (Vibepollo `calculate_app_id`):** IDs are CRC32 of the app **UUID** when present, so *artwork can change without the appid changing* (comment: "Artwork can be refreshed by Playnite sync, so image bytes must not affect launch identity"). Legacy apps without UUID hash `name + image sha256`, so their ID changes when the image changes. Consequence: a boxart disk cache keyed only on `(host, appid)` can go stale on UUID-based hosts; use a TTL or re-fetch on refresh.

**Per-app image configuration host-side:** user sets `image-path` per app in the host web UI (port 47990) or apps.json; must be a PNG on the host filesystem. There is no upload-from-client path in stock Sunshine; Vibepollo's web UI has a cover-picker that saves under `covers/`.

## (b) SteamGridDB API v2 (verified from the official OpenAPI spec at `https://www.steamgriddb.com/static/openapi.yml`, spec version 2.10.0)

- **Base URL:** `https://www.steamgriddb.com/api/v2`
- **Auth:** required for all requests. Free account → generate key at `https://www.steamgriddb.com/profile/preferences/api`. Send `Authorization: Bearer <key>` (HTTP bearer scheme). 401 without it.
- **Endpoints (GET):**
  - `/search/autocomplete/{term}` — search by name (URL-encode term). Returns `{success, data:[{id, name, types[], verified}]}` (live API also returns `release_date`).
  - `/games/id/{gameId}`, `/games/{platform}/{platformId}` (platform enum for this route: `steam`, `flashpoint`).
  - `/grids/game/{gameId}` and `/grids/{platform}/{id}` — platform enum: `steam, origin, egs, bnet, uplay, flashpoint, eshop`; the platform route accepts comma-separated multiple ids and returns HTTP 207 with per-game results.
  - Same two shapes for `/heroes/...`, `/logos/...`, `/icons/...`.
- **Common query params:** `styles`, `dimensions`, `mimes`, `types` (comma-delimited), `nsfw`, `humor`, `epilepsy` (`false`(default)/`true`/`any`), `oneoftag` (`humor,nsfw,epilepsy`), `limit` (default 50, values >50 ignored), `page` (0-based).
- **Enums:**
  - Grid styles: `alternate, blurred, white_logo, material, no_logo`; grid dimensions: `460x215, 920x430, 600x900, 342x482, 660x930, 512x512, 1024x1024` (600×900 is the standard Steam vertical capsule; 660×930 is the hi-res variant).
  - Hero styles: `alternate, blurred, material`; hero dimensions: `1920x620, 3840x1240, 1600x650`.
  - Logo styles: `official, white, black, custom`; logo mimes exclude jpeg (`image/png, image/webp`).
  - Icon styles: `official, custom`; icon dimensions are square sizes 8…1024; icon mimes `image/png, image/vnd.microsoft.icon`.
  - Mimes (grids/heroes): `image/png, image/jpeg, image/webp`. Types: `static, animated` (default `static`).
- **Asset response object:** `{id, score, style, url (full size), thumb (thumbnail), tags[], author{name, steam64, avatar}}` inside `{success, data[], page, total, limit}`. Sort by `score` for "best" art.
- **CDN:** assets live at `https://cdn2.steamgriddb.com/{grid|thumb|hero|logo|icon}/<hash>.<png|jpg|webp>` — content-hashed filenames served with `Cache-Control: max-age=31536000`. Treat URLs as immutable → cache forever on disk.
- **Rate limits:** none published anywhere in the spec or docs; community reports (steamtinkerlaunch wiki) say batch usage does get rate-limited. Be conservative: serialize requests (~1 req/s), cache all lookups, never re-search on every launch.
- **Terms for a free OSS client:** the site ToS at `/terms` is a JS SPA and could not be extracted server-side; the API docs impose no stated usage terms beyond needing a key. Established practice in free OSS apps that the SGDB docs themselves showcase ("Projects using the API": Steam ROM Manager, UWPHook, steamtinkerlaunch, GameHub, boppreh/steamgrid, clear, Playnite SGDB extension, decky-steamgriddb) is: **have the user paste their own API key** (steamtinkerlaunch's documented approach; also avoids shipping a secret in a public repo), attribute "Artwork provided by SteamGridDB" with a link, keep nsfw/humor filters at their default `false`. Note the artwork itself is community-uploaded and largely copyrighted game art — display in a personal launcher matches how every other launcher uses it, but don't redistribute the images in the app bundle.

## (c) How other launchers solve artwork

- **moonlight-qt (the reference for host art):** `app/backend/boxartmanager.cpp` — disk cache at `<cache dir>/boxart/<computerUUID>/<appId>.png`; QThreadPool capped at 4 concurrent fetches ("not crushing GFE with tons of requests"); returns bundled placeholder `qrc:/res/no_app_image.png` immediately and swaps when the network fetch lands; retries a failed fetch exactly once; cache never revalidated, wiped only when the PC is deleted. No SGDB integration at all.
- **Playnite:** artwork comes from *metadata extensions* (IGDB and others; a popular SteamGridDB metadata extension exists) applied at import time, plus a manual per-game "web image search" in the edit dialog; media is copied into Playnite's own library-files store. Pattern: automatic provider + manual override, all persisted locally.
- **Pegasus:** no online scraping at all — purely local assets: `assets.boxfront:` entries in `metadata.pegasus.txt`, auto-discovered `media/<game>/boxFront.png` directories, and native recognition of Skraper's media layout. Pattern: filesystem-convention fallback chain.
- **MoonDeck (Steam Deck):** MoonDeck itself does **no artwork**; it creates Steam shortcuts for host apps (plus its `MoonDeckStream` runner app on the host), and users apply art with the separate **decky-steamgriddb** plugin, which sets capsule/wide-capsule/hero/logo/icon on any Steam or non-Steam shortcut via the SGDB API.
- **Daijishou (Android retro frontend):** built-in scraper with its own sources plus manual "Import Preview Media" folder mapping; SteamGridDB support was still an open feature request (TapiocaFox/Daijishou issues #345, #688).

Common pattern: **layered art with user override — platform/host art → community DB (almost always SteamGridDB for PC-game box art) → manual/generated fallback**, everything cached locally.

## (d) Name-matching strategy

**Zero-width injection — confirmed, host-side, Apollo family.** Apollo and Vibepollo ship `src/zwpad.h`: when "legacy ordering" is active, every `AppTitle` in the `/applist` XML is prefixed with a fixed-width binary index encoded in zero-width characters — **U+200B ZERO WIDTH SPACE = bit 0, U+200C ZERO WIDTH NON-JOINER = bit 1, MSB first**, width = `bit_width(appCount-1)` (min 1). Purpose: force Moonlight clients that sort alphabetically to display the host's ordering (U+200B < U+200C lexically). Activation: `config::sunshine.legacy_ordering` (global, default **false** in current Apollo and Vibepollo) AND per-client `enable_legacy_ordering` (default **true**). So any Apollo/Vibepollo host with the global flag on will feed VibeLight invisible-prefixed names. MoonDeck does *not* inject zero-width chars (verified by grepping its repo); its contribution to weird names is the literal app `MoonDeckStream` plus users' custom host apps.

**Vibepollo/Apollo applist extensions:** each `<App>` node carries `AppTitle`, `ID`, and extra `UUID` and `IDX` fields (stock Sunshine has only ID/AppTitle). `IDX` gives you the host ordering directly — prefer it over relying on the ZW-prefix trick. Pseudo-apps to special-case: Vibepollo/Apollo emit a "Terminate …" entry (`terminate_app_id`) and hide other apps while streaming when input-only mode is on; also `Virtual Desktop` / `Input Only` entries exist on Apollo-family hosts.

**Recommended normalization pipeline (in order):**
1. Strip zero-width/invisible code points: U+200B, U+200C (the two actually used), plus U+200D and U+FEFF defensively. Keep the **raw** name too — moonlight-qt CLI launches match app names against the same padded applist, so pass the raw name (or better, launch by appid if using `moonlight stream` name matching fails).
2. Unicode-normalize (NFKC), trim, collapse internal whitespace.
3. Strip trailing parenthetical qualifiers for search purposes: "Playnite (Fullscreen)" → "Playnite"; also strip ™ ® ©.
4. Alias table for known system/launcher tiles — do NOT send these to SteamGridDB; render bespoke tiles instead: `Desktop`, `Virtual Desktop`, `desktop-alt`, `Input Only`, `Terminate*`, `Steam Big Picture` (use Steam-branded tile), `Playnite`/`Playnite (Fullscreen)`, `MoonDeckStream`, `vibeshine`/host-utility apps.
5. Remaining names → SGDB `/search/autocomplete/{term}`; choose `data[0]` with a preference for `verified == true` and a case/punctuation-insensitive similarity check against the query (reject if similarity is poor — better a generated tile than wrong art). Persist the `appName → sgdbGameId` decision so search runs once per app ever.
6. Bonus on Vibepollo hosts: the web API (`/api/apps`, port 47990, admin basic-auth — probably out of scope for the launcher) knows `playnite-id`; the nvhttp applist `UUID` is a stable join key for your cache.

## (e) Local disk caching on macOS

- **Location:** `FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)` + bundle-id subfolder → `~/Library/Caches/<bundle-id>/`. Correct per Apple's guidance for regenerable data; the system may purge it, which is fine because every layer is re-fetchable. Keep the *decisions* (name→SGDB-id mapping, chosen grid id, user overrides) in `~/Library/Application Support/<bundle-id>/artwork-index.json` — that's user state, not purgeable cache.
- **Layout (mirrors moonlight-qt):**
  - `Caches/<bid>/boxart/<hostUUID>/<appId>.png` — host `/appasset` bytes
  - `Caches/<bid>/sgdb/<gameId>/grid-<assetId>.<ext>` (+ `hero-…`, `logo-…`) — SGDB assets
- **Validators:** `/appasset` sends no ETag/Cache-Control → manual policy: cache indefinitely, but re-fetch when (a) app appears/disappears from applist, (b) sha256 of a cheap periodic re-fetch differs, or (c) TTL ~24 h expires on a UUID-stable Vibepollo host (artwork can change under the same appid there). Legacy-ID hosts self-invalidate because the appid changes with the image.
- **SGDB CDN:** content-hashed URLs + `Cache-Control: max-age=31536000` → cache forever keyed by URL; never revalidate. `URLCache` would work but explicit files give offline startup and simple SwiftUI loading.
- **Performance:** decode off-main; downsample to tile size with ImageIO (`CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize`) so a wall of 600×900 PNGs doesn't balloon memory; cap concurrent host fetches at ~4 like moonlight-qt to avoid hammering the host.

## Recommended concrete pipeline

1. **Applist ingest** (HTTPS 47984, client cert): store raw name, cleaned display name (ZW-stripped), appid, UUID/IDX if present.
2. **Tier 0 — instant generated tile:** always render immediately: deterministic gradient seeded by a hash of the cleaned name (stable hue pair), 2:3 aspect, app name set in bold rounded type (2-line truncation, auto-shrink), optional big monogram. No network dependency, no flicker across launches.
3. **Tier 1 — host art:** fetch `/appasset?appid=`; if sha256 == box.png hash (or 130×180) → keep generated tile; if it matches a stock-asset hash (desktop/steam/etc.) → usable but mark "generic, SGDB may improve"; otherwise it's real art (e.g., Playnite-synced covers) → display it (aspect-fill into 2:3; host art is 600×800 3:4 for stock, 600×900 for Playnite covers).
4. **Tier 2 — SGDB enrichment (optional, only when user supplies an API key):** for non-aliased apps whose host art is default/generic: `/search/autocomplete` → `/grids/game/{id}?dimensions=600x900,660x930&mimes=image/png,image/jpeg&types=static` (nsfw/humor default to false) → highest `score` → download `url` → cache → crossfade in. Optionally grab a hero (`1920x620`) for a detail/focus view and a logo for overlay. One-time per app; persist mapping; allow per-app manual re-pick later.
5. **Precedence:** user override > SGDB art > non-default host art > stock host art > generated tile. Every tier cached on disk; UI never blocks on network.