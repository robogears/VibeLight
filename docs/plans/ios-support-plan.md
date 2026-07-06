# iOS / iPadOS support plan — VibeLight

**Goal:** make VibeLight run and **stream** on iPhone and iPad, sharing as much
of the existing macOS SwiftUI codebase as possible.

**Status:** IMPLEMENTED through Phase 4 — shipped in v0.1.8 (video, audio,
controller, touch). This document is the historical plan; the CURRENT
architecture + load-bearing invariants live in `docs/STREAMING-STATUS.md`.

---

## ⓪·⁵ Phase 1 — IMPLEMENTED (2026-07-05) + hard-won findings

Phase 1 (shared launcher on iOS, streaming disabled) is **built, running, and
partly verified**. What landed and what the next attempt must know:

- **Targets/seam.** `project.yml` has a `VibeLight-iOS` app target + a
  `VibeLightiOSTests` unit-test target (both iOS 17). Streaming sits behind
  `StreamEngine` (Contracts.swift): macOS keeps `StreamSessionManager`; iOS uses
  `DisabledStreamEngine` (`App/iOS/`). OS chrome is behind `PlatformChrome`
  (`WindowCoordinator` on macOS, `iOSPlatformChrome` on iOS). AppKit/Process
  files are `#if os(macOS)`; `AppRelocator`/`UpdateService` gained iOS stubs;
  `ControllerManager` split (GCController shared, NSEvent gated); the entry point
  is `App/iOS/VibeLightApp.swift`.

- **Identity — the macOS path was deliberately NOT changed.** macOS keeps
  openssl→P12→`SecPKCS12Import` (it must handle Moonlight-**imported** PEM
  identities, which can't be keychain-assembled ad-hoc). iOS (no Moonlight plist,
  no `Process`) self-generates via `SecKeyCreateRandomKey(kSecAttrIsPermanent)` +
  apple/swift-certificates, assembling a `SecIdentity` from the keychain
  (`Core/iOSIdentity.swift`, `#if os(iOS)`). swift-certificates is an **iOS-only**
  SPM dependency (macOS never links it).

- **⚠️ THE GOTCHA that will bite the next person: iOS keychain needs an
  entitlement.** An unsigned/adhoc iOS build with no entitlements CANNOT write a
  permanent key — `SecKeyCreateRandomKey` fails with `errSecMissingEntitlement`
  (-34018) and identity generation returns nil *silently* (pairing then just
  fails). Fix already in tree: `VibeLightiOS.entitlements` declares
  `keychain-access-groups` and the iOS target is ad-hoc **signed** (not
  `CODE_SIGNING_ALLOWED=NO`). On a real device, provisioning supplies the
  team-prefixed default group. This entitlement wall is the same one that blocks
  keychain-assembled identities on macOS-adhoc — hence macOS staying on P12.

- **Verified:** `VibeLightiOSTests.IOSIdentityTests` runs in the simulator and
  proves key-gen → `SecIdentity` assembly → RSA-2048 signing → cert CN → PEM
  byte-stability. The launcher builds + runs + renders (controller/focus UI,
  pairing panel, settings). **Not verified (needs a device + an awake host):** the
  live GameStream pairing/serverinfo network handshake.

- **Phase 2+ (streaming) is unchanged below and remains the real remaining work.**
  It is device-gated (VideoToolbox/CoreAudio) and needs the moonlight-common-c +
  mbedTLS + libopus iOS build. Start there. The `StreamEngine` seam means it
  drops in behind `DisabledStreamEngine` with zero AppState changes.

---

## 0. The one-paragraph answer

On macOS, VibeLight is a **shell** that shells out to an embedded moonlight-qt
`.app` helper (`StreamSessionManager` spawns `Process`, drives it over the `@VL`
stdout protocol). **That subprocess model is impossible on iOS** — iOS apps
cannot `fork`/`exec` helper processes or ship a second executable. The answer is
to **link `moonlight-common-c` (the cross-platform C streaming core) directly
into the app and drive the stream in-process** via its `Limelight.h` API
(`LiStartConnection` + `DecoderRenderer`/`AudioRenderer`/`ConnectionListener`
callbacks), implementing the three platform sinks — **video** (VideoToolbox
decode → `AVSampleBufferDisplayLayer`/Metal), **audio** (Opus → CoreAudio), and
**input** (`GCController` → `LiSendControllerEvent`, touch → `LiSendTouchEvent`).
The existing Swift GameStream client (`HostAPIClient`, `HostPairing`,
`GameStreamCrypto`) already speaks the pairing/serverinfo/applist/cancel
protocol and is 95% portable — the one hard blocker is that identity/P12
generation shells to `/usr/bin/openssl`, which iOS forbids; that must be
reimplemented with Security.framework + swift-certificates (and that same rewrite
cleans up macOS). This is also the moment to introduce the **in-process stream
engine on macOS**, retiring the QT helper entirely, so both platforms share one
`StreamEngine` protocol.

The reference implementation for every native sink is **moonlight-ios**
(`Limelight/Stream/Connection.m`, `VideoDecoderRenderer.m`, and the audio
renderer) — study it, do not reinvent it.

---

## 1. The core problem & its shape

