# GameStream-compatible HTTP(S) API — Sunshine / Apollo / Vibepollo, as consumed by Moonlight

All findings verified directly against current source: `LizardByte/Sunshine src/nvhttp.cpp + nvhttp.h + crypto.cpp` (master, fetched 2026-07-03), `Nonary/Vibepollo src/nvhttp.cpp + nvhttp.h + crypto.h` (master), and `moonlight-stream/moonlight-qt app/backend/{nvhttp.cpp,nvhttp.h,nvcomputer.cpp,nvaddress.h,identitymanager.cpp,nvpairingmanager.cpp,main.cpp}`. Vibepollo (github.com/Nonary/Vibepollo) is a fork of Apollo (ClassicOldSong/Apollo), itself a Sunshine fork; its nvhttp is Apollo's, with the same core GameStream API plus extensions (documented below).

## 1. Ports

Sunshine-family servers have one configurable "base port" (default **47989**). Everything else is an offset (`net::map_port(offset)` = base + offset):

| Port | Offset | Protocol | Purpose |
|---|---|---|---|
| **47984** | base − 5 (`PORT_HTTPS = -5`) | HTTPS/TLS, **mTLS** | Authenticated GameStream API |
| **47989** | base + 0 (`PORT_HTTP = 0`) | Plain HTTP | Unauthenticated: `/serverinfo`, `/pair` only |
| **47990** | base + 1 | HTTPS | Sunshine **Web UI / config REST API** (confighttp; Basic-auth username/password, NOT part of the GameStream protocol) |
| 48010 | base + 21 | TCP | RTSP setup (returned in `sessionUrl0`) |
| 47998/47999/48000 | — | UDP | video / control / audio streams |

moonlight-qt constants (`app/backend/nvaddress.h`): `#define DEFAULT_HTTP_PORT 47989`, `#define DEFAULT_HTTPS_PORT 47984`. The client learns the real HTTPS port from the `HttpsPort` field of an HTTP `/serverinfo` response, falling back to 47984.

## 2. Endpoint → server matrix (verbatim from route registration)

**Upstream Sunshine** (`nvhttp.cpp start()`):
- HTTPS 47984 (all GET): `^/serverinfo$`, `^/pair$`, `^/applist$`, `^/appasset$`, `^/launch$`, `^/resume$`, `^/cancel$`
- HTTP 47989 (all GET): `^/serverinfo$`, `^/pair$` — *nothing else*; everything unregistered returns XML `<root status_code="404"/>`.

**Vibepollo/Apollo additions**:
- HTTPS: same core set, plus `^/pair/?$` (GET **and** POST), `^/unpair/?$` (GET+POST), `^/actions/clipboard$` (GET=read host clipboard, POST=set; needs `type` arg), `^/bitrate$` (GET, `bitrate` arg — dynamic session bitrate), `^/api/abr/capabilities$` (GET).
- HTTP: `serverinfo`, `pair` (GET+POST), `unpair` (GET+POST).

## 3. Common request conventions (moonlight-qt `NvHTTP::openConnection`)

Every request the client makes is `GET http(s)://host:port/<command>?uniqueid=...&uuid=...[&args]`:

```cpp
url.setPath("/" + command);
url.setQuery("uniqueid=" + (m_UseTrueUid ? IdentityManager::get()->getUniqueId() : "0123456789ABCDEF") +
             "&uuid=" + QUuid::createUuid().toRfc4122().toHex() +
             ((arguments != nullptr) ? ("&" + arguments) : ""));
request.setSslConfiguration(IdentityManager::get()->getSslConfig());   // client cert+key on EVERY request
```

