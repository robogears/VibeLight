# Moonlight-qt Fork Plan (VibeLight v2)

**First milestone:** M1: Get the stock (unmodified) fork building and streaming first, to de-risk the toolchain before any code changes. Concretely: `brew install qt`; create the public GitHub fork and clone it; `git submodule update --init --recursive`; `python3 setup-deps.py` (MANDATORY before qmake — app.pro:55-62 hard-errors without libs/mac); `export PATH="$(brew --prefix qt)/bin:$PATH"`; `qmake moonlight-qt.pro && make -j$(sysctl -n hw.logicalcpu) release`; then run `app/Moonlight.app/Contents/MacOS/Moonlight stream <host> "<app>"` against the live Vibepollo host and confirm you see the game stream. This proves the (highest-friction) build environment works before you touch a single source file.

**Top risks:**
- Headless path still needs a QQuickWindow: Session::initialize() takes a QQuickWindow* and session.cpp:1313-1315 reads m_QtWindow->screen() to pick the display. Mitigation: keep one hidden (visible=false) QQuickWindow in the C++ orchestrator instead of chasing a true zero-QML build; the non-fullscreen min/maximize uses of m_QtWindow are all guarded by !m_IsFullScreen and never fire for the fullscreen helper.
- streamsession.cpp must faithfully replicate StreamSegue.qml's orchestration (initialize(window) -> handle launchWarnings -> start(), plus the initialize()-returns-false early exit and the exact clean-exit condition quitAfter && no-error-text at StreamSegue.qml:76). Getting this subtly wrong = silent no-stream or a reintroduced hang. Mitigation: port it line-for-line from the verified QML.
- LSUIElement agent app does NOT auto-take key focus, and the visible window is SDL's NSWindow (separate from Qt's), so keyboard/gamepad capture and frontmost handoff can break. Mitigation: add the Objective-C++ activation shim ([NSApp activateIgnoringOtherApps:YES] + [nsWindow makeKeyAndOrderFront:]) compiled in the existing app.pro macx block, exposed as a RAISE/FOCUS control command, and test focus explicitly in M4.
- Nested-app codesigning: codesign --deep mis-signs the Qt/SDL2/FFmpeg frameworks that macdeployqt folds in. Mitigation: sign inside-out (helper + its frameworks first, VibeLight.app last), no --deep, hardened runtime on the helper's main executable, and test entitlements (likely disable-library-validation / allow-unsigned-executable-memory for Qt/QML/FFmpeg) against notarytool before shipping.
- Mac App Store is permanently off the table for the bundled GPLv3 helper (VLC precedent; you are not the sole copyright holder so cannot grant an App-Store exception). If MAS ever becomes a hard requirement the entire engine choice must change. Plan on Developer-ID + notarized direct distribution from day one.
- License infection if the process boundary is broken: moonlight-common-c is GPLv3-only and static-linked, so the whole helper is one GPLv3 work. If VibeLight ever links or dlopens moonlight code (instead of exec+CLI+socket), VibeLight's own SwiftUI code is forced GPLv3. Mitigation: keep communication strictly to CLI args / unix socket / signals / exit code; never link across the boundary.

---

## THE PLAN: Fork moonlight-qt into `vibelight-moonlight-helper`

I verified every load-bearing claim against the actual source in the scratchpad clones before writing this. Line references below are confirmed, not paraphrased from the research. Repo root in examples = `$MLQT`.

---

### 1. VERDICT

**Fork moonlight-qt as a headless helper. Do NOT embed moonlight-common-c yourself.** Embedding the raw protocol lib means you personally reimplement the entire proven pipeline that lives *above* it in the `Session` class (`app/streaming/session.cpp`, ~2400 lines): the VideoToolbox/Metal + libplacebo/MoltenVK renderers, SDL window/input/gamepad handling, HDR/EDR color setup in `vt_metal.mm`, audio via Opus, RTSP handshake orchestration, port-testing, and all the macOS-specific fullscreen/Spaces workarounds. That is thousands of lines of hard-won, device-tested code you'd be re-debugging for months, and you'd *still* be GPLv3 (moonlight-common-c is itself GPL-3.0, static-linked). Forking keeps all of that intact and confines your work to a small, well-isolated surface: swap the QML orchestration layer for a headless C++ launcher, neuter the dialogs, add a plist key and an activation shim. The one honest caveat: you inherit Qt (QtCore/Network/Qml/Quick) as a runtime dependency even though you'll never show QML — but you keep a *hidden* `QQuickWindow` anyway because `Session::initialize()` needs a `QQuickWindow*` and `session.cpp:1313-1315` reads `m_QtWindow->screen()` to pick the display. Fighting that to go zero-QML is not worth it for M1. Fork wins decisively.

