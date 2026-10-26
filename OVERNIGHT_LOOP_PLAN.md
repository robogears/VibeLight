# Overnight Loop Plan — 2026-10-21

<!-- run metadata — recovery reads this first; update it at the end of every turn -->
STATE: STOPPED             # stopped by the owner, 26 Oct 2026
PROJECT_PATH: ~/Developer/VibeLight
SKILL_PATH: ~/.claude/skills/overnightprotocol/SKILL.md
START_EPOCH: 1792610686
LAST_TURN_EPOCH: 1793004200
CEILING_EPOCH: none
BASE_BRANCH: main
BRANCH: codeX
RUNG: mission               # mission | 1-qa | 2-audit | 3-qol
CYCLE: 0                    # completed ladder cycles
LAST_AUDIT: none            # set when item 1 lands: <epoch> 8c51dc7
DENY_RULES: added by scripts/deny-rules.sh — record in <git-dir>/overnight-loop/ (private)
KEEP_AWAKE: caffeinate -dis via scripts/keep-awake.sh — pid record in <git-dir>/overnight-loop/ (private); re-checked every turn, stopped at wrap-up
TICK_PROMPT: Overnight loop tick for `~/Developer/VibeLight`. You are mid-run: skip Phase 0. Follow the overnightprotocol turn contract — if its instructions are not in your context, first read `~/.claude/skills/overnightprotocol/SKILL.md`. Continue from the plan: resume the `[~]` item, else the top open item, else the ladder rung in the plan header. End the turn with ScheduleWakeup using this same prompt. Only /overnightprotocol stop from the user, or the plan's CEILING, ends the loop.
EVERY TURN: re-read this header + open items → handle user messages → check the ceiling → work → update this header → ScheduleWakeup(TICK_PROMPT)
STOP: the user runs /overnightprotocol stop (or presses the Stop button)

<!-- Standing rules for this run (owner, 21 Oct 2026):
     - Global ~/.claude/CLAUDE.md + AGENT_OPERATING_MANUAL.md apply. Versioning: GitHub has v0.2.1 → the
       first real change bumps MARKETING_VERSION to 0.2.2 in project.yml (2 places), then HOLD. Never release.
     - "no visual changes for now": no layout/colour/motion changes — design findings get PARKED with a plan.
       Accessibility labels, keyboard/controller dead ends, wording and bugs are in scope.
     - AIKnowledge.md stays local-only (excluded via .git/info/exclude). Never commit it.
     - Audit reports stay in <git-dir>/overnight-loop/ (private). Committed files carry finding IDs + one-line
       titles only — no exploit detail, no real IPs/MACs/hostnames (those live only in CLAUDE.local.md).
     - Manual §5.2: every Medium+ finding gets its own skeptic before it is fixed. -->

