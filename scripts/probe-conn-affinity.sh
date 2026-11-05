#!/usr/bin/env bash
# Does the SAME connection get served by the SAME runtime thread, at each concurrency?
#
# The previous probe counted `sched_migrate_task` and found ~0.1-0.3 per request. That instrument
# cannot answer the question, and this is the correction: `sched_migrate_task` fires when the
# *kernel* moves a thread to another CPU. A tokio runtime moves *tasks* between its threads while
# every thread stays exactly where it is, so the counter is blind to the thing being suspected.
#
# The suspicion, stated so it can be refuted: tokio's work-stealing gives a task's data locality
# only while no thread is idle. At low concurrency there are empty workers, so a woken connection
# task is pushed to a remote queue and picked up by whichever thread is free -- a different one
# each time, on a different CPU, with a different L1 and a different slice of the shared LLC. The
# connection's socket buffer, its FastCGI request and its response are then re-fetched from a
# cache that no longer holds them. At high concurrency every worker is busy, nothing is stolen,
# and each connection is polled by the thread that polled it last time -- which is why the cost
# FALLS again, and why `TOKIO_WORKER_THREADS=1` is flat (there is nobody to steal from).
#
# The measurement: for every connection (file descriptor) the front-end reads from, how many
# distinct threads read from it? One means the connection is sticky. Several means it moves.
#
# This is a property of the *runtime*, not of the backend, which is consistent with the hump
# appearing identically on the `upstream` arm.
#
# Usage: probe-conn-affinity.sh [secs] [children]
#   CONCS="1 4 16 100"  RT=12
set -eu

SECS=${1:-12}
CHILDREN=${2:-96}
CONCS=${CONCS:-"1 4 16 100"}
RT=${RT:-12}
SETTLE=${SETTLE:-6}
WINDOW=${WINDOW:-6}
WARMUP=${WARMUP:-5}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-conn-affinity
BIN=${BIN:-$HOME/hello-bench/bin/volucer-050}
PORT=23070

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

if [ -f "$D/vol.pid" ]; then kill -9 "$(cat "$D/vol.pid")" 2>/dev/null || true; sleep 1; fi
TOKIO_WORKER_THREADS=$RT "$BIN" serve -c "$D/vol.toml" >"$D/vol.log" 2>&1 &
VOL_PID=$!
echo "$VOL_PID" > "$D/vol.pid"
sleep 2
body=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/" || echo "<no answer>")
case $body in *'"hello"'*) ;; *) echo "=== FATAL: $body"; exit 1 ;; esac
wrk -t4 -c8 -d5s "http://127.0.0.1:$PORT/" >/dev/null 2>&1 || true

printf "%-6s %9s %9s %14s %14s %14s\n" "conc" "rps" "fe_us" "conns" "tids_per_conn" "conns_served_by_1"
for c in $CONCS; do
    sleep "$SETTLE"
    t=$(nproc); if [ "$t" -gt "$c" ]; then t=$c; fi
    f0=$(ns_of "$VOL_PID")
    wrk -t"$t" -c"$c" -d"$(( WARMUP + WINDOW + 3 ))s" "http://127.0.0.1:$PORT/" \
        >"$D/wrk-$c.txt" 2>&1 &
    WJ=$!
    sleep "$WARMUP"
    # For every fd, the set of tids that read from it. `recvfrom` is how both the client connection
    # and the FastCGI socket are read, so this covers both directions.
    sudo bpftrace -p "$VOL_PID" -e '
        tracepoint:syscalls:sys_enter_recvfrom { @tids[args->fd, tid] = 1; }
        interval:s:'"$WINDOW"' {
            exit();
        }
    ' >"$D/bt-c$c.txt" 2>&1
    wait $WJ 2>/dev/null || true
    f1=$(ns_of "$VOL_PID")
    rps=$(awk '/^Requests\/sec:/{print $2}' "$D/wrk-$c.txt")
    total=$(awk '/requests in /{print $1}' "$D/wrk-$c.txt")
    # `@tids[fd, tid]: 1` prints one line per (fd, tid) pair.
    stats=$(awk '
        /^@tids\[/ {
            line = $0
            sub(/^@tids\[/, "", line)
            sub(/\].*$/, "", line)
            n = split(line, p, ",")
            fd = p[1] + 0
            conns[fd] = 1
            seen[fd "|" p[2]] = 1
            count[fd]++
        }
        END {
            nfd = 0; tot = 0; solo = 0
            for (f in conns) {
                nfd++
                tot += count[f]
                if (count[f] == 1) solo++
            }
            printf "%d %.2f %d\n", nfd, (nfd > 0 ? tot / nfd : 0), solo
        }' "$D/bt-c$c.txt")
    awk -v c="$c" -v r="${rps:-0}" -v d="$(( f1 - f0 ))" -v s="$SECS" -v n="${total:-1}" \
        -v st="$stats" '
        BEGIN {
            split(st, q, " ")
            printf "%-6s %9d %9.1f %14d %14.2f %14d\n", c, r, (n>0?d/1e3/n:0), q[1], q[2], q[3]
        }'
done
