#!/usr/bin/env bash
# Is the c=2..16 hump the runtime bouncing its threads between CPUs?
#
# Measured shape (probe-fe-curve.sh, external arm, 96 children):
#
#     c      1     2     3     4     6     8    12    16    24    50   100
#     us  44.6  62.0  71.8  75.7  75.9  74.7  71.9  71.1  62.7  57.1  54.4
#
# flat (~44) with `TOKIO_WORKER_THREADS=1`, and the same hump on the `upstream` arm -- so it is a
# property of the multi-threaded runtime, not of the backend. What is left is to say *what* it
# costs. Three candidates, and this probe separates the first two:
#
#   cross-CPU wakeup -- a task is woken onto a CPU other than the one it last ran on. The cache
#                       and TLB are cold and, on Xen, the wake is an IPI (a trap). Predicted: a
#                       rise exactly where the hump is, because at low concurrency there IS an
#                       idle CPU to move to, while at c=100 every worker is busy and the task
#                       stays put -- which is why the cost falls again.
#
#   re-park          -- a woken thread finds no work and sleeps again. Predicted: wakeups without
#                       a matching switch-in.
#
#   plain volume     -- simply more switches per request. Already refuted: `switch/req` FALLS
#                       monotonically with concurrency (10.4 at c=1 to 4.5 at c=100), the opposite
#                       of the hump.
#
# Method: remember the CPU each thread was last running on (from `sched_switch`, where it
# switched *out*), then compare against `target_cpu` of its next `sched_wakeup`. A mismatch is a
# cross-CPU wake.
#
# Usage: probe-crosscpu.sh [secs] [children]
#   CONCS="1 4 16 100"  RTS="1,12"
set -eu

SECS=${1:-12}
CHILDREN=${2:-96}
CONCS=${CONCS:-"1 4 16 100"}
RTS=${RTS:-"12"}
SETTLE=${SETTLE:-6}
WINDOW=${WINDOW:-6}
WARMUP=${WARMUP:-5}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-crosscpu
BIN=${BIN:-$HOME/hello-bench/bin/volucer-050}
PORT=23030

rm -rf "$D"; mkdir -p "$D"

cleanup() {
    for p in $(pgrep -f "$D/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(ps -eo pid,args --no-headers 2>/dev/null \
               | grep "[p]hp-fpm: pool bench$" | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    [ -f "$D/vol.pid" ] && kill -9 "$(cat "$D/vol.pid")" 2>/dev/null || true
    pkill -x wrk 2>/dev/null || true
    sleep 0.3
}
trap cleanup EXIT INT TERM
cleanup

echo "=== volucer: $("$BIN" --version 2>&1) $(sha256sum "$BIN" | awk '{print substr($1,1,16)}')"

cat > "$D/pool.conf" <<EOF
[global]
daemonize = no
error_log = $D/fpm-error.log
[bench]
listen = $D/fpm.sock
pm = static
pm.max_children = $CHILDREN
pm.max_requests = 0
catch_workers_output = yes
php_admin_value[memory_limit] = 512M
php_admin_value[date.timezone] = UTC
EOF
FPM=$(command -v php-fpm8.5 || command -v php-fpm || echo /usr/sbin/php-fpm8.5)
"$FPM" -y "$D/pool.conf" -F -d opcache.enable=1 -d opcache.validate_timestamps=0 \
    >"$D/fpm.log" 2>&1 &
for _ in $(seq 1 300); do [ -S "$D/fpm.sock" ] && break; sleep 0.05; done
[ -S "$D/fpm.sock" ] || { echo "=== FATAL: php-fpm never bound"; cat "$D/fpm.log"; exit 1; }

sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{SOCKET}}|$D/fpm.sock|g" \
    "$ROOT/conf/hello-external-fpm.toml.template" > "$D/vol.toml"

ns_of() { local total=0 pid t v; for pid in "$@"; do for t in /proc/"$pid"/task/*/schedstat; do
    [ -r "$t" ] || continue; v=$(awk '{print $1}' "$t" 2>/dev/null); total=$(( total + ${v:-0} )); done; done; echo "$total"; }

for rt in $(echo "$RTS" | tr ',' ' '); do
    echo
    echo "########## TOKIO_WORKER_THREADS=$rt"
    if [ -f "$D/vol.pid" ]; then kill -9 "$(cat "$D/vol.pid")" 2>/dev/null || true; sleep 1; fi
    TOKIO_WORKER_THREADS=$rt "$BIN" serve -c "$D/vol.toml" >"$D/vol-rt$rt.log" 2>&1 &
    VOL_PID=$!
    echo "$VOL_PID" > "$D/vol.pid"
    sleep 2
    body=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/" || echo "<no answer>")
    case $body in *'"hello"'*) ;; *) echo "=== FATAL rt=$rt: $body"; exit 1 ;; esac
    wrk -t4 -c8 -d5s "http://127.0.0.1:$PORT/" >/dev/null 2>&1 || true

    printf "%-6s %9s %10s %14s %14s\n" "conc" "rps" "fe_us" "cross_cpu/req" "wake/req"
    for c in $CONCS; do
        sleep "$SETTLE"
        t=$(nproc); if [ "$t" -gt "$c" ]; then t=$c; fi
        f0=$(ns_of "$VOL_PID")
        wrk -t"$t" -c"$c" -d"$(( WARMUP + WINDOW + 3 ))s" "http://127.0.0.1:$PORT/" \
            >"$D/wrk-$c.txt" 2>&1 &
        WJ=$!
        sleep "$WARMUP"
        sudo bpftrace -p "$VOL_PID" -e '
            tracepoint:sched:sched_switch {
                @last_cpu[args->prev_pid] = cpu;
            }
            tracepoint:sched:sched_wakeup {
                $was = @last_cpu[args->pid];
                if ($was >= 0) {
                    if ($was == args->target_cpu) { @same_cpu = count(); }
                    else { @cross_cpu = count(); }
                }
                @wake = count();
            }
            interval:s:'"$WINDOW"' { exit(); }
        ' >"$D/bt-rt$rt-c$c.txt" 2>&1
        wait $WJ 2>/dev/null || true
        f1=$(ns_of "$VOL_PID")
        rps=$(awk '/^Requests\/sec:/{print $2}' "$D/wrk-$c.txt")
        total=$(awk '/requests in /{print $1}' "$D/wrk-$c.txt")
        awk -v c="$c" -v r="${rps:-0}" -v d="$(( f1 - f0 ))" -v s="$SECS" \
            -v n="${total:-1}" -v w="$WINDOW" '
            BEGIN { nw = (r > 0) ? r * w : 1 }
            /^@/ { name=$1; sub(/^@/,"",name); sub(/:$/,"",name); v[name]=$2 }
            END {
                printf "%-6s %9d %10.1f %14.2f %14.2f\n", c, r, (n>0?d/1e3/n:0),
                       (v["cross_cpu"]+0)/nw, (v["wake"]+0)/nw
            }' "$D/bt-rt$rt-c$c.txt"
    done
done
