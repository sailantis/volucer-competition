#!/usr/bin/env bash
# Price the exchange-thread boundary against the real worker protocol.
#
# Starts the hello arm's own PHP supervisor on a unix relay, then runs the probe's three
# arms against it — `sync-pool`, `handoff`, `async` — each with the same number of
# connections and the same number of round trips. The arms differ only in where the wait
# happens, so the two differences decompose the cost:
#
#   handoff - sync-pool   the thread boundary (two wakeups + a second thread's scheduling)
#   async   - sync-pool   epoll versus blocking I/O
#   handoff - async       what an async client would buy the front-end
#
# Every cell re-runs the arms in a rotated order and reports the mean, because the first
# run on a cold host is systematically slower and a single pass cannot tell that from a
# real difference. The rotation is printed so the order is auditable.
#
#   fcgi-async-run.sh <rounds> <connections> [rounds-per-connection]
#
# Knobs:
#   PROBE=path      the probe binary (default: the checkout's release build)
#   SECS=…          unused; the work is counted in requests, not seconds
#   PIN=…           taskset mask for the supervisor, so PHP cannot drift across cores
set -uo pipefail

ROUNDS=${1:-3}
CONNECTIONS=${2:-12}
PER_CONN=${3:-20000}

BENCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The probe is built from the same checkout it measures, so a change to the protocol is
# measured rather than remembered.
PROBE=${PROBE:-$HOME/volucer-bench/target/release/fcgi-async-probe}
OUT="$BENCH/.probe/async-client"
SOCK="$OUT/relay"
SUP="$OUT/supervisor.log"

rm -rf "$OUT"
mkdir -p "$OUT"

if [ ! -x "$PROBE" ]; then
    echo "no probe at $PROBE — build it with:" >&2
    echo "  cd ~/volucer-bench && cargo build --release -p volucer-server --bin fcgi-async-probe" >&2
    exit 1
fi

# The same wrapper the attach arm uses, so the interpreter is configured identically and
# the 45 us/request Phase 9 measured for PHP is the same 45 us here.
PHP_ARGS=(-d opcache.enable_cli=1 -d opcache.validate_timestamps=0
          -d opcache.jit=off -d xdebug.mode=off -d memory_limit=512M)

# One child per connection: the supervisor forks on accept, and the probe dials exactly
# `CONNECTIONS` sockets before the first request, so both sides agree by construction.
php "${PHP_ARGS[@]}" "$BENCH/apps/hello/supervisor.php" "unix:$SOCK" >"$SUP" 2>&1 &
SUP_PID=$!
if [ -n "${PIN:-}" ]; then
    taskset -apc "$PIN" $SUP_PID >/dev/null 2>&1
fi

cleanup() {
    kill -TERM $SUP_PID 2>/dev/null
    for _ in $(seq 1 100); do kill -0 $SUP_PID 2>/dev/null || break; sleep 0.05; done
    kill -9 $SUP_PID 2>/dev/null
    pkill -f "supervisor.php unix:$SOCK" 2>/dev/null
}
trap cleanup EXIT

for _ in $(seq 1 200); do
    [ -S "$SOCK" ] && break
    sleep 0.05
done
if [ ! -S "$SOCK" ]; then
    echo "the supervisor never listened; log follows" >&2
    cat "$SUP" >&2
    exit 1
fi

echo "relay     $SOCK"
echo "probe     $PROBE"
echo "shape     $CONNECTIONS connections x $PER_CONN requests = $(( CONNECTIONS * PER_CONN )) each"
echo "rounds    $ROUNDS"
echo

# Rotation, not repetition: on a cold host the first cell of each round is slower, and a fixed
# order would charge that to whichever arm happened to go first. Each round runs the arms in a
# different order and the mean is reported per arm.
#
# Two figures are collected per run. `wall` is throughput; `cpu` is what the design question
# is actually about. They differ because at 12 connections the hand-off arm runs 12 runtime
# threads *plus* 12 exchange threads on 12 cores — so its wall time carries contention the
# async arm does not have, and a wall-only comparison overstates the async win.
ARMS=(handoff async sync-pool)
declare -A W_SUM W_COUNT C_SUM C_COUNT

