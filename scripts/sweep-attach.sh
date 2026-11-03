#!/usr/bin/env bash
# Worker sweep for the attach arm, with PHP counted.
#
# The question this answers: does the front-end's ~5.5 cores come from being the
# bottleneck (in which case more backends change nothing) or from waiting on PHP (in
# which case more backends would raise the request rate and grow PHP's share)?
set -uo pipefail
ROOT="/home/competition/volucer-competition"
BIN=${BIN:-/home/competition/hello-bench/bin/volucer-async}
CONC=${CONC:-100}
SECS=${SECS:-18}
WORKERS=${WORKERS:-"12 24 48"}
EXTRA=${EXTRA:-}

for w in $WORKERS; do
    echo "===== workers=$w conc=$CONC ${EXTRA:+extra=$EXTRA}"
    if [ -n "$EXTRA" ]; then
        bash "$ROOT/scripts/attach-probe.sh" "$BIN" "$w" "$CONC" "$SECS" "w$w" "$EXTRA" 2>&1 \
            | grep -E 'Requests/sec|^front-end|^php |^wrk |^slots:|^ +50%'
    else
        bash "$ROOT/scripts/attach-probe.sh" "$BIN" "$w" "$CONC" "$SECS" "w$w" 2>&1 \
            | grep -E 'Requests/sec|^front-end|^php |^wrk |^slots:|^ +50%'
    fi
done
