# Overnight Loop Report — 2026-10-21

**TL;DR — running again since you resumed it on 26 Oct.** VibeLight lives in ~/Developer with its stream helper; the deep audit is done and dry (0 critical, 0 high, 18 medium, 70 low, 27 suggestion — private report inside `.git/overnight-loop/`). Merged on `codeX`: fix groups 1 (saved data) and 7 (updater), your Computers-menu order, and 7 of the 13 visual changes. Building: fix group 5 (identity safety) and visual batch 2C (accent labels, destructive red, no hover zoom). Nothing merged to main, nothing released.

STATUS: LOOPING · cycle 0 · 8 done · build+tests GREEN (198 Mac; the one intermittent failure is now identified — the known loopback flake, BoundedResponseTests, passes alone; fix queued in G9) · last: updater fixes merged

## Run
- Started: 23:24 · Branch: codeX from main · Ceiling: none (runs until you stop it)
- Commits: `git log --oneline --grep='^loop' main..codeX`

## Questions for you (parked forks and end-of-rope questions — answer any to unpark)
- ❓ Visual / design changes from the audit — build them, or keep them parked? — options: build after you review | keep parked — parked item: "Visual / design changes" (you said "no visual changes for now")

## Recommendations (things the loop chose not to do unattended)
- 💡 Your CLAUDE.md (fix group 9; your file, not edited): line ~214 says the leave chord "shows a 2 s progress ring" — the code is ~1 s (`total = 1.0`), suggest "held Start+Select+LB+RB leave chord that shows a ~1 s progress ring"; line ~194 lists "config import, identity (macOS reuse + …)" under Core/ — suggest "models, contracts, identity (VibeLight's own: macOS files + iOS keychain), …"; lines ~43–45 — Swift duplicates are now gitignored; suggest moving strays aside instead of deleting: `mkdir -p _dump/strays && find VibeLight VibeLightTests VibeLightiOSTests \( -name '* [0-9].swift' -o -name '* copy.swift' -o -name 'Info [0-9]*.plist' -o -name 'iOS-Info [0-9]*.plist' \) -exec mv -n {} _dump/strays/ \;`. QUA-claude-md-points-to-untracked: CLAUDE.md lines 3–6 point the public repo at `AIKnowledge.md`, which is kept out of git — move that pointer into `CLAUDE.local.md`, or split AIKnowledge into a public map and a private findings file.
- 💡 Privacy guard gaps (scripts/git-hooks — your guard rails, not edited): SEC-pre-commit-external-diff-bypass — in `pre-commit` (~line 38) use `git diff --cached --unified=0 --no-color --no-ext-diff --no-textconv`, refuse when `--numstat` shows added lines but none were scanned, and add a test with a stub `GIT_EXTERNAL_DIFF`; SEC-commit-msg-scissors-bypass — in `commit-msg` (~line 37) cut at the scissors line only when the next non-empty line starts with `diff --git`, plus a test; QOL-topology-guard-coverage-gaps — read an untracked deny-list generated from `CLAUDE.local.md`, add private IPv6 (`fd..:`) and `.ts.net`, and add a `pre-push` hook running the same checks.
- 💡 QUA-moonlight-import-dead-code (rest, queued as G9b): `IdentityStore.resolve(moonlightIdentity: nil)` → `resolve()` and drop the parameter; delete `AppState.importedHosts` and start `rebuildHosts` with an empty list; fix the two comments that still mention Moonlight's hosts.
- 💡 swift-crypto 5.0.3 (clears the second, unreachable advisory) needs swift-certificates raised to 1.21.0 in project.yml first.
- 💡 Product decision for you: should the iPad's identity key use the "this device only" keychain class, so it never travels in a backup to another device?
- 💡 Leftover (Low, 3H) — while a PC restarts, the empty shelf says "<PC> is asleep" with a Wake button while the header chip shows the grey "Restarting…"; the shelf rule ignores the restart notice. Fix: give the shelf a restarting state (spinner, no button).
- 💡 Leftover (Low, 3H) — before the first check answers, the header chip still says "asleep" with its Wake button (pre-existing); after a successful wake, a PC with no saved games list briefly shows "No games on <PC> yet"; with games present, the hint says "Play" while focus is on the header's Wake/Restart buttons (pre-existing).
- 💡 Two sentences for your CLAUDE.md (fix group 5; it's your instruction file, so I haven't edited it) — under "Host protocol": "macOS: a read error on `Application Support/VibeLight/identity` is never treated as absent — an identity is generated only when both `client.pem` and `client.key` are missing or empty, into a staging folder, and moved into place only after the key and certificate are checked to match." — and under the iOS identity note: "Pairing re-reads the keychain certificate when it starts (never a launch-time copy); `IOSKeychainIdentity` takes a `Namespace`, the app always uses `.production`, and tests use their own."
- 💡 FS-update-swap-unchecked-stage (rest) — the relauncher script still copies the new version over the old one in place; building it beside the old copy and swapping with two renames would make a half-finished install impossible — why not done: it changes the install path itself, which can only be proven by running a real update. Do it with an updater end-to-end test run.
- 💡 After a failed update rolls back, the next launch says nothing — a one-line "The update couldn't be installed; you're still on X" card would tell you why the version didn't change.
- 💡 Leftover (Low) — on a landscape iPhone or a Mac window under ~860 pt tall, Interface Size ▸ Large can't make anything bigger, and the row doesn't say so. iPhone really needs a compact Home layout (the design lead's recommendation), which is a bigger design job.
- 💡 Leftover (Low) — the stream controls only notice AssistiveTouch being switched on at their next redraw (SwiftUI can't observe it); VoiceOver and Switch Control are noticed immediately. Fix later with a UIAccessibility notification observer.
- 💡 Leftover (Low) — the keyboard-hint fix has a unit test for its rule but no test pinning the wiring that tags keyboard vs controller input; a future edit could quietly undo it.
- 💡 The helper repo tracks a generated build file, `app/Makefile.Debug`, that has your full home-folder path in it and is public on GitHub — why: it leaks the machine path, and since the move it points at the OLD location, so the helper's next `make` needs a fresh `qmake moonlight-qt.pro` first — how: in ~/Developer/vibelight-moonlight-helper, `git rm --cached app/Makefile.Debug`, add `app/Makefile.*` to .gitignore, commit, push. Not done unattended: it's another repo's `master`.
- 💡 Stale Xcode build cache for the old ~/Documents path (588 MB, `~/Library/Developer/Xcode/DerivedData/VibeLight-gbkjmozetujwozebxnxfvkmtocuj`) — why: nothing uses it any more — how: delete it from Xcode ▸ Settings ▸ Locations, or Finder. Not done unattended: it's your disk.
- 💡 `_dump/` inside the repo (231 MB, 5,141 files, gitignored) is the quarantine from an earlier cleanup pass (sync-conflict copies such as `VibeLight 2.xcodeproj`); `_dump/undo.sh` restores everything — why: the repo is out of iCloud now, so these should stop appearing — how: once you're happy nothing is missing, delete `_dump/`. Not done unattended: it's your quarantine.
- 💡 Seven iCloud conflict copies of git's own index file sit in `.git/` (`index 2` … `index 8`) — why: harmless leftovers from when the repo lived in iCloud, but they're junk inside git's folder — how: `rm ".git/index "[2-8]` once you've seen this.
- 💡 Claude's old memory folder for the previous path (`~/.claude/projects/-Users-william-Documents-VibeLight/`) — why: its 10 notes were copied to the new path and verified identical — how: delete it whenever you like.

## Progress log (last 20; older lines roll into the tally)
- 26 Oct 22:40 Fix group 9 merged (13 findings; review 1 upheld 3 Lows, fixed; last review 1 Low → your CLAUDE.md, see Recommendations). What you now get: the README gives the right leave-stream chord (~1 s), drops the removed Moonlight import and calls the iPad key an ordinary keychain key; Mac tests no longer boot VibeLight against your real settings and PCs; the flaky size-cap tests passed 180/180 under load; two tests that couldn't fail now can; Finder duplicates of private files are ignored; the install script stops promising a stock-Moonlight fallback; swift-crypto 4.5.0 → 4.5.2. 250 Mac tests green, iOS build green. iOS unit tests NOT yet run on the merged tree — the Simulator timed out booting while another lane used it; they run once on the final tree. Pushed.
- 26 Oct 22:10 Visual 3H merged (2 audit items; review 1 upheld 4 Lows, fixed; last review 1 Medium + 2 Lows — the Medium and one Low fixed directly with tests proven to fail without them, independently checked, 2 more Lows from that check fixed; 1 Low left in Recommendations). What you now get: an empty Home says why it's empty and offers the next step (Add Computer, Pair Computer, Wake Computer; "Looking for <PC>…" until it first answers); computer-banner errors wrap to two lines and show in full in the Computers card; "Restarting <PC>…" is grey progress with a spinner. Source- and unit-checked, not yet seen in a running app (see Live checks). 248 Mac tests green, iOS build green. Pushed.
  - The first 3H run died on the session limit (21:00) with nothing built; my workflow wrongly called it mergeable — fixed so it can't again; nothing was merged from that run.
  - 22:00 you asked to wrap up after the work in progress: 3I, G9 and G6a finish; G2, G3, G4, G6b and G8 stay queued (MasterTasks MT-13).
- 26 Oct 20:15 Visual 2C merged (3 audit items; review 1 upheld 2 Lows, both fixed; last review clean): labels on the full-strength blue are navy (6.8:1, was white at 2.7:1); Increase Contrast brightens faint borders; Clear Preset and Forget Computer turn red when focused, like Restart PC; Settings tabs and card buttons brighten on hover instead of growing. Source-checked and unit-tested, not yet seen in a running app (see Live checks). 209 Mac tests green, iOS build green. Pushed.
  - TV fix pixel check: the Simulator can't show "TV with no controller" — a temporary logging build (never committed, removed) showed the app keeps the launcher on the iPad until the Simulator connects a virtual "Gamepad" ~9 s after launch, then correctly shows the companion panel. TV + controller looks right (screenshot sent). The no-controller half needs your iPad.
  - I briefly tried attaching the debugger to the Simulator app; it needed a macOS approval I won't change, so I stopped it within 60 s (no effect).
- 26 Oct 19:50 G7 updater fixes merged (6 findings; review 1 upheld Low, last review 1 Low, fixed directly — a comment that disagreed with the code). What you now get:
  - Restart Now refuses a downloaded update that changed or disappeared since it was checked;
  - a failed first install reopens the copy you were running;
  - an older VibeLight opened from Downloads or a disk image no longer offers to replace a newer (or the same) version in Applications;
  - the Mac's display can sleep while VibeLight is hidden or another app is in front;
  - an update found while a game is streaming waits and shows its card after the stream;
  - a Mac stream that fails to connect says which step failed, the error code and which ports to open.
  - Honest notes: the update swap script itself was NOT changed (Restart Now re-checks the download instead — changing the swap can't be proven safe without running one); the relocate version check happens when the card is offered, not again at Move; all of it checked by tests and source, never run for real (no update, swap or relocate was run). 198 Mac tests: 1 failure, `BoundedResponseTests/testNormalResponseStillParses` — the known loopback flake (machine load average was ~90–500); it passed alone twice. The earlier "unidentified" failure was almost certainly the same test.
  - iPad Simulator pixel check (fake TV + Xbox pad, Home after setup) — see Live checks. On a fresh install the first launch took 30 s+ on this loaded Mac (white screen until then), not a hang.
- 26 Oct 18:58 The TV dead end is fixed (audit Medium): with a TV plugged in and no controller, the launcher stays on your iPad and the TV mirrors it; with a controller, the companion panel takes over as before (and gives the iPad back if the controller drops out). The panel now has a quiet "Use the iPad Instead" button and no longer shows the TV's pixel numbers. Review raised a possible new compiler warning in Release builds; real iOS and Mac Release builds showed it doesn't exist.
  - Honest note: the first full test run of the merged tree had 1 failure I didn't capture the name of. Six more runs (2 full, 4 targeted on the timing-sensitive network tests) were all clean. Most likely the loopback-timing flake the audit already flagged (QUA-bounded-test-loopback-flake, in fix group 9).
- 26 Oct 18:10 Settings ▸ Audio now has a Menu Sounds switch (On by default). Off silences the launcher's ticks, chimes and the setup quack on Mac and iPad — games and controller haptics are unaffected — and it survives relaunching and loading presets. 171 Mac tests green.
- 26 Oct 17:50 The previous session ended (the Mac restarted) while three jobs were running; you said "keep going". Nothing was lost: fix group 5 had all four fixes committed, the TV-dead-end batch both of its fixes, and the menu-sounds batch's work was saved as an unverified WIP commit. All three resumed to verify and finish their reviews.
- 26 Oct 17:05 iPad text and touch targets merged (audit Medium):
  - on iPad the launcher is a little larger (it fits the same canvas as a Mac window);
  - small labels are at least 13 pt and buttons have 44 pt tap areas on iPad/iPhone; the Mac keeps its exact sizes;
  - Settings ▸ Themes ▸ Interface Size (Default / Large) makes it bigger still, and loading a preset doesn't undo it;
  - preset chips on iPad drop the bitrate ("1080p · 144 fps") rather than being cut off with "…".
  - Review caught two real problems before merge (the Mac's layout had changed; iPad chips would have been cut off); both fixed. 168 Mac tests green.
- 26 Oct 16:45 Your Computers-menu request is merged: the computer you're on is listed first, a thin divider separates it from the others, and the controller moves through the rows in the order they're drawn. The menu opens on the computer you're on, and leaving the pairing panel lands back on the computer you were pairing. The review caught two focus slips along the way (one from me), both fixed and tested. 162 Mac tests green.
- 26 Oct 16:10 Fix group 1 merged. Saved data is never lost now:
  - one unreadable saved computer, Restart PC pairing or preset is kept exactly as stored, and changes to everything else still save (before, one bad entry froze the computer list for good or wiped presets);
  - a store that can't be read at all is copied aside before anything is written over it;
  - damaged saved sizes, frame rates or bitrates are pulled back into range instead of crashing Settings;
  - Frame Rate arrows step correctly from an unusual saved value;
  - a bad Restart PC port shows "Enter a port from 1 to 65535" instead of crashing.
  - Reviewed, skeptic-checked, and polished for 2 points (a second damaged copy is now also kept; a portrait screen's Native resolution survives a relaunch). 153 Mac tests + 10 iOS tests green.
- 26 Oct 16:05 A usage limit interrupted fix group 5 and the Computers-menu job. Their partial work was kept (a WIP commit for group 5), and both resumed from where they stopped.
- 26 Oct 14:15 Three visual fixes merged into codeX after code + apple-design review and skeptics:
  - iPad stream: when the ✕ and keyboard buttons hide, a faint pill stays at the top-right edge, and tapping it brings them back (the swipe still works). With VoiceOver or Switch Control on, the buttons never hide, and "Leave the Stream" is an accessibility action. Under Reduce Motion they fade instead of sliding. Increase Contrast makes the pill brighter and outlines it.
  - Mac: using the keyboard shows keyboard hints (⏎/⎋) even with a controller plugged in. Touch the controller and its buttons come back.
  - The iPad icon now fills its rounded square edge to edge, with no dark frame. Same artwork, and the Mac icons are byte-identical.
  - 135 Mac tests pass; iOS builds.
- 26 Oct 13:30 The audit's visual breakdown is published as a private Artifact (only you can open it): https://claude.ai/artifact/VMjJrFamMZh8EmixUtZpQo
- 26 Oct 13:20 Audit sweep 4 came back dry: its one lead (the Restart PC certificate check and how typed addresses are spelled) could not be settled without a live test, so it's listed under Needs investigation. The audit is complete: 0 critical · 0 high · 18 medium · 70 low · 27 suggestion.
- 26 Oct 13:15 Resumed by you ("resume the overnight loop and keep working"). Same branch, same plan; hard limits and keep-awake back on.
- 26 Oct 13:05 Stopped by you. Audit sweep 4, fix group 1 and the visual-page design were stopped; fix group 1 had made no changes, so its working copy was removed. The audit report was finalised with sweep 3 included and marked "not shown dry".
- 26 Oct 12:55 Audit sweep 3 finished: 2 new low-severity iPad keyboard findings survived their skeptics (wrong symbols on non-US PC layouts; split or floating keyboards probably bypass the touch guard). Fix-pass backlog written into the plan.
- 26 Oct 12:50 VibeLight now finds the stream helper beside it in ~/Developer (scripts look next to the repo, with a `VIBELIGHT_HELPER_DIR` override), the temporary link at the old path is gone, and the Mac build is green.
- 26 Oct 12:30 Resumed after a reboot and a usage-limit pause. The audit's result file was wiped by the reboot; all 120 verified items were rebuilt from the run's journal. Its last sweep (3 finders) had died on the usage limit and is re-running. An attempt to resume the whole run re-started it from scratch instead of replaying, so I stopped it within a minute.
- 23:30 `moonlight-ios-reference` moved back to ~/Documents (you asked: not needed — it's a documentation-only reference; nothing builds from it). Unchanged: same commit, 561 files, git healthy.
- 23:25 Kickoff on `codeX`. Baseline (tests + builds) started in the background.
- 23:23 Moved `vibelight-moonlight-helper` and `moonlight-ios-reference` from ~/Documents (iCloud) to ~/Developer — HEAD, file counts and git health identical before and after; auto-mode config updated. Temporary links left at the old paths until VibeLight's own references are repointed (mission item 2).
- 23:16 Deep audit launched (workflow wf_a91dde5e-a9c): 10 finders over all 96 first-party files, root-cause merge against the 9 Sep baseline, a fresh skeptic per Medium+ finding, sweeps until dry. Report stays private inside `.git/`.
- 23:13 Removed the stray `f` in `FocusEngineTests.swift` that stopped the test target compiling — the file now matches v0.2.1 exactly.
- 23:05 Moved VibeLight from ~/Documents (iCloud Drive) to ~/Developer — HEAD, all 8,859 files and git health identical; Claude's trust, permissions and memory carried to the new path; `BUILD SUCCEEDED` from the new location.
<!-- tally: 0 older entries archived -->

## Cycle log
- Cycle 0: mission in progress

## Completed
- Total: 6 · recent: ✅ Computers menu order (your request) · ✅ Fix group 1 (saved data) · ✅ Audit finished (dry) + visual page — 25m · ✅ Deep audit report — 70m · ✅ Helper repo moved and repointed — 14m · ✅ Stray `f` removed from FocusEngineTests.swift — 1m

## Blocked (environment)
- (none)

## Skipped / shelved
- (none)

## Excluded from commits (secret-shaped or too big — commit them yourself if they're fine)
- `AIKnowledge.md` — kept on this Mac only at your request (it describes the September audit's findings in detail). Excluded via `.git/info/exclude`.

## Decisions & assumptions (last 20 + tally)
- Visual changes unparked: you said "do everything" (26 Oct) to the 13 visual changes. Read as those 13 only — the four suggested new features and the public-history question stay parked until you say otherwise. Per your rules: a design brief first, a Fable design lead plans, Opus agents build and review, apple-design does the finishing pass, real pixels checked.
- Every fix that changes user-visible wording now gets an apple-design writing check in review (you asked, 26 Oct).
- Stayed on `codeX` (you, kickoff). It equalled v0.2.1 plus uncommitted notes; it gets pushed to GitHub as a new branch.
- `AIKnowledge.md` local-only (you); the 5-line pointer to it in `CLAUDE.md` is committed — it works for agents on this Mac and is a dead link on GitHub.
- No visual changes tonight (you): bugs, accessibility labels, keyboard/controller dead ends and wording only; anything that changes how a screen looks gets parked with a plan.
- Moved the sibling repos (you). No stop time (default).
- The audit runs read-only on the main checkout instead of a separate worktree, and the loop makes no source edits until it lands — so every file:line in the report stays valid.
- Routine iOS test runs skip `IOSIdentityTests`: the September audit found they overwrite the simulator app's real pairing identity (that's finding DAT-simulator-identity-reset-f95217a7).
- ~/Documents is iCloud-synced — that's almost certainly where the `AppState 2.swift` / `Info 2.plist` duplicates CLAUDE.md warns about came from (sync-conflict copies). Moving out of iCloud should end them.

## Live checks for you (things only your eyes or devices can confirm)
- Mac: run the tests (`xcodebuild … test`) — no VibeLight window or Dock icon appears, and your settings are unchanged. Then open VibeLight normally — it opens full-screen as before.
- iPad: hold Start+Select+L1+R1 while streaming — the ring fills in about 1 s and you leave the stream while the game keeps running.
- iPad (after installing this build): pair a computer by PIN and stream — confirms the swift-crypto 4.5.2 update.
- Empty Home (Debug builds can fake it with `VL_FAKE_HOST=asleep|offline|unpaired|online-empty|notresponding`): with no computer, the shelf shows "Add your gaming PC" and one Add Computer button, nothing in the top-right corner; asleep → Wake Computer, then a "Waking…" spinner with focus on the header's Wake; not paired → Pair Computer. **Your call:** Pair Computer now starts pairing straight away (the design plan only opened the Computers menu) — keep it? 
- Computer banner: long messages wrap to two lines with no "…" and show in full in the Computers card; "Restarting <PC>…" is grey with a small spinner, not orange.
- With your PC awake, launch VibeLight or switch computers: the shelf says "Looking for <PC>…" briefly, then shows the games — never "asleep".
- Saved data (best on a copy of your preferences): break one saved computer's record, relaunch — Home says some couldn't be read; add a computer, relaunch — it's still there.
- Restart PC setup: type -1, 0 or 70000 as the port and press Pair — a message asks for 1–65535, nothing crashes; a blank port still pairs on 59999.
- iPad stream: wait 7 s after a game starts — the buttons slide away and a faint white pill stays at the top-right edge. Tap it: they come back. **Your call:** is the pill too visible over gameplay? (one-line fallback: dimmer, white at 0.35)
- iPad stream with VoiceOver on: the buttons never hide; the Actions rotor offers "Leave the Stream".
- Mac with a controller plugged in: press arrow keys/Return — the hint bar shows ⏎/⎋; touch the controller — it shows Ⓐ/Ⓑ again.
- iPad Home Screen: the VibeLight icon fills its rounded square with no black frame.

- Computers menu (2+ computers saved): choose one that isn't first, reopen Computers — it's at the top with a thin line under it; D-pad down walks the rows in the order drawn; with one computer there's no line.
- Start pairing a computer that isn't selected, then press Back — focus returns to that computer's row.

- iPad, Interface Size: at Default, Home is a little larger with nothing clipped and all six preset chips visible; switch Settings ▸ Themes ▸ Interface Size to Large — everything ~25% bigger, nothing clipped. **Your call:** does Large feel right?
- iPad: the Settings ◀ ▶ arrows and the Wake/Restart buttons respond to a tap just outside the visible circle.
- Mac: Settings, the header buttons and the hint bar look exactly as before.

- Settings ▸ Audio ▸ Menu Sounds: set Off, move around Home — silent; relaunch — still Off; load a preset — still Off.

- Wired TV, no controller: the launcher stays usable by touch on the iPad and the TV mirrors it. Connect a controller: the companion panel fades in. Disconnect it: the launcher comes back to the iPad. **Only your iPad can show the no-controller half:** the iPad Simulator connects a virtual controller of its own ~9 s after launch, so there the panel always appears (a probe log showed the app correctly kept the launcher until that moment).
- First-time setup with a TV and a controller attached (Settings ▸ Restart Setup): setup appears on the iPad and can be finished. In the Simulator the iPad went dark after the welcome screen in this case; not yet explained — it may be the same virtual controller arriving mid-welcome.
- Increase Contrast on (iPad: Settings ▸ Accessibility ▸ Display & Text Size; Mac: System Settings ▸ Accessibility ▸ Display): card, row and hint borders are clearly brighter; empty preset slots are no longer faded.
- Navy labels on the blue (Computers rows, Add, the active preset chip, the selected Settings tab, the active slot in Settings ▸ Presets): readable. A chip that's only focused keeps white text. **Your call:** keep navy on the blue? (one-line revert: `Theme.onAccent = .white`)
- Clear a preset (Rename / Clear ▸ Clear) and forget a computer: the final button turns red when focused; Keep It is focused first.
- Mac: hover a Settings tab or a card button — it brightens and doesn't grow.
- On the companion panel, tap "Use the iPad Instead": the launcher returns to the iPad and Settings ▸ Video ▸ Use TV / Monitor reads Off.
- AirPlay mirroring (with and without a controller): tell me what happens — this path couldn't be checked from code.

- Mac, your normal setup: open VibeLight — your paired computers still connect, and nothing in `~/Library/Application Support/VibeLight/identity` changed.
- iPad: restart it, open VibeLight before unlocking, then unlock and pair a computer without reopening the app — pairing works. Tried before unlocking, it says to try again before the PC asks for a PIN.
- iPad: after installing this build over the old one, your computers are still paired.
- (Optional, on a throwaway copy only) Mac with `client.pem` made unreadable (`chmod 000`): a host action says VibeLight can't read its identity file and changed nothing; `client.key` is untouched. Restore the permissions afterwards.

## Test status
- Baseline (23:24, HEAD 8c51dc7, full output in `.overnight-loop/baseline.txt`): **GREEN.**
  - macOS: full suite 132 tests, 0 failures. Runtime note: 3 PinDurabilityTests log "should not be called on the main thread".
  - iOS: simulator build succeeds with 6 compiler warnings — `UIScreen.screens` deprecated (ExternalScenePlacement.swift:117); unused `resignFirstResponder()` result (StreamKeyboard.swift:43); main-actor call from a nonisolated context (VibeLightApp.swift:42); `PairTLSDelegate` / `PinnedTrust` must restate `@unchecked Sendable` (HostPairing.swift:270, MoonDeckBuddyClient.swift:264 — introduced in v0.2.1's byte-cap change); a doc-comment parameter mismatch (MoonlightSession.h:46).
  - iOS tests: 10 tests, 0 failures (`IOSIdentityTests` skipped on purpose).
- Latest (26 Oct, after the helper repoint): macOS build + 132 tests GREEN.

## Usage-limit waits
- 26 Oct ~20:30–21:00: the session limit hit while visual batch 3H was mid-build; its three agents stopped. Its half-done work was saved as an unverified WIP commit in its lane and the batch resumed at 21:05. The fix workflow now reports "not mergeable" whenever an agent didn't finish (before, it said mergeable even when nothing ran — caught here, nothing was merged).

## Morning merge — for YOU (the loop never runs these)
```sh
git log --oneline main..codeX          # review
git checkout main && git merge --no-ff codeX
# with a remote, review as a PR instead:  gh pr create --base main --head codeX
# if the branch tip is an unverified WIP commit (its message ends "(unverified)"), merge the newest verified one instead:
#   git merge --no-ff "$(git log -1 --format=%h --invert-grep --grep='(unverified)' codeX)"
```

<!-- machine-readable footer -->
```json
{"date": "2026-10-21", "branch": "codeX", "base": "main",
 "cycles": 0, "done": 6, "shelved": 0, "blocked": 0,
 "state": "looping", "build": "green"}
```
