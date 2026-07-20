# mac-perf-profiler

A read-only diagnostics skill for figuring out **why a Mac is slow** — built for
Apple Silicon dev machines where the usual culprit is memory overcommit and swap
thrashing, not a single runaway process.

It ships as a [Claude Code](https://claude.com/claude-code) skill (`SKILL.md`)
plus a standalone collector script you can also run by hand.

## What it checks

- CPU / load / memory pressure (with the "is high `sys` just paging?" read)
- Swap fullness + **live swapout rate** (the real thrashing tell)
- Memory aggregated **by app family** (Cursor, Chrome, Arc, Figma, node, …)
- Top processes by memory footprint (incl. compressed) and by CPU
- Stuck (uninterruptible-wait) processes and whether a hung mount explains them
- macOS background tasks (Spotlight, Time Machine, iCloud, media analysis)
- Jetsam memory-kill events and recent crash reports
- Thermal throttling and power state
- Third-party launch agents/daemons
- Dev-tooling leftovers: orphaned dev servers, watchman leaks, headless/puppeteer
  browsers, node process count, git-worktree bloat

Every check only **reads** state — no `sudo`, no process kills, no config
changes, no deletes. Safe to run on a machine that's already thrashing.

## Install

Via the [skills](https://www.skills.sh/) CLI ([vercel-labs/skills](https://github.com/vercel-labs/skills)):

```bash
npx skills add kr4chinin/mac-perf-profiler        # into ./.claude/skills (project)
npx skills add -g kr4chinin/mac-perf-profiler     # into ~/.claude/skills (global)
```

Or manually — copy `skills/mac-perf-profiler/` into `~/.claude/skills/` (global)
or a project's `.claude/skills/`. Claude invokes it automatically when you say
things like "my Mac is slow" or "profile my system performance".

## Usage

The skill drives itself, but you can also run the collector by hand:

```bash
bash skills/mac-perf-profiler/scripts/collect.sh          # full report (~6s live paging sample)
bash skills/mac-perf-profiler/scripts/collect.sh --fast   # skip the live paging sample
```

Read the report top-to-bottom; the **QUICK VERDICT** at the end classifies the
situation and points at the fix. `SKILL.md` has the interpretation guide and a
safe remediation playbook.

## Repository layout

```
skills/
└── mac-perf-profiler/
    ├── SKILL.md               # the skill: mental model, interpretation, playbook
    └── scripts/collect.sh     # read-only diagnostics collector
```

This `skills/<name>/SKILL.md` layout is what the `skills` CLI discovers.

## License

MIT
