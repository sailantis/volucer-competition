#!/usr/bin/env bash
# Does `idle_ping_ms` rescue a worker that reads a read deadline as a close?
#
# # The pair, and why both arms are necessary
#
# A worker that treats an empty read as end-of-file ends itself when its read deadline lands on an
# idle connection. The current SDK does not do that any more, so a pool with no keepalive loses
# nothing and the feature has nothing to prove. `apps/hello/vulcan-worker.php` is the case that
# remains: a worker that advertises `answers_ping` and has not fixed its read loop.
#
# So the arms are:
#
#   no-keepalive   the vulnerable worker, default deadline, no pings   -> should lose every slot
#   keepalive      the same worker, same deadline, `idle_ping_ms` set  -> should lose none
#
# Same binary, same worker, same deadline, one config line different. That is the whole measurement.
#
#   verify-keepalive-rescue.sh [idle-seconds]
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=${BIN:-$HOME/hello-bench/bin/volucer-keepalive}
IDLE=${1:-12}
D=${D:-$HOME/keepalive-rescue}
PORT=${PORT:-22976}
WORKERS=${WORKERS:-8}

# The deadline, well below the idle window on purpose: a worker with no keepalive must hit it.
PHP_TIMEOUT=${PHP_TIMEOUT:-3}
# A third of the deadline, so a ping lands inside every window rather than racing it.
PING_MS=${PING_MS:-1000}

rm -rf "$D"; mkdir -p "$D"

cleanup() {
    pkill -x volucer 2>/dev/null
    pkill -f "$D/.*/relay" 2>/dev/null
    sleep 0.5
    pkill -9 -x volucer 2>/dev/null
    pkill -9 -f "$D/.*/relay" 2>/dev/null
}
trap cleanup EXIT INT TERM

# Children of one arm's supervisor, identified by that arm's own relay path — so the two arms can
# never count each other's processes.
children() { pgrep -f "vulcan-worker.php" 2>/dev/null | xargs -r -n1 sh -c \
    'tr "\0" "\n" < /proc/$0/environ 2>/dev/null | grep -qx "VOLUCER_WORKER_SOCKET=unix:'"$1"'/relay"' \
    2>/dev/null; }

run_arm() {
    local label="$1" ping="$2" dir="$D/$1"
    mkdir -p "$dir"

    for _ in $(seq 1 400); do [ -S "$dir/relay" ] && break; sleep 0.02; done

    sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$REPO|g" -e "s|{{WORKERS}}|$WORKERS|g" \
        -e "s|{{SOCKET_DIR}}|$dir|g" "$REPO/conf/hello-attach.toml.template" >"$dir/cfg.toml"
    # The arm under test is a `worker` pool driving the vulnerable fixture over a socket, because
    # `attach` needs a supervisor and the fixture *is* the worker. `spawn_cgi` is not involved: the
    # server-side keepalive is above the transport.
    cat >"$dir/cfg.toml" <<TOML
[server]
http = "127.0.0.1:$PORT"
default_backend = "app"

[server.static_files]
enabled = false

[backends.app]
kind = "worker"
command = "php -d default_socket_timeout=$PHP_TIMEOUT $REPO/apps/hello/vulcan-worker.php"
workers = $WORKERS
max_requests = 0
transport = "socket"
socket = "unix:$dir/worker"
TOML
    if [ "$ping" != "0" ]; then
        printf 'idle_ping_ms = %s\n' "$ping" >>"$dir/cfg.toml"
    fi

    "$BIN" serve -c "$dir/cfg.toml" >"$dir/volucer.log" 2>&1 &
    local vol=$!
    for _ in $(seq 1 600); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.05; done

    wrk -t4 -c16 -d3s "http://127.0.0.1:$PORT/" >"$dir/warm.txt" 2>&1

    local before after replaced serves
    before=$(pgrep -f "vulcan-worker.php" 2>/dev/null | wc -l)
    sleep "$IDLE"
    after=$(pgrep -f "vulcan-worker.php" 2>/dev/null | wc -l)
    replaced=$(grep -ac 'a worker died\|did not complete' "$dir/volucer.log" 2>/dev/null || true)
    replaced=${replaced:-0}

    serves=no
    if curl -sf -m 5 -o /dev/null "http://127.0.0.1:$PORT/"; then serves=yes; fi

    printf '%-14s children %2s -> %-2s   replacements %-3s   serves after idle: %s\n' \
        "$label" "$before" "$after" "$replaced" "$serves"

    kill -TERM "$vol" 2>/dev/null
    sleep 1
    kill -9 "$vol" 2>/dev/null
    pkill -f "$dir/worker" 2>/dev/null
    pkill -f "vulcan-worker.php" 2>/dev/null
    sleep 0.5
}

echo "=== worker -> vulcan-worker.php, $WORKERS slots, read deadline ${PHP_TIMEOUT}s, idle ${IDLE}s"
echo "    the vulnerable fixture ends on an idle deadline; the keepalive should prevent that"
run_arm "no-keepalive" 0
run_arm "keepalive-${PING_MS}ms" "$PING_MS"
echo "--- logs: $D"
