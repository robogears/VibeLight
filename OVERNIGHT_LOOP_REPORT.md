# Overnight Loop Report — 2026-10-21

**TL;DR — stopped by you on 26 Oct.** VibeLight moved out of iCloud into ~/Developer along with its stream helper; the test build that a stray character had broken compiles again; the deep audit is written (0 critical, 0 high, 18 medium, 70 low, 27 suggestion — private report inside `.git/overnight-loop/`). The fix pass had not started: nine fix groups are queued in `OVERNIGHT_LOOP_PLAN.md`. Not finished: the audit's last sweep and its visual page. Build and all 132 Mac tests green; nothing merged to main, nothing released.

STATUS: LOOPING · cycle 0 · 6 done · build+tests GREEN (177 Mac; 1 unidentified intermittent failure, not reproduced) · last: TV dead end fixed

## Run
- Started: 23:24 · Branch: codeX from main · Ceiling: none (runs until you stop it)
- Commits: `git log --oneline --grep='^loop' main..codeX`

## Questions for you (parked forks and end-of-rope questions — answer any to unpark)
- ❓ Visual / design changes from the audit — build them, or keep them parked? — options: build after you review | keep parked — parked item: "Visual / design changes" (you said "no visual changes for now")

## Recommendations (things the loop chose not to do unattended)
- 💡 Leftover (Low) — on a landscape iPhone or a Mac window under ~860 pt tall, Interface Size ▸ Large can't make anything bigger, and the row doesn't say so. iPhone really needs a compact Home layout (the design lead's recommendation), which is a bigger design job.
- 💡 Leftover (Low) — the stream controls only notice AssistiveTouch being switched on at their next redraw (SwiftUI can't observe it); VoiceOver and Switch Control are noticed immediately. Fix later with a UIAccessibility notification observer.
- 💡 Leftover (Low) — the keyboard-hint fix has a unit test for its rule but no test pinning the wiring that tags keyboard vs controller input; a future edit could quietly undo it.
- 💡 The helper repo tracks a generated build file, `app/Makefile.Debug`, that has your full home-folder path in it and is public on GitHub — why: it leaks the machine path, and since the move it points at the OLD location, so the helper's next `make` needs a fresh `qmake moonlight-qt.pro` first — how: in ~/Developer/vibelight-moonlight-helper, `git rm --cached app/Makefile.Debug`, add `app/Makefile.*` to .gitignore, commit, push. Not done unattended: it's another repo's `master`.
- 💡 Stale Xcode build cache for the old ~/Documents path (588 MB, `~/Library/Developer/Xcode/DerivedData/VibeLight-gbkjmozetujwozebxnxfvkmtocuj`) — why: nothing uses it any more — how: delete it from Xcode ▸ Settings ▸ Locations, or Finder. Not done unattended: it's your disk.
- 💡 `_dump/` inside the repo (231 MB, 5,141 files, gitignored) is the quarantine from an earlier cleanup pass (sync-conflict copies such as `VibeLight 2.xcodeproj`); `_dump/undo.sh` restores everything — why: the repo is out of iCloud now, so these should stop appearing — how: once you're happy nothing is missing, delete `_dump/`. Not done unattended: it's your quarantine.
- 💡 Seven iCloud conflict copies of git's own index file sit in `.git/` (`index 2` … `index 8`) — why: harmless leftovers from when the repo lived in iCloud, but they're junk inside git's folder — how: `rm ".git/index "[2-8]` once you've seen this.
- 💡 Claude's old memory folder for the previous path (`~/.claude/projects/-Users-william-Documents-VibeLight/`) — why: its 10 notes were copied to the new path and verified identical — how: delete it whenever you like.

## Progress log (last 20; older lines roll into the tally)
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

- Wired TV, no controller: the launcher stays usable by touch on the iPad and the TV mirrors it. Connect a controller: the companion panel fades in. Disconnect it: the launcher comes back to the iPad.
- On the companion panel, tap "Use the iPad Instead": the launcher returns to the iPad and Settings ▸ Video ▸ Use TV / Monitor reads Off.
- AirPlay mirroring (with and without a controller): tell me what happens — this path couldn't be checked from code.

## Test status
- Baseline (23:24, HEAD 8c51dc7, full output in `.overnight-loop/baseline.txt`): **GREEN.**
  - macOS: full suite 132 tests, 0 failures. Runtime note: 3 PinDurabilityTests log "should not be called on the main thread".
  - iOS: simulator build succeeds with 6 compiler warnings — `UIScreen.screens` deprecated (ExternalScenePlacement.swift:117); unused `resignFirstResponder()` result (StreamKeyboard.swift:43); main-actor call from a nonisolated context (VibeLightApp.swift:42); `PairTLSDelegate` / `PinnedTrust` must restate `@unchecked Sendable` (HostPairing.swift:270, MoonDeckBuddyClient.swift:264 — introduced in v0.2.1's byte-cap change); a doc-comment parameter mismatch (MoonlightSession.h:46).
  - iOS tests: 10 tests, 0 failures (`IOSIdentityTests` skipped on purpose).
- Latest (26 Oct, after the helper repoint): macOS build + 132 tests GREEN.

## Usage-limit waits
- (none)

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