### 1.1 What is macOS-only today

The streaming path is the only truly platform-locked part of the app. It is
entirely contained in **`VibeLight/Core/StreamSessionManager.swift`**, which:

- spawns `/Applications/Moonlight.app/.../Moonlight stream …` (or the embedded
  `Contents/Helpers/StreamHelper.app`) via `Foundation.Process`
  (`resolveStreamBinary()`, `startStreamProcess()`);
- reads the child's `@VL STARTED/FAILED/ENDED` protocol on stdout;
- treats the child PID as a liveness signal and reconciles against `/serverinfo`.

**None of `Process`, subprocess spawning, or a second bundled executable exists
on iOS.** The `/launch` and `/resume` GameStream calls that actually start the
RTSP stream are *not* in our Swift `HostAPIClient` at all — they live inside the
moonlight-qt CLI (which uses moonlight-common-c). So on iOS we must implement the
launch/RTSP/stream path ourselves, in-process, using moonlight-common-c.

Everything the C core needs already exists on iOS:

| Need | iOS API |
|---|---|
| H.264/HEVC/AV1 hardware decode | **VideoToolbox** (`VTDecompressionSession`, or feed straight to `AVSampleBufferDisplayLayer`) |
| Video presentation | **AVSampleBufferDisplayLayer** (simplest) or **Metal** (`CAMetalLayer`, needed for true HDR/EDR + lowest latency) |
| Opus audio decode | libopus (vendored) → **AudioUnit / AVAudioEngine** (CoreAudio) |
| Controller input | **GameController** (`GCController`) — identical API to macOS |
| Touch input | UIKit gestures → `LiSendTouchEvent` / `LiSendMousePositionEvent` |
| Crypto for pairing | **Security.framework** + **CryptoKit** (already used) |

### 1.2 The four workstreams

1. **Portable Core** — make `Core/` build for iOS. Blocker: openssl-Process
   identity generation (§4). Everything else in `Core/` is Foundation-only or a
   trivial gate.
2. **Link moonlight-common-c** as a static library with its deps (§2).
3. **In-process stream engine** — a `StreamEngine` that calls `LiStartConnection`
   and implements the three sinks (§3, video/audio/input phases).
4. **Platform UI** — replace `NSWindow`/`NSCursor`/`NSEvent` with iOS equivalents
   (mostly deletion — iOS is inherently fullscreen) and add touch controls (§6).

---

## 2. Building & linking moonlight-common-c for iOS

### 2.1 Dependency graph (verified against the vendored source)

`moonlight-common-c` at
`~/Documents/vibelight-moonlight-helper/moonlight-common-c/moonlight-common-c/`
is a **C library**. Its `CMakeLists.txt` and `src/` reveal these dependencies:

| Dependency | How satisfied today | iOS plan |
|---|---|---|
| **enet** (reliable UDP control stream) | vendored: `enet/` subdir, `add_subdirectory(enet)` | Compile the vendored `enet/*.c` into the same static lib. Pure C, uses BSD sockets — builds on iOS unchanged. |
| **nanors** (Reed-Solomon FEC) | vendored: `nanors/rs.c` + `nanors/deps/obl` | Compile into the static lib. Pure C. |
| **mbedTLS** (crypto: AES-GCM for the encrypted control/video/audio streams) | `option(USE_MBEDTLS)`; `PlatformCrypto.c` includes `<mbedtls/*.h>` and calls `mbedtls_cipher_*`, `mbedtls_ctr_drbg_*` | **Build mbedcrypto for iOS** (device arm64 + simulator arm64). This is the only real third-party build. Options: (a) SwiftPM binary target / xcframework of mbedTLS, (b) build from source via a small script, (c) `USE_MBEDTLS=OFF` and link BoringSSL/OpenSSL instead — **do not**; mbedTLS is smaller, is the default the fork already uses, and matches moonlight-ios. |
| **libopus** (audio decode) | **not** a dependency of common-c itself — common-c hands raw Opus packets to our `AudioRendererDecodeAndPlaySample` callback; **we** own the decode | Vendor libopus, build for iOS, call `opus_multistream_decode` in the audio sink (§audio phase). moonlight-ios does exactly this. |
| **expat / libxml** | **none** — grep confirms common-c does no XML. The `/serverinfo`/`/applist` XML is parsed in the Qt layer on desktop, and by our Swift `HostAPIClient` here. | Nothing to build. |
| BSD sockets, pthreads | `PlatformSockets.c`, `PlatformThreads.h` | Present on iOS. |

**Key point:** the dependency set is small and all-C: **enet + nanors + mbedcrypto**
compile into one static library; **libopus** is a second static library for the
audio sink. No Qt, no SDL, no FFmpeg — those are moonlight-**qt** frontend
concerns, not common-c.

### 2.2 Build strategy

Prefer a **SwiftPM package** or an **Xcode static-library target**, not CMake
inside the Xcode build:

- Create an Xcode framework/static-lib target `MoonlightCore` (Objective-C++/C)
  in the same project that compiles: all of `moonlight-common-c/src/*.c`, the
  vendored `enet/*.c`, and `nanors/rs.c`. Set `USE_MBEDTLS` in
  `GCC_PREPROCESSOR_DEFINITIONS` and add the mbedTLS + opus headers to the search
  path.
