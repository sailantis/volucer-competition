#!/usr/bin/env bash
# Where does volucer's extra front-end CPU go, against a front-end that is doing the same job?
#
# `probe-nginx-cpu.sh` measures volucer at ~49-56 us of front-end CPU per request and nginx at
# ~34 us, through the same php-fpm pool at the same concurrency. That gap is 40% of the request
# path and it is the one number still separating the two arms. This probe attributes it.
#
# `perf record -e cpu-clock` because the guest has no PMU: `perf stat -e cycles` returns
# `<not supported>`, so hardware events are unavailable and the software clock is the only
# sampling source. `-g` for call graphs, since the question is which *caller* is responsible
# rather than which leaf instruction.
#
# Usage: probe-volucer-profile.sh [secs] [conc] [children]
set -eu

SECS=${1:-20}
CONC=${2:-100}
CHILDREN=${3:-96}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-vprof
BIN=${BIN:-$HOME/hello-bench/bin/volucer-adopt}
PORT_X=23001

rm -rf "$D"; mkdir -p "$D"

cleanup() {
    for p in $(pgrep -f "probe-vprof/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(ps -eo pid,args --no-headers 2>/dev/null \
               | grep "[p]hp-fpm: pool bench$" | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    sleep 0.3
}
trap cleanup EXIT INT TERM
cleanup

echo "=== volucer: $BIN $("$BIN" --version 2>&1) $(sha256sum "$BIN" | cut -c1-16)"

# Run the pool as the account that owns the workspace, not as whoever invoked the probe: php-fpm
# refuses to run children as root, and `perf` needs root. `SUDO_USER` is the bridge.
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
"$BIN" serve -c "$D/vol.toml" >"$D/vol.log" 2>&1 &
for _ in $(seq 1 100); do
    curl -sf --max-time 2 "http://127.0.0.1:$PORT_X/" >/dev/null 2>&1 && break
    sleep 0.1
done
body=$(curl -s --max-time 5 "http://127.0.0.1:$PORT_X/" || echo "<no answer>")
echo "  body -> $body"
case $body in *'"hello"'*) ;; *) echo "=== FATAL: not serving"; exit 1 ;; esac

PID=$(pgrep -f "$D/vol.toml" | head -1)
CORES=$(nproc)
T=$CORES
[ "$T" -gt "$CONC" ] && T=$CONC

echo "--- warm-up (discarded)"
wrk -t"$T" -c"$CONC" -d5s "http://127.0.0.1:$PORT_X/" >/dev/null 2>&1 || true
sleep 3

echo "--- sampling $SECS s at c=$CONC"
wrk -t"$T" -c"$CONC" -d"${SECS}s" "http://127.0.0.1:$PORT_X/" >"$D/wrk.txt" 2>&1 &
WRK=$!
sleep 4
perf record -e cpu-clock -F999 -g -p "$PID" -o "$D/perf.data" -- sleep $(( SECS - 6 )) \
    >"$D/perf.log" 2>&1 || true
wait "$WRK" || true
echo "  rps: $(awk '/^Requests\/sec:/{print $2}' "$D/wrk.txt")"

echo
echo "=== flat profile (self time), top 30"
perf report -i "$D/perf.data" --stdio --no-children --percent-limit 0.4 -g none 2>/dev/null \
    | grep -E '^ +[0-9]+\.[0-9]+%' | head -30

echo
echo "=== by call graph (inclusive), top 40"
perf report -i "$D/perf.data" --stdio --children --percent-limit 0.5 -g graph,0.5 2>/dev/null \
    | grep -vE '^#|^$' | head -60

echo
echo "=== dso summary"
perf report -i "$D/perf.data" --stdio --sort dso --percent-limit 1 -g none 2>/dev/null \
    | grep -E '^ +[0-9]+\.[0-9]+%' | head -12

echo
echo "(perf data: $D/perf.data)"
