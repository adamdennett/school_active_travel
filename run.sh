#!/usr/bin/env bash
# run.sh - Route all of England, resumably.
#   DEADLINE="2026-11-12 07:00" ./run.sh   stop cleanly at that time (mid-tile, between chunks)
#   touch data/PAUSE                         stop at the next chunk; delete it before restarting
# Each step skips what is already done, so the same command carries on the next night.
set -u
cd "$(dirname "$0")"
RS="${RSCRIPT:-/c/Program Files/R/R-4.5.2/bin/Rscript.exe}"
export DEADLINE="${DEADLINE:-}"
mkdir -p logs
log() { echo "$(date '+%Y-%m-%d %H:%M') $*" | tee -a logs/run.log; }
late() { [ -f data/PAUSE ] && return 0; [ -n "$DEADLINE" ] && [ "$(date +%s)" -ge "$(date -d "$DEADLINE" +%s)" ]; }

log "start${DEADLINE:+, stopping at $DEADLINE}"
[ -f data/cache/frame.rds ] || { log "frame"; "$RS" R/01_frame.R > logs/frame.log 2>&1 || { log "frame failed"; exit 1; }; }
if late; then log "stopped before clipping"; exit 0; fi
log "clipping streets (tiles already clipped are skipped)"
"$RS" R/02_osm.R >> logs/osm.log 2>&1 || { log "clipping failed, see logs/osm.log"; exit 1; }

TILES=$("$RS" -e 'cat(readRDS("data/cache/frame.rds")$tiles$tile)')
n=0; total=$(echo $TILES | wc -w)
for t in $TILES; do
  n=$((n + 1))
  [ -f "data/cache/tiles/$t/gathered.csv" ] && continue
  if late; then log "stopped before $t ($n of $total)"; exit 0; fi
  log "$t ($n of $total)"
  "$RS" R/03_route.R "$t" >> "logs/$t.log" 2>&1; st=$?
  if [ $st -eq 3 ]; then log "stopped in $t at the deadline; rerun to carry on"; exit 0; fi
  if [ $st -ne 0 ]; then log "$t failed (exit $st), see logs/$t.log; going on to the next"; continue; fi
  "$RS" R/04_assemble.R "$t" >> "logs/$t.log" 2>&1 || log "$t gathering failed, see logs/$t.log"
done
"$RS" R/04_assemble.R >> logs/assemble.log 2>&1
log "all tiles done: $(tail -1 logs/assemble.log)"
