#!/usr/bin/env bash
# Is there a concurrency sweet spot? The sweep suggested c=48 and c=100 give the same throughput
# (62.6k vs 63.2k) at half the latency (715 us vs 1.44 ms). If that reproduces, the deployment
# advice is "cap concurrency near 4x cores" rather than a code change.
set -uo pipefail
cd ~/volucer-competition || exit 1
BIN=~/hello-bench/bin/volucer-async-attach
run() {
  ./scripts/attach-probe.sh "$BIN" 96 "$1" 14 "$2" 2>&1 | awk -v c="$1" '
      /^Requests\/sec:/ { rps=$2 }
      /50%/ && !p50 { p50=$2 }
      /^front-end/ { feus=$4 }
      END { printf "  c=%-4s %8.0f rps  p50 %-9s fe %s us/req\n", c, rps, p50, feus }
    '
}
for round in 1 2; do
  echo "--- round $round"
  if [ $round -eq 1 ]; then run 48 "sw2-48-r$round"; run 100 "sw2-100-r$round"
  else run 100 "sw2-100-r$round"; run 48 "sw2-48-r$round"; fi
done