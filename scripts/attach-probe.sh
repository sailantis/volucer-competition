#!/usr/bin/env bash
# Probe the `attach` arm on its own, without the full matrix.
#
# Every cell starts the supervisor and the front-end fresh, runs one wrk pass, then stops
# both gracefully so volucer prints its own contention line. That line is a measurement the
# analysis is built on, so it is captured per cell rather than once at the end of a sweep.
#
#   attach-probe.sh <binary> <workers> <concurrency> <seconds> <tag> [extra.toml]
#
# `extra.toml` is appended to the generated configuration, so one variable can be changed
# without a second copy of this script — the route-skip experiment appends a
# `[[server.routes]]` entry and measures the same binary against the same relay.
#
# Environment knobs, each of which exists because a question needed it:
#   PERF=1         record a perf call graph from the middle of the run
#   FE_TASKSET=…   pin the front-end (e.g. `0-7`)
#   PHP_TASKSET=…  pin the supervisor, inherited by every child it forks
#
# The wrk thread count is the core count, not the connection count. `-t<c>` puts one
# load-generator thread per connection, which at `c=400` is 138% oversubscription on a
# 12-core host and biases every CPU figure against whichever server schedules more threads.
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
LOG="$OUT/volucer.log"
SUP="$OUT/sup.log"

rm -rf "$OUT"
mkdir -p "$OUT"

PHP_ARGS=(-d opcache.enable_cli=1 -d opcache.validate_timestamps=0
          -d opcache.jit=off -d xdebug.mode=off -d memory_limit=512M)

sed -e "s|{{PORT}}|$PORT|g" \
    -e "s|{{ROOT}}|$ROOT|g" \
    -e "s|{{WORKERS}}|$WORKERS|g" \
    -e "s|{{SOCKET_DIR}}|$OUT|g" \
    "$ROOT/conf/hello-attach.toml.template" > "$OUT/attach.toml"

if [ -n "$EXTRA" ]; then
    printf '\n' >> "$OUT/attach.toml"
    cat "$EXTRA" >> "$OUT/attach.toml"
fi

php "${PHP_ARGS[@]}" "$ROOT/apps/hello/supervisor.php" "unix:$SOCK" >"$SUP" 2>&1 &
SUP_PID=$!
# Pinning is a probe, not a deployment tweak: the point is to tell contention between
# the two thread populations apart from per-request cost. `taskset -ap` after the fact
# would miss the children the supervisor forks on connect, so the affinity is set on the
# supervisor and inherited by every fork.
if [ -n "${PHP_TASKSET:-}" ]; then
    taskset -apc "$PHP_TASKSET" $SUP_PID >/dev/null 2>&1
fi

for _ in $(seq 1 100); do
    [ -S "$SOCK" ] && break
    sleep 0.05
done
[ -S "$SOCK" ] || { echo "supervisor never listened"; cat "$SUP"; kill $SUP_PID 2>/dev/null; exit 1; }

"$BIN" serve -c "$OUT/attach.toml" >"$LOG" 2>&1 &
VOL_PID=$!
if [ -n "${FE_TASKSET:-}" ]; then
    taskset -apc "$FE_TASKSET" $VOL_PID >/dev/null 2>&1
fi

for _ in $(seq 1 200); do
    curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break
    sleep 0.05
done

CORES=$(nproc)

# CPU is sampled from schedstat field 1 (nanoseconds), because /proc/<pid>/stat is
# 10 ms-granular at CLK_TCK=100 — too coarse to divide by a request count.
#
# `sum` over every task in the process, not /proc/<pid>/schedstat: that file reports
# the thread-group *leader* only, so reading it for volucer measures the main thread
# and reports ~0 cores while eleven runtime threads are busy.
#
# wrk runs in the background so its threads exist while it is sampled. It must be matched
# with `pgrep -x wrk`, not on a path: `argv[0]` is `wrk`, so a pattern like
# `-f "^$(command -v wrk)"` matches nothing and every "wrk CPU" figure silently reads 0.
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
wrk_pids() { pgrep -x wrk 2>/dev/null; }
php_pids() { pgrep -f "supervisor.php unix:$SOCK" 2>/dev/null; }

