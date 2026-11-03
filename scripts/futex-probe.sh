#!/usr/bin/env bash
# Count futex syscalls per request in each probe arm.
#
# This is the corroboration for the probe's timings, and deliberately a *different*
# measurement of the same claim: the cpu/req difference must be traceable to wakeups, or the
# explanation ("the boundary is two futexes") is wrong even when the timing is right.
#
# `bpftrace -p PID` rather than `-c`: `-c` neither shell-splits its argument nor reliably
# execs a wrapper here, and attaching to the pid is what the question actually asks for
# anyway — the count must cover exactly this process, and `-p` scopes it to one process tree.
set -uo pipefail
CONNECTIONS=${1:-12}
PER_CONN=${2:-20000}
BENCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE=${PROBE:-$HOME/volucer-bench/target/release/fcgi-async-probe}
OUT="$BENCH/.probe/async-client"
SOCK="$OUT/relay"
REPORT="$OUT/report.txt"
BTLOG="$OUT/bpftrace.out"

PHP_ARGS=(-d opcache.enable_cli=1 -d opcache.validate_timestamps=0
          -d opcache.jit=off -d xdebug.mode=off -d memory_limit=512M)

rm -rf "$OUT"; mkdir -p "$OUT"
php "${PHP_ARGS[@]}" "$BENCH/apps/hello/supervisor.php" "unix:$SOCK" >"$OUT/sup.log" 2>&1 &
SUP_PID=$!
cleanup() {
    kill -TERM $SUP_PID 2>/dev/null; sleep 0.2; kill -9 $SUP_PID 2>/dev/null
    pkill -f "supervisor.php unix:$SOCK" 2>/dev/null
}
trap cleanup EXIT
for _ in $(seq 1 200); do [ -S "$SOCK" ] && break; sleep 0.05; done
[ -S "$SOCK" ] || { echo "no supervisor"; cat "$OUT/sup.log"; exit 1; }

for arm in handoff async sync-pool; do
    rm -f "$REPORT" "$BTLOG"
    "$PROBE" "$SOCK" "$arm" "$CONNECTIONS" "$PER_CONN" >"$REPORT" 2>&1 &
    PROBE_PID=$!
    # Attached immediately, so the count starts before the first request and covers the whole
    # run. A short delay only skips connect/handshake futexes, which are constant per arm.
    sudo -n bpftrace -e 'tracepoint:syscalls:sys_enter_futex { @futex = count(); }' \
        -p "$PROBE_PID" >"$BTLOG" 2>&1 &
    BT_PID=$!
    wait $PROBE_PID
    # SIGINT makes bpftrace print its maps; SIGTERM can drop them.
    sudo -n kill -INT $BT_PID 2>/dev/null
    wait $BT_PID 2>/dev/null

    fut=$(grep -o '@futex: [0-9]*' "$BTLOG" | awk '{print $2}')
    req=$(awk '/reqs/{for(i=1;i<=NF;i++) if($i=="reqs") print $(i-1)}' "$REPORT" 2>/dev/null)
    if [ -z "$fut" ] || [ -z "$req" ]; then
        echo "$arm: no data (futex=${fut:-none} req=${req:-none})"
        head -3 "$BTLOG" 2>/dev/null
        continue
    fi
    awk -v a="$arm" -v n="$req" -v f="$fut" 'BEGIN{printf "%-10s %8d requests  %9d futex  %6.2f per request\n", a, n, f, f/n}'
done