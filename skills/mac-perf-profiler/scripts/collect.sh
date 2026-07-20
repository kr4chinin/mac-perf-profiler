#!/usr/bin/env bash
# mac-perf-profiler — read-only macOS slowdown diagnostics collector.
#
# SAFE BY DESIGN: no sudo, no process kills, no config changes, no file deletes.
# Everything here only *reads* system state, so it is safe to run even on a
# machine that is already thrashing. Output is one plain-text report to stdout.
#
# Usage:
#   bash collect.sh            # full report (takes ~6s for the live paging sample)
#   bash collect.sh --fast     # skip the 3s live-paging sample
#
# The report is organized so both a human and an AI agent can read top-to-bottom.
# The QUICK VERDICT at the very end summarizes whether this is memory thrashing.

set -uo pipefail
export LC_ALL=C

FAST=0
[ "${1:-}" = "--fast" ] && FAST=1

section() { printf '\n\n========== %s ==========\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Capture the live paging delta FIRST (used by the verdict at the end).
# vm_stat with an interval prints: line1 banner, line2 headers,
# line3 = cumulative-since-boot, line4 = delta over the interval.
# Pages are 16 KiB on Apple Silicon. Large counts get a trailing 'K'.
# ---------------------------------------------------------------------------
SWAPOUT_DELTA=""; SWAPIN_DELTA=""; PAGING_RAW=""
if [ "$FAST" -eq 0 ]; then
  # `head -4` MUST bound this: `vm_stat <interval>` prints forever, so head
  # reads the 4 lines it needs (banner, headers, cumulative, first delta) and
  # exits, SIGPIPE-ing vm_stat. Lines 3/4 = cumulative / interval-delta.
  PAGING_FULL="$(vm_stat 3 2>/dev/null | head -4)"
  PAGING_RAW="$(printf '%s\n' "$PAGING_FULL" | sed -n '2,4p')"
  SWAPIN_DELTA="$(printf '%s\n'  "$PAGING_FULL" | awk 'NR==4{v=$21; sub(/K$/,"000",v); print v+0}')"
  SWAPOUT_DELTA="$(printf '%s\n' "$PAGING_FULL" | awk 'NR==4{v=$22; sub(/K$/,"000",v); print v+0}')"
fi

section "SYSTEM"
system_profiler SPHardwareDataType 2>/dev/null \
  | grep -E "Model (Name|Identifier)|Chip|Total Number of Cores|Memory:"
sw_vers 2>/dev/null
uptime

section "LOAD / CPU / MEMORY  (top 2nd sample = accurate)"
# Load avg > core count means the run queue is backed up. On Apple Silicon a
# high 'sys' % with a normal 'user' % almost always means the kernel is busy
# paging/compressing memory — a SYMPTOM of overcommit, not a rogue process.
top -l 2 -n 0 2>/dev/null | grep -E 'Load Avg|CPU usage|PhysMem|VM:' | tail -4

section "SWAP"
sysctl vm.swapusage 2>/dev/null
printf 'swap files on /System/Volumes/VM: %s\n' \
  "$(ls /System/Volumes/VM/ 2>/dev/null | grep -c swapfile)"
memory_pressure 2>/dev/null | tail -3

if [ "$FAST" -eq 0 ]; then
  section "LIVE PAGING RATE  (delta over 3s — the thrashing tell)"
  echo "$PAGING_RAW"
  echo
  echo "  swapins Δ/3s : ${SWAPIN_DELTA:-?} pages  (~$(( ${SWAPIN_DELTA:-0} * 16 / 1024 )) MB)"
  echo "  swapouts Δ/3s: ${SWAPOUT_DELTA:-?} pages  (~$(( ${SWAPOUT_DELTA:-0} * 16 / 1024 )) MB)"
  echo "  Nonzero swapouts every few seconds = the machine is actively thrashing."
fi

section "MEMORY BY APP FAMILY  (resident RSS; undercounts compressed/swapped pages)"
# Aggregates processes into app families. RSS undercounts because a process
# that is mostly swapped shows a tiny RSS but a large footprint — cross-check
# the 'TOP BY MEMORY FOOTPRINT' section (top MEM includes compressed pages).
ps -axo rss,comm 2>/dev/null | awk '
  NR>1 {
    rss=$1; $1=""; n=$0
    if      (n ~ /[Cc]ursor/)                       f="Cursor"
    else if (n ~ /Chrome for Testing/)              f="Chrome-for-Testing(puppeteer)"
    else if (n ~ /agent-browser-chrome/)            f="headless-agent-Chrome"
    else if (n ~ /Google Chrome/)                   f="Chrome"
    else if (n ~ /Arc\.app|ArcCore|Browser Helper/) f="Arc"
    else if (n ~ /Figma/)                           f="Figma"
    else if (n ~ /Slack/)                           f="Slack"
    else if (n ~ /Telegram/)                        f="Telegram"
    else if (n ~ /Code Helper|Visual Studio Code/)  f="VSCode"
    else if (n ~ /ChatGPT|[Cc]odex/)                f="ChatGPT/Codex"
    else if (n ~ /[Hh]elium/)                        f="Helium"
    else if (n ~ /Spotify/)                          f="Spotify"
    else if (n ~ /Docker|com.docker|qemu/)          f="Docker/VM"
    else if (n ~ /next-server|next dev/)            f="Next.js-dev"
    else if (n ~ /vite/)                            f="Vite-dev"
    else if (n ~ /watchman/)                        f="watchman"
    else if (n ~ /(^| |\/)node( |$)/)              f="node(other)"
    else next
    sum[f]+=rss; cnt[f]++
  }
  END { for (k in sum) printf "%-32s %6.2f GB  (%d proc)\n", k, sum[k]/1048576, cnt[k] }
' | sort -k2 -rn

section "TOP 15 BY MEMORY FOOTPRINT  (top MEM incl. compressed)"
top -l 1 -o mem -n 15 -stats pid,command,mem,cpu,state 2>/dev/null | tail -16

section "TOP 15 BY CPU  (2nd sample = accurate)"
top -l 2 -o cpu -n 15 -stats pid,command,cpu,mem,th,state 2>/dev/null | tail -16

section "STUCK PROCESSES  (uninterruptible wait — 'U' in STAT)"
# A handful that changes between runs = transient page-in waits (a memory
# symptom). A stable set stuck on the SAME resource = a hung mount/disk/FUSE.
STUCK="$(ps -axo pid,stat,time,comm 2>/dev/null | awk 'NR==1 || $2 ~ /U/')"
echo "$STUCK"
printf 'stuck count: %s\n' "$(printf '%s\n' "$STUCK" | awk 'NR>1' | grep -c . )"

section "MOUNTS  (a hung network/FUSE mount blocks processes)"
mount 2>/dev/null | grep -Ei 'smbfs|nfs|fuse|osxfuse|macfuse' || echo "  none (no network/FUSE mounts)"
echo "-- /Volumes --"; ls /Volumes/ 2>/dev/null

section "macOS BACKGROUND TASKS  (Spotlight / Time Machine / iCloud / media)"
have mdutil && mdutil -as 2>/dev/null | head
have tmutil && { echo "-- Time Machine --"; tmutil status 2>/dev/null | head -6; }
echo "-- daemons by CPU-time --"
ps -Ao pcpu,time,comm 2>/dev/null \
  | grep -iE 'mds|mdworker|photoanalysisd|mediaanalysisd|backupd|cloudd|bird|fileproviderd|corespotlight' \
  | grep -v grep | sort -rn | head

section "JETSAM / MEMORY-KILL & RECENT CRASH REPORTS"
# JetsamEvent reports = the kernel killed processes to reclaim RAM. Repeated
# ones (esp. multiple per day) are hard proof of chronic memory exhaustion.
DR=~/Library/Logs/DiagnosticReports
echo "-- jetsam events (memory kills) --"
ls -lt "$DR"/ 2>/dev/null | grep -iE 'jetsam' | head -8 || true
[ -z "$(ls "$DR"/ 2>/dev/null | grep -iE 'jetsam')" ] && echo "  none found"
echo "-- most recent 10 diagnostic reports --"
ls -t "$DR"/ 2>/dev/null | head -10

section "THERMAL / POWER"
pmset -g therm 2>/dev/null | grep -iE 'CPU_Speed_Limit|CPU_Scheduler_Limit|CPU_Available' \
  || echo "  (no thermal limits reported)"
pmset -g batt 2>/dev/null | head -2

section "THIRD-PARTY LAUNCH AGENTS / DAEMONS  (running, non-Apple)"
launchctl list 2>/dev/null | grep -v com.apple \
  | awk 'NR==1 || $1 != "-"' | head -40

section "DEV LEFTOVERS  (orphaned dev servers, watchers, automation browsers)"
echo "-- dev servers LISTENing --"
lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -iE 'node|next|vite|webpack|ruby|python' | head -20 || true
echo "-- next/vite dev server processes --"
pgrep -fl 'next-server|next dev|vite' 2>/dev/null | head || echo "  none"
echo "-- watchman --"
if WPID="$(pgrep watchman 2>/dev/null | head -1)"; [ -n "${WPID:-}" ]; then
  ps -o rss= -p "$WPID" 2>/dev/null | awk '{printf "  watchman PID '"$WPID"' RSS %.1f MB (footprint can be far larger if swapped)\n",$1/1024}'
else
  echo "  not running"
fi
echo "-- headless / automation browsers (puppeteer, agent browsers) --"
# Show only main browser processes (drop --type= helper children) and clip width.
AUTO="$(pgrep -fl 'agent-browser-chrome|Chrome for Testing|--headless' 2>/dev/null \
  | grep -v -- '--type=' | sed -E 's/ --.*//' | cut -c1-110)"
if [ -n "$AUTO" ]; then
  echo "$AUTO"
  printf '  (total automation-browser processes incl. helpers: %s)\n' \
    "$(pgrep -f 'agent-browser-chrome|Chrome for Testing|--headless' 2>/dev/null | wc -l | tr -d ' ')"
else
  echo "  none"
fi
echo "-- node process count --"
printf '  node processes: %s\n' "$(pgrep -x node 2>/dev/null | wc -l | tr -d ' ')"
echo "-- git repos with many worktrees (bloat check; >3 shown) --"
FOUND_WT=0
for base in "$HOME/Desktop" "$HOME/Projects" "$HOME/Developer" "$HOME/dev" "$HOME/code" "$HOME/src"; do
  [ -d "$base" ] || continue
  while IFS= read -r gitdir; do
    repo="$(dirname "$gitdir")"
    n="$(git -C "$repo" worktree list 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${n:-0}" -gt 3 ]; then printf '  %-45s %s worktrees\n' "$(basename "$repo")" "$n"; FOUND_WT=1; fi
  done < <(find "$base" -maxdepth 4 -type d -name node_modules -prune -o -type d -name .git -print 2>/dev/null)