for r in $(seq 1 "$ROUNDS"); do
    echo "--- round $r"
    for i in 0 1 2; do
        arm=${ARMS[$(( (i + r - 1) % 3 ))]}
        line=$("$PROBE" "$SOCK" "$arm" "$CONNECTIONS" "$PER_CONN" 2>&1)
        echo "$line"
        # Parsed from the probe's own report rather than timed outside it, so connect and
        # handshake stay out of the figure.
        wall=$(printf '%s\n' "$line" | awk '/us\/req/{for(i=1;i<=NF;i++) if($i=="wall") print $(i+1)}')
        cpu=$(printf '%s\n' "$line" | awk '/us\/req/{for(i=1;i<=NF;i++) if($i=="cpu") print $(i+1)}')
        if [ -z "$wall" ] || [ -z "$cpu" ]; then
            echo "  (no figure on that line; not counted)" >&2
            continue
        fi
        W_SUM[$arm]=$(awk -v a="${W_SUM[$arm]:-0}" -v b="$wall" 'BEGIN{print a+b}')
        C_SUM[$arm]=$(awk -v a="${C_SUM[$arm]:-0}" -v b="$cpu" 'BEGIN{print a+b}')
        W_COUNT[$arm]=$(( ${W_COUNT[$arm]:-0} + 1 ))
        C_COUNT[$arm]=$(( ${C_COUNT[$arm]:-0} + 1 ))
    done
    echo
done

echo "=== mean over $ROUNDS rounds"
for arm in handoff async sync-pool; do
    [ -n "${W_COUNT[$arm]:-}" ] || continue
    # Formatted with `awk`, not `printf`: this host's locale is German and `printf %.2f`
    # refuses "38.31" there ("Ungültige Zahl"). The first version of this line silently
    # truncated every figure to its integer part.
    awk -v w="${W_SUM[$arm]}" -v c="${C_SUM[$arm]}" -v n="${W_COUNT[$arm]}" -v arm="$arm" \
        'BEGIN{printf "%-10s  wall %6.2f us/req   cpu %6.2f us/req   (%d runs)\n", arm, w/n, c/n, n}'
done

echo
echo "=== decomposition (cpu per request, the figure that is not confounded by contention)"
# A decomposition computed from a missing arm is worse than no decomposition: it prints a
# number that looks like a measurement. `async - sync-pool = -8.26` was printed once from two
# empty variables and read as "epoll is 8 us faster". Refuse instead.
missing=0
for arm in handoff async sync-pool; do
    if [ -z "${C_COUNT[$arm]:-}" ]; then
        echo "  incomplete: the $arm arm produced no figure, so no decomposition is possible" >&2
        missing=1
    fi
done
if [ "$missing" -eq 0 ]; then
    h=$(awk -v s="${C_SUM[handoff]}" -v n="${C_COUNT[handoff]}" 'BEGIN{print s/n}')
    a=$(awk -v s="${C_SUM[async]}" -v n="${C_COUNT[async]}" 'BEGIN{print s/n}')
    p=$(awk -v s="${C_SUM[sync-pool]}" -v n="${C_COUNT[sync-pool]}" 'BEGIN{print s/n}')
    awk -v h="$h" -v a="$a" -v p="$p" 'BEGIN{
        printf "the thread boundary         handoff - sync-pool = %+.2f us/req\n", h - p
        printf "epoll vs blocking I/O      async   - sync-pool = %+.2f us/req\n", a - p
        printf "what an async client buys  handoff - async     = %+.2f us/req", h - a
        if (h > 0) printf "  (%.0f%% of the handoff arm)", (h - a) / h * 100
        printf "\n"
    }'
fi
echo "=== out: $OUT"
