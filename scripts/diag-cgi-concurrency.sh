#!/bin/bash
# Does one `php-cgi -b` serve a second connection while the first is idle?
#
# The question decides whether a `spawn_cgi` backend could ever have a supervisor in the
# shape `attach` uses - one PHP master, N forked children, one shared listener - or whether
# it must stay what it is: N independent processes on N ports, each with its own connection.
#
# Why the window is wide: the first version of this probe used a 6 s hold and a 5 s
# timeout, and php-cgi answered at 4.9 s. That reads as "concurrent" but proves nothing,
# because a server that *queues* the second connection in its backlog answers the moment
# the first one goes away - and the answer arrived just before the holder left. So the
# hold is long, the timeout is longer, and the interesting number is *which pid* answered:
# the same pid as the lone request means one process served both connections, and the time
# it took says whether that was concurrency or a queue.
#
# The request goes through `cgi-fcgi`, which ships with php-cgi. Hand-rolled framing
# produced connection resets against the same server cgi-fcgi talks to happily, so the
# probe uses the client that ships with the thing it is probing. Its output is CRLF, which
# is why every parse here strips \r first: `sed '/^$/,$p'` silently matches nothing on
# "Content-type: ...\r\n\r\n".
#
# `PHP_FCGI_CHILDREN` is varied as well, because it is the flag that looks like it answers
# the question. On Linux it does not: `sapi/cgi/cgi_main.c` reads it under `#ifdef
# PHP_WIN32`, so it is accepted and ignored - which is what the two blocks below show.
#
# Usage:
#   bash scripts/diag-cgi-concurrency.sh
#   PHP_CGI=/usr/bin/php-cgi8.3 bash scripts/diag-cgi-concurrency.sh
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHP_CGI="${PHP_CGI:-$(command -v php-cgi8.5 || command -v php-cgi || true)}"
PORT="${PORT:-19880}"
HOLD="${HOLD:-20}"
WINDOW="${WINDOW:-30}"
D="$(mktemp -d /tmp/diag-cgi.XXXXXX)"

fail() { echo "FATAL: $*" >&2; exit 1; }

cleanup() {
    [ -n "${CGI:-}" ] && kill -KILL "$CGI" 2>/dev/null
    [ -n "${HOLDER:-}" ] && kill -KILL "$HOLDER" 2>/dev/null
    [ -n "${HOLDER2:-}" ] && kill -KILL "$HOLDER2" 2>/dev/null
    rm -rf "$D"
}
trap cleanup EXIT

[ -n "$PHP_CGI" ] || fail "no php-cgi on PATH (set PHP_CGI)"
[ -x "$PHP_CGI" ] || fail "$PHP_CGI is not executable"
command -v cgi-fcgi >/dev/null 2>&1 || fail "no cgi-fcgi (it ships with php-cgi)"
[ -f "$SCRIPT_DIR/fcgi-hold.py" ] || fail "missing $SCRIPT_DIR/fcgi-hold.py"

cat > "$D/probe.php" <<'PHP'
<?php

echo 'served-by-' . getmypid();
PHP

# One request, printing only the body.
fcgi_body() {
    SCRIPT_FILENAME="$D/probe.php" REQUEST_METHOD=GET QUERY_STRING= \
    REQUEST_URI=/probe.php SERVER_PROTOCOL=HTTP/1.1 \
        cgi-fcgi -bind -connect "127.0.0.1:$PORT" 2>&1 | tr -d '\r' | sed -n '/^$/,$p' | tail -n +2
}

start_cgi() {
    # A php-cgi left behind by an earlier run keeps the port bound, so a fresh one dies
    # with "Address already in use" while a readiness probe happily connects to the stale
    # listener and measures a process it never started.
    pkill -KILL -f "$PHP_CGI -b 127.0.0.1:$PORT" 2>/dev/null
    sleep 0.3

    env PHP_FCGI_CHILDREN="${CHILDREN:-0}" "$PHP_CGI" -b "127.0.0.1:$PORT" >"$D/cgi.log" 2>&1 &
    CGI=$!
    for _ in $(seq 1 80); do
        kill -0 "$CGI" 2>/dev/null || break
        (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && return 0
        sleep 0.1
    done
    sed 's/^/    /' "$D/cgi.log"
    return 1
}

echo "=== one php-cgi, idle connections, and a request: $("$PHP_CGI" -v | head -1) ==="
echo "    hold ${HOLD}s, window ${WINDOW}s"
echo

for children in 0 4; do
    echo "--- PHP_FCGI_CHILDREN=$children ---"
    CHILDREN=$children start_cgi || fail "php-cgi did not bind 127.0.0.1:$PORT"

    # The baseline: no other connection open, so this is the pid of the process that
    # serves requests when nothing is in the way.
    lone="$(fcgi_body)"
    case "$lone" in
        served-by-*) echo "  lone request:        $lone" ;;
        *) echo "  lone request did not answer; raw: ${lone:-<empty>}"; fail "probe broken" ;;
    esac

    # Two idle connections, because one is not always enough to block a backlog of 128 and
    # the question is about a pool of slots, not one slot.
    python3 "$SCRIPT_DIR/fcgi-hold.py" "$PORT" "$HOLD" >"$D/hold1.out" 2>&1 &
    HOLDER=$!
    for _ in $(seq 1 60); do grep -q holding "$D/hold1.out" 2>/dev/null && break; sleep 0.1; done
    python3 "$SCRIPT_DIR/fcgi-hold.py" "$PORT" "$HOLD" >"$D/hold2.out" 2>&1 &
    HOLDER2=$!
    for _ in $(seq 1 60); do grep -q holding "$D/hold2.out" 2>/dev/null && break; sleep 0.1; done
    # Let php-cgi reach its accept loop with both connections pending.
    sleep 1

    started=$(date +%s%N)
    reply="$(timeout "$WINDOW" env SCRIPT_FILENAME="$D/probe.php" REQUEST_METHOD=GET \
        QUERY_STRING= REQUEST_URI=/probe.php SERVER_PROTOCOL=HTTP/1.1 \
        cgi-fcgi -bind -connect "127.0.0.1:$PORT" 2>&1 | tr -d '\r' | sed -n '/^$/,$p' | tail -n +2)"
    elapsed=$(( ($(date +%s%N) - started) / 1000000 ))

    case "$reply" in
        served-by-*)
            pid="${reply#served-by-}"
            if [ "$elapsed" -lt 1000 ]; then
                verdict="concurrent"
            else
                verdict="queued"
            fi
            echo "  with 2 idle open:    $reply after ${elapsed} ms  -> $verdict"
            if [ "$pid" = "${lone#served-by-}" ]; then
                echo "  the same process served both, so there is exactly one worker"
            else
                echo "  a different process served it, so php-cgi fanned out"
            fi
            ;;
        *)
            echo "  with 2 idle open:    no answer within ${WINDOW}s -> serial"
            ;;
    esac

    kill -KILL "$HOLDER" "$HOLDER2" 2>/dev/null
    wait "$HOLDER" "$HOLDER2" 2>/dev/null
    HOLDER=""; HOLDER2=""

    echo "  php-cgi processes on the port: $(pgrep -cf "$PHP_CGI -b 127.0.0.1:$PORT" 2>/dev/null || true)"
    kill -KILL "$CGI" 2>/dev/null
    wait "$CGI" 2>/dev/null
    CGI=""
    sleep 0.5
    echo
done
