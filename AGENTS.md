# AGENTS.md

**The project instructions live in [`CLAUDE.md`](CLAUDE.md). Read that file.**

It is the single source of truth for this repo: build commands, architecture, the
load-bearing invariants, and the ship/release process. This file exists only so
agents that look for `AGENTS.md` by convention find their way there.

This used to be a byte-for-byte copy of `CLAUDE.md`, which went wrong the way
duplicated docs always do — the copy drifted, and the single line it drifted on
was the one telling agents where to put real network addresses.  One file means
nothing to drift.

## The one rule worth repeating here

Real host addresses, hostnames, and Wake-on-LAN MACs go in **`CLAUDE.local.md`**
and nowhere else. **This repo is public.** `.gitignore` covers `*.local.md`, so a
tool-specific variant is safe too — but prefer `CLAUDE.local.md`: one file, one
place to look.

Install the topology guard once per clone, so a slip is caught before it becomes
permanent public history:

```bash
git config core.hooksPath scripts/git-hooks
```