- Vend **mbedTLS** and **libopus** as prebuilt `.xcframework`s (device + sim
  slices). Build scripts live under `scripts/ios/` (mirror how moonlight-ios’s
  `BuildScripts/` produce these). Alternative: SwiftPM `binaryTarget`s.
- Expose `Limelight.h` to Swift via a module map / bridging header so Swift can
  call `LiStartConnection`, `LiSendControllerEvent`, etc. directly. moonlight-ios
  bridges through Objective-C (`Connection.m`); we can do the same — an ObjC++
  `MoonlightSession` class that owns the C callbacks and marshals to Swift — or
  bridge C directly. **Recommendation:** a thin ObjC++ shim (`MoonlightSession`)
  because the C callbacks are global function pointers with a `void* context`,
  and it is cleaner to bounce them through an ObjC object than to juggle Swift
  `@convention(c)` closures with captured context. This mirrors
  `Connection.m`/`ConnectionCallbacks.h`.

### 2.3 Licensing note (unchanged posture)

moonlight-common-c is **GPLv3**. Linking it into the VibeLight app makes the iOS
app a GPLv3 work — same as the desktop story (see CLAUDE.md “GPL fork = never
MAS”). **This means the iOS app cannot ship on the App Store either.** It would
distribute via **AltStore / sideloading / a personal dev-signed IPA**, or the
project accepts that iOS is a build-it-yourself target. This is a hard product
constraint to confirm with the user **before** any code — it may reshape scope.
(A separate discussion: an in-house/ad-hoc distribution profile, or Apple’s new
EU alternative-marketplace path.)

---

## 3. Multiplatform project structure

### 3.1 Target layout (project.yml)

`project.yml` currently declares one macOS target. Restructure to a shared-code +
per-platform-shell model:

```
targets:
  VibeLightCore:            # shared library target, both platforms
    type: framework         # or a source group compiled into both apps
    platform: [macOS, iOS]
    sources: [VibeLight/Core, VibeLight/Input, VibeLight/UI]
  MoonlightCore:            # C static lib: common-c + enet + nanors
    type: library.static
    platform: [macOS, iOS]
    sources: [ThirdParty/moonlight-common-c, ...]
  VibeLight (macOS):        # existing app shell
    platform: macOS
    sources: [VibeLight/App, VibeLight/Platform/macOS]
    dependencies: [VibeLightCore, MoonlightCore, mbedTLS.xcframework, opus.xcframework]
  VibeLight-iOS:            # new app shell
    platform: iOS
    sources: [VibeLight/App-iOS, VibeLight/Platform/iOS]
    dependencies: [VibeLightCore, MoonlightCore, mbedTLS.xcframework, opus.xcframework]
```

Add `deploymentTarget: { iOS: "17.0" }` (17+ gives us the modern SwiftUI +
GameController + Observation stack the app already relies on; the app uses
`@Observable`/Observation which is iOS 17+ anyway).

xcodegen remains the source of truth (never edit pbxproj — CLAUDE.md).

### 3.2 Introduce a `StreamEngine` protocol (the seam)

Today `AppState` holds a concrete `StreamSessionManager`. Extract its **public
surface** into a protocol in `Core/Contracts.swift` so both platforms conform:

```swift
@MainActor protocol StreamEngine: AnyObject {
    var phase: SessionPhase { get }
    var onPhaseChange: ((SessionPhase) -> Void)? { get set }
    var onStreamDidStart: ((_ pid: pid_t?) -> Void)? { get set }   // pid nil on iOS
    var onStreamDidEnd: ((_ cleanly: Bool) -> Void)? { get set }
    var remoteQuitRequested: Bool { get }
    func launch(app: StreamApp, on host: StreamHost, settings: StreamSettings) async
    func disconnect()
    func quitCompletely(host: StreamHost) async
    func acknowledgeEnd()
}
```

- **macOS:** `ProcessStreamEngine` = today’s `StreamSessionManager` (rename), or
  the new in-process engine (see §7 recommendation). Its rich reconcile /
  watchdog logic (`/serverinfo` truth polling, `/cancel` quit, invariants 3–6)
  **stays and is platform-agnostic** — it talks to `HostAPIProviding`, not to
  AppKit.
- **iOS:** `InProcessStreamEngine` = drives `LiStartConnection` on a background
  thread, plus the same reconcile/quit logic (the `/serverinfo` polling and
  `/cancel` calls are pure `HostAPIClient` and are reused verbatim).

The genius of the current design is that `StreamSessionManager` is **already
AppKit-free** (its doc comment says so: activation handoff is delegated via
`onStreamDidStart`/`onStreamDidEnd`). So the reconcile brain ports as-is; only
the "how do I make pixels appear" part differs.

### 3.3 File-by-file: what is AppKit-only and must be gated/replaced

Grep (`import AppKit|NSApp|NSWindow|NSCursor|NSEvent|Process(`) pinpoints exactly
these files. Classification:

