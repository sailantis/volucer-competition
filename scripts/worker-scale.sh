#!/usr/bin/env bash
# Is PHP the limit? Workers 48 -> 96 -> 192 at fixed concurrency.
#
# If 48 children were the constraint, doubling them nearly doubles throughput. If the curve is
# still asymptotic at 96 and 192, the limiter is upstream of the backend count and the "PHP
# saturates" reading is wrong.
set -uo pipefail
cd ~/volucer-competition || exit 1
BIN=~/hello-bench/bin/volucer-async-attach
for w in 48 96 192; do
  echo "=== workers=$w c=100"
  ./scripts/attach-probe.sh "$BIN" "$w" 100 12 "wk-$w" 2>&1 \
    | grep -E 'Requests/sec:|^ +50%|^front-end|^php |^slots:|too many'
done