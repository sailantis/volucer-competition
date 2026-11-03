#!/usr/bin/env bash
# Is the park/wake traffic the runtime's own threads, or the blocking pool's?
#
#   futex-tid.sh <binary> <workers> <concurrency> <seconds> <tag>
#
# The runtime's threads exist at startup; a blocking thread exists only while the pool has
# work for it. Snapshotting the tid set before the load and again during it is enough to
# attribute every park and wake to one of the two populations, without needing to
# distinguish them by name (they share one).
set -uo pipefail

BIN=${1:?binary}
WORKERS=${2:?workers}
CONC=${3:?concurrency}
SECS=${4:?seconds}
TAG=${5:?tag}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.probe/$TAG"
PORT=$((22600 + WORKERS % 100))
SOCK="$OUT/relay"
WIN=5

rm -rf "$OUT"
mkdir -p "$OUT"

sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{WORKERS}}|$WORKERS|g" \
    -e "s|{{SOCKET_DIR}}|$OUT|g" \
    "$ROOT/conf/hello-attach.toml.template" > "$OUT/attach.toml"

php -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 -d opcache.jit=off \
    "$ROOT/apps/hello/supervisor.php" "unix:$SOCK" >"$OUT/sup.log" 2>&1 &
SUP_PID=$!
for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.05; done

"$BIN" serve -c "$OUT/attach.toml" >"$OUT/volucer.log" 2>&1 &
VOL_PID=$!
for _ in $(seq 1 200); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.05; done
# One warm request so the pool is fully built before the "before" snapshot.
curl -sf -o /dev/null "http://127.0.0.1:$PORT/" || true
sleep 1

ls /proc/"$VOL_PID"/task >"$OUT/tids-idle"
IDLE=$(wc -l <"$OUT/tids-idle")

CORES=$(nproc)
wrk -t"$CORES" -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:$PORT/" >"$OUT/wrk.txt" 2>&1 &
WRK_PID=$!
sleep 3
ls /proc/"$VOL_PID"/task >"$OUT/tids-load"

sudo -n timeout "$WIN" bpftrace -p "$VOL_PID" "$ROOT/scripts/futex-tid.bt" >"$OUT/tid.txt" 2>&1

wait $WRK_PID
cat "$OUT/wrk.txt"
RPS=$(awk '/^Requests\/sec:/{print $2}' "$OUT/wrk.txt")
TOTAL=$(awk '/requests in /{print $1}' "$OUT/wrk.txt")

# Requests seen by the probe window: rps x window, which is the divisor that makes a
# per-request rate out of a sample taken over WIN seconds of the same run.
WREQ=$(awk -v r="${RPS:-0}" -v w="$WIN" 'BEGIN{printf "%.0f", r*w}')
echo "--- idle threads ${IDLE}; sampled ${WIN}s at ~${RPS:-?} rps (~${WREQ} requests)"

sed -n 's/^@by_tid\[\([0-9]*\), \([0-9]*\)\]: \([0-9]*\)$/\1 \2 \3/p' "$OUT/tid.txt" >"$OUT/tid.rows"
awk -v idle="$OUT/tids-idle" -v wreq="$WREQ" '
    BEGIN { while ((getline t < idle) > 0) was[t] = 1 }
    {
        op = $1; tid = $2; n = $3
        pop = ($2 in was) ? "pre-existing" : "added-by-pool"
        c[op, pop] += n
        tot[op] += n
    }
    END {
        printf "%-6s %-15s %12s %10s\n", "op", "population", "count", "per-request"
        for (k in c) {
            split(k, p, SUBSEP)
            printf "%-6s %-15s %12d %10.2f\n", p[1], p[2], c[k], c[k] / wreq
        }
        printf "%-6s %-15s %12d %10.2f\n", "all", "all", tot[129] + tot[137] + tot[128], (tot[129] + tot[137] + tot[128]) / wreq
    }
' "$OUT/tid.rows"

echo "--- thread count during load: $(wc -l <"$OUT/tids-load")"

kill -TERM $VOL_PID 2>/dev/null; sleep 1; kill -9 $VOL_PID 2>/dev/null
kill -TERM $SUP_PID 2>/dev/null; sleep 0.5; kill -9 $SUP_PID 2>/dev/null
pkill -f "supervisor.php unix:$SOCK" 2>/dev/null
echo "--- out: $OUT"