| File | AppKit / Process usage | iOS action |
|---|---|---|
| `App/main.swift` | Manual `NSApplication` boot, `NSMenu`, `setActivationPolicy` | **Replace.** New iOS entry point: `@main struct VibeLightApp: App` with a `WindowGroup`/full-screen `Immersive... ` — iOS has no NSApplication, no menu bar. |
| `App/BigPictureWindow.swift` | `NSWindow` subclass, `NSScreen`, `NSHostingView`, `presentationOptions`, `NSCursor`, `beginActivity` sleep | **Delete on iOS.** iOS apps are already a single full-screen window. Replace `preventDisplaySleep()` with `UIApplication.shared.isIdleTimerDisabled = true`. Replace stream handoff (activate helper PID) with **swapping the SwiftUI view to the stream layer** — there is no second process to activate. |
| `App/AppState.swift` | `import AppKit`; `NSCursor.setHiddenUntilMouseMoves`; `NSApplication.shared.terminate`; `windowCoordinator` refs | **Gate.** Wrap the ~4 AppKit call sites in a `PlatformChrome` protocol (see §3.4). `terminate()` becomes a no-op / "return to home" on iOS (iOS apps don't self-quit). Cursor hiding is a no-op on iOS. |
| `Input/ControllerManager.swift` | `import AppKit`, `NSEvent.addLocalMonitorForEvents` (keyboard + mouse), `NSApplication.didBecomeActiveNotification` | **Split.** The GCController half is 100% shared (identical API on iOS). The `NSEvent` keyboard/mouse monitors are macOS-only → move behind `#if os(macOS)`. iOS keyboard support (optional) uses `GCKeyboard` (GameController) or `UIKeyCommand`; iOS "became active" uses `UIApplication.didBecomeActiveNotification` / scene phase. The runaway-repeat reset (`resetTransientInputState` on activation) must fire on the iOS lifecycle event too. |
| `Core/StreamSessionManager.swift` | `Foundation.Process`, `kill()`, `SIGKILL` | **macOS-only.** Keep as `ProcessStreamEngine` under `Platform/macOS`, OR retire in favor of the in-process engine (§7). Its reconcile logic is extracted to a shared helper either way. |
| `Core/UpdateService.swift` | `import AppKit`, `NSWorkspace.open`, `NSApp.terminate`, `Process` (ditto/codesign/bash relauncher) | **macOS-only.** Self-updating a bundle is impossible on iOS (no writable app bundle, no `open`, no codesign). On iOS: either no in-app updater (sideload updates externally) or a "new version available → open App Store/AltStore URL" card. Put the whole class behind `#if os(macOS)`; provide a stub `UpdateService` on iOS whose `phase` is always `.upToDate`. |
| `Core/AppRelocator.swift` | `NSApp`, bash relauncher, `/Applications` | **macOS-only.** Delete from the iOS target entirely — there is no "move to Applications" concept. `#if os(macOS)`. |
| `Core/ClientIdentityProvider.swift` | `/usr/bin/openssl` via `Process` (P12 build) | **Rewrite (both platforms).** See §4 — this is the one shared blocker. |
| `Core/IdentityStore.swift` | `/usr/bin/openssl` via `Process` (RSA keygen + self-signed cert) | **Rewrite (both platforms).** See §4. |
| `Core/HostAPIClient.swift` | Security.framework (`SecIdentity`, `SecTrust`), URLSession, mTLS delegate | **Portable as-is.** All Security/URLSession APIs exist on iOS. **Blocker on iOS:** ATS. See §3.5. |
| `Core/HostPairing.swift` | Security.framework, URLSession | **Portable as-is** (same ATS caveat). |
| `Core/GameStreamCrypto.swift` | CommonCrypto, CryptoKit, Security | **Portable as-is** — all cross-platform. |
| `Core/MoonlightConfigImporter.swift` | reads `~/Library/Preferences/com.moonlight-stream.Moonlight.plist` | **macOS-only in practice.** On iOS there is no desktop Moonlight plist to import (sandboxed; different app). iOS users pair fresh in-app (which §4 enables). Keep the type; on iOS `importAll()` simply finds no plist and returns nil → falls through to generated identity. No code change needed, but the "zero-setup from existing Moonlight" story does not apply on iOS. |
| `Core/ArtworkStore.swift` | `ImageIO`/`CGImageSource`, Caches dir | **Portable as-is** (ImageIO is cross-platform; comment already notes it deliberately avoids NSImage). |
| `Core/WakeOnLAN.swift` | BSD sockets | **Portable as-is.** |
| `UI/*` (Theme, HomeView, tiles, overlays, Settings) | SwiftUI `Color`, `.onHover`, SF Rounded | **Mostly portable.** `Color`/SwiftUI is cross-platform. `.onHover` is a harmless no-op on touch iOS. Any `NSImage`/`Color(NSColor:)` (none found — Theme uses `Color(red:…)`) would need `UIColor`. Font `.system(...` design: .rounded)` is cross-platform. Focus engine (`Input/FocusEngine.swift`) is pure logic — fully shared and is the single biggest win: controller navigation already works on iOS. |

### 3.4 `PlatformChrome` seam

Introduce a small protocol so `AppState` never touches AppKit/UIKit directly:

```swift
@MainActor protocol PlatformChrome: AnyObject {
    func preventSleep(_ on: Bool)
    func hidePointer()                 // no-op on iOS
    func beginStreamPresentation()     // macOS: activate helper; iOS: push stream view
    func endStreamPresentation()
    func quitApp()                     // macOS: NSApp.terminate; iOS: route(.home)
}
```

macOS conformer wraps `WindowCoordinator`; iOS conformer flips
`isIdleTimerDisabled` and toggles a `@Published var isStreaming` the root view
observes. `AppState.windowCoordinator` becomes `AppState.chrome: PlatformChrome`.

### 3.5 ATS (App Transport Security) on iOS

macOS `project.yml` already sets `NSAppTransportSecurity.NSAllowsArbitraryLoads =
true` (needed because GameStream hosts are self-signed and our TLS delegate does
byte-exact pinning stronger than CA trust). **The same key is required in the iOS
target's Info.plist.** On iOS, `NSAllowsArbitraryLoads` + `NSAllowsLocalNetworking`
plus the **Local Network privacy permission** (`NSLocalNetworkUsageDescription`,
already present) and a **Bonjour usage** entry if we ever mDNS-discover. Without
these the mTLS handshake to `<HOST_IP>:47984` / `192.168.x` dies before our
pinning delegate runs — exactly the `-1200` failure the macOS comment describes.
The C stream engine's raw UDP/TCP sockets are **not** subject to ATS (ATS only
governs URLSession/CFNetwork HTTP), so the moonlight-common-c stream itself is
unaffected — but it **does** require the Local Network permission grant, which
iOS prompts for on first socket to a LAN peer.

---

## 4. Identity & pairing portability (the shared blocker)

### 4.1 The problem

Two files shell to `/usr/bin/openssl` through `Foundation.Process`, which **iOS
forbids** (no `Process`, no `/usr/bin/openssl`):

- **`Core/IdentityStore.generateAndPersist()`** — `openssl req -x509 -newkey
  rsa:2048 … -subj "/CN=NVIDIA GameStream Client"` to mint a self-signed client
  identity for users who never installed Moonlight.
- **`Core/ClientIdentityProvider.ensureP12()`** — `openssl pkcs12 -export` to turn
  the PEM cert+key into a P12 that `SecPKCS12Import` can load into an in-memory
  `SecIdentity` for mTLS.

Everything downstream (the mTLS delegate, the pairing handshake in `HostPairing`,
signing with `SecKeyCreateSignature` in `GameStreamCrypto`) is already pure
Security/CryptoKit and portable. **Only the two generation steps are the blocker,
and both need replacing on macOS too** (removing the `/usr/bin/openssl`
dependency is a strict improvement — no external process, no temp-file dance, no
`chmod 600` P12 on disk).

### 4.2 The replacement

**RSA keygen** — Security.framework does this natively, no external tool:

```swift
let attrs: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
    kSecAttrKeySizeInBits as String: 2048,
]
let privKey = SecKeyCreateRandomKey(attrs as CFDictionary, &err)   // iOS + macOS
```

**Self-signed X.509 cert** — this is the genuinely hard part, because
Security.framework can **create keys** but has **no public API to build/sign an
X.509 certificate**. Options:

1. **swift-certificates + swift-crypto (recommended).** Apple's own
   `apple/swift-certificates` (built on `swift-asn1`) can construct and
   **sign a self-signed certificate** from a private key entirely in Swift, no C,
   no external process, iOS + macOS. Add as SwiftPM deps. Build a cert with
   `CN=NVIDIA GameStream Client`, 20-year validity, SHA-256, matching what
   `IdentityStore` documents mirroring from moonlight-qt's `IdentityManager`.
   Bridge the resulting key to a `SecKey` (swift-crypto RSA ↔ `SecKey` via
   PEM/DER round-trip, or generate the `SecKey` first and hand its DER public key
   to swift-certificates for signing — swift-certificates supports signing with a
   caller-supplied key). This is the cleanest, fully-native path.

2. **BoringSSL/mbedTLS in-process.** We are already linking mbedcrypto for the
   stream (§2). mbedTLS can generate a key and self-signed cert
   (`mbedtls_x509write_crt`), callable from the same C shim. Reuses a dependency
   we already have, but writing X.509 cert-gen in C is more error-prone than
   swift-certificates and mixes concerns. **Fallback, not first choice.**

**P12 → SecIdentity** — the *reason* the code builds a P12 is that
`SecPKCS12Import` is the documented way to get a `SecIdentity` (cert+key pair)
for URLSession client-cert auth. Replacement without openssl:

- Build the PKCS#12 blob **in Swift** with **swift-certificates**' PKCS#12 support
  (or a small mbedtls path), then `SecPKCS12Import` as today — the import call is
  fine on iOS, only the *building* used openssl.
- **Or** avoid P12 entirely: on macOS you can `SecIdentityCreate` /
  `SecKeychainItemImport`; on iOS the reliable path is to import the key +
  cert into the (in-memory or app) keychain and fetch the `SecIdentity` via
  `SecItemCopyMatching`. The current `kSecImportToMemoryOnly` trick is macOS-only
  behavior. **Simplest cross-platform:** keep building a P12 (now in Swift) and
  keep `SecPKCS12Import` — least churn, one code path.

### 4.3 Migration shape

`ClientIdentity` (in `Models.swift`) is already the clean abstraction: it carries
`certificatePEM` + `privateKeyPEM` + `uniqueID`. Neither the mTLS delegate nor the
pairing handshake cares *how* those PEMs were produced. So the rewrite is
localized to:

- `IdentityStore.generateAndPersist()` → SecKeyCreateRandomKey + swift-certificates
  self-signed cert → PEM.
- `ClientIdentityProvider.ensureP12()` → build P12 in Swift → `SecPKCS12Import`.

Everything else is untouched. **Do this rewrite first (Phase 1)** because it
unblocks the entire Core on iOS and improves macOS.

### 4.4 Pairing on iOS

`HostPairing` already implements the full 5-phase NvPairingManager handshake in
portable Swift (AES-128-ECB via CommonCrypto, RSA-SHA256 via `SecKeyCreateSignature`,
X.509 sig extraction via manual DER walk in `GameStreamCrypto`). Once §4.2 gives
iOS a valid client identity, **pairing works on iOS unchanged.** The user types
the PIN on the host's web UI (`https://<ip>:47990`) exactly as on macOS. This is
the entire iOS onboarding: add host by IP → pair → stream.

