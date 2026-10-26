# MasterTasks (MT)

Everything William has asked for, in his words, with where it stands. New requests that arrive while
other work is running go here instead of interrupting it, and nothing leaves this list until it's done.
(Rule, 26 Oct 2026: *"when I tell you stuff, dont stop what you're doing to complete the task if you
cant do it side by side add it to a new .md file in the project file called MasterTasks MT for short and
make sure you get everything finished"*.)

Detail for in-flight work lives in `OVERNIGHT_LOOP_PLAN.md` (the build queue) and
`OVERNIGHT_LOOP_REPORT.md` (progress, live checks, decisions). Security findings are listed by ID only.

**States:** ⏳ Queued · 🔨 In progress · ✅ Done · ⏸ Waiting on you

## Open

| # | Asked | Request (his words) | State | Where it stands |
|---|---|---|---|---|
| MT-8 | 26 Oct | "do everything" (the 13 visual changes the audit suggested) | 🔨 | 7 of 13 merged (stream-controls handle, keyboard hints on Mac, full-bleed iPad icon, iPad text and touch-target sizes + Interface Size, Menu Sounds switch, TV dead end, companion readout removed). Next: accent labels/contrast, destructive red, no hover zoom, empty Home, banner, setup hints. |
| MT-2b | 21 Oct | Fix pass on the audit's findings (part of "run /overnightprotocol") | 🔨 | Fix group 1 merged (saved data never lost, bad values can't crash — 7 findings). Groups 5 (client identity safety) and 7 (updater, move-to-Applications, helper errors) building. Groups 2–4, 6, 8, 9 queued. |
| MT-2 | 21 Oct | "also run /overnightprotocol" | 🔨 | Running on `codeX`; stop with `/overnightprotocol stop`. |
| MT-P1 | 21 Oct | Four new features the audit suggested (not defects) | ⏸ | Not asked for yet: one PC with two addresses, iPad hardware-keyboard launcher navigation, more on-screen-keyboard keys, saved game list at start-up. Say which. |
| MT-P2 | 21 Oct | Old private addresses still in the public git history | ⏸ | Your call: rotate the addresses (recommended) or rewrite public history. |

## Done

| # | Asked | Request (his words) | Done |
|---|---|---|---|
| MT-10 | 26 Oct | "under computers, the last used PC should be at the top with a little bar that seperates it from the other PCS, the last used PC should probably be the current one thats connected/the user is on" | Merged into `codeX`: the computer you're on is first, a thin divider follows, the controller walks the rows in the drawn order, and the menu opens (and returns from pairing) on the right computer. Live check in the loop report. |
| MT-11 | 26 Oct | "dont stop what you're doing … add it to … MasterTasks" | Standing rule; this file. |
| MT-9 | 26 Oct | "are you also looking at this from an /apple-design perspective?" | Yes — the audit's UI review used apple-design; every fix that changes wording or UI now gets an apple-design check in review. |
| MT-7 | 26 Oct | "can you explain the visual changes you'd like to do?" | Explained in chat (13 items, grouped). |
| MT-1 | 21 Oct | "take a look at it with some fresh eyes … running a deep /audit and look for everything, ui, ux, vulnerabilities, literally everything and come back to me" | Audit complete and dry: 0 critical · 0 high · 18 medium · 70 low · 27 suggestion. Report private in `.git/overnight-loop/`; visual breakdown published as a private Artifact. |
| MT-6 | 21 Oct | "do we still need moonlight ios reference, if not move it back into documents" | Not needed (documentation-only); moved back to `~/Documents`. |
| MT-5 | 21 Oct | "say on codex, keep local only, no visual changes for now, yes move these to developer and also can you explain what they do" | Stayed on `codeX`; `AIKnowledge.md` local-only; helper moved to `~/Developer`; both repos explained. (Visual changes later unparked by MT-8.) |
| MT-4 | 21 Oct | "make sure you read the updated global claude.md" / "did you read agent operating manual?" | Read both. |
| MT-3 | 21 Oct | "move the project folder to ~/Developer and make sure git and everything is locked into that new path" | Moved; git, Claude settings, memory and builds verified at the new path. |