---

### 2. TOOLCHAIN SETUP (macOS 15, Apple Silicon, Xcode 26.6, Homebrew)

Xcode 26.6 is already present and far exceeds the Xcode 14 floor. Exact commands for a first green build:

```bash
# 1. Qt 6.11.1 (byte-for-byte the CI version) + qmake + macdeployqt
brew install qt                       # lands in $(brew --prefix qt)/bin

# 2. Fork + clone (do this AFTER you create the public GitHub fork, see §6)
git clone https://github.com/<you>/vibelight-moonlight-helper
cd vibelight-moonlight-helper
git submodule update --init --recursive   # moonlight-common-c, qmdnsengine, h264bitstream, SDL_GameControllerDB

# 3. Prebuilt media/crypto libs — MANDATORY before qmake (app.pro:55-62 hard-errors if libs/mac missing)
python3 setup-deps.py                  # downloads libs/mac (OpenSSL3, FFmpeg, Opus, SDL2, SDL2_ttf, libplacebo)

# 4. Fast arm64-only dev build (a few minutes; skip universal+LTO for the dev loop)
export PATH="$(brew --prefix qt)/bin:$PATH"
qmake moonlight-qt.pro
make -j$(sysctl -n hw.logicalcpu) release
# → app/Moonlight.app/Contents/MacOS/Moonlight
```

