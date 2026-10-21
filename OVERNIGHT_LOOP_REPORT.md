# Overnight Loop Report — 2026-10-21

STATUS: LOOPING · cycle 0 · 1 done · build+tests GREEN · last: kickoff committed — audit running

## Run
- Started: 23:24 · Branch: codeX from main · Ceiling: none (runs until you stop it)
- Commits: `git log --oneline --grep='^loop' main..codeX`

## Questions for you (parked forks and end-of-rope questions — answer any to unpark)
- ❓ Visual / design changes from the audit — build them, or keep them parked? — options: build after you review | keep parked — parked item: "Visual / design changes" (you said "no visual changes for now")

## Recommendations (things the loop chose not to do unattended)
- 💡 The helper repo tracks a generated build file, `app/Makefile.Debug`, that has your full home-folder path in it and is public on GitHub — why: it leaks the machine path and goes stale on every rebuild — how: in ~/Developer/vibelight-moonlight-helper, `git rm --cached app/Makefile.Debug`, add `app/Makefile.*` to .gitignore, commit, push. Not done unattended: it's another repo's `master`.
- 💡 Stale Xcode build cache for the old ~/Documents path (588 MB, `~/Library/Developer/Xcode/DerivedData/VibeLight-gbkjmozetujwozebxnxfvkmtocuj`) — why: nothing uses it any more — how: delete it from Xcode ▸ Settings ▸ Locations, or Finder. Not done unattended: it's your disk.
- 💡 `_dump/` inside the repo (231 MB, 5,141 files, gitignored) holds iCloud sync-conflict copies such as `VibeLight 2.xcodeproj` — why: the repo is out of iCloud now, so they should stop appearing — how: look through it once, then delete it. Not done unattended: it might hold something you meant to keep.
- 💡 Claude's old memory folder for the previous path (`~/.claude/projects/-Users-william-Documents-VibeLight/`) — why: its 10 notes were copied to the new path and verified identical — how: delete it whenever you like.

## Progress log (last 20; older lines roll into the tally)
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
- Total: 1 · recent: ✅ Stray `f` removed from FocusEngineTests.swift — 1m

## Blocked (environment)
- (none)

## Skipped / shelved
- (none)

## Excluded from commits (secret-shaped or too big — commit them yourself if they're fine)
- `AIKnowledge.md` — kept on this Mac only at your request (it describes the September audit's findings in detail). Excluded via `.git/info/exclude`.

## Decisions & assumptions (last 20 + tally)
- Stayed on `codeX` (you, kickoff). It equalled v0.2.1 plus uncommitted notes; it gets pushed to GitHub as a new branch.
- `AIKnowledge.md` local-only (you); the 5-line pointer to it in `CLAUDE.md` is committed — it works for agents on this Mac and is a dead link on GitHub.
- No visual changes tonight (you): bugs, accessibility labels, keyboard/controller dead ends and wording only; anything that changes how a screen looks gets parked with a plan.
- Moved the sibling repos (you). No stop time (default).
- The audit runs read-only on the main checkout instead of a separate worktree, and the loop makes no source edits until it lands — so every file:line in the report stays valid.
- Routine iOS test runs skip `IOSIdentityTests`: the September audit found they overwrite the simulator app's real pairing identity (that's finding DAT-simulator-identity-reset-f95217a7).
- ~/Documents is iCloud-synced — that's almost certainly where the `AppState 2.swift` / `Info 2.plist` duplicates CLAUDE.md warns about came from (sync-conflict copies). Moving out of iCloud should end them.

## Test status
- Baseline (23:24, HEAD 8c51dc7, full output in `.overnight-loop/baseline.txt`): **GREEN.**
  - macOS: full suite 132 tests, 0 failures. Runtime note: 3 PinDurabilityTests log "should not be called on the main thread".
  - iOS: simulator build succeeds with 6 compiler warnings — `UIScreen.screens` deprecated (ExternalScenePlacement.swift:117); unused `resignFirstResponder()` result (StreamKeyboard.swift:43); main-actor call from a nonisolated context (VibeLightApp.swift:42); `PairTLSDelegate` / `PinnedTrust` must restate `@unchecked Sendable` (HostPairing.swift:270, MoonDeckBuddyClient.swift:264 — introduced in v0.2.1's byte-cap change); a doc-comment parameter mismatch (MoonlightSession.h:46).
  - iOS tests: 10 tests, 0 failures (`IOSIdentityTests` skipped on purpose).
- Latest: same as baseline.

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
 "cycles": 0, "done": 1, "shelved": 0, "blocked": 0,
 "state": "looping", "build": "green"}
```