---

## 5. Phased plan (each phase independently verifiable)

### Phase 0 — Product gate (no code)
Confirm the **GPL/distribution** constraint (§2.3) with the user. iOS + GPL =
no App Store; sideload/AltStore/dev-signed only. If that is acceptable, proceed.
**Verify:** a written decision.

### Phase 1 — Shared Core builds & runs on iOS (no streaming)
- Rewrite `IdentityStore` + `ClientIdentityProvider` off `/usr/bin/openssl`
  onto SecKeyCreateRandomKey + swift-certificates (§4). Ship on macOS first,
  prove parity with existing `GameStreamCryptoTests`.
- Restructure `project.yml` into shared `VibeLightCore` + macOS/iOS app shells
  (§3.1). Gate AppKit files with `#if os(macOS)` / `PlatformChrome` (§3.3, §3.4).
- Add the iOS app entry point (`@main App`, full-screen), ATS + Local Network
  Info.plist keys (§3.5).
- iOS `UpdateService`/`AppRelocator` = stubs / excluded.
- **Verify:** iOS app launches on device, shows the home UI, controller
  navigates the focus engine, **user pairs a host and sees the app list + box
  art** (all of `HostAPIClient`/`HostPairing`/`ArtworkStore` exercised). No
  streaming yet — the launch button shows "streaming not yet supported on iOS".
  This is a **shippable milestone**: a native iOS Moonlight *library browser +
  pairer* with controller UI.

