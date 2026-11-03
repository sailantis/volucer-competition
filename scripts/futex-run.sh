#!/usr/bin/env bash
# Which lock do the runtime threads park on? (3.6 futex/request, 0.04 epoll_wait/request)
set -uo pipefail
cd ~/volucer-competition || exit 1
BIN=${1:-~/hello-bench/bin/volucer-async-attach}
WORKERS=${2:-96}; CONC=${3:-100}; SECS=${4:-20}
OUT=.probe/futex-stacks; rm -rf "$OUT"; mkdir -p "$OUT"
PORT=22612; SOCK="$OUT/relay"
sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$PWD|g" -e "s|{{WORKERS}}|$WORKERS|g" \
    -e "s|{{SOCKET_DIR}}|$OUT|g" conf/hello-attach.toml.template > "$OUT/attach.toml"
php -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 -d opcache.jit=off \
    apps/hello/supervisor.php "unix:$SOCK" >"$OUT/sup.log" 2>&1 &
SUP=$!
for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.05; done
"$BIN" serve -c "$OUT/attach.toml" >"$OUT/volucer.log" 2>&1 &
VOL=$!
for _ in $(seq 1 200); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.05; done
CORES=$(nproc)
wrk -t"$CORES" -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:$PORT/" >"$OUT/wrk.txt" 2>&1 &
WRK=$!
sleep 3
sudo -n timeout $((SECS - 4)) bpftrace scripts/futex-stacks.bt >"$OUT/stacks.txt" 2>&1 &
BPF=$!
wait $WRK
wait $BPF 2>/dev/null
grep -E 'Requests/sec:|requests in ' "$OUT/wrk.txt" | tail -2
echo "=== futex stacks"
head -80 "$OUT/stacks.txt"
kill -TERM $VOL 2>/dev/null; sleep 1; kill -9 $VOL 2>/dev/null
kill -TERM $SUP 2>/dev/null; sleep 0.5; kill -9 $SUP 2>/dev/null
pkill -f "supervisor.php unix:$SOCK" 2>/dev/null