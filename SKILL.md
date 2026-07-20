---
name: mac-perf-profiler
version: 1.0.0
description: Diagnose why a Mac (esp. Apple Silicon) is slow — profile CPU, memory/swap, stuck processes, macOS background tasks, jetsam kills, thermal throttling, and dev-tooling leftovers (orphaned dev servers, watchman leaks, worktree bloat, headless browsers). Use when the user says their Mac is slow, laggy, beachballing, hot, or fans are spinning, or asks to profile/diagnose system performance.
requires:
  os: ["darwin"]
---

# Mac performance profiler

Diagnose a slow macOS machine and recommend safe, targeted fixes. Built for
Apple Silicon dev machines where the usual culprit is **memory overcommit**, not
a single runaway process.

## The one mental model that matters

On a modern Mac the slowdown is almost always **memory pressure → swap
thrashing**, and most of the scary numbers are *symptoms*, not causes:

- **High `sys` CPU % with normal `user` %** → the kernel is busy
  compressing/paging memory. `kernel_task` at 150%+ is the kernel doing this
  work. It is a symptom. Do **not** try to kill or throttle `kernel_task`.
- **Load average ≫ core count** → the run queue is backed up, usually because
  processes are blocked waiting for pages to swap back in from disk.
- **Many "stuck" (uninterruptible-wait, `U`) processes** → usually transient
  page-in waits, not a hung disk. The tell: the stuck set *changes* between
  samples. A *stable* set stuck on the same resource points at a hung
  network/FUSE mount instead.
- **The actual cause** is whatever *holds the memory*: a fleet of Electron apps,
  browsers with hundreds of tabs, IDEs (Cursor/VS Code), and orphaned dev
  servers whose combined footprint is 2–3× physical RAM.

So: **find who holds the memory, free it, then reboot to drain swap.** Chasing
the high-CPU process is usually a dead end.

## How to run

Run the read-only collector — no sudo, no kills, no config changes, safe even on
a thrashing machine:

```bash
bash "$SKILL_DIR/scripts/collect.sh"        # full report (~6s live paging sample)
bash "$SKILL_DIR/scripts/collect.sh" --fast # skip the paging sample
```

(`$SKILL_DIR` is this skill's directory. On a badly overloaded machine each
section can be slow — `system_profiler`, `lsof`, and `top -l 2` all take a few
seconds under load. Let it finish; it is not hung.)

Read the report **top to bottom**, but jump to **QUICK VERDICT** at the bottom
first — it classifies the situation (active thrashing / memory critical / tight
/ OK) from live swapout rate and swap fullness.

## How to read the report

| Section | What you're looking for |
|---|---|
| LOAD / CPU / MEMORY | `sys` % high + low `idle` = paging load. `PhysMem ... unused` near 0 = RAM exhausted. |
| SWAP | `used` near `total` = swap full. Many swapfiles = kernel kept growing it. |
| LIVE PAGING RATE | Nonzero **swapouts** every few seconds = actively thrashing *right now*. |
| MEMORY BY APP FAMILY | The money shot: which app family holds the most memory. Attack biggest-first. |
| TOP BY MEMORY FOOTPRINT | `top` MEM includes compressed pages — catches processes swapped out (tiny RSS, huge footprint). |
| TOP BY CPU | Only meaningful once memory is ruled out. `WindowServer`/`fseventsd` high = window/file churn. |
| STUCK PROCESSES | Changing set = memory symptom. Stable set on one resource = hung mount. |
| MOUNTS | Any `smbfs`/`nfs`/`fuse` present + stuck procs = investigate that mount. |
| macOS BACKGROUND TASKS | Rule in/out Spotlight (`mds`), Time Machine (`backupd`), photo analysis. Check accumulated CPU-time, not instantaneous %. |
| JETSAM / CRASHES | `JetsamEvent*` reports = kernel killed procs for RAM. Repeated = chronic exhaustion (strong evidence). |
| THERMAL / POWER | `CPU_Speed_Limit < 100` = thermal throttling (dust, hot environment, blocked vents). |
| DEV LEFTOVERS | Orphaned `next`/`vite` dev servers, leaked `watchman`, headless/puppeteer Chrome, high node count, repos with many worktrees. |

## Remediation playbook (safe order)

Never `sudo`, never mass-kill blindly. Free memory **biggest-first** from the
app-family table, checking each before acting:

1. **Orphaned dev servers** (`next-server`, `vite`) with 0% CPU but GB of
   footprint — pure waste. Confirm nobody's using the port
   (`lsof -iTCP:PORT -sTCP:LISTEN`), then `kill <pid>`. Prefer Ctrl+C in their
   terminal, or kill the `next dev` wrapper so the whole tree dies.
2. **Automation leftovers** — headless "agent" Chrome and puppeteer "Chrome for
   Testing" from finished test/agent runs: `pkill -f 'Chrome for Testing'`,
   `pkill -f 'agent-browser-chrome'`. Verify no test run is live first.
3. **watchman leak** (large footprint, tiny RSS, long uptime):
   `watchman watch-del-all && watchman shutdown-server`. It restarts on demand.
   First re-crawl after is slow — expected.
4. **IDE** (Cursor / VS Code) holding many GB across dozens of helpers:
   `Cmd+Shift+P → Developer: Restart Extension Host` (soft), or quit the app.
   If quit hangs on a thrashing machine, `kill -TERM` then, only if needed,
   `pkill -9 -f '/Applications/<App>.app'`. **Save work first** — hot-exit
   usually restores buffers, but not guaranteed under heavy thrash.
5. **Browsers / Electron** — close unused windows/tabs; enable tab memory saver.
6. **Reboot** once the heavy holders are freed. Swap files (which can grow to
   20+ GB) do **not** shrink until reboot, and stuck processes won't fully clear
   otherwise. Never delete `/System/Volumes/VM/swapfile*` by hand — that panics
   the kernel.

**Do NOT touch:** `kernel_task`, the swap files, or any Apple system daemon.
They normalize on their own once memory is free.

## Dev-machine root-cause fixes (stop it recurring)

The chronic version of this on an agent-heavy dev box is **git-worktree bloat**
plus **file watchers indexing them**:

- Editors re-index every nested repo. In an IDE with a GitLab/GitLens-style
  extension, dozens of agent worktrees (`.claude/worktrees/*`, `.codex/worktrees/*`)
  can each be indexed as a separate repo, pinning the extension host at 100%+ CPU
  and multiple GB. Exclude them globally (VS Code / Cursor `settings.json`):

  ```json
  "files.watcherExclude": {
    "**/.claude/worktrees/**": true,
    "**/.codex/worktrees/**": true
  },
  "search.exclude": {
    "**/.claude/worktrees": true,
    "**/.codex/worktrees": true
  },
  "git.autoRepositoryDetection": "openEditors"
  ```

- Periodically prune stale worktrees. For each repo:
  `git worktree list`, check `git status` in each (agents may leave uncommitted
  work — branches/commits survive removal, only the working copy is deleted),
  then `git worktree remove <path>` for the clean/idle ones and
  `git worktree prune`. Skip any that are `locked` or were touched in the last
  hour (likely an active agent).

- Kill `next dev` / `vite` when an agent task finishes — don't leave dozens
  running across worktrees.

- Add `.watchmanconfig` `ignore_dirs` for `node_modules`, `.next`, build output
  so watchman's footprint doesn't balloon.

- Honest hardware note: an IDE + AI agents + 3 browsers + Figma + several dev
  servers does not fit in 16 GB. Either cap concurrency or move to 32 GB+.