### Phase 2 — Link moonlight-common-c
- Add `MoonlightCore` static-lib target: common-c `src/*.c` + enet + nanors,
  `USE_MBEDTLS` (§2.2). Vendor mbedTLS + libopus xcframeworks (§2.1).
- Add the ObjC++ `MoonlightSession` shim exposing `LiStartConnection` /
  `LiStopConnection` / `LiSend*` and the callback structs to Swift (§2.2).
- **Verify:** a throwaway test that calls `LiStartConnection` with **no-op**
  decoder/audio callbacks against a real host and receives `stageComplete` up
  through `STAGE_VIDEO_STREAM_START` + `connectionStarted`, then `LiStopConnection`.
  Proves the C core links, the crypto works, and the RTSP/control handshake
  completes on-device. (moonlight-common-c even ships `FakeCallbacks.c` for
  exactly this.)

### Phase 3 — Video decode + render
- Implement `DecoderRenderer` callbacks (`setup`/`start`/`submitDecodeUnit`/
  `stop`/`cleanup`). In `submitDecodeUnit`, walk the `PLENTRY` buffer chain
  (Annex-B NALUs; `BUFFER_TYPE_SPS/PPS/VPS` on IDR frames), build a
  `CMVideoFormatDescription` + `CMSampleBuffer`, and enqueue on an
  **`AVSampleBufferDisplayLayer`** (fastest path to first pixels; VideoToolbox
  handles decode implicitly). Set `CAPABILITY_DIRECT_SUBMIT`.
- Copy the algorithm from moonlight-ios **`Limelight/Stream/VideoDecoderRenderer.m`**
  (it does precisely this: parameter-set extraction, `CMSampleBuffer` construction,
  HEVC/H.264 handling). Start H.264-only, add HEVC, defer AV1.
- **Verify:** live video appears on device for a real game. Measure latency;
  if `AVSampleBufferDisplayLayer` adds latency, switch to the Metal/VT-explicit
  path later (see moonlight-qt issue #1885 — Metal renderer is lower-latency;
  matches CLAUDE-noted HDR needs). HDR is a Phase-3.5 add via `CAMetalLayer` EDR.

### Phase 4 — Audio + input
- **Audio:** implement `AudioRenderer` callbacks. `init` receives
  `OPUS_MULTISTREAM_CONFIGURATION` → create an `opus_multistream_decoder`;
  `decodeAndPlaySample` → `opus_multistream_decode` → push PCM into an
  **AudioUnit (RemoteIO) or `AVAudioEngine`** ring buffer. Set
  `CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION`. Mirror moonlight-ios's audio
  renderer.
