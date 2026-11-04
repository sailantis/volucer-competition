#!/usr/bin/env bash
# End-to-end check of the SDK read-deadline fix, in the configuration that reproduced the
# 96-child mass death: one `attach` arm, 96 forked children behind a unix relay, warmed, then
# left idle past PHP's `default_socket_timeout`.
#
#   ./scripts/verify-idle-fix.sh [idle-seconds]
#
# Before the fix, every child exits at t+59 s and the server replaces all 96 on the next
# request. After it, nothing happens: the children sit in their read loop and answer normally.
#
# The supervisor's timeout is left at the host default (60 s) on purpose. Setting `-1` also
# works, and is measured, but the point of the SDK change is that a deployment does not have to
# know about the knob.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=${BIN:-$HOME/hello-bench/bin/volucer-repro}
IDLE=${1:-100}
D=${D:-$HOME/idle-e2e}
PORT=${PORT:-22980}
PHP_TIMEOUT=${PHP_TIMEOUT:-60}

rm -rf "$D"; mkdir -p "$D"
pkill -f "$D/relay" 2>/dev/null
sleep 1

php -d default_socket_timeout="$PHP_TIMEOUT" \
    -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 -d opcache.jit=off \
    -d xdebug.mode=off -d memory_limit=512M \
    "$REPO/apps/hello/supervisor.php" "unix:$D/relay" >"$D/sup.log" 2>&1 &
SUP=$!

cleanup() {
    kill -TERM "$VOL" "$SUP" 2>/dev/null
    sleep 1
    kill -9 "$VOL" "$SUP" 2>/dev/null
    pkill -f "$D/relay" 2>/dev/null
}
VOL=""
trap cleanup EXIT INT TERM

for _ in $(seq 1 400); do [ -S "$D/relay" ] && break; sleep 0.05; done

sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$REPO|g" -e "s|{{WORKERS}}|96|g" \
    -e "s|{{SOCKET_DIR}}|$D|g" "$REPO/conf/hello-attach.toml.template" >"$D/cfg.toml"
"$BIN" serve -c "$D/cfg.toml" >"$D/volucer.log" 2>&1 &
VOL=$!

for _ in $(seq 1 600); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.05; done
wrk -t12 -c100 -d8s "http://127.0.0.1:$PORT/" >"$D/warm.txt" 2>&1

children() { pgrep -f "supervisor.php unix:$D/relay" 2>/dev/null | grep -vx "$SUP"; }
replacements() { grep -ac 'did not complete' "$D/volucer.log" 2>/dev/null | head -1; }

echo "=== idle start $(date -u +%H:%M:%S)  children=$(children | wc -l)  timeout=${PHP_TIMEOUT}s"
for i in $(seq 1 "$IDLE"); do
    kids=$(children | wc -l)
    reps=$(replacements); reps=${reps:-0}
    printf '%s t+%3ds children=%-4s replacements=%s\n' "$(date -u +%H:%M:%S)" "$i" "$kids" "$reps"
    if [ "$reps" -gt 0 ]; then
        echo "=== MASS DEATH at $(date -u +%H:%M:%S), after ~$i s idle"
        break
    fi
    sleep 1
done

echo "--- reloading after the idle window"
wrk -t12 -c100 -d8s "http://127.0.0.1:$PORT/" >"$D/again.txt" 2>&1
sleep 1

echo "=== result"
printf '  children:      %s\n' "$(children | wc -l)"
printf '  replacements:  %s\n' "$(replacements)"
printf '  rps before:    %s\n' "$(awk '/Requests\/sec:/{print $2}' "$D/warm.txt")"
printf '  rps after:     %s\n' "$(awk '/Requests\/sec:/{print $2}' "$D/again.txt")"
printf '  non-2xx:       %s\n' "$(awk -F: '/Non-2xx/{gsub(/ /,"",$2); print $2+0}' "$D/again.txt")"
printf '  detail:        %s\n' "$D"
