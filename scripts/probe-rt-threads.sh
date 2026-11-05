#!/usr/bin/env bash
# Is the 22.7%-of-self-time spinlock contention between tokio's own runtime threads?
#
# The profile's top entry is `_raw_spin_unlock_irqrestore`, which is where a cross-core wake spends
# its cost. volucer runs 12 runtime threads (tokio's default: one per core); nginx runs 4 worker
# processes and measured ~34 us of front-end CPU against volucer's ~49-56. If the spinlock is
# self-contention, fewer runtime threads should *raise* per-request CPU (less parallelism) while
# lowering the spinlock share — and if it is not, the thread count will not move latency or
# throughput in the shape a queueing effect would.
#
# `TOKIO_WORKER_THREADS` is read by tokio's builder without a code change, so this is one binary
# against one config with only that variable differing.
#
# Usage: probe-rt-threads.sh [secs] [conc] [children]
set -eu

SECS=${1:-14}
CONC=${2:-100}
CHILDREN=${3:-96}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-rtt
BIN=${BIN:-$HOME/hello-bench/bin/volucer-adopt}
PORT_X=23005

rm -rf "$D"; mkdir -p "$D"

cleanup() {
    for p in $(pgrep -f "probe-rtt/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(ps -eo pid,args --no-headers 2>/dev/null \
               | grep "[p]hp-fpm: pool bench$" | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    sleep 0.3
}
trap cleanup EXIT INT TERM
cleanup

echo "=== volucer: $BIN $("$BIN" --version 2>&1) $(sha256sum "$BIN" | cut -c1-16)"

FPM_USER=${SUDO_USER:-$(id -un)}
FPM_GROUP=$(id -gn "$FPM_USER" 2>/dev/null || id -gn)
cat > "$D/pool.conf" <<EOF
[global]
daemonize = no
error_log = $D/fpm-error.log
[bench]
listen = $D/fpm.sock
listen.owner = $FPM_USER
listen.group = $FPM_GROUP
listen.mode = 0660
user = $FPM_USER
group = $FPM_GROUP
pm = static
pm.max_children = $CHILDREN
pm.max_requests = 0
catch_workers_output = yes
php_admin_value[error_log] = $D/fpm-worker-error.log
php_admin_flag[log_errors] = on
php_admin_value[memory_limit] = 512M
php_admin_value[date.timezone] = UTC
EOF
FPM=$(command -v php-fpm8.5 || command -v php-fpm || echo /usr/sbin/php-fpm8.5)
"$FPM" -y "$D/pool.conf" -F -d opcache.enable=1 -d opcache.validate_timestamps=0 \
    >"$D/fpm.log" 2>&1 &
for _ in $(seq 1 300); do [ -S "$D/fpm.sock" ] && break; sleep 0.05; done
[ -S "$D/fpm.sock" ] || { echo "=== FATAL: php-fpm never bound"; cat "$D/fpm.log"; exit 1; }

sed -e "s|{{PORT}}|$PORT_X|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{SOCKET}}|$D/fpm.sock|g" \
    "$ROOT/conf/hello-external-fpm.toml.template" > "$D/vol.toml"

wait_quiet() {
    local n=0 l
    while :; do
        l=$(cut -d' ' -f1 /proc/loadavg)
        awk -v v="$l" 'BEGIN{exit !(v<1.2)}' && return 0
        n=$(( n + 1 )); [ "$n" -ge 24 ] && return 0
        sleep 5
    done
}

ns_of_pid() {
    local total=0 t v
    for t in /proc/"$1"/task/*/schedstat; do
        [ -r "$t" ] || continue
        v=$(awk '{print $1}' "$t" 2>/dev/null); total=$(( total + ${v:-0} ))
    done
    echo "$total"
}

threads_of() { grep -c '^Threads' /proc/"$1"/status 2>/dev/null | head -1; }

CORES=$(nproc)
T=$CORES
[ "$T" -gt "$CONC" ] && T=$CONC

run_cell() {   # $1 label
    local label=$1 p n0 n1 rps p50 bad thr
    p=$(pgrep -f "$D/vol.toml" 2>/dev/null | head -1)
    [ -n "$p" ] || { echo "  !! no server"; return 1; }
    wrk -t"$T" -c"$CONC" -d5s "http://127.0.0.1:$PORT_X/" >/dev/null 2>&1 || true
    wait_quiet
    n0=$(ns_of_pid "$p")
    wrk -t"$T" -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:$PORT_X/" >"$D/wrk.txt" 2>&1 || true
    n1=$(ns_of_pid "$p")
    thr=$(awk '/^Threads:/{print $2}' /proc/"$p"/status 2>/dev/null)
    rps=$(awk '/^Requests\/sec:/{print $2}' "$D/wrk.txt")
    p50=$(awk '/^ +50%/{print $2}' "$D/wrk.txt")
    bad=$(awk -F: '/Non-2xx/{gsub(/ /,"",$2); print $2+0}' "$D/wrk.txt")
    awk -v l="$label" -v r="${rps:-0}" -v p="${p50:--}" -v d="$(( n1 - n0 ))" -v s="$SECS" \
        -v bad="${bad:-0}" -v c="$CONC" -v th="${thr:-0}" \
        'BEGIN{
            printf "  %-16s c=%-5s %7d rps  p50 %-9s  fe %6.1f us  threads %d%s\n",
                   l, c, r, p, (r>0 ? (d/(r*s))/1000 : 0), th,
                   (bad > 0 ? "   NON-2xx " bad : "")
        }'
}

echo
for rt in 12 8 6 4 2; do
    wait_quiet
    echo "--- TOKIO_WORKER_THREADS=$rt (load $(cut -d' ' -f1 /proc/loadavg))"
    TOKIO_WORKER_THREADS=$rt "$BIN" serve -c "$D/vol.toml" >"$D/vol.log" 2>&1 &
    for _ in $(seq 1 100); do
        curl -sf --max-time 2 "http://127.0.0.1:$PORT_X/" >/dev/null 2>&1 && break
        sleep 0.1
    done
    run_cell "rt=$rt"
    run_cell "rt=$rt (2)"
    p=$(pgrep -f "$D/vol.toml" 2>/dev/null | head -1)
    [ -n "$p" ] && kill -9 "$p" 2>/dev/null || true
    sleep 0.5
done

echo
echo "=== php-fpm children at end: $(pgrep -cf 'php-fpm: pool bench$' || echo 0)"
