#!/usr/bin/env bash
# Does the front-end use more cores if given more runtime threads?
#
# At 48 workers it is at 4.4 cores / 68.4 us/req = 64.3k rps, matching the measured 63.9k -- so the
# cap is "cores the front-end actually uses", not the worker count. Twelve runtime threads at 4.4
# cores are each only ~37% busy. If per-thread utilisation is the limit, more threads scale; if it
# is not, they do not. TOKIO_WORKER_THREADS is tokio's own override, so no rebuild is needed.
set -uo pipefail
cd ~/volucer-competition || exit 1
BIN=~/hello-bench/bin/volucer-async-attach
for rt in "" 24 48; do
  tag="rt-${rt:-default}"
  label="rt=${rt:-default}"
  echo "=== $label"
  if [ -z "$rt" ]; then
    ./scripts/attach-probe.sh "$BIN" 48 100 12 "$tag" 2>&1 | grep -E 'Requests/sec:|^ +50%|^front-end|^php |^slots:'
  else
    TOKIO_WORKER_THREADS=$rt ./scripts/attach-probe.sh "$BIN" 48 100 12 "$tag" 2>&1 | grep -E 'Requests/sec:|^ +50%|^front-end|^php |^slots:'
  fi
done