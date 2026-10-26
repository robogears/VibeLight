# Overnight Loop Plan — 2026-10-21

<!-- run metadata — recovery reads this first; update it at the end of every turn -->
STATE: LOOPING              # LOOPING | PAUSED (<why>) | STOPPED
PROJECT_PATH: ~/Developer/VibeLight
SKILL_PATH: ~/.claude/skills/overnightprotocol/SKILL.md
START_EPOCH: 1792610686
LAST_TURN_EPOCH: 1792614105
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
- [~] 1. Deep /audit, FULL scope ("look for everything, ui, ux, vulnerabilities, literally everything") — done when: Markdown report saved privately in <git-dir>/overnight-loop/audit-2026-10-21/, the visual breakdown published as a private Artifact, provenance + summary + findings index posted in chat, and every finding tagged New / Still-open / Fixed / Refuted against the 9 Sep baseline — STARTED 1792610300 · attempt 1 · approach: read-only workflow on the main checkout · active: 40m · wip: none · sweeps 1–2 done (120 items, all skeptic-verified); a reboot wiped the result file, rebuilt from the run journal; sweep 3 (3 finders lost to a usage limit) re-running as workflow wf_62d43d85-b4e; visual page being designed by a background agent
- [x] 2. Move the helper repo to ~/Developer and explain the sibling repos — 14m. Helper moved (HEAD, 1,810 files, fsck identical); `scripts/embed-helper.sh` and `scripts/ios/build-deps.sh` now find it beside the repo (`$ROOT/../vibelight-moonlight-helper`, override with `VIBELIGHT_HELPER_DIR`) instead of a hard-coded path; Swift dev-build fallback, CLAUDE.md and the iOS plan doc updated; temporary link removed; macOS build green. `moonlight-ios-reference` stays in ~/Documents (documentation-only, owner's call).
- [ ] 3. Fix pass on the audit's verified findings — done when: every Safe finding is fixed (with a test where testable) and committed as `loop: audit-fix — <ID>`; Needs-verification findings get their non-drastic version plus a Recommendation; design/visual findings are PARKED, not built; MARKETING_VERSION is 0.2.2.
<!-- open = [ ] or [~]; resume [~] first
     [~] N. <item> — STARTED <epoch> · attempt <n> · approach: <one line> · active: <m>m · wip: <hash|none> [· delegated: <task/run id> · <worktree/branch>] [· interrupted]
     [x] N. <item> — <active>m
     [>] N. <item> — <reason> · shelved: overnight-loop/shelved/<slug>
     [!] N. <item> — blocked by <reason> (morning command in the report) -->

## Ladder backlog (self-generated when the mission is exhausted)
<!-- audit finding IDs + one-line titles land here when item 1 completes -->

## Parked — needs direction (never build these on a guess)
- ⏸ Visual / design changes the audit recommends — question: build them, or keep parked? — options: build after you review the design findings | keep parked — unlocks: the UX-category fixes that change how a screen looks (owner, 21 Oct: "no visual changes for now")
