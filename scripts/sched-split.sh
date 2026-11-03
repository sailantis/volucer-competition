#!/usr/bin/env bash
# Off-CPU split for the front-end runtime threads, run as one measurement.
#
#   sched-split.sh <binary> <workers> <concurrency> <seconds> <tag>
#
# Separates the two reasons a thread is not on a CPU: asleep (blocked on futex/epoll/socket)
# versus runnable (ready, not scheduled = scheduler latency). The first says the request path is
# latency-bound; the second says the box is oversubscribed.
set -uo pipefail
BIN=${1:?binary}; WORKERS=${2:?}; CONC=${3:?}; SECS=${4:?}; TAG=${5:?}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.probe/$TAG"; PORT=$((22600 + WORKERS % 100)); SOCK="$OUT/relay"
rm -rf "$OUT"; mkdir -p "$OUT"
PHP_ARGS=(-d opcache.enable_cli=1 -d opcache.validate_timestamps=0 -d opcache.jit=off -d xdebug.mode=off -d memory_limit=512M)
sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{WORKERS}}|$WORKERS|g" \
    -e "s|{{SOCKET_DIR}}|$OUT|g" "$ROOT/conf/hello-attach.toml.template" > "$OUT/attach.toml"
php "${PHP_ARGS[@]}" "$ROOT/apps/hello/supervisor.php" "unix:$SOCK" >"$OUT/sup.log" 2>&1 &
SUP_PID=$!
for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.05; done
"$BIN" serve -c "$OUT/attach.toml" >"$OUT/volucer.log" 2>&1 &
VOL_PID=$!
for _ in $(seq 1 200); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.05; done
CORES=$(nproc)
wrk -t"$CORES" -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:$PORT/" >"$OUT/wrk.txt" 2>&1 &
WRK_PID=$!
sleep 3
sudo -n timeout $((SECS - 4)) bpftrace "$ROOT/scripts/sched-rt.bt" >"$OUT/sched.txt" 2>&1 &
BPF=$!
# Syscall latency, so "asleep" can be attributed: futex vs the socket the worker answers on.
sudo -n timeout $((SECS - 4)) bpftrace "$ROOT/scripts/syscall-lat.bt" -c "" >/dev/null 2>&1 &
wait $WRK_PID; W=$?
wait $BPF 2>/dev/null
cat "$OUT/wrk.txt"
TOTAL=$(awk '/requests in /{print $1}' "$OUT/wrk.txt")
RPS=$(awk '/^Requests\/sec:/{print $2}' "$OUT/wrk.txt")
echo "=== not-on-CPU, tokio-rt-worker population (${TOTAL:-?} req, ${RPS:-?} rps)"
cat "$OUT/sched.txt"
echo "=== slots"
grep '^slots:' "$OUT/volucer.log" || echo "(none)"
kill -TERM $VOL_PID 2>/dev/null
for _ in $(seq 1 200); do kill -0 $VOL_PID 2>/dev/null || break; sleep 0.05; done
kill -9 $VOL_PID 2>/dev/null
kill -TERM $SUP_PID 2>/dev/null; sleep 0.5; kill -9 $SUP_PID 2>/dev/null
pkill -f "supervisor.php unix:$SOCK" 2>/dev/null
exit $W