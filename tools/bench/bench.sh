#!/usr/bin/env bash
# One controlled Cycle VII benchmark run (the fixed 10-minute window).
# Usage: bench.sh <name> <exe> [launcher switches, comma-joined] [KEY=VALUE ...]
#
# Two start settings (BENCH_START), each a wrapper too:
#   saved    (bench-saved.sh)    the benchmark save in bench-save/ is put in place
#                                of any story save: every run starts at the same
#                                spot. Make one with capture-bench-save.ps1.
#   opening  (bench-opening.sh)  every story save is moved aside: the game starts
#                                a new story and plays its opening (cutscenes, so
#                                the content of the window depends on the build's
#                                frame rate; good for start-up and loading, not
#                                for comparing frame rates).
# Story saves are only ever moved aside (save-backups\aside-bench-<name>-<time>),
# never deleted.
#
# Protocol (v2, from T8): Windows unlocked, no controller, no other input; stray
# apps closed; launch hidden through run-test.ps1 with a 15-minute cap; never a
# key press in the world (one Enter only if the account picker shows); the game
# stopped BENCH_STOP_S (615) seconds after the world starts (the 600 s window
# plus a margin), recorded in STOPPED_BY_BENCH.txt; then bench_window.py.
#
# Paths: BENCH_RUNS (default ~/victory-runs/cycle-vii) holds tools/, data/ and
# bench-save/; the title's saves are under %LOCALAPPDATA%\victory\data\7952987A.
set -u
NAME=$1; EXE=$2; ARGS=${3:--Safe}; shift 3 || shift $#
START=${BENCH_START:-saved}
case "$START" in saved|opening) ;; *) echo "ABORT: BENCH_START must be saved or opening"; exit 2;; esac
RUNS=${BENCH_RUNS:-$HOME/victory-runs/cycle-vii}
TOOLS=$RUNS/tools
D=$RUNS/data/$NAME
W_RUNS=$(cygpath -w "$RUNS")
W_D="$W_RUNS\\data\\$NAME"
PROC=$(basename "${EXE//\\//}" .exe)
WINDOW_STOP_S=${BENCH_STOP_S:-615}
if powershell -NoProfile -Command "if (Get-Process LogonUI -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"; then
  echo "ABORT: Windows is locked"; exit 2
fi
if powershell -NoProfile -Command "if (Get-Process '$PROC' -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"; then
  echo "ABORT: $PROC is already running"; exit 2
fi
if [ "$START" = saved ] && ! ls -d "$RUNS"/bench-save/SARC* >/dev/null 2>&1; then
  echo "ABORT: no benchmark save in $RUNS/bench-save (make one with capture-bench-save.ps1)"; exit 2
fi
powershell -NoProfile -Command "Get-Process ChatGPT, Discord, chrome, Spotify, SpotifyXboxGamebarWebView, steam -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue"
SAVE_NOTE=$(powershell -NoProfile -Command "
  \$base = Join-Path \$env:LOCALAPPDATA 'victory\\data\\7952987A'
  \$u = Join-Path \$base 'saves\\0009000000000001\\00000000-0000-0000-0000-00007952987a'
  \$aside = Join-Path \$base ('save-backups\\aside-bench-$NAME-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  \$old = @(Get-ChildItem \$u -Directory -Filter 'SARC*' -ErrorAction SilentlyContinue)
  if (\$old.Count) { New-Item -ItemType Directory -Force \$aside | Out-Null; \$old | Move-Item -Destination \$aside }
  \$moved = if (\$old.Count) { 'moved aside: ' + (\$old.Name -join ', ') } else { 'no story save was present' }
  if ('$START' -eq 'saved') {
    \$bench = @(Get-ChildItem '$W_RUNS\\bench-save' -Directory -Filter 'SARC*')
    \$bench | Copy-Item -Recurse -Destination \$u
    \$made = Get-Content '$W_RUNS\\bench-save\\SAVE-INFO.txt' -TotalCount 1 -ErrorAction SilentlyContinue
    'saved: ' + (\$bench.Name -join ', ') + \$(if (\$made) { ' (' + \$made + ')' }) + '; ' + \$moved
  } else { 'opening: no save; ' + \$moved }")
echo "start: $SAVE_NOTE"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$W_RUNS\\tools\\run-test.ps1' -Name '$NAME' -Exe '$EXE' -MaxMinutes 15 -LauncherArgs '$ARGS' -Env @{$(for kv in "$@"; do printf "'%s'='%s';" "${kv%%=*}" "${kv#*=}"; done)}" > "$RUNS/data/.bench-$NAME.out" 2>&1 &
RUN=$!
L=$D/victory.log
last(){ sed 's/\x1b\[[0-9;]*m//g' "$L" 2>/dev/null | grep "overlay: " | tail -1 | grep -oE "\) [0-9]+ draws" | grep -oE "[0-9]+"; }
alive(){ kill -0 $RUN 2>/dev/null; }
n=0; i=0; w=0
while [ $i -lt 150 ] && alive; do d=$(last); if [ "${d:-0}" = "11" ]; then n=$((n+1)); else n=0; fi; [ $n -ge 5 ] && break
  # Straight into the world (a save loads with no picker): never press anything.
  if [ "${d:-0}" -ge 1000 ]; then w=$((w+1)); else w=0; fi; [ $w -ge 5 ] && break
  sleep 2; i=$((i+1)); done
echo "picker wait ended after ~$((i*2)) s (draws=${d:-none})"
[ "${d:-0}" = "11" ] && for k in 1 2 3; do
  powershell -NoProfile -ExecutionPolicy Bypass -File "$TOOLS/game-screen.ps1" -Out "$W_D\\screens\\press-enter-$k.png" -Press Enter -Down 1500 -Hold 500 >/dev/null 2>&1
  sleep 8; d=$(last); echo "after Enter $k: draws=$d"; [ "$d" != "11" ] && break
done
# The world starts at the first of 5 status lines in a row with >= 1000 draws
# (bench_window.py's rule); stop the game WINDOW_STOP_S later.
if [ $w -lt 5 ]; then w=0; while alive; do d=$(last); if [ "${d:-0}" -ge 1000 ]; then w=$((w+1)); else w=0; fi; [ $w -ge 5 ] && break; sleep 2; done; fi
if alive; then
  WORLD=$(date +%s); echo "world from ~$(date +%T)"
  while alive && [ $(( $(date +%s) - WORLD )) -lt $WINDOW_STOP_S ]; do sleep 5; done
  if alive; then
    powershell -NoProfile -Command "Get-Process '$PROC' -ErrorAction SilentlyContinue | Stop-Process -Force"
    echo "stopped by bench.sh at $(date +%T), ${WINDOW_STOP_S} s after the world started" | tee "$D/STOPPED_BY_BENCH.txt"
  fi
fi
wait $RUN
cat "$RUNS/data/.bench-$NAME.out"
echo "$SAVE_NOTE" > "$D/bench-start.txt"
cd "$RUNS" && python -I tools/parse_run.py "data/$NAME" >/dev/null 2>&1
python -I tools/bench_window.py "data/$NAME" --json "data/$NAME/bench.json"
