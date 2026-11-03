#!/usr/bin/env bash
# The `worker` (pipe) arm: does the hop-less preparation help it too?
#
#   worker-nostat.sh <before-binary> <after-binary> <workers> <conc> <secs>
#
# `attach` and `worker` share everything above the pool, so the preparation hop this change
# removes exists on both. They differ below it ? an attached worker's connection is awaited,
# a spawned worker keeps a thread ? so the gain is expected to be smaller here, and measuring
# it is the point: the change should not be justified for one arm and quietly regress the other.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

A=${1:?before}
B=${2:?after}
WORKERS=${3:-48}
CONC=${4:-100}
SECS=${5:-12}

run() {
    local bin=$1 tag=$2
    local OUT="$ROOT/.probe/$tag"
    local PORT=$((22800 + WORKERS % 90))
    rm -rf "$OUT"; mkdir -p "$OUT"
    sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$ROOT|g" \
        -e "s|{{WORKERS}}|$WORKERS|g" -e "s|{{PHP}}|php|g" \
        "$ROOT/conf/hello-worker.toml.template" > "$OUT/cfg.toml"

    "$bin" serve -c "$OUT/cfg.toml" >"$OUT/volucer.log" 2>&1 &
    local VOL=$!
    for _ in $(seq 1 300); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.05; done

    ns() { local t=0 p v; for p in "$@"; do for f in /proc/"$p"/task/*/schedstat; do
        [ -r "$f" ] || continue; v=$(awk '{print $1}' "$f"); t=$((t+${v:-0})); done; done; echo $t; }
    local c0=$(ns $VOL)
    wrk -t"$(nproc)" -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:$PORT/" >"$OUT/wrk.txt" 2>&1
    local c1=$(ns $VOL)

    local rps=$(awk '/^Requests\/sec:/{print $2}' "$OUT/wrk.txt")
    local total=$(awk '/requests in /{print $1}' "$OUT/wrk.txt")
    local p50=$(awk '/^ +50%/{print $2}' "$OUT/wrk.txt")
    awk -v t="$(basename "$bin")" -v r="${rps:-0}" -v p="$p50" -v d="$((c1-c0))" -v n="${total:-1}" -v s="$SECS" \
        'BEGIN{ printf "  %-22s %8.0f rps  p50 %-9s fe %.2f cores %6.1f us/req\n", t, r, p, d/1e9/s, d/1e3/n }'

    kill -TERM $VOL 2>/dev/null; sleep 1; kill -9 $VOL 2>/dev/null
    pkill -f "apps/hello/worker.php" 2>/dev/null
}

for round in 1 2; do
    echo "--- round $round"
    if [ $(( round % 2 )) -eq 1 ]; then run "$A" "wk-a-$round"; run "$B" "wk-b-$round"
    else run "$B" "wk-b-$round"; run "$A" "wk-a-$round"; fi
done
