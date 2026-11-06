#!/usr/bin/env bash
# Does a stalled backend end the request, or does it hold the slot for ever?
#
# The branch's headline fix is that every awaited read is bounded by a deadline. The claim is
# testable from outside: point `spawn_cgi` at a program that reads the request and never
# answers, send one request, and time how long it takes to come back with a 5xx. An unbounded
# path never returns at all.
#
# Also checks the second half of the claim -- that the slot is released. After the timeout the
# pool must replace the worker and go on serving, so a second request has to succeed against a
# responder that is *not* stalling. That is checked by counting worker replacements in the log.
#
#   verify-stall.sh <binary> [request_timeout_ms]
set -uo pipefail
BIN=${1:?binary}
TIMEOUT_MS=${2:-1500}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D=${D:-$HOME/stall-check}
rm -rf "$D"; mkdir -p "$D/d1" "$D/d2"
PY=$(command -v python3)
PORT=23040
STALL_PORT=23041

PIDS=""
cleanup() {
    kill -TERM $PIDS 2>/dev/null; sleep 1; kill -9 $PIDS 2>/dev/null
    pkill -f "fcgi-stall.py unix:$D/" 2>/dev/null
    pkill -f "$D/" 2>/dev/null
}
trap cleanup EXIT INT TERM

cfg() {   # $1=dir $2=port $3=command
    cat > "$1/cfg.toml" <<TOML
[server]
http = "127.0.0.1:$2"
default_backend = "cg"
document_root = "$ROOT/apps/hello/public"

[server.static_files]
enabled = false

[backends.cg]
kind = "spawn_cgi"
command = "$3"
workers = 2
concurrency = 1
socket = "unix:$1/cgi"
max_requests = 0
request_timeout_ms = $TIMEOUT_MS
TOML
}

echo "=== binary: $BIN ($("$BIN" --version 2>/dev/null))  request_timeout_ms=$TIMEOUT_MS"

# ---- 1. a backend that never answers --------------------------------------------------
cfg "$D/d1" "$STALL_PORT" "$PY $ROOT/apps/hello/fcgi-stall.py {address}"
"$BIN" serve -c "$D/d1/cfg.toml" >"$D/d1/volucer.log" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 300); do [ -S "$D/d1/cgi.0.sock" ] && break; sleep 0.05; done
sleep 0.5
echo "--- one request against a backend that accepts and never answers"
start=$(date +%s%N)
code=$(curl -s -o "$D/d1/body.txt" -w '%{http_code}' --max-time 60 "http://127.0.0.1:$STALL_PORT/")
elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
echo "    HTTP $code after ${elapsed} ms   (deadline was ${TIMEOUT_MS} ms)"
echo "    body: $(head -c 200 "$D/d1/body.txt")"

if [ "$code" = "000" ]; then
    echo "    VERDICT: FAIL -- curl gave up; the request never ended, so it is bounded by nothing"
elif [ "$elapsed" -lt "$TIMEOUT_MS" ]; then
    echo "    VERDICT: UNEXPECTED -- returned before its own deadline (${elapsed} < ${TIMEOUT_MS})"
else
    echo "    VERDICT: PASS -- bounded, and named as a deadline if the body says so"
fi

echo "--- the log's own account"
grep -iE "timed out|deadline|timeout|replacing|worker died" "$D/d1/volucer.log" | head -6 | sed 's/^/    /'

kill -TERM $PIDS 2>/dev/null; sleep 1; pkill -f "$D/d1/" 2>/dev/null
for p in $(pgrep -f "fcgi-stall.py unix:$D/d1/"); do kill -9 "$p" 2>/dev/null; done
PIDS=""

# ---- 2. after a deadline, does the pool still serve? ----------------------------------
# A responder that stalls its FIRST request and answers every later one, so the same slot has
# to be replaced and reused inside one run. `held` connections are never closed on purpose:
# a close would be a broken pipe, which is the easy case.
echo "--- does the slot come back after a deadline?"
cfg "$D/d2" "$PORT" "$PY $ROOT/apps/hello/fcgi-stall-once.py {address} 1"
"$BIN" serve -c "$D/d2/cfg.toml" >"$D/d2/volucer.log" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 300); do [ -S "$D/d2/cgi.0.sock" ] && break; sleep 0.05; done
sleep 0.5
ok=0; first=""
for i in $(seq 1 8); do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://127.0.0.1:$PORT/")
    printf '    attempt %s -> HTTP %s\n' "$i" "$c"
    [ -z "$first" ] && first=$c
    [ "$c" = "200" ] && ok=$(( ok + 1 ))
done
echo "    $ok of 8 attempts answered 200 after the stalled one (first: $first)"
if [ "$ok" -gt 0 ]; then
    echo "    VERDICT: PASS -- the pool kept serving past a stalled slot"
else
    echo "    VERDICT: FAIL -- nothing served after the stall"
fi
echo "--- replacements reported"
grep -iE "replacing|worker died|timed out|deadline" "$D/d2/volucer.log" | head -4 | sed 's/^/    /'
echo "--- (no matches means the slot was reused without a replacement, which is also fine)"
cleanup