done
[ "$FOUND_WT" -eq 0 ] && echo "  none with >3 worktrees"

# ---------------------------------------------------------------------------
section "QUICK VERDICT"
SWAP_LINE="$(sysctl -n vm.swapusage 2>/dev/null)"
SWAP_USED="$(printf '%s' "$SWAP_LINE"  | sed -E 's/.*used = ([0-9.]+)M.*/\1/')"
SWAP_TOTAL="$(printf '%s' "$SWAP_LINE" | sed -E 's/.*total = ([0-9.]+)M.*/\1/')"
PCT="$(awk -v u="${SWAP_USED:-0}" -v t="${SWAP_TOTAL:-1}" 'BEGIN{ if(t>0) printf "%.0f", 100*u/t; else print 0 }')"
printf 'swap used: %s / %s MB  (%s%%)\n' "${SWAP_USED:-?}" "${SWAP_TOTAL:-?}" "$PCT"
[ "$FAST" -eq 0 ] && printf 'live swapouts: %s pages/3s (~%s MB)\n' "${SWAPOUT_DELTA:-?}" "$(( ${SWAPOUT_DELTA:-0} * 16 / 1024 ))"
echo
if [ "$FAST" -eq 0 ] && [ "${SWAPOUT_DELTA:-0}" -ge 3000 ]; then
  echo ">> ACTIVE SWAP THRASHING. The kernel is paging heavily right now — this is"
  echo "   the cause of the slowdown. Root cause is MEMORY OVERCOMMIT, not any single"
  echo "   CPU-hungry process. Free RAM via the app-family table above (biggest first),"
  echo "   then reboot to fully drain swap. See SKILL.md 'Remediation playbook'."
elif [ "${PCT:-0}" -ge 85 ]; then
  echo ">> MEMORY CRITICAL: swap nearly full but not actively thrashing this instant."
  echo "   One more heavy app will tip it into thrashing. Free memory now and plan a reboot."
elif [ "${PCT:-0}" -ge 60 ]; then
  echo ">> MEMORY TIGHT: swap is filling. Watch the app-family table; trim the top holders."
else
  echo ">> Memory looks OK. If it is still slow, look at CPU (top-by-CPU), a hung mount"
  echo "   (stuck processes on the same resource), thermal throttling, or disk I/O."
fi
echo
echo "(read-only report — nothing was killed or changed)"
