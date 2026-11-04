#!/usr/bin/env bash
# The same idle-gap check as `verify-idle-fix.sh`, against the `worker_socket` transport.
#
#   ./scripts/verify-idle-worker-socket.sh [idle-seconds]
#
# Both arms are reachable by PHP's `default_socket_timeout`, because both hand the worker a unix
# socket: `attach` through its relay, `worker_socket` through `socket = "unix:..."`. A *pipe*
# worker is structurally immune — pipes have no stream timeout — which is the second, independent
# reason `pipe` remains the safer default beyond the ~4.5 µs it costs.
#
# Phase 25 added the awaited exchange for this transport and Phase 27 fixed the SDK read deadline;
# neither had been verified end to end on it. Before those, this script reproduced the same mass
# death as `attach`: every child gone 60 s after its last request, replaced on the next one.
#
# The worker wrapper is not optional. `attach` inherits its ini from the supervisor's command
# line, so an unwrapped `worker` arm would silently run with the host's CLI defaults — a different
# measurement rather than a different server. That is hazard 28 in the README.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=${BIN:-$HOME/hello-bench/bin/volucer-repro}
IDLE=${1:-105}
D=${D:-$HOME/idle-ws}
PORT=${PORT:-22985}
PHP_TIMEOUT=${PHP_TIMEOUT:-60}

rm -rf "$D"; mkdir -p "$D"

# Anchored on the probe directory, so it can only reach processes this run started. The socket
# path is the shared resource: a supervisor left holding it makes the next run's listener fail,
# and the new children then speak to the *old* one — which reads as an SDK bug and is not.
cleanup() {
    pkill -x volucer 2>/dev/null
    sleep 1
    pkill -9 -f "$D" 2>/dev/null
    sleep 1
}
cleanup

WRAP="$D/phpwrap"
cat > "$WRAP" <<EOF
#!/usr/bin/env bash
exec php -d default_socket_timeout=$PHP_TIMEOUT \
    -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 -d opcache.jit=off \
    -d xdebug.mode=off "\$@"
EOF
chmod +x "$WRAP"

sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$REPO|g" -e "s|{{WORKERS}}|96|g" \
    -e "s|{{SOCKET_DIR}}|$D|g" -e "s|{{PHP}}|$WRAP|g" \
    "$REPO/conf/hello-worker-socket.toml.template" >"$D/cfg.toml"

"$BIN" serve -c "$D/cfg.toml" >"$D/volucer.log" 2>&1 &
VOL=$!
trap cleanup EXIT INT TERM

for _ in $(seq 1 600); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.05; done

kids() { pgrep -cf "apps/hello/worker.php" 2>/dev/null; }
replacements() { grep -ac 'replacing' "$D/volucer.log" 2>/dev/null | head -1; }
body() { curl -s --max-time 5 "http://127.0.0.1:$PORT/"; }

rps() { wrk -t12 -c100 -d8s "http://127.0.0.1:$PORT/" 2>/dev/null | grep -oP 'Requests/sec:\s+\K[\d.]+'; }

wrk -t12 -c100 -d8s "http://127.0.0.1:$PORT/" >"$D/warm.txt" 2>&1   # discarded warm-up
BEFORE=$(rps)
BEFORE_BODY=$(body)

echo "=== idle start $(date -u +%H:%M:%S)  children=$(kids)  timeout=${PHP_TIMEOUT}s"
for i in $(seq 1 "$IDLE"); do
    printf '%s t+%3ds children=%-4s replacements=%s\n' \
        "$(date -u +%H:%M:%S)" "$i" "$(kids)" "$(replacements)"
    sleep 1
done

AFTER=$(rps)
AFTER_BODY=$(body)

echo "=== result"
printf '  children:      %s\n' "$(kids)"
printf '  replacements:  %s\n' "$(replacements)"
printf '  warnings:      %s\n' "$(grep -ac 'WARN' "$D/volucer.log")"
printf '  rps before:    %s\n' "$BEFORE"
printf '  rps after:     %s\n' "$AFTER"
printf '  body before:   %s\n' "$BEFORE_BODY"
printf '  body after:    %s\n' "$AFTER_BODY"
printf '  detail:        %s\n' "$D"

# A run that lost its pool can still print a healthy rps after the rebuild, so the verdict is the
# child count and the replacement count, never the throughput.
if [ "$(replacements)" = "0" ] && [ "$BEFORE_BODY" = '{"hello":"world"}' ] \
    && [ "$AFTER_BODY" = '{"hello":"world"}' ]; then
    echo "  verdict:       PASS — the pool survived the gap"
else
    echo "  verdict:       FAIL — the pool did not survive the gap"
    exit 1
fi