- `m_UseTrueUid = !computer->isNvidiaServerSoftware` → **for Sunshine-family hosts moonlight sends its real random uniqueid**; the placeholder `0123456789ABCDEF` is only for real GFE. Sunshine barely uses `uniqueid`: only as the pairing-session key during `/pair`, and in HTTPS `/serverinfo` merely *presence-checked* to set `PairStatus=1`. Identity/authorization is purely the TLS client certificate.
- `uuid=` is a random per-request value; Sunshine ignores it entirely (cache-buster). Safe for VibeLight to send anything or omit `uuid` (but send `uniqueid` — see PairStatus and pair).
- All responses (except appasset) are XML: `<?xml version="1.0" encoding="utf-8"?><root status_code="200" ...>...</root>`. Moonlight's `verifyResponseStatus` reads the **`status_code` attribute of `<root>`** (must be 200) and `status_message` on failure — you must check the XML attribute, not just the HTTP status line. HTTP/2 must be disabled; connections are not reused (`close_connection_after_response = true` server-side).

## 4. Endpoints in detail

### GET /serverinfo (HTTP 47989 unauthenticated, or HTTPS 47984 with client cert)
Query: `uniqueid`, `uuid` (both effectively optional; over HTTPS, presence of `uniqueid` ⇒ `PairStatus=1`).

Sunshine response fields (verbatim tree.put order):
```xml
<root status_code="200">
  <hostname>MyPC</hostname>
  <appversion>7.1.431.-1</appversion>          <!-- Sunshine/Vibepollo constant; negative last part = "not GFE" -->
  <GfeVersion>3.23.0.74</GfeVersion>            <!-- constant -->
  <uniqueid>{server-uuid}</uniqueid>
  <HttpsPort>47984</HttpsPort>
  <ExternalPort>47989</ExternalPort>
  <MaxLumaPixelsHEVC>1869449984</MaxLumaPixelsHEVC>   <!-- "0" if HEVC disabled -->
  <mac>aa:bb:cc:dd:ee:ff</mac>                  <!-- HTTPS only; "00:00:00:00:00:00" over HTTP -->
  <LocalIP>192.168.1.10</LocalIP>               <!-- 127.0.0.1 for pure-IPv6 connections -->
  <ServerCodecModeSupport>259</ServerCodecModeSupport>  <!-- bitmask: 0x1 H264, 0x100 HEVC, 0x200 HEVC Main10, 0x1_0000 AV1 main8, 0x2_0000 AV1 main10, plus 4:4:4 bits -->
  <ExternalIP>...</ExternalIP>                  <!-- only if configured -->
  <PairStatus>1</PairStatus>                    <!-- 1 ONLY over verified HTTPS with uniqueid param; always 0 over HTTP -->
  <currentgame>0</currentgame>                  <!-- running appid, 0 if idle -->
  <state>SUNSHINE_SERVER_FREE</state>           <!-- or SUNSHINE_SERVER_BUSY when an app is running -->
</root>
```
Vibepollo/Apollo adds (HTTPS only): `<Permission>` (uint32 bitmask, see §8), `<VirtualDisplayCapable>true</VirtualDisplayCapable>`, `<VirtualDisplayDriverReady>`, repeated `<ServerCommand>` elements (if client has server_cmd permission), and `<currentgameuuid>`; over HTTP it forces `currentgame=0`, `currentgameuuid=""`, `state=SUNSHINE_SERVER_FREE` and `Permission=0` (i.e. Vibepollo hides busy-state from unauthenticated HTTP; upstream Sunshine does NOT hide it on HTTP).

What moonlight-qt reads from serverinfo (`nvcomputer.cpp` + `nvhttp.cpp`): `hostname`, `uniqueid` (→ host UUID), `mac`, `ServerCodecModeSupport`, `MaxLumaPixelsHEVC`, `LocalIP`, `HttpsPort`, `ExternalPort`, `ExternalIP`, `state` (`isNvidiaServerSoftware = state.contains("MJOLNIR")`; busy check = `state.endsWith("_SERVER_BUSY")`), `PairStatus == "1"`, `appversion`, `GfeVersion`, `gputype`, `currentgame` (only trusted when state ends with `_SERVER_BUSY`, else forced 0).

Client polling strategy (`NvHTTP::getServerInfo`): if it has a pinned server cert + known HTTPS port → try HTTPS `/serverinfo` first; on XML-status 401 (cert rejected/unpaired) → retry over HTTP 47989. Before pairing, use HTTP only, read `HttpsPort` from response.

