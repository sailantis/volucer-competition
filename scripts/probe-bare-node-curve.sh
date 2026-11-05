#!/usr/bin/env bash
# Is the per-request cost hump a property of tokio, or of THIS MACHINE?
#
# Everything measured so far is a front-end that runs on a multi-threaded tokio runtime:
#
#   external arm, rt=12   c=1 46.6   c=2 62.0   c=4 75.7   c=16 71.1   c=100 54.4
#   external arm, rt=1    c=1 47.8   c=2    -    c=4 46.0   c=16 43.9   c=100 43.7
#   upstream arm, rt=12   c=1 43.5               c=4 61.6               c=100 51.9
#
# Counted and ruled out for the hump: futex/request (falls 5.8 -> 3.1), context switches/request
# (falls 10.4 -> 4.5), migrations (~0.1), cross-CPU wakeups (~0.1-0.3, flat), and the symbol-level
# profile shares (lock/switch 29-37% in every cell). Yet the absolute cost doubles, which is what
# a per-operation slowdown looks like and none of those counts can see it.
#
# Before blaming tokio, the machine has to be cleared. A Xen guest with 12 vCPUs is not 12
# dedicated cores: when one vCPU is busy the hypervisor can give it a whole physical core, and
# when five are busy it may co-schedule them onto fewer, or onto SMT siblings of one. That would
# produce exactly this shape -- per-request cost rising as more threads become runnable -- and it
# would have nothing to do with volucer.
#
# The control is a server with no tokio and no volucer: bare Node + Fastify in cluster mode,
# measured by the same instrument. If its per-request CPU humps with concurrency too, the hump is
# the platform and every conclusion drawn from it about volucer is withdrawn.
#
# `steal` from /proc/stat is printed per cell as well: a guest that is being descheduled shows it
# directly, and it costs one file read.
#
# Usage: probe-bare-node-curve.sh [secs]
#   CONCS="1 2 4 8 16 100"  NODE_WORKERS=12
set -eu

SECS=${1:-10}
CONCS=${CONCS:-"1 2 4 8 16 100"}
NODE_WORKERS=${NODE_WORKERS:-12}
SETTLE=${SETTLE:-5}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-bare-node
NODE=${NODE:-$HOME/hello-bench/bin/node-v24.11.1-linux-x64/bin/node}
PORT=23050

rm -rf "$D"; mkdir -p "$D"

cleanup() {
    for p in $(pgrep -f "$D/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    [ -f "$D/node.pid" ] && kill -9 "$(cat "$D/node.pid")" 2>/dev/null || true
    pkill -x wrk 2>/dev/null || true
    sleep 0.3
}
trap cleanup EXIT INT TERM
cleanup

"$NODE" "$ROOT/apps/hello/fastify-hello.js" --port "$PORT" --workers "$NODE_WORKERS" \
    >"$D/node.log" 2>&1 &
echo $! > "$D/node.pid"
for _ in $(seq 1 100); do
    curl -sf --max-time 1 "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break; sleep 0.1
done
body=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/" || echo "<no answer>")
case $body in *'"hello"'*) echo "=== bare node -> $body, $NODE_WORKERS procs" ;;
    *) echo "=== FATAL: not serving: $body"; cat "$D/node.log"; exit 1 ;; esac

ns_of() { local total=0 pid t v; for pid in "$@"; do for t in /proc/"$pid"/task/*/schedstat; do
    [ -r "$t" ] || continue; v=$(awk '{print $1}' "$t" 2>/dev/null); total=$(( total + ${v:-0} )); done; done; echo "$total"; }

# Every node process this run started, including cluster children. Matched on the script path in
# argv rather than on the name `node`, so an unrelated node process cannot be charged to it.
node_pids() { pgrep -f "fastify-hello.js --port $PORT" 2>/dev/null | tr '\n' ' '; }

steal_ticks() { awk '/^cpu /{print $9+0}' /proc/stat; }

wrk -t4 -c8 -d5s "http://127.0.0.1:$PORT/" >/dev/null 2>&1 || true
sleep 3

printf "%-6s %10s %10s %12s %10s %10s\n" "conc" "rps" "us_per_req" "cores" "procs" "steal_ms"
for c in $CONCS; do
    sleep "$SETTLE"
    t=$(nproc); if [ "$t" -gt "$c" ]; then t=$c; fi
    PIDS=$(node_pids)
    s0=$(steal_ticks)
    f0=$(ns_of $PIDS)
    wrk -t"$t" -c"$c" -d"${SECS}s" "http://127.0.0.1:$PORT/" >"$D/wrk-$c.txt" 2>&1
    f1=$(ns_of $PIDS)
    s1=$(steal_ticks)
    rps=$(awk '/^Requests\/sec:/{print $2}' "$D/wrk-$c.txt")
    total=$(awk '/requests in /{print $1}' "$D/wrk-$c.txt")
    nproc_now=$(echo $PIDS | wc -w)
    awk -v c="$c" -v r="${rps:-0}" -v d="$(( f1 - f0 ))" -v s="$SECS" -v n="${total:-1}" \
        -v p="$nproc_now" -v st="$(( (s1 - s0) * 10 ))" '
        BEGIN { printf "%-6s %10d %10.1f %12.2f %10d %10d\n",
                       c, r, (n>0?d/1e3/n:0), d/1e9/s, p, st }'
done
