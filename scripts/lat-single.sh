#!/usr/bin/env bash
# What does ONE uncontended keep-alive request cost in wall time?
#
# At 100 connections the front-end is only ~36% busy per runtime thread and PHP uses 2.7 of 96
# possible cores, yet p50 is 1.44 ms. Neither side is CPU-saturated, so the question is what a
# single request actually waits for. `wrk -t1 -c1` is one connection, one request in flight,
# keep-alive (wrk pipelines per-connection but at c=1 there is one request outstanding).
set -uo pipefail
cd ~/volucer-competition || exit 1
BIN=${1:-~/hello-bench/bin/volucer-async-attach}
OUT=.probe/lat-single; rm -rf "$OUT"; mkdir -p "$OUT"
PORT=22612; SOCK="$OUT/relay"
sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$PWD|g" -e "s|{{WORKERS}}|1|g" \
    -e "s|{{SOCKET_DIR}}|$OUT|g" conf/hello-attach.toml.template > "$OUT/attach.toml"
php -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 -d opcache.jit=off \
    apps/hello/supervisor.php "unix:$SOCK" >"$OUT/sup.log" 2>&1 &
SUP=$!
for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.05; done
"$BIN" serve -c "$OUT/attach.toml" >"$OUT/volucer.log" 2>&1 &
VOL=$!
for _ in $(seq 1 200); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.05; done

T0=$(awk '{print $14+$15}' /proc/$VOL/stat)
echo "=== wrk -t1 -c1, 10 s, one request in flight, keep-alive"
wrk -t1 -c1 -d10s --latency "http://127.0.0.1:$PORT/" 2>&1 \
  | grep -E 'Requests/sec:|^Latency|^ +50%|^ +99%|requests in '
T1=$(awk '{print $14+$15}' /proc/$VOL/stat)
REQ=$(wrk -t1 -c1 -d5s "http://127.0.0.1:$PORT/" 2>&1 | awk '/requests in /{print $1}')

echo "=== front-end CPU per request, single-connection run"
awk -v a="$T0" -v b="$T1" -v r="${REQ:-1}" 'BEGIN{
  d=(b-a)*10; printf "  ticks delta over the 10 s run: %d -> %.2f core(s)\n", b-a, (b-a)/100/10
}'

kill -TERM $VOL 2>/dev/null; sleep 1; kill -9 $VOL 2>/dev/null
kill -TERM $SUP 2>/dev/null; sleep 0.5; kill -9 $SUP 2>/dev/null
pkill -f "supervisor.php unix:$SOCK" 2>/dev/null