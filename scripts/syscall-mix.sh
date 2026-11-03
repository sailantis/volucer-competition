#!/usr/bin/env bash
# What does the request path still syscall per request, now that it has no hand-off?
#
#   syscall-mix.sh <binary> <workers> <conc> <secs> <tag>
#
# A profile share is a fraction of samples; a count is a fact. The two candidates this is aimed at
# are `getrandom` (trace-context ids minted per request) and `clock_gettime`, which on this
# hypervisor is a syscall rather than a vDSO read -- Phase 5 measured both and set them aside
# because the profile was then four times larger.
set -uo pipefail

BIN=${1:?binary}
WORKERS=${2:-96}
CONC=${3:-100}
SECS=${4:-16}
TAG=${5:-mix}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.probe/$TAG"
PORT=$((22960 + WORKERS % 30))
WIN=5
rm -rf "$OUT"; mkdir -p "$OUT"

sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{WORKERS}}|$WORKERS|g" \
    -e "s|{{SOCKET_DIR}}|$OUT|g" \
    "$ROOT/conf/hello-attach.toml.template" > "$OUT/cfg.toml"

php -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 -d opcache.jit=off \
    "$ROOT/apps/hello/supervisor.php" "unix:$OUT/relay" >"$OUT/sup.log" 2>&1 &
SUP=$!
for _ in $(seq 1 100); do [ -S "$OUT/relay" ] && break; sleep 0.05; done

"$BIN" serve -c "$OUT/cfg.toml" >"$OUT/v.log" 2>&1 &
VOL=$!
for _ in $(seq 1 300); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.05; done
# One warm pass: the first `wrk` against a cold pool answers ~20 requests with a non-2xx while the
# workers come up (measured: 24 on run 1, 0 on runs 2 and 3), and a cold-run sample is not steady
# state.
wrk -t"$(nproc)" -c"$CONC" -d4s "http://127.0.0.1:$PORT/" >/dev/null 2>&1

wrk -t"$(nproc)" -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:$PORT/" >"$OUT/wrk.txt" 2>&1 &
WRK=$!
sleep 3
sudo -n timeout "$WIN" bpftrace -p "$VOL" "$ROOT/scripts/syscall-mix.bt" >"$OUT/mix.txt" 2>&1
wait $WRK

cat "$OUT/wrk.txt"
RPS=$(awk '/^Requests\/sec:/{print $2}' "$OUT/wrk.txt")
WREQ=$(awk -v r="${RPS:-0}" -v w="$WIN" 'BEGIN{printf "%.0f", r*w}')
echo "--- sampled ${WIN}s at ~${RPS:-?} rps (~${WREQ} requests)"
awk -v n="$WREQ" '
    BEGIN {
        name["gr"]="getrandom"; name["cg"]="clock_gettime"; name["cg64"]="clock_gettime64"
        name["ep"]="epoll_wait"; name["fx"]="futex"; name["wv"]="writev"
        name["st"]="sendto"; name["rf"]="recvfrom"
    }
    /^@/ {
        split($0, a, ":"); key = a[1]; sub(/^@/, "", key); sum[key] = a[2] + 0
    }
    END {
        printf "  %-16s %12s %10s\n", "syscall", "count", "per-request"
        for (k in sum) printf "  %-16s %12d %10.3f\n", name[k], sum[k], (n+0>0 ? sum[k]/n : 0)
    }
' "$OUT/mix.txt"

kill -TERM $VOL 2>/dev/null; sleep 1; kill -9 $VOL 2>/dev/null
kill -TERM $SUP 2>/dev/null; sleep 0.3; kill -9 $SUP 2>/dev/null
pkill -f "supervisor.php unix:$OUT/relay" 2>/dev/null
echo "--- out: $OUT"
