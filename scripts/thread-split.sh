#!/usr/bin/env bash
# Split the front-end's CPU by thread population during a real run.
#
#   thread-split.sh <binary> <workers> <concurrency> <seconds> <tag> [extra.toml]
#
# Why this exists: `attach-probe.sh` reports one CPU number for the whole process. After the
# async attach exchange that number is the sum of two populations with completely different
# reasons to exist --
#
#   tokio-runtime-w   the front-end's own runtime, which awaits the connections
#   volucer-attach    `AsyncRuntime`, which owns them and must outlive them
#
# -- and the question "is `AsyncRuntime` sized too small" cannot be asked of the total. It is
# asked here by grouping every thread of the process by its `comm` and summing `schedstat`.
#
# Reading it: if the `volucer-attach` share is a rounding error, that runtime is not on the
# request path during HTTP load (the front-end awaits on its own runtime), and its thread
# count is not a throughput lever. If it is a large share, the opposite.
set -uo pipefail

BIN=${1:?binary}
WORKERS=${2:?workers}
CONC=${3:?concurrency}
SECS=${4:?seconds}
TAG=${5:?tag}
EXTRA=${6:-}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.probe/$TAG"
PORT=$((22600 + WORKERS % 100))
SOCK="$OUT/relay"

rm -rf "$OUT"
mkdir -p "$OUT"

PHP_ARGS=(-d opcache.enable_cli=1 -d opcache.validate_timestamps=0
          -d opcache.jit=off -d xdebug.mode=off -d memory_limit=512M)

sed -e "s|{{PORT}}|$PORT|g" \
    -e "s|{{ROOT}}|$ROOT|g" \
    -e "s|{{WORKERS}}|$WORKERS|g" \
    -e "s|{{SOCKET_DIR}}|$OUT|g" \
    "$ROOT/conf/hello-attach.toml.template" > "$OUT/attach.toml"

[ -n "$EXTRA" ] && { printf '\n' >> "$OUT/attach.toml"; cat "$EXTRA" >> "$OUT/attach.toml"; }

php "${PHP_ARGS[@]}" "$ROOT/apps/hello/supervisor.php" "unix:$SOCK" >"$OUT/sup.log" 2>&1 &
SUP_PID=$!
for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.05; done
[ -S "$SOCK" ] || { echo "supervisor never listened"; cat "$OUT/sup.log"; kill $SUP_PID 2>/dev/null; exit 1; }

"$BIN" serve -c "$OUT/attach.toml" >"$OUT/volucer.log" 2>&1 &
VOL_PID=$!
for _ in $(seq 1 200); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.05; done

CORES=$(nproc)

# One line per thread: <comm> <nanoseconds>. `schedstat` field 1 is CPU time in ns; summing
# every task is required because /proc/<pid>/schedstat is the leader only.
snapshot() {
    local tid comm cpu
    for d in /proc/"$VOL_PID"/task/*; do
        [ -r "$d/schedstat" ] || continue
        tid=${d##*/}
        comm=$(cat "$d/comm" 2>/dev/null)
        cpu=$(awk '{print $1}' "$d/schedstat" 2>/dev/null)
        echo "${comm:-?}|${tid}|${cpu:-0}"
    done
}

snapshot >"$OUT/t0"
T0_THREADS=$(wc -l <"$OUT/t0")

wrk -t"$CORES" -c"$CONC" -d"$SECS"s --latency "http://127.0.0.1:$PORT/" >"$OUT/wrk.txt" 2>&1 &
WRK_PID=$!
sleep 2
snapshot >"$OUT/t1"
wait $WRK_PID
W=$?
snapshot >"$OUT/t2"

cat "$OUT/wrk.txt"
RPS=$(awk '/^Requests\/sec:/{print $2}' "$OUT/wrk.txt")
TOTAL=$(awk '/requests in /{print $1}' "$OUT/wrk.txt")

echo "--- cpu by thread population (over $((SECS - 2))s of load, ${TOTAL:-?} requests, ${RPS:-?} rps)"
WIN=$(( SECS - 2 ))
awk -F'|' -v total="${TOTAL:-0}" -v win="$WIN" '
    FNR==NR { before[$2] = $3; next }
    {
        # Threads that did not exist before the load started are counted from zero.
        d = $3 - (before[$2] + 0)
        if (d < 0) d = 0
        cpu[$1] += d
        n[$1]++
    }
    END {
        printf "%-18s %6s %10s %10s %12s\n", "thread", "count", "cores", "us/req", "share"
        for (c in cpu) {
            grand += cpu[c]
            order[++k] = c
        }
        for (i = 1; i <= k; i++)
            for (j = i + 1; j <= k; j++)
                if (cpu[order[j]] > cpu[order[i]]) { t = order[i]; order[i] = order[j]; order[j] = t }
        for (i = 1; i <= k; i++) {
            c = order[i]
            cores = cpu[c] / 1e9 / win
            usreq = (total + 0 > 0) ? cpu[c] / 1e3 / total : 0
            printf "%-18s %6d %10.2f %10.1f %11.1f%%\n", c, n[c], cores, usreq, 100 * cpu[c] / grand
            nthr += n[c]
        }
        printf "%-18s %6d %10.2f\n", "TOTAL", nthr, grand / 1e9 / win
    }
' "$OUT/t0" "$OUT/t2"

# Within a group, a tokio runtime and its blocking pool share the `comm` `tokio-rt-worker`,
# which is exactly the split that matters: twelve threads polling a socket and thirty-nine
# parked in `spawn_blocking` look identical in the table above. Counting how many of them
# do real work says whether the blocking hop is still on the request path.
echo "--- per-thread detail (threads above 0.05 cores)"
awk -F'|' -v win="$WIN" '
    FNR==NR { before[$2] = $3; next }
    { d = $3 - (before[$2] + 0); if (d < 0) d = 0; if (d > 0) { cpu[$2] = d; comm[$2] = $1 } }
    END {
        for (t in cpu) if (cpu[t] / 1e9 / win >= 0.05) { n++; busiest[n] = t }
        for (i = 1; i <= n; i++)
            for (j = i + 1; j <= n; j++)
                if (cpu[busiest[j]] > cpu[busiest[i]]) { s = busiest[i]; busiest[i] = busiest[j]; busiest[j] = s }
        for (i = 1; i <= n; i++) {
            t = busiest[i]
            printf "  %-18s tid=%-8s %6.2f cores\n", comm[t], t, cpu[t] / 1e9 / win
        }
        printf "  (%d threads below the threshold)\n", length(cpu) - n
    }
' "$OUT/t0" "$OUT/t2"

echo "--- slots"
grep '^slots:' "$OUT/volucer.log" || echo "(no contention line)"

kill -TERM $VOL_PID 2>/dev/null
for _ in $(seq 1 200); do kill -0 $VOL_PID 2>/dev/null || break; sleep 0.05; done
kill -9 $VOL_PID 2>/dev/null
kill -TERM $SUP_PID 2>/dev/null
for _ in $(seq 1 100); do kill -0 $SUP_PID 2>/dev/null || break; sleep 0.05; done
kill -9 $SUP_PID 2>/dev/null
pkill -f "supervisor.php unix:$SOCK" 2>/dev/null
echo "--- out: $OUT"
exit $W
