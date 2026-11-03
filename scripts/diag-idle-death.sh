#!/usr/bin/env bash
# Why do all 96 attached workers die together after an idle minute?
#
# The event this investigates is the one every multi-arm run shows and no single-arm run
# does: `attach` loses **every** child at one instant, mid-run, having lost none before it.
# `worker` (pipe) loses none; `worker_socket` loses all 96 the same way. The two arms that
# fail are the two whose protocol runs over a **unix socket**; the arm that does not fail is
# the one whose protocol runs over a **pipe**.
#
# That is the clue. PHP's `default_socket_timeout` (60 s on this host) is a deadline on
# stream reads, and a unix socket is a stream it applies to. The SDK's `readHeader()` is:
#
#     $bytes = stream_get_contents($this->in, Header::HEADER_LEN);
#     if ($bytes === false || $bytes === '') { return null; }   // "clean EOF: break"
#
# so **a timed-out read and a closed peer are the same value**, and both mean "the server
# is done with me, return from run()". A child that idles for longer than the timeout
# therefore exits *silently* -- no exception, no stderr line -- and `volucer` sees only
# that the connection closed.
#
# This script reproduces it in isolation: warm the arm, then idle, sampling the child
# population and the child's own `wchan` once a second. `wchan` is the part that matters,
# because it separates "the child is blocked in a socket read" from "the child is gone":
#
#     sk_wait_data    blocked in recv on the socket      (healthy, waiting for work)
#     do_wait/0       the supervisor's master, no child  (the event)
#
#   diag-idle-death.sh [idle-seconds]
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=${BIN:-$HOME/hello-bench/bin/volucer-repro}
IDLE=${1:-100}
D=${D:-$HOME/idle-death}
PORT=${PORT:-22972}

# PHP's `default_socket_timeout`, in the supervisor that owns the attached children.
#
# The default is the host's (60 s here), and this knob exists to prove what it does: at 60 s
# every child exits after a minute of idleness, and at -1 (no deadline) none of them ever do.
# A deployment that goes quiet for longer than a minute *will* hit this.
PHP_TIMEOUT=${PHP_TIMEOUT:-60}

rm -rf "$D"; mkdir -p "$D"

# Any previous copy of this probe owns the relay, and a second supervisor on one path is
# the failure mode that reads as "No such file or directory" further up the stack.
pkill -f "$D/relay" 2>/dev/null
sleep 1

php -d default_socket_timeout="$PHP_TIMEOUT" \
    -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 -d opcache.jit=off \
    -d xdebug.mode=off -d memory_limit=512M \
    "$REPO/apps/hello/supervisor.php" "unix:$D/relay" >"$D/sup.log" 2>&1 &
SUP=$!
for _ in $(seq 1 400); do [ -S "$D/relay" ] && break; sleep 0.05; done

sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$REPO|g" -e "s|{{WORKERS}}|96|g" \
    -e "s|{{SOCKET_DIR}}|$D|g" "$REPO/conf/hello-attach.toml.template" >"$D/cfg.toml"
"$BIN" serve -c "$D/cfg.toml" >"$D/volucer.log" 2>&1 &
VOL=$!

cleanup() {
    kill -TERM "$VOL" "$SUP" 2>/dev/null
    sleep 1
    kill -9 "$VOL" "$SUP" 2>/dev/null
    pkill -f "$D/relay" 2>/dev/null
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 600); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.05; done

# A real load first: the event happens after the pool has served requests, never before.
wrk -t12 -c100 -d8s "http://127.0.0.1:$PORT/" >"$D/warm.txt" 2>&1

children() { pgrep -f "supervisor.php unix:$D/relay" 2>/dev/null | grep -vx "$SUP"; }

echo "=== idle start $(date -u +%H:%M:%S)  ($(children | wc -l) children)"
for i in $(seq 1 "$IDLE"); do
    kids=$(children | wc -l)
    pid=$(children | head -1)

    if [ -n "$pid" ]; then
        state=$(awk '/^State:/{print $2}' "/proc/$pid/status" 2>/dev/null)
        wchan=$(cat "/proc/$pid/wchan" 2>/dev/null)
    else
        state="-"; wchan="-"
    fi

    warns=$(grep -ac 'did not complete' "$D/volucer.log" 2>/dev/null)
    warns=${warns:-0}
    printf '%s t+%3ds children=%-4s first=%-8s state=%-2s wchan=%-14s warns=%s\n' \
        "$(date -u +%H:%M:%S)" "$i" "$kids" "${pid:--}" "$state" "$wchan" "$warns"

    if [ "$warns" -gt 0 ]; then
        echo "=== FIRST WARNING at $(date -u +%H:%M:%S), after ~$i s idle"
        break
    fi
    sleep 1
done

echo "--- reloading"
wrk -t12 -c100 -d6s "http://127.0.0.1:$PORT/" >"$D/again.txt" 2>&1

echo "=== result"
printf '  children at end:   %s\n' "$(children | wc -l)"
replacements=$(grep -ac 'did not complete' "$D/volucer.log" 2>/dev/null)
printf '  replacements:      %s\n' "${replacements:-0}"
printf '  socket timeout:    %ss (PHP_TIMEOUT)\n' "$PHP_TIMEOUT"
printf '  rps before idle:   %s\n' "$(awk '/Requests\/sec:/{print $2}' "$D/warm.txt")"
printf '  rps after idle:    %s\n' "$(awk '/Requests\/sec:/{print $2}' "$D/again.txt")"
printf '  detail:            %s\n' "$D"