### GET /applist (HTTPS only)
Query: just `uniqueid`&`uuid`. Response:
```xml
<root status_code="200">
  <App><IsHdrSupported>1</IsHdrSupported><AppTitle>Desktop</AppTitle><ID>881448767</ID></App>
  <App>...</App>
</root>
```
Moonlight parses per-App: `AppTitle` (may be empty element), `ID` (int), `IsHdrSupported` ("1"), `IsAppCollectorGame` (GFE-only, absent on Sunshine). Vibepollo/Apollo adds `<UUID>` and `<IDX>` per app; without "List applications" permission it returns a single fake app `ID=114514`, `AppTitle="Permission denied - enable \"List applications\" for this device in the host's Web UI"`.

### GET /appasset (HTTPS only)
Query (verbatim moonlight-qt): `appid=<id>&AssetType=2&AssetIdx=0`. Response: raw `image/png` body (Sunshine serves the app's configured `image-path` or default `box.png`; HTTP 200, non-XML). Sunshine reads only `appid` and ignores AssetType/AssetIdx.

### GET /launch (HTTPS only)
Server-required params (Sunshine 400s "Missing a required launch parameter" if absent): **`rikey`, `rikeyid`, `localAudioPlayMode`, `appid`** (Vibepollo: `appid` OR `appuuid`).
Full moonlight-qt query (verbatim construction, `startApp`):
`appid=<id>&mode=<w>x<h>x<fps>&additionalStates=1&sops=<0|1>&rikey=<32-hex = 16-byte AES-GCM remote-input key>&rikeyid=<int32 from first 4 IV bytes, big-endian>[&hdrMode=1&clientHdrCapVersion=0&clientHdrCapSupportedFlagsInUint32=0&clientHdrCapMetaDataId=NV_STATIC_METADATA_TYPE_1&clientHdrCapDisplayData=0x0x0x0x0x0x0x0x0x0x0]&localAudioPlayMode=<0|1>&surroundAudioInfo=<int>&remoteControllersBitmap=<mask>&gcmap=<mask>&gcpersist=<0|1>` + `LiGetLaunchUrlQueryParameters()` (moonlight-common-c adds `&corever=1&...` incl. encryption flags).
Sunshine also parses: `mode` (falls back to config default), `sops`, `surroundAudioInfo` (default "196610"), `surroundParams`, `gcmap`, `hdrMode`, `corever`; Vibepollo additionally: `appuuid`, `clientName`, `virtualDisplay=0|1`, `scaleFactor` (default 100).
Success response:
```xml
<root status_code="200">
  <sessionUrl0>rtsp://192.168.1.10:48010</sessionUrl0>   <!-- rtspenc:// when encryption negotiated -->
  <gamesession>1</gamesession>
</root>
```
Moonlight reads `sessionUrl0` and hands it to moonlight-common-c for RTSP setup. Errors: `400 "An app is already running on this host"` (must /cancel or /resume instead), `503 "Failed to initialize video capture/encoding..."`, `403` mandatory-encryption rejection, `5xx` "Failed to start the specified application". Note `appid=0` is accepted and starts a stream with no app (Desktop-style passthrough).

### GET /resume (HTTPS only) — reconnect to the already-running app
Required: `rikey`, `rikeyid` (`localAudioPlayMode` honored if present and no active session). Moonlight sends the same query as launch minus `appid`. Success: `<root status_code="200"><sessionUrl0>rtsp://...</sessionUrl0><resume>1</resume></root>`. If nothing is running: `503 "No running app to resume"` with `<resume>0</resume>`.
Client logic: if `currentgame != 0` and it equals the app you want → `resume`, else `launch`; if a *different* app is running, you must `/cancel` first.

### GET /cancel (HTTPS only) — quit the running app / kill sessions
No extra params. Always returns `<root status_code="200"><cancel>1</cancel></root>`; it calls `rtsp_stream::terminate_sessions()` and `proc::proc.terminate()`. moonlight-qt then re-fetches serverinfo and, if `currentgame` still != 0, synthesizes error 599 ("can't quit someone else's stream" — GFE semantics; on Sunshine cancel genuinely kills the app regardless of which paired client started it).

## 5. Pairing flow (`/pair`, works on HTTP 47989 pre-pairing; 5 requests)

Server session state machine keyed by `uniqueid` (`map_id_sess`), phases must run strictly in order (`Out of order call to ...` → 400 + session deleted). Hashing: **SHA-256** for Sunshine-family (client picks SHA-256 when server `appversion` major ≥ 7, SHA-1 for GFE ≤ 6). All binary values hex-encoded in query/response.

1. **`GET /pair?uniqueid=<uid>&uuid=<r>&devicename=roth&updateState=1&phrase=getservercert&salt=<32 hex = 16 bytes random>&clientcert=<hex of client PEM cert>`**
   Server blocks the response until the user enters the 4-digit PIN in the host Web UI (47990) or stdin. `AES key = first 16 bytes of SHA-256(salt_bytes || PIN_ascii)` (`crypto::gen_aes_key`). Response: `<root status_code="200"><paired>1</paired><plaincert><hex of server PEM cert></plaincert></root>`. (moonlight-qt literally sends `devicename=roth`; Vibepollo renames such clients "Legacy Moonlight Client". Vibepollo also accepts an `otpauth=<SHA256(otp_pin+salt+passphrase) hex>` param for PIN-less one-time-password pairing.)
2. **`...&clientchallenge=<hex AES-128-ECB(16 random bytes)>`** → server decrypts, appends **server cert's X.509 signature bytes** + 16-byte random `serversecret`, hashes (SHA-256, 32B), generates 16-byte `serverchallenge`, returns `<challengeresponse> = hex(AES-ECB(hash(32) || serverchallenge(16)))`, `<paired>1`.
3. **`...&serverchallengeresp=<hex AES-ECB(SHA-256(serverchallenge || client_cert_signature || clientsecret(16 random)))>`** → server stores that hash as `clienthash`, returns `<pairingsecret> = hex(serversecret(16) || RSA-SHA256-sign(serversecret, server_private_key))`, `<paired>1`. Client MUST verify: (a) hash received in phase 2 == SHA-256(clientchallenge || server_cert_signature || serversecret), (b) the signature over serversecret validates against the plaincert public key — else MITM/wrong PIN.
4. **`...&clientpairingsecret=<hex(clientsecret(16) || RSA-SHA256-sign(clientsecret, client_private_key))>`** → server checks `SHA-256(serverchallenge || client_cert_signature || clientsecret) == clienthash` AND `crypto::verify256(client_cert, secret, sign)`. On success `<paired>1</paired>`, cert is added to the trust chain + persisted (`add_authorized_client`); on failure `<paired>0`.
5. **HTTPS confirmation: `GET https://host:47984/pair?uniqueid=...&devicename=roth&updateState=1&phrase=pairchallenge`** with the client cert → `<root status_code="200"><paired>1</paired></root>`. This validates end-to-end mTLS.

All pairing failure responses: `<root status_code="400" status_message="..."><paired>0</paired></root>`.

## 6. mTLS with an existing moonlight-qt pair — exactly how auth works

**There is no token, cookie, or header auth.** Authentication to 47984 is 100% TLS-layer:
- Server presents its self-signed cert (the `plaincert` from pairing). moonlight-qt ignores TLS validation errors **only if the presented cert byte-equals the pinned per-host `srvcert`** (`handleSslErrors`). A client MAY skip pinning and accept any server cert (weaker, but functional).
- Server **requests a client certificate** during the handshake. Its verify callback (`https_server.verify`) takes the peer cert, checks it against the stored chain of paired client certs (`cert_chain.verify(x509)` — exact-match pool of self-signed certs collected at pairing, not a CA hierarchy), and in Sunshine also `is_client_enabled(pem)` (per-device enable flag in `sunshine_state.json` `named_devices[]{name,uuid,enabled,cert}`).
- On verify failure the TLS handshake still completes, but **every request gets body `<root status_code="401" query="/..." status_message="The client is not authorized. Certificate verification failed."/>`** — so "unpaired" manifests as XML status 401, not a TLS abort.
- Therefore: a client that possesses moonlight-qt's cert+key simply performs TLS client authentication with them on every request to 47984. Nothing else is required. From Sunshine's perspective it IS that paired Moonlight install (uniqueid value is irrelevant to authorization).

**Client identity material (moonlight-qt, macOS)** — verified against the live plist on this machine, `~/Library/Preferences/com.moonlight-stream.Moonlight.plist` (QSettings NativeFormat; org domain `moonlight-stream.com`, app `Moonlight`):
- Key `certificate` → PEM `-----BEGIN CERTIFICATE-----` (stored as plist `<data>`): X.509v3, **RSA-2048**, subject/issuer CN = `NVIDIA GameStream Client`, self-signed SHA-256, serial 0, 20-year validity.
- Key `key` → PEM RSA private key (plist `<data>`, ~1704 bytes on this machine).
- Key `uniqueid` → random 64-bit hex string, generated once (`RAND_bytes` → `QString::number(uid,16)`). NOTE: absent on this machine's plist — treat as optional; generate/send any stable hex string, Sunshine doesn't authorize by it.
- Per-host data under `hosts.N.*`: `hostname`, `uuid` (server's uniqueid), `mac`, `localaddress/localport`, `manualaddress/manualport`, `remoteaddress/remoteport`, `ipv6address/ipv6port`, `srvcert` (pinned server PEM), `nvidiasw` (bool), cached `apps.N.{id,name,hdr,appcollector,directlaunch,hidden}`.
- For Swift/URLSession mTLS you must wrap cert+key into a `SecIdentity` (e.g. build an in-memory PKCS#12 and `SecPKCS12Import`, or use a custom `URLSessionDelegate` answering `NSURLAuthenticationMethodClientCertificate` with `URLCredential(identity:certificates:persistence:)`), and answer the ServerTrust challenge by pinning `srvcert`.

## 7. Sunshine constants
`nvhttp.h`: `VERSION = "7.1.431.-1"` (negative last component tells Moonlight it's Sunshine, not GFE — enables Sunshine-specific client behavior like >60fps modes and true uniqueid), `GFE_VERSION = "3.23.0.74"`. Vibepollo uses identical values, plus `OTP_EXPIRE_DURATION = 180s`.

## 8. Vibepollo/Apollo permission model (affects VibeLight against Vibepollo hosts)
Per-client permission bitmask (uint32, `crypto.h enum PERM`): input group `0x0100..0x1000` (controller/touch/pen/mouse/kbd), operation group `0x1_0000..0x10_0000` (clipboard_set/clipboard_read/file_upload/file_download/server_cmd), action group `0x100_0000` list, `0x200_0000` view, `0x400_0000` launch. **`_default` for newly paired clients = view|list** — i.e. a fresh pair can list apps and view streams but `launch` may need to be granted in the host Web UI depending on host config. `/applist` requires list perm (else fake "Permission denied" app), serverinfo's `Permission` field tells the client its own mask. `/launch`, `/resume`, `/cancel` are gated on launch/view perms similarly.

## 9. Practical call sequence for VibeLight
1. Read `certificate`+`key` (+ per-host `srvcert`, address, `uuid`) from `com.moonlight-stream.Moonlight.plist`.
2. `GET http://host:47989/serverinfo?uniqueid=X&uuid=R` → confirm reachable, read `HttpsPort`, `state`.
3. `GET https://host:47984/serverinfo?uniqueid=X&uuid=R` with client identity → expect `PairStatus=1`; XML 401 ⇒ not paired (fall back to moonlight-qt pairing or implement /pair).
4. `GET https://.../applist` → app IDs/titles (+UUID/IDX on Vibepollo); `GET https://.../appasset?appid=N&AssetType=2&AssetIdx=0` → PNG box art.
5. Poll HTTPS `/serverinfo` for `state`/`currentgame` to show "Running" badges; use `/cancel` to quit a running app. Leave `/launch`/`/resume` to moonlight-qt CLI (`moonlight stream <host> <app>`) — it sends the rikey/rikeyid stream params itself.