- **Input:** the shared `ControllerManager` already reads `GCController`. In a
  stream, instead of emitting `NavigationEvent`s, translate `GCExtendedGamepad`
  state → `LiSendControllerEvent(buttonFlags, LT, RT, LSx, LSy, RSx, RSy)` using
  the `A_FLAG`/`B_FLAG`/… bitfield from `Limelight.h`. Route `ConnListenerRumble`
  → `GCController.haptics`. Add **touch** controls: on-screen or trackpad-style
  gestures → `LiSendTouchEvent` / `LiSendMousePositionEvent` /
  `LiSendMouseButtonEvent` (the header explicitly recommends
  `LiSendMouseMoveAsMousePositionEvent` for iOS to avoid double-acceleration).
- **Verify:** full playable stream on iPad with a controller; touch drives the
  pointer for desktop/menu apps.

### Phase 5 — iOS UI polish
- Stream overlay controls (disconnect / quit / stats) as a touch HUD.
- On-screen virtual controller for phone-without-pad (optional, large effort —
  can defer). iPad-with-Magic-Keyboard trackpad → pointer.
- Handle rotation/safe-area/notch; `isIdleTimerDisabled` during stream.
- Reconcile phase-changes with the existing overlay system in `AppState`.
- **Verify:** end-to-end couch/handheld experience; disconnect keeps the game
  running (invariant 6 via SIGTERM-equivalent = `LiStopConnection`), quit-completely
  goes through `/cancel` (already in `HostAPIClient`, reused).

---

## 6. UI adaptation specifics

What actually changes, concretely:

- **Window:** `BigPictureWindow`/`WindowCoordinator` deleted on iOS. iOS is one
  full-screen scene; the "big picture" *is* the app. No borderless-key-window
  problem, no Space-swipe problem, no `canBecomeKey` override. Net simplification.
- **Cursor:** `NSCursor.setHiddenUntilMouseMoves` → no-op on iOS (no cursor
  unless iPad + trackpad, where iPadOS manages the pointer itself). The
  `inputMode` (.directed/.pointer) enum still makes sense: iPad trackpad =
  `.pointer`, controller/touch-nav = `.directed`.
- **Focus engine:** **unchanged and load-bearing** — this is the payoff. The
  custom spatial focus engine (`Input/FocusEngine.swift`) plus `GCController`
  already give full controller navigation on iOS, where SwiftUI focus also
  ignores game controllers. Nothing to port.
- **Keyboard:** `NSEvent` local monitor → `#if os(macOS)`. iOS keyboard nav
  (optional) via `GCKeyboard` (GameController framework, cross-platform) feeding
  the same `NavigationEvent` stream, or `UIKeyCommand`. Low priority.
- **Lifecycle reset:** the runaway-repeat guard (reset input state on
  `didBecomeActiveNotification`) must hook `UIApplication.didBecomeActiveNotification`
  / SwiftUI `scenePhase` on iOS — this bug (releases dropped while backgrounded)
  applies equally when iOS backgrounds the app during a stream.
- **Controller arbitration:** on macOS, `shouldMonitorBackgroundEvents = false`
  arbitrates between launcher and the separate stream *process*. On iOS there is
  **one process**, so arbitration is internal: while streaming, controller input
  routes to `LiSendControllerEvent`; while browsing, to `NavigationEvent`. A
  single `isStreaming` flag in `ControllerManager` switches the sink. Simpler
  than the macOS foreground-handoff dance.
- **App self-quit:** `route(.quitApp)` / hold-B → on iOS there is no app
  self-termination (Apple HIG forbids it); repurpose to "return to home screen"
  or drop the gesture on iOS.
- **Theme/tiles/overlays/settings:** SwiftUI, cross-platform, ship as-is. The
  settings screen even maps 1:1 — the same `StreamSettings` now feeds
  `STREAM_CONFIGURATION` fields (width/height/fps/bitrate/codec/audioConfig/HDR)
  instead of CLI flags. `cliValue` accessors gain a sibling that yields the
  `VIDEO_FORMAT_*` / `AUDIO_CONFIGURATION_*` constants.

---

## 7. A strategic recommendation: converge macOS onto the in-process engine

Building the in-process engine for iOS creates the opportunity to **use it on
macOS too**, retiring the moonlight-qt helper (`StreamSessionManager`'s `Process`
spawn, the `@VL` protocol, `scripts/embed-helper.sh`, the 200 MB Qt helper
bundle, the notarization headache, the activation/handoff gymnastics in
`WindowCoordinator`). Benefits: one `StreamEngine`, no second executable, no
"CLI hangs on a modal dialog" watchdog zoo (invariant 3–4 exist *because* of the
opaque subprocess), true in-app control of decode/render. Cost: macOS must then
implement the same VideoToolbox/Metal/CoreAudio sinks — but they are ~identical
to iOS (same frameworks) and moonlight-qt's own macOS renderer + moonlight-ios are
the references.

