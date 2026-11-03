#!/usr/bin/env bash
# Who reads the clock 16 times per request, and is it worth changing?
#
#   clock-sites.sh <binary> <tag> [path]
#
# `clock_gettime` is 15.9 syscalls per request and 3.5% of the front-end's CPU in
# `pvclock_clocksource_read`, which on this hypervisor is a real syscall rather than a vDSO read.
# At the measured 0.2 us a syscall costs here that is ~3 us of a 40 us request, so the question is
# not "is it big" but "is it removable": a timeout that is never armed and a metric that is always
# recorded both read the clock for a reason, and only the code says which.
#
# Attribution first, decision second -- the reverse order is what produced three wrong conclusions
# earlier in this record.
set -uo pipefail

BIN=${1:?binary}
TAG=${2:-clk}
PATH_REQ=${3:-/}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.probe/$TAG"
PORT=22970
rm -rf "$OUT"; mkdir -p "$OUT"

sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{WORKERS}}|96|g" \
    -e "s|{{SOCKET_DIR}}|$OUT|g" \
    "$ROOT/conf/hello-attach.toml.template" > "$OUT/cfg.toml"

php -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 -d opcache.jit=off \
    "$ROOT/apps/hello/supervisor.php" "unix:$OUT/relay" >"$OUT/sup.log" 2>&1 &
SUP=$!
for _ in $(seq 1 100); do [ -S "$OUT/relay" ] && break; sleep 0.05; done
"$BIN" serve -c "$OUT/cfg.toml" >"$OUT/v.log" 2>&1 &
VOL=$!
for _ in $(seq 1 300); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.05; done
wrk -t"$(nproc)" -c100 -d4s "http://127.0.0.1:$PORT/" >/dev/null 2>&1

wrk -t"$(nproc)" -c100 -d14s --latency "http://127.0.0.1:$PORT$PATH_REQ" >"$OUT/wrk.txt" 2>&1 &
WRK=$!
sleep 3
sudo -n timeout 5 bpftrace "$ROOT/scripts/clock-sites.bt" -p "$VOL" >"$OUT/sites.txt" 2>&1
wait $WRK
cat "$OUT/wrk.txt"
echo "--- clock_gettime by top frame (raw; demangle with c++filt)"
sed -n 's/^@clk\[".*", \(.*\)\]: \([0-9]*\)$/\2 \1/p' "$OUT/sites.txt" | head -20
echo "--- op totals"
grep -E '^@(clk|total)' "$OUT/sites.txt"
kill -TERM $VOL 2>/dev/null; sleep 1; kill -9 $VOL 2>/dev/null
kill -TERM $SUP 2>/dev/null; sleep 0.3; kill -9 $SUP 2>/dev/null
pkill -f "supervisor.php unix:$OUT/relay" 2>/dev/null
echo "--- out: $OUT"