## Mission (official items — do these first)
- [x] 0. Remove the stray `f` at VibeLightTests/FocusEngineTests.swift:62 that stopped the test target compiling (baseline QUA-focus-test-typo-d5283e8d) — 1m. Restored the committed file exactly; no diff to commit.
- [x] 1. Deep /audit, FULL scope — 70m. Report written privately (<git-dir>/overnight-loop/audit-2026-10-21/AUDIT-REPORT-2026-10-26.md): 0 critical · 0 high · 18 medium · 70 low · 27 suggestion; 1 fixed since 9 Sep, 4 refuted, 2 unsettled; all 26 September findings re-checked. NOT finished: sweep 4 (the audit is not yet shown dry) and the visual page — both stopped with the loop.
- [x] 2. Move the helper repo to ~/Developer and explain the sibling repos — 14m. Helper moved (HEAD, 1,810 files, fsck identical); `scripts/embed-helper.sh` and `scripts/ios/build-deps.sh` now find it beside the repo (`$ROOT/../vibelight-moonlight-helper`, override with `VIBELIGHT_HELPER_DIR`) instead of a hard-coded path; Swift dev-build fallback, CLAUDE.md and the iOS plan doc updated; temporary link removed; macOS build green. `moonlight-ios-reference` stays in ~/Documents (documentation-only, owner's call).
- [ ] 3. Fix pass on the audit's verified findings — done when: every Safe finding is fixed (with a test where testable) and committed as `loop: audit-fix — <ID>`; Needs-verification findings get their non-drastic version plus a Recommendation; design/visual findings are PARKED, not built; MARKETING_VERSION is 0.2.2. NOT STARTED: fix group 1 was launched and stopped within minutes with no changes made; its working copy was removed.
<!-- open = [ ] or [~]; resume [~] first
     [~] N. <item> — STARTED <epoch> · attempt <n> · approach: <one line> · active: <m>m · wip: <hash|none> [· delegated: <task/run id> · <worktree/branch>] [· interrupted]
     [x] N. <item> — <active>m
     [>] N. <item> — <reason> · shelved: overnight-loop/shelved/<slug>
     [!] N. <item> — blocked by <reason> (morning command in the report) -->

## Ladder backlog (self-generated when the mission is exhausted)
<!-- Fix-pass groups from the 26 Oct audit. IDs + one-line titles only — the full report stays private in <git-dir>/overnight-loop/.
     Security-related items are named by area, not by how they could be misused. -->
- [ ] G1. Saved data never lost, bad values can't crash — DAT-added-hosts-latch-forever-65fb270f, DAT-buddy-config-latch-silent-70e69eae, DAT-preset-recovery-loss-f4edc9a4, DAT-settings-reset-overwrites-original-a64bff9c, DAT-stored-size-overflow-a8df08bd, NET-negative-buddy-port-eb2859c2, QUA-fps-offgrid-jump-eeb0f080 — done when: unreadable saved entries survive every save, new changes persist, stored out-of-range values are clamped, tests prove each (fail without the fix)
- [ ] G2. Pairing trust hardening — NET-unpinned-host-full-use-48acc13a, ERR-pairing-error-category-797eda5b, DAT-host-uuid-spoofs-synthetic-id-a209fe14, NET-buddy-pin-auto-dropped-490cdb57 — done when: an unpaired computer can only be asked whether it is paired; Forget also unpairs on the PC (best effort); pairing errors are labelled correctly
- [ ] G3. Stream start/stop lifecycle — NET-wrong-game-resume-1203de39, LIF-stale-launch-restart-3aa8d709, LIF-quit-cancels-kept-game-950096d0, LIF-ios-background-quit-stuck-ending-b572b510, LIF-stale-session-callback-after-quit-32c8351a, ERR-silent-ios-quit-78297871, NET-stale-switch-snapshot-3c07c421, ERR-stale-host-error-7eadedb4, QUA-stream-end-flag-ignored-57e6197a — done when: switching games starts the chosen game, leaving/quitting cancels in-flight launches, stale results are ignored (non-drastic where device-only; live checks written)
- [ ] G4. Keyboard and controller dead ends — QUA-keyboard-settings-tabs-553f2493, QUA-address-field-focus-27c153bd, QOL-controller-forget-computer-803c44b7, QUA-cmd-comma-repeat-toggles-settings-b9ce3c71, QUA-controller-pointer-mode-93ddc141, QUA-armed-destructive-confirms-d3559964, QUA-moondeck-cancel-becomes-restart-d0cf101d, QUA-touch-quit-hold-refires-7b5b2cc4, QUA-quit-app-hint-hides-hold-8f8a23ba, QUA-onboarding-back-hold-swallowed-34f18427, QUA-home-focus-lands-on-restart-67703195, QOL-select-toggles-row-3c32bb98, QUA-host-select-stale-id-89b0a9ab, LIF-held-input-survives-deactivation-446acd5f
- [ ] G5. Client identity safety — FS-identity-read-loss-02d74004, ERR-ios-pairing-empty-cert-snapshot-e0df9a96, DAT-simulator-identity-reset-f95217a7, QUA-ios-unavailable-test-cannot-fail-b2014ba1
- [ ] G6. iPad/iPhone platform behaviour — UX-stream-edge-gestures-not-deferred-d26c4e8b, LIF-menu-sfx-audio-category-leak-69eba787, LIF-menu-sfx-engine-never-paused-a1e4245d, LIF-stream-keys-stuck-after-keyboard-loss-2feb…, LIF-companion-pre-dimmed-on-midstream-tv-9f1fe…, LIF-keyboard-survives-tv-attach-and-dim-375283…, QUA-hardware-keyboard-double-typing-1cb2a137, the two sweep-3 iPad keyboard items
- [ ] G7. Updater, relocator and helper errors — FS-update-rollback-opens-self-deleting-copy, FS-update-swap-unchecked-stage-ca635165, FS-relocate-replaces-newer-copy-ec5b9509, ERR-helper-failure-reason-dropped-0fc3262c, QUA-launch-update-card-no-stream-gate-a643370b, LIF-display-sleep-held-hidden-39bea787
- [ ] G8. Wording that says what happened and how to fix it — UX-launch-errors-no-fix-85c90989, UX-stream-fail-stage-jargon-af8468b9, UX-companion-trackpad-copy-1ad3c20c, UX-shortcuts-sheet-wrong-inputs-d03e44bf, UX-ended-card-quit-default-b84d536f, ERR-timeout-hides-wake-10d93881, QOL-accessible-custom-controls-75a1f6e6 (VoiceOver labels only), QOL-respect-reduce-motion-fcc0da28 (only when Reduce Motion is on)
- [ ] G9. Docs, privacy guards and test quality — README fixes (3), CLAUDE.md pointer, .gitignore patterns, pre-commit/commit-msg guard gaps (2), install-script message, test-quality items (4), stale comments and dead import code, swift-crypto patch pin

## Parked — needs direction (never build these on a guess)
- ⏸ Visual / design changes the audit recommends — question: build them, or keep parked? — options: build after you review the design findings | keep parked — unlocks: UX-ios-scale-shrinks-text-targets-8462e247, UX-tv-attached-touch-dead-end-72aad067, UX-stream-controls-hidden-reveal-cb058b27, UX-white-on-accent-contrast-af29f979, UX-destructive-styling-inconsistent-6cda93bb, UX-hover-zoom-settings-tabs-f4c267b0, UX-host-banner-truncates-7b235bc6, UX-empty-home-no-invitation-7607e663, UX-companion-geometry-readout-ed0a4d5c, UX-onboarding-hints-generic-glyphs-128fcac0, QOL-keyboard-hints-show-pad-glyphs-4222cb10, UX-menu-sounds-no-toggle-d3cf475c, QOL-ios-icon-transparent-margin-f607c51f (owner, 21 Oct: "no visual changes for now")
- ⏸ New features the audit suggested (not defects) — question: which, if any? — unlocks: one PC with two addresses, iPad hardware-keyboard launcher navigation, more on-screen-keyboard keys, cached shelf at start-up
- ⏸ Old private network details in the public git history (SEC-historical-network-details-5a96ebca) — question: rotate the addresses (recommended) or rewrite public history? — unlocks: closing that finding