**Recommendation:** keep the Process engine on macOS through Phases 1–4
(de-risks: iOS streaming can ship without touching the working macOS path), then
evaluate converging macOS onto `InProcessStreamEngine` as a **Phase 6**. Do not
block iOS on it. The `StreamEngine` protocol (§3.2) makes this a drop-in swap.

---

## 8. Effort & risk assessment

| Area | Effort | Risk | Notes |
|---|---|---|---|
| Phase 0 product/GPL gate | trivial | **high (product)** | Could kill or reshape the whole effort. Do first. |
| Identity rewrite (§4) | S–M | low | swift-certificates is proven; improves macOS. Well-bounded. |
| Project restructure + AppKit gating | M | low | Mechanical; xcodegen. Biggest tedium is the `#if os` sweep. |
| Link common-c + mbedTLS + opus | M | **medium** | The xcframework builds are fiddly (device+sim slices, bitcode-free, arm64). moonlight-ios's BuildScripts are the map. |
| Video decode/render | M–L | **medium** | Copy `VideoDecoderRenderer.m`. Latency tuning + HDR are the long tail. |
| Audio | M | low–med | Opus + AudioUnit is well-trodden; moonlight-ios reference. |
| Input (controller + touch) | M | low (controller) / med (touch UX) | Controller trivial. Good touch controls for phones are a real design effort. |
| iOS UI polish | M | low | SwiftUI reuse is high. |
| macOS convergence (Phase 6, optional) | L | medium | Pure upside, not required for iOS. |

**Overall:** medium-large but **de-risked by phasing**. The single biggest
external risk is the **GPL/App-Store** constraint (§0), then the **mbedTLS/opus
iOS build** (mitigated: moonlight-ios already does it, and the code is right here
in the vendored tree).

### Is an incremental "launcher-now, streaming-later" milestone achievable?

**Yes, cleanly.** **Phase 1 is that milestone**: after the identity rewrite and
project restructure, VibeLight runs on iPhone/iPad as a native, controller-driven
Moonlight **host browser + pairer + artwork gallery**, with the launch button
disabled and labeled. Every non-streaming subsystem — pairing, mTLS GameStream
API, serverinfo/applist polling, box-art pipeline, focus engine, settings — is
already portable Swift and gets exercised end-to-end. Streaming then lands
additively in Phases 2–5 behind that same button, with **zero risk to the working
macOS product** because the stream engine sits behind the `StreamEngine`
protocol seam.

---

## 9. First implementation step (do this before anything else in code)

**Rewrite `Core/IdentityStore.swift` and `Core/ClientIdentityProvider.swift` to
generate the RSA key with `SecKeyCreateRandomKey` and the self-signed X.509 cert
with `apple/swift-certificates`, eliminating every `/usr/bin/openssl` `Process`
call — landing and verifying it on macOS first** (against the existing
`GameStreamCryptoTests` + a live pair with "MyServer"). It is the only shared
blocker, it strictly improves the current macOS app, and it is a self-contained,
independently shippable change that unblocks the entire iOS Core in Phase 1.

---

## Appendix — reference files

**In this repo (the seam / what moves):**
- `VibeLight/Core/StreamSessionManager.swift` — the Process engine to sit behind `StreamEngine`; its reconcile logic is portable.
- `VibeLight/Core/HostAPIClient.swift`, `HostPairing.swift`, `GameStreamCrypto.swift` — portable GameStream client (needs ATS on iOS).
- `VibeLight/Core/IdentityStore.swift`, `ClientIdentityProvider.swift` — the openssl blocker (§4).
- `VibeLight/Input/FocusEngine.swift`, `ControllerManager.swift` — focus engine fully shared; controller half shared, `NSEvent` half gated.
- `VibeLight/App/BigPictureWindow.swift`, `main.swift`, `AppState.swift` — AppKit shell to replace/gate.
- `VibeLight/Core/UpdateService.swift`, `AppRelocator.swift` — macOS-only, exclude from iOS.
- `project.yml` — restructure into shared + per-platform targets.

**The C core (vendored):**
- `~/Documents/vibelight-moonlight-helper/moonlight-common-c/moonlight-common-c/src/Limelight.h` — the entire public API (`LiStartConnection`, callback structs, `LiSend*`).
- `.../src/PlatformCrypto.c` — confirms **mbedTLS** dependency.
- `.../CMakeLists.txt` — confirms **enet** (vendored) + **nanors** (vendored); `USE_MBEDTLS` option.
- `.../src/FakeCallbacks.c` — no-op callbacks for the Phase-2 link test.

**Reference iOS client (study, don't reinvent):**
- moonlight-ios `Limelight/Stream/Connection.m` + `ConnectionCallbacks.h` — the ObjC wrapper around `LiStartConnection` and the C callbacks (model for `MoonlightSession`).
- moonlight-ios `Limelight/Stream/VideoDecoderRenderer.m` — VideoToolbox/`AVSampleBufferDisplayLayer` decode+render (Phase 3).
- moonlight-ios audio renderer — Opus → CoreAudio (Phase 4).
- moonlight-ios `.gitmodules` — confirms it too vendors `moonlight-common-c`; its `BuildScripts/` are the map for the mbedTLS/opus iOS builds.
