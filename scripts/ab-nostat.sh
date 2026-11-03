#!/usr/bin/env bash
# Does removing the preparation hop from a request that cannot name a script buy anything?
#
#   ab-nostat.sh [workers] [conc] [secs]
#
# Phase 16 attributed the front-end's remaining cost to futexes: 5.18/request, of which ~2.2 park
# and ~2.2 wake. A follow-up callsite probe showed where they come from -- the `spawn_blocking`
# hand-off that prepares every CGI request parks and wakes a blocking-pool thread even when the
# closure does nothing but encode (measured: `/` costs the front-end zero `stat` calls, because a
# path with no script extension never reaches the router's `is_file`).
#
# So the two arms differ by exactly that: `async-attach` hands every request to a blocking thread,
# `nostat` prepares it inline when the path cannot name a script. Same commit otherwise, rotated so
# host drift cannot favour either.
set -uo pipefail
cd ~/volucer-competition || exit 1

A=~/hello-bench/bin/volucer-async-attach   # before: every request through spawn_blocking
B=~/hello-bench/bin/volucer-nostat         # after:  inline when the path cannot name a script
WORKERS=${1:-96}
CONC=${2:-100}
SECS=${3:-14}

run() {
  ./scripts/attach-probe.sh "$1" "$WORKERS" "$CONC" "$SECS" "$2" 2>&1 | awk -v t="$(basename "$1")" '
      /^Requests\/sec:/ { rps=$2 }
      /50%/ && !p50 { p50=$2 }
      /^front-end/ { fe=$2; feus=$4 }
      /^php / { ph=$2 }
      /^slots:/ { split($0,x,"wait p50 "); split(x[2],y," "); sw=y[1] }
      END { printf "  %-22s %8.0f rps  p50 %-8s fe %s cores %6s us/req  php %s  slotwait %s\n",
                   t, rps, p50, fe, feus, ph, sw }'
}
for round in 1 2 3; do
  echo "--- round $round"
  if [ $(( round % 2 )) -eq 1 ]; then run "$A" "ns-a-$round"; run "$B" "ns-b-$round"
  else run "$B" "ns-b-$round"; run "$A" "ns-a-$round"; fi
done
