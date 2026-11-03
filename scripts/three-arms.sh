#!/usr/bin/env bash
# Where do the three arms stand *now*, after the preparation hop was removed?
#
#   three-arms.sh [secs] [conc]
#
# Every comparison in this record before Phase 17 was taken against a front-end that paid a
# `spawn_blocking` round trip per request. With that gone the interesting question is no longer
# "how much did we gain" but "what is left between us and the arm that was never hop-bound".
#
# Hard guards, each because it has already produced a believable wrong number:
#   - both bodies are fetched and compared before anything is timed, and the run is refused if
#     either arm is not answering `{"hello":"world"}`. A 502 is answered *faster* than a real
#     request, so a dead origin wins a benchmark it never ran (Phase 11).
#   - wrk's own non-2xx counter is read and reported, not ignored (Phase 11 again).
#   - `wrk -t` is the core count, never the connection count (Phase 5's oversubscription bug).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECS=${1:-16}
CONC=${2:-100}
BIN=${BIN:-$HOME/hello-bench/bin/volucer-nostat2}
NODE_BIN=$HOME/hello-bench/bin/node-v24.11.1-linux-x64/bin
CORES=$(nproc)

ns_of() {
    local total=0 pid v
    for pid in "$@"; do
        for t in /proc/"$pid"/task/*/schedstat; do
            [ -r "$t" ] || continue
            v=$(awk '{print $1}' "$t" 2>/dev/null)
            total=$(( total + ${v:-0} ))
        done
    done
    echo "$total"
}

echo "=== binary: $BIN"
echo "=== $(git -C "$HOME/volucer-bench" log --oneline -1 2>/dev/null || echo 'no checkout')"

# ---- attach -----------------------------------------------------------------
AT="$ROOT/.probe/ta-attach"; rm -rf "$AT"; mkdir -p "$AT"
PORT_A=22930
php -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 -d opcache.jit=off \
    -d xdebug.mode=off -d memory_limit=512M \
    "$ROOT/apps/hello/supervisor.php" "unix:$AT/relay" >"$AT/sup.log" 2>&1 &
SUP_A=$!
for _ in $(seq 1 100); do [ -S "$AT/relay" ] && break; sleep 0.05; done
sed -e "s|{{PORT}}|$PORT_A|g" -e "s|{{ROOT}}|$ROOT|g" \
    -e "s|{{WORKERS}}|96|g" -e "s|{{SOCKET_DIR}}|$AT|g" \
    "$ROOT/conf/hello-attach.toml.template" > "$AT/cfg.toml"
"$BIN" serve -c "$AT/cfg.toml" >"$AT/volucer.log" 2>&1 &
VOL_A=$!
for _ in $(seq 1 300); do curl -sf -o /dev/null "http://127.0.0.1:$PORT_A/" && break; sleep 0.05; done

# ---- upstream ---------------------------------------------------------------
UP="$ROOT/.probe/ta-upstream"; rm -rf "$UP"; mkdir -p "$UP"
PORT_U=22931; ORIGIN_PORT=22940
PATH="$NODE_BIN:$PATH" node "$ROOT/apps/hello/fastify-hello.js" \
    --port "$ORIGIN_PORT" --workers 12 --cluster reuseport >"$UP/origin.log" 2>&1 &
ORIGIN=$!
for _ in $(seq 1 300); do curl -sf -o /dev/null "http://127.0.0.1:$ORIGIN_PORT/" && break; sleep 0.05; done
sed -e "s|{{PORT}}|$PORT_U|g" -e "s|{{ROOT}}|$ROOT|g" \
    -e "s|{{ORIGIN_PORT}}|$ORIGIN_PORT|g" \
    "$ROOT/conf/hello-upstream.toml.template" > "$UP/cfg.toml"
"$BIN" serve -c "$UP/cfg.toml" >"$UP/volucer.log" 2>&1 &
VOL_U=$!
for _ in $(seq 1 300); do curl -sf -o /dev/null "http://127.0.0.1:$PORT_U/" && break; sleep 0.05; done

# ---- the guard --------------------------------------------------------------
A_BODY=$(curl -s "http://127.0.0.1:$PORT_A/")
U_BODY=$(curl -s "http://127.0.0.1:$PORT_U/")
N_BODY=$(curl -s "http://127.0.0.1:$ORIGIN_PORT/")
echo "=== bodies"
echo "  attach    $A_BODY"
echo "  upstream  $U_BODY"
echo "  fastify   $N_BODY"
for pair in "attach:$A_BODY" "upstream:$U_BODY" "fastify:$N_BODY"; do
    if ! printf '%s' "${pair#*:}" | grep -q '"hello"'; then
        echo "REFUSING TO MEASURE: ${pair%%:*} is not serving the page -- a dead backend answers"
        echo "faster than a live one, so a timing here would be meaningless or backwards."
        kill $VOL_A $VOL_U $ORIGIN $SUP_A 2>/dev/null
        pkill -f "supervisor.php unix:$AT/relay" 2>/dev/null
        exit 1
    fi
done

# ---- measure ----------------------------------------------------------------
# `arm|port|pids-to-charge|label`
measure() {
    local port=$1 label=$2; shift 2
    local c0 c1
    c0=$(ns_of "$@")
    wrk -t"$CORES" -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:$port/" >"$ROOT/.probe/ta-$label.txt" 2>&1
    c1=$(ns_of "$@")
    local f="$ROOT/.probe/ta-$label.txt"
    local rps=$(awk '/^Requests\/sec:/{print $2}' "$f")
    local total=$(awk '/requests in /{print $1}' "$f")
    local p50=$(awk '/^ +50%/{print $2}' "$f")
    local bad=$(awk -F: '/Non-2xx/{gsub(/ /,"",$2); print $2+0}' "$f")
    awk -v t="$label" -v r="${rps:-0}" -v p="$p50" -v d="$((c1-c0))" -v n="${total:-1}" \
        -v s="$SECS" -v bad="${bad:-0}" \
        'BEGIN{ printf "  %-10s %8.0f rps  p50 %-9s fe %.2f cores  %6.1f us/req%s\n",
                 t, r, p, d/1e9/s, d/1e3/n, (bad>0 ? "  <<< NON-2xx: " bad : "") }'
}

for round in 1 2; do
    echo "--- round $round"
    if [ $(( round % 2 )) -eq 1 ]; then
        measure "$PORT_A" "attach-r$round" "$VOL_A"
        measure "$PORT_U" "upstream-r$round" "$VOL_U" "$ORIGIN"
    else
        measure "$PORT_U" "upstream-r$round" "$VOL_U" "$ORIGIN"
        measure "$PORT_A" "attach-r$round" "$VOL_A"
    fi
done

kill -TERM $VOL_A $VOL_U $ORIGIN 2>/dev/null; sleep 1
kill -9 $VOL_A $VOL_U $ORIGIN 2>/dev/null
kill -TERM $SUP_A 2>/dev/null; sleep 0.5; kill -9 $SUP_A 2>/dev/null
pkill -f "supervisor.php unix:$AT/relay" 2>/dev/null
pkill -f "fastify-hello.js --port $ORIGIN_PORT" 2>/dev/null
echo "--- out: $ROOT/.probe/ta-*.txt"