Notes / gotchas that will bite otherwise:
- **Order is load-bearing:** `setup-deps.py` MUST run before `qmake` (it's a *qmake-time* hard error, not a make-time one). Re-run it after every `git clean`.
- Forgetting `git submodule update --init --recursive` yields confusing *linker* errors (undefined symbols vs moonlight-common-c/qmdnsengine/h264bitstream), not a clear message.
- **Skip `--with-debug`** (README is stale; no debug bottle exists). Ship Release.
- **Skip `create-dmg`/`node`** entirely — you're embedding, not shipping a DMG.
- Don't run the CI universal+LTO path (`generate-dmg.sh` with `QMAKE_APPLE_DEVICE_ARCHS="x86_64 arm64"` + `-flto=thin`) for the dev loop — it's ~10-20 min vs a few minutes. You'll do universal only for the final embed if you want x86_64 support.
- **`macdeployqt` is load-bearing for embedding:** a bare binary won't launch after being moved. Run `macdeployqt app/Moonlight.app -qmldir=app/gui` to fold Qt frameworks + QML runtime + fixed rpaths (`@executable_path/../Frameworks`, app.pro:577) into the .app before you copy it into VibeLight.

---

### 3. FORK CHANGES (ordered checklist)

The single organizing insight, verified in source: **the modal-hang failure mode lives entirely in QML, not C++.** The C++ `Session` already emits clean structured Qt signals for every transition (`session.h:128-145`). The QML segues turn those signals into blocking `Dialog.open()` calls whose `onClosed` is the only thing that calls `Qt.quit()`. So the fork's core move is: replace the QML orchestrator with a headless C++ launcher, and delete the segue QML from the failure path.

**(a) Strip UI + go headless for stream/quit**
1. **New file `app/cli/streamsession.{h,cpp}`** — a `QObject` that replaces `StreamSegue.qml`'s orchestration. Model it on the `list` path (`main.cpp:1028-1036`), the ONLY existing `hasGUI=false` action. It must replicate exactly what `StreamSegue.qml` does today:
   - Construct a hidden `QQuickWindow` (needed only so `Session::initialize()` can read `->screen()` at session.cpp:1313; keep it `visible=false`).
   - On `CliStartStream::Launcher::sessionCreated(appName, Session*)`, connect all 7 Session signals (`stageStarting`, `stageFailed`, `connectionStarted`, `displayLaunchError`, `quitStarting`, `sessionFinished`, `readyForDeletion`) to the status emitter (§3d).
   - Call `session->initialize(hiddenWindow)`; if it returns false, emit failure + exit. Then `session->start()`. (This mirrors `StreamSegue.qml` `streamLoader.onLoaded` and `startSessionTimer`.)
2. **`app/main.cpp:998-1024`** — in `StreamRequested`/`QuitRequested`: when the new `--headless`/`--vlctl` flag is present, set `hasGUI = false`, construct the `CliStartStream::Launcher` + your `StreamSession` orchestrator, call `launcher->execute(new ComputerManager(StreamingPreferences::get()))` directly (exactly like line 1033), and DO NOT set `initialView`. The `if (hasGUI)` block at `main.cpp:1039-1047` then never loads `qrc:/gui/main.qml`. This one change eliminates the entire chrome + every hang.
3. **`app/gui/main.qml`, `StreamSegue.qml`, `CliStartStreamSegue.qml`, `CliQuitStreamSegue.qml`, `QuitSegue.qml`, `ErrorMessageDialog.qml`** and the library/settings QML (`PcView.qml`, `AppView.qml`, `SettingsView.qml`, `GamepadMapper.qml`) — remove from `app/qml.qrc` and their C++ models (`gui/computermodel.*`, `gui/appmodel.*`) from `app.pro` SOURCES. This is *optional polish for M2+* (attack surface / size); M1 just never loads them. If you keep them, the hang can silently return, so prefer deleting once the headless path works.

**(b) Kill blocking dialogs → clean signals**
Because you drove stream/quit fully headless in (a), there are **no dialogs left** in the stream path — the QML that owned them is never loaded. The failure signals now arrive as C++ `Session`/`Launcher` signals and route straight to the status emitter:
- `CliStartStream::Launcher::failed(QString)` (emitted at `startstream.cpp:89` not-paired, `:124` quit-prev-failed, `:131` connect-timeout, `:135` app-not-found) → status line + `QCoreApplication::exit(code)`.
- `Session::stageFailed`/`displayLaunchError`/`sessionFinished` → status line. The clean-exit condition is preserved from `StreamSegue.qml:76`: `quitAfter && no error text` → exit 0.
- **"Another app running":** `Launcher::appQuitRequired(appName)` (from `startstream.cpp:107`) was an interactive Yes/No modal. Replace with a **deterministic policy**: default to auto-`launcher->quitRunningApp()` then proceed (matches VibeLight's own pre-launch reconcile), OR emit status `ANOTHER_APP_RUNNING <name>` and exit code 15 for VibeLight to drive. No modal either way.
- The 25s+ **quit-action hang** disappears with the QuitRequested headless path — `quitstream.cpp:99` already exits 0 cleanly on success; only the QML `onFailure` dialog was hanging.

**(c) Hide dock icon / chromeless window**
- **`app/Info.plist`** — add `<key>LSUIElement</key><true/>`. Absent today (verified). Makes it an agent: no Dock icon, no menu bar, no Cmd-Tab. The plist is templated through `app.pro:557-561`, so the source edit propagates.
- **Also in `app/Info.plist`:** change `CFBundleIdentifier` from `com.moonlight-stream.Moonlight` to e.g. `com.vibelight.streamhelper`, and `CFBundleExecutable`/`CFBundleName`/`CFBundleDisplayName` to fork-specific names. **And** change the QSettings domain at `main.cpp:431-433` (`setOrganizationName`/`setApplicationName`) — otherwise the helper shares/clobbers the user's real `com.moonlight-stream.Moonlight.plist` (host/cert state, last-writer-wins). Give the helper its own domain and pass all config via CLI flags (flags never persist anyway — the parser never calls `save()`).
- **Window mode:** the SDL/Metal window is already borderless in fullscreen-desktop. The **Spaces fix is via `windowMode`, not a raw hint edit** (this corrects the research): `session.cpp:592` sets `shouldUseFullScreenSpaces = (windowMode != WM_FULLSCREEN)`, and on macOS *all* window modes resolve `m_FullScreenFlag` to `SDL_WINDOW_FULLSCREEN_DESKTOP` anyway (`session.cpp:896-908`, real modesetting only under `I_WANT_BUGGY_FULLSCREEN`). So **set the helper's `StreamingPreferences::windowMode = WM_FULLSCREEN`** → you get safe borderless-desktop fullscreen AND `SDL_HINT_VIDEO_MAC_FULLSCREEN_SPACES=0` (same Space as VibeLight, no swipe animation). Do NOT switch to real modesetting fullscreen (documented deadlocks, issues #973/#999/#1211/#1218).

**(d) Control channel + status protocol**
- **New `app/cli/vlctl.{h,cpp}`** — a bidirectional local channel. Primary: a unix domain socket passed as `--vlctl <path>`. Fallback: stdout status + stdin commands. Keep it OFF the Qt/SDL log stream (`main.cpp:459-473` log redirect) so status is never interleaved with log spew.
- **Status OUT** (newline-delimited, machine-readable, raw ints not localized `tr()` strings):
  ```
  STAGE <name>                              # from stageStarting
  STARTED                                    # from connectionStarted (= negotiated, NOT first-frame)
  FAILED code=<int> stage=<name> ports=<f> reason="<text>"   # stageFailed/displayLaunchError/Launcher::failed
  QUITTING_HOST_APP                          # from quitStarting
  ENDED reason=graceful|terminated code=<int> port_test=<int>  # from sessionFinished
  BYE                                        # from readyForDeletion → then exit
  ```
  Emit the raw `errorCode` from `clConnectionTerminated` (`session.cpp:88-145`) — VibeLight must NOT string-match localized text.
- **Commands IN** (this is the feature the CLI lacks): `DISCONNECT` → `Session::get()->interrupt()` (session.cpp:1751, disconnect only, game keeps running); `QUIT_GAME` → `Session::get()->setShouldExit(true)` then push `SDL_QUIT` (mirrors `keyboard.cpp:142-154`, terminates remote app via host `/cancel`); optional `RAISE`/`FOCUS` → the activation shim. `Session::get()` is a static accessor (`session.h:114`) and both `interrupt()` and `setShouldExit()` are cross-thread-safe (push SDL events / set atomics), so this is a few lines.
- **Honest exit codes** as a backstop (all paths funnel through `DeferredSessionCleanupTask::run`, session.cpp:1254-1296): 0=graceful, 64=failed-to-start, 65=terminated-mid-stream, 66=user-quit. Treat the control channel going silent as the real crash signal; keep a VibeLight-side watchdog.

**(e) Native quit keybind — ALREADY EXISTS, verified**
`KeyComboQuitAndExit` = **Ctrl+Alt+Shift+E** (`input.cpp:116-118`, `enabled=true` on macOS) → `keyboard.cpp:142-154` calls `Session::get()->setShouldExit(true)` → `session.cpp:1719-1730` forces `quitAppAfter=true` → `DeferredSessionCleanupTask` does host `http.quitApp()` (the `/cancel` action) AND `QCoreApplication::quit()`. **This is exactly "quit game completely" — nothing to build for keyboard.** (Plain Ctrl+Alt+Shift+Q is disconnect-only.) Fork work is only:
1. **Gamepad full-quit chord** — the built-in `Start+Select+L1+R1` (gamepad.cpp:366-374) is disconnect-only. Add a *distinct* chord in `handleControllerButtonEvent` that calls `setShouldExit(true)` before pushing `SDL_QUIT`, mirroring the keyboard handler. (Env `NO_GAMEPAD_QUIT=1` disables the built-in one if you want to own the chord.)
2. Optionally emit a `QUIT_REQUESTED_BY_USER` status line from that path so VibeLight distinguishes intentional quit from crash.

**(f) Activation shim (new `.mm`)**
Agent apps (`LSUIElement=1`) do NOT auto-activate or take key focus. Add a small Objective-C++ file compiled in the existing `macx {` block (`app.pro:407-413` already builds `.mm` files). After stream-window creation, call `[NSApp activateIgnoringOtherApps:YES]` + `[nsWindow makeKeyAndOrderFront:nil]` on the SDL window's NSWindow (via `SDL_GetWindowWMInfo` → `cocoa.window`). Expose it as the `RAISE`/`FOCUS` control command. On teardown do nothing — VibeLight re-activates itself when the helper exits.

Leave `vt_metal.mm` HDR/color untouched — HDR works as-is once the `hdr` preference/flag is set.

---

### 4. VIBELIGHT INTEGRATION

**Where it lives:** `VibeLight.app/Contents/Helpers/StreamHelper.app` (Apple TN2206 convention for nested helpers). Copy the *full macdeployqt-processed* `.app` (binary + `Contents/Frameworks` Qt/SDL2/FFmpeg/placebo dylibs + `Contents/Resources/qml`). Never the bare binary.

**Launch & drive — replacing the current CLI + watchdog hackery:**
- **Today** (from research): VibeLight `Process`-execs the stock `Moonlight stream <host> <app> [flags]`, tails a log file for status, SIGTERMs to disconnect, and fights the hang-forever dialogs with watchdog timers and log-scraping.
- **New `StreamSessionManager`:** exec `Contents/Helpers/StreamHelper.app/Contents/MacOS/StreamHelper stream <host> "<padded-appName>" --vlctl /tmp/vibelight-<uuid>.sock --headless [--fps 144 --bitrate ... --hdr ...]`. The argv *shape is unchanged*, so existing launch code mostly survives. Then:
  - Open the `--vlctl` socket, read newline-delimited status (`STAGE`/`STARTED`/`FAILED`/`ENDED`/`BYE`) — replaces log-tailing with a deterministic parse.
  - Send `QUIT_GAME` on the socket for "quit game completely" (replaces the separate `moonlight quit` process that itself hung), `DISCONNECT` for disconnect-only, `RAISE` on handoff.
  - **Drop the log-scraping and the dialog-dismissal watchdog entirely.** Keep only a lightweight watchdog that treats *socket silence + process exit without `BYE`* as a crash.
  - Exit codes become honest (0/64/65/66) as a secondary confirmation.

**Seamless activation handoff:**
- **VibeLight → helper (stream start):** on `STARTED`, send `RAISE`; the shim calls `activateIgnoringOtherApps` + `makeKeyAndOrderFront` so the fullscreen SDL/Metal window comes frontmost over VibeLight. Because the helper runs with `windowMode=WM_FULLSCREEN` → `SPACES=0`, it lands in VibeLight's *current* Space — no swipe animation.
- **helper → VibeLight (stream end):** on `ENDED`/`BYE` or process exit, VibeLight calls `NSApp.activate(ignoringOtherApps:)` on itself. The helper does nothing special on teardown — this is VibeLight's job (there is no parent-handback code in moonlight, confirmed).

**Process boundary stays pristine** (critical for licensing, §6): only CLI args + the unix socket + signals + exit code between the two. Never link helper code into the Swift process.

---

### 5. MILESTONES (each independently verifiable)

- **M1 — Builds unmodified + launches + streams.** `brew install qt`, submodules, `setup-deps.py`, `qmake && make`. Run the *stock* built `Moonlight.app` with `stream <host> <app>` against the live Vibepollo host. **Verify:** you see the game stream. No fork changes yet — this de-risks the toolchain (the biggest first-build friction) before touching code.
- **M2 — Headless stream, no chrome, clean signals.** Implement §3a (`streamsession.cpp` + `main.cpp` `--headless` branch) and §3d status-OUT over stdout. **Verify:** streaming works with zero QML window ever shown; a forced failure (wrong app name, unpaired host) prints a `FAILED code=…` line and the process **exits deterministically** (no hang) with a nonzero code.
- **M3 — Control channel IN + native quit.** Add the `--vlctl` socket with `DISCONNECT`/`QUIT_GAME`/`RAISE` (§3d) and the gamepad full-quit chord (§3e). **Verify:** VibeLight sends `QUIT_GAME`, the remote game actually terminates on the host (check host shows no running app), and in-stream Ctrl+Alt+Shift+E does the same.
- **M4 — Invisible agent + Spaces + focus handoff.** Add `LSUIElement` + fork bundle id + QSettings domain (§3c), `windowMode=WM_FULLSCREEN` for `SPACES=0`, and the activation shim (§3f). **Verify:** no Dock icon, no Cmd-Tab entry; stream appears in VibeLight's Space with **no swipe animation**; focus lands on the stream at start and returns to VibeLight at end.
- **M5 — Embed + sign + notarize.** `macdeployqt`, universal build if wanted, nest into `VibeLight.app/Contents/Helpers/`, sign inside-out (no `--deep`, hardened runtime), notarize the outer DMG. Rewire `StreamSessionManager` to the embedded path. **Verify:** clean notarized VibeLight.app on a fresh machine streams end-to-end via the bundled helper.

---

### 6. RISKS & LICENSING

**Top risks + mitigations:**
1. **Headless `Session::initialize()` needs a `QQuickWindow*`** (reads `->screen()` at session.cpp:1313). *Mitigation:* keep one hidden `QQuickWindow` in the C++ orchestrator; don't chase zero-QML for M1. Low risk, already scoped.
2. **`streamsession.cpp` must faithfully replicate `StreamSegue.qml`'s init sequence** (`initialize(window)` → `launchWarnings` → `start()`, and the `initialize`-returns-false early-out). *Mitigation:* port it line-for-line from the verified QML; it's ~40 lines of logic.
3. **Agent app may not take key focus / SDL window focus quirks** under `LSUIElement`. *Mitigation:* the activation shim (§3f); test focus explicitly in M4.
4. **Nested-app signing** — `--deep` mis-signs macdeployqt's Qt frameworks. *Mitigation:* sign inside-out, each component explicitly, hardened runtime on the helper's main exec; Qt/QML/FFmpeg may need `disable-library-validation`/`allow-unsigned-executable-memory` entitlements (test against notarytool). Moonlight's own notarized build proves a clean set exists.
5. **Deps asset case mismatch** (`setup-deps.py` requests `macos-universal.zip`, real asset is `macOS-universal.zip`; works only via GitHub's case-insensitive redirect). *Mitigation:* if you mirror/pin the deps zip, match the capitalized name.

**GPL compliance checklist (the practical path — no lawyer needed for personal/optionally-OSS + Developer-ID distribution):**
1. **Fork moonlight-qt PUBLICLY on GitHub** (`vibelight-moonlight-helper`). A public repo alone satisfies GPLv3 §6 source-availability. Pin all submodules at the exact built commits (moonlight-common-c, qmdnsengine, h264bitstream, SDL_GameControllerDB) so Corresponding Source is complete + buildable.
2. **Keep `LICENSE` (GPLv3) unchanged.** moonlight-qt AND moonlight-common-c are both GPL-3.0-**only** (no "or later" — you're pinned to v3). moonlight-common-c is static-linked (`CONFIG += staticlib`), so the whole helper binary is one GPLv3 work — no proprietary carve-out possible.
3. **Add a top-level `CHANGES` note** ("Modified from moonlight-stream/moonlight-qt (GPLv3): headless chromeless helper, no menu/settings UI, error signals via exit code/stdout+socket instead of modal dialogs, control channel, gamepad quit chord.") and per-file "modified by <you>, <date>" notices (§5(a)) on every file you touch.
4. **Attribution in VibeLight's About/Acknowledgements** — the chromeless helper has no About box, so this is the ONLY attribution surface. Credit moonlight-qt + moonlight-common-c (GPLv3, link to your fork), SDL2 (zlib), FFmpeg (LGPL), enet/nanors/qmdnsengine (MIT), h264bitstream (LGPL-2.1). Ship an aggregated third-party-licenses NOTICE in both fork and VibeLight.
5. **Keep the process boundary pristine** — only CLI args / unix socket / signals / exit code between VibeLight and the helper. **Never static-link or `dlopen` moonlight code into the Swift process.** This is the entire basis for VibeLight's own SwiftUI code staying non-GPL (FSF "mere aggregation / separate programs communicating at arm's length"). If you ever link it in, VibeLight itself becomes GPLv3.
6. **Distribute via Developer-ID + notarization (DMG/zip), NOT the Mac App Store.** GPL is fundamentally incompatible with MAS (VLC precedent: MAS Usage Rules impose per-device restrictions GPLv3 §6/§7 forbid; you can't grant an App-Store exception because you're not the sole copyright holder). Notarization/codesigning are integrity signatures, NOT usage restrictions — zero GPL conflict. This is exactly how official Moonlight ships.
7. **Ship-or-offer source with every release:** simplest = release notes link to the exact public fork tag the bundled helper was built from (GPLv3 §6(d)/(e) network-location option). If you ever ship a binary without the public repo, include a written 3-year source offer.
8. **VibeLight's own license is free choice** (proprietary or any OSS) as long as 1-7 hold.
9. **Lawyer only if:** you pursue the Mac App Store, or you abandon the process boundary (link moonlight into VibeLight), or you commercially sell the bundle. None apply to the current plan.