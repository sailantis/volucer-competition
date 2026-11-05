#!/usr/bin/env bash
# Two questions about the `cgi_prefork` vs `external_fpm` gap, both answered by counting.
#
#   1. How many sockets does each arm's *volucer* actually dial? `ClientPool` retains only
#      `MAX_IDLE_CONNECTIONS = 1` warm connection, so at c=100 nearly every `external` request
#      may be paying a fresh `connect(2)` that the prefork arm does not -- volucer-side cost in
#      the `fe` column, not PHP-side in `be`.
#   2. Does php-fpm's supervision layer explain the `be` difference? `php_admin_value`,
#      `php_admin_flag` and `catch_workers_output` are serviced per request, not per worker,
#      so `FPM_LEAN=1` removes them and the residual is the interpreter.
#
# Usage: probe-connect.sh [secs] [conc]   (arms are left running by arms.sh; this attaches)
set -eu

SECS=${1:-20}
CONC=${2:-100}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=/tmp/probe-connect
rm -rf "$OUT"; mkdir -p "$OUT"

( cd "$ROOT" && ARMS_FILTER="cgi_prefork external_fpm" \
    bash scripts/arms.sh "$SECS" "$CONC" 1 >"$OUT/arms.log" 2>&1 & )

# Land inside the *timed* round, not the warm-up: the warm-up is the same length, so wait for
# it plus a margin. Attaching during startup would count the pool being built.
sleep $(( SECS + 8 ))

vol_of() { pgrep -f "volucer.*$1/cfg.toml" 2>/dev/null | head -1 || true; }

for arm in cgi-prefork external; do
    pid=$(vol_of "$arm")
    if [ -z "$pid" ]; then echo "=== $arm: no volucer process found"; continue; fi
    echo "=== $arm (volucer pid $pid): connect(2) per second"
    # `-f` follows the pool's worker threads; `-c` prints the summary this reads. A short
    # window inside the round is enough -- these are steady-state rates, not bursts.
    # `sudo` is required: `ptrace_scope=1` refuses to attach to a non-descendant otherwise,
    # which is silent -- it prints "ptrace: Operation not permitted" and the summary is empty,
    # which reads exactly like "zero connects" and would have been a wrong answer.
    sudo timeout 5 strace -f -c -e trace=connect -p "$pid" 2>&1 \
        | grep -E 'connect|total|ptrace' || echo "   (no output)"
done

echo
echo "=== arm results"
grep -E 'rps|=== host load' "$OUT/arms.log" || true
