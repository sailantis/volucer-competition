#!/usr/bin/env bash
# Where does throughput saturate?
#
# c=1 gives p50 115 us (8.3k rps) and c=100 gives p50 1.44 ms (64k rps): concurrency rises 100x
# for 7.7x throughput, so effective parallelism is only ~8 of 12 runtime threads, at 37% CPU.
# Sweeping concurrency locates the knee.
#
# wrk needs c >= t, so the thread count tracks the connection count here but never exceeds 12.
set -uo pipefail
cd ~/volucer-competition || exit 1
BIN=~/hello-bench/bin/volucer-async-attach
for c in 1 2 4 8 16 24 32 48 64 100; do
  t=$c; [ "$t" -gt 12 ] && t=12
  tag="cs-$c"
  ./scripts/attach-probe.sh "$BIN" 96 "$c" 10 "$tag" 2>&1 \
    | awk -v c="$c" '
        /^Requests\/sec:/ { rps=$2 }
        /^requests in / { req=$1 }
        /50%/ && !p50 { p50=$2 }
        /^front-end/ { fe=$2; feus=$4 }
        /^php / { ph=$2 }
        END { printf "c=%-4s %8.0f rps  p50 %-8s fe %5s cores %6s us/req  php %s\n", c, rps, p50, fe, feus, ph }
      '
done