#!/usr/bin/env bash
# jemalloc arena contention: is the allocator mutex in the futex profile worth anything?
#
# The futex stacks showed `__GI___lll_lock_wake -> pac_dalloc_impl` and
# `_rjem_je_malloc_mutex_lock_slow` underneath tokio's parker, i.e. jemalloc's own arena lock is
# reachable from the request path. jemalloc was added in d9362ac for throughput (measured +7.3%)
# but its arena configuration was never tuned or tested.
#
# Each arm is the SAME binary; only MALLOC_CONF differs, so any difference is the allocator's
# configuration and not a build.
#   base        shipped behaviour
#   narenas     4x arenas, so runtime threads contend less
#   tcaches     one tcache per thread (jemalloc's default is per-thread already; this pins it)
#   dirty       return memory to the OS lazily instead of on free
set -uo pipefail
cd ~/volucer-competition || exit 1
BIN=~/hello-bench/bin/volucer-async-attach
run() {
  local conf=$1 label=$2 tag=$3
  if [ -z "$conf" ]; then
    ./scripts/attach-probe.sh "$BIN" 96 100 14 "$tag" 2>&1
  else
    MALLOC_CONF="$conf" ./scripts/attach-probe.sh "$BIN" 96 100 14 "$tag" 2>&1
  fi | awk -v t="$label" '
        /^Requests\/sec:/ { rps=$2 }
        /50%/ && !p50 { p50=$2 }
        /^front-end/ { fe=$2; feus=$4 }
        /^php / { ph=$2 }
        END { printf "  %-12s %8.0f rps  p50 %-8s fe %s cores %6s us/req  php %s\n", t, rps, p50, fe, feus, ph }
      '
}
for round in 1 2; do
  echo "--- round $round"
  if [ $round -eq 1 ]; then
    run ""                       "base"    "mc-base-$round"
    run "narenas:64"             "narenas" "mc-nar-$round"
    run "dirty_decay_ms:30000"   "dirty"   "mc-dirty-$round"
  else
    run "dirty_decay_ms:30000"   "dirty"   "mc-dirty-$round"
    run "narenas:64"             "narenas" "mc-nar-$round"
    run ""                       "base"    "mc-base-$round"
  fi
done