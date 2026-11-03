#!/usr/bin/env bash
# Who parks, and who wakes?
#
#   futex-callsite.sh <binary> <workers> <concurrency> <seconds> <tag>
#
# Phase 16 counted the shapes but not the owners: ~2.2 FUTEX_WAIT_BITSET (park) and ~2.2
# FUTEX_WAKE_BITSET (wake) per request on the runtime threads, against 0.04 epoll_wait. Equal
# counts on both directions is the signature of symmetric park/wake pairs, but a pair is two
# call sites and only one of them is worth removing. This attributes each op to a user stack.
#
# Stack capture is expensive (5 futexes x 64k rps), so the probe window is short and the
# totals are printed beside the request count: if the sampled rate falls well below the
# ~5/request Phase 16 measured, bpftrace dropped events and the split is indicative only.
set -uo pipefail

BIN=${1:?binary}
WORKERS=${2:?workers}
CONC=${3:?concurrency}
SECS=${4:?seconds}
TAG=${5:?tag}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.probe/$TAG"
PORT=$((22600 + WORKERS % 100))
SOCK="$OUT/relay"
WIN=4

rm -rf "$OUT"
mkdir -p "$OUT"

sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{WORKERS}}|$WORKERS|g" \
    -e "s|{{SOCKET_DIR}}|$OUT|g" \
    "$ROOT/conf/hello-attach.toml.template" > "$OUT/attach.toml"

php -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 -d opcache.jit=off \
    "$ROOT/apps/hello/supervisor.php" "unix:$SOCK" >"$OUT/sup.log" 2>&1 &
SUP_PID=$!
for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.05; done

"$BIN" serve -c "$OUT/attach.toml" >"$OUT/volucer.log" 2>&1 &
VOL_PID=$!
for _ in $(seq 1 200); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.05; done

CORES=$(nproc)
wrk -t"$CORES" -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:$PORT/" >"$OUT/wrk.txt" 2>&1 &
WRK_PID=$!
sleep 4

# The window is measured, not assumed: the request count either side of it is what makes
# the per-request rate honest.
REQ0=$(awk '/Requests\/sec:/{print $2}' "$OUT/wrk.txt")

sudo -n timeout "$WIN" bpftrace "$ROOT/scripts/futex-callsite.bt" -p "$VOL_PID" \
    >"$OUT/callsite.txt" 2>&1

wait $WRK_PID
cat "$OUT/wrk.txt"
RPS=$(awk '/^Requests\/sec:/{print $2}' "$OUT/wrk.txt")
TOTAL=$(awk '/requests in /{print $1}' "$OUT/wrk.txt")
echo "--- sampled ${WIN}s at ~${RPS:-?} rps  (${TOTAL:-?} requests in the run)"

echo "=== futex by op"
sed -n '/^@op/,/^$/p' "$OUT/callsite.txt"

echo "=== futex by op and call site"
awk '/^@by_op/{p=1} p' "$OUT/callsite.txt" | head -120

kill -TERM $VOL_PID 2>/dev/null; sleep 1; kill -9 $VOL_PID 2>/dev/null
kill -TERM $SUP_PID 2>/dev/null; sleep 0.5; kill -9 $SUP_PID 2>/dev/null
pkill -f "supervisor.php unix:$SOCK" 2>/dev/null
echo "--- out: $OUT"
