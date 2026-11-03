#!/usr/bin/env bash
cd ~/volucer-competition || exit 1
BIN=~/hello-bench/bin/volucer-async-attach
for w in 12 24 48; do
  for c in 100 400; do
    tag="sw-${w}-${c}"
    echo "=== workers=$w conc=$c"
    ./scripts/attach-probe.sh "$BIN" "$w" "$c" 12 "$tag" 2>&1 \
      | grep -E 'Requests/sec:|^Latency|^ +50%|^front-end|^php|^wrk |^slots:'
  done
done