wrk -t"$CORES" -c"$CONC" -d"$SECS"s --latency "http://127.0.0.1:$PORT/" >"$OUT/wrk.txt" 2>&1 &
WRK_PID=$!
sleep 2

cpu0=$(ns_of "$VOL_PID")
php0=$(ns_of $(php_pids))
# The PID from `$!`, not a `pgrep`: a name lookup can land on a recycled PID or miss
# the process entirely, and one earlier run reported the generator's CPU as negative.
wrk0=$(ns_of "$WRK_PID")

# wrk exits when its own timer expires, so its threads are gone by the time `wait`
# returns. Sample it near the end but while it still exists: this subshell starts ~2 s
# into the run, so the delay is `SECS - 4` to land at `SECS - 2`. Sleeping `SECS - 2`
# here is a photo finish against wrk's own timer, and it usually loses — which reads as
# "0 cores" rather than as a race.
( sleep $(( SECS > 5 ? SECS - 4 : SECS - 2 )); ns_of "$WRK_PID" >"$OUT/wrk1" ) &
wrk1_bg=$!

# `cpu-clock`, not `cycles`: this host exposes no PMU, so `perf stat -e cycles`
# reports <not supported> and a software event is the only option. Captured from the
# middle of the run, past the connection ramp, so the sample is of steady state.
if [ -n "${PERF:-}" ]; then
    sudo -n perf record -o "$OUT/perf.data" -e cpu-clock -F999 -g -p "$VOL_PID" \
        -- sleep $((SECS - 6)) >/dev/null 2>&1
fi

wait $WRK_PID
W=$?
wait $wrk1_bg 2>/dev/null

cpu1=$(ns_of "$VOL_PID")
php1=$(ns_of $(php_pids))
wrk1=$(cat "$OUT/wrk1" 2>/dev/null || echo 0)

cat "$OUT/wrk.txt"

RPS=$(awk '/^Requests\/sec:/{print $2}' "$OUT/wrk.txt")
TOTAL=$(awk '/requests in /{print $1}' "$OUT/wrk.txt")
cores() { awk -v d="$1" -v s="$SECS" 'BEGIN{printf "%.2f", d/1e9/s}'; }
us_req() { awk -v d="$1" -v n="${TOTAL:-0}" 'BEGIN{ if (n+0>0) printf "%.1f", d/1e3/n; else print "?" }'; }
# wrk is sampled over a shorter window than the server, because its threads do not exist
# before it starts or after it exits. Dividing that delta by the full run would understate
# the generator's share by the ratio of the two windows.
wrk_cores() { awk -v d="$1" -v s="$SECS" 'BEGIN{ w = (s > 5 ? s - 4 : 2); printf "%.2f", d/1e9/ (w > 0 ? w : 1) }'; }

echo "--- cpu (over ${SECS}s, ${TOTAL:-?} requests, ${RPS:-?} rps)"
echo "front-end  $(cores $((cpu1-cpu0))) cores  $(us_req $((cpu1-cpu0))) us/req"
echo "php        $(cores $((php1-php0))) cores  $(us_req $((php1-php0))) us/req"
echo "wrk        $(wrk_cores $((wrk1-wrk0))) cores"

# Graceful stop, so the pool prints its contention summary.
kill -TERM $VOL_PID 2>/dev/null
for _ in $(seq 1 200); do kill -0 $VOL_PID 2>/dev/null || break; sleep 0.05; done
kill -9 $VOL_PID 2>/dev/null

kill -TERM $SUP_PID 2>/dev/null
for _ in $(seq 1 100); do kill -0 $SUP_PID 2>/dev/null || break; sleep 0.05; done
kill -9 $SUP_PID 2>/dev/null
pkill -f "supervisor.php unix:$SOCK" 2>/dev/null

echo "--- slots"
grep '^slots:' "$LOG" || echo "(no contention line; check $LOG)"
echo "--- out: $OUT"
exit $W
