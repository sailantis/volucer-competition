#!/usr/bin/env bash
# Does the async attach exchange's CPU saving convert to throughput when PHP is NOT the limit?
#
# Phase 15 measured -19 us/req of front-end CPU but 0% rps at 12 workers, where the pool
# saturates first. Workers 48 -> 96 showed PHP is not the constraint (63.7k -> 63.8k), so at 96
# workers the front-end's own cost is the only candidate. Rotated, twice.
set -uo pipefail
cd ~/volucer-competition || exit 1
A=~/hello-bench/bin/volucer-async          # before: thread per slot exchange
B=~/hello-bench/bin/volucer-async-attach   # after:  awaited connection
run() {
  local bin=$1 tag=$2
  ./scripts/attach-probe.sh "$bin" 96 100 14 "$tag" 2>&1 \
    | awk -v t="$(basename $bin)" '
        /^Requests\/sec:/ { rps=$2 }
        /50%/ && !p50 { p50=$2 }
        /^front-end/ { fe=$2; feus=$4 }
        /^php / { ph=$2 }
        /^slots:/ { split($0,x,"wait p50 "); split(x[2],y," "); sw=y[1] }
        END { printf "  %-22s %8.0f rps  p50 %-8s fe %s cores %6s us/req  php %s  slotwait %s\n", t, rps, p50, fe, feus, ph, sw }
      '
}
for round in 1 2; do
  echo "--- round $round"
  if [ $round -eq 1 ]; then run "$A" "ab96-a-$round"; run "$B" "ab96-b-$round"
  else run "$B" "ab96-b-$round"; run "$A" "ab96-a-$round"; fi
done