#!/usr/bin/env bash
# Is the c=2..16 hump cache-coherence traffic between the runtime's threads?
#
# The evidence so far says the hump is a property of the multi-threaded runtime, not of the
# backend and not of more work:
#
#   * it vanishes with `TOKIO_WORKER_THREADS=1` (flat ~44 us from c=1 to c=100)
#   * it appears identically on the `upstream` arm (Node origin, hyper client, no FastCGI)
#   * every COUNT is flat or falling across it: futex/req 5.8->3.1, switches/req 10.4->4.5,
#     migrations/req ~0.1, cross-CPU wakes/req ~0.1-0.3
#   * the symbol SHARES barely move (lock/switch 29-37%), yet the absolute cost doubles --
#     so the same operations are taking twice as long
#
# Same operations, twice the time, no extra syscalls, no extra switches: that is what a cache
# miss costs, and cache misses are invisible to every counter used above. If it is right, then
# the amount of it must depend on how many DISTINCT caches the request's data is spread over --
# so holding concurrency fixed and reducing the number of cores the process may run on should
# bring the per-request cost back down, without changing the work at all.
#
# This is the control for that: the same run, the same concurrency, `taskset` to 12, 6, 4 and 2
# cores. Throughput is expected to fall (less parallelism); the CLAIM under test is that the
# per-request CPU cost falls too. If it does not, the hump is not coherence and this says so.
#
# Usage: probe-affinity-curve.sh [secs] [children]
#   CONCS="4 16 100"  RT=12  CPUS="0-11 0-5 0-3 0-1"
set -eu

SECS=${1:-10}
CHILDREN=${2:-96}
CONCS=${CONCS:-"4 16 100"}
RT=${RT:-12}
CPUS=${CPUS:-"0-11 0-5 0-3 0-1"}
SETTLE=${SETTLE:-6}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-affinity
BIN=${BIN:-$HOME/hello-bench/bin/volucer-050}
PORT=23060
OUT="$D/curve.txt"

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
echo "=== runtime threads: $RT"

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

# php-fpm stays unpinned: it is a separate population and pinning it too would confound the
# measurement with the backend's own contention.
: > "$OUT"
for cpus in $(echo "$CPUS" | tr ',' ' '); do
    echo
    echo "########## cpus=$cpus"
    if [ -f "$D/vol.pid" ]; then kill -9 "$(cat "$D/vol.pid")" 2>/dev/null || true; sleep 1; fi
    taskset -c "$cpus" env TOKIO_WORKER_THREADS=$RT "$BIN" serve -c "$D/vol.toml" \
        >"$D/vol-$cpus.log" 2>&1 &
    VOL_PID=$!
    echo "$VOL_PID" > "$D/vol.pid"
    sleep 2
    body=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/" || echo "<no answer>")
    case $body in *'"hello"'*) ;; *) echo "=== FATAL cpus=$cpus: $body"; tail -5 "$D/vol-$cpus.log"; exit 1 ;; esac
    wrk -t4 -c8 -d5s "http://127.0.0.1:$PORT/" >/dev/null 2>&1 || true
    echo "  pinned to: $(grep -o 'Cpus_allowed_list.*' /proc/$VOL_PID/status)"

    printf "%-6s %10s %10s %10s\n" "conc" "rps" "fe_us" "cores"
    for c in $CONCS; do
        sleep "$SETTLE"
        t=$(nproc); if [ "$t" -gt "$c" ]; then t=$c; fi
        f0=$(ns_of "$VOL_PID")
        wrk -t"$t" -c"$c" -d"${SECS}s" "http://127.0.0.1:$PORT/" >"$D/wrk-$cpus-$c.txt" 2>&1
        f1=$(ns_of "$VOL_PID")
        rps=$(awk '/^Requests\/sec:/{print $2}' "$D/wrk-$cpus-$c.txt")
        total=$(awk '/requests in /{print $1}' "$D/wrk-$cpus-$c.txt")
        awk -v cp="$cpus" -v c="$c" -v r="${rps:-0}" -v d="$(( f1 - f0 ))" -v s="$SECS" -v n="${total:-1}" '
            BEGIN {
                printf "%-6s %10d %10.1f %10.2f\n", c, r, (n>0?d/1e3/n:0), d/1e9/s
            }' | tee -a "$OUT" | sed "s/^/[$cpus] /"
    done
done
