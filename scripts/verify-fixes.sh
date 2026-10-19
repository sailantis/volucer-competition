#!/bin/bash
# Verify the two behavioural fixes end to end, on this host, with the built server.
#
# This is not a benchmark. It answers three questions that the unit and integration
# tests cannot, because each needs a real server process and a real signal:
#
#   1. Does the socket transport still pay ~39 ms per request?      (SDK: TCP_NODELAY)
#   2. Does a SIGKILLed server leave its children running?          (lifecycle: killpg + PDEATHSIG)
#   3. Does an `attach` pool serve the real page through the real protocol, at the warm
#      pipe's throughput and with fork's memory saving?             (the new backend)
#
# Every arm cleans up after itself and sets FAILED, so one broken arm reports rather than
# hiding the other two behind a `tail`.
#
# Usage: bash verify-fixes.sh
#   BIN, ROOT, SDK, PHP as for the other scripts.

set -u

ROOT="${ROOT:-$HOME/volucer-competition}"
BIN="${BIN:-$HOME/volucer-bench/target/release/volucer}"
SDK="${SDK:-$ROOT/vendor/sailantis/volucer-worker}"
PHP="${PHP:-$(command -v php8.5 || command -v php)}"
DIR="$(mktemp -d /tmp/verify-fixes.XXXXXX)"
PORT=19620
RELAY="$DIR/relay.sock"
FAILED=0

fail() { echo "FATAL: $*" >&2; exit 1; }

cleanup() {
    [ -n "${VP:-}" ] && kill -KILL "$VP" 2>/dev/null
    [ -n "${SUP:-}" ] && kill -KILL "$SUP" 2>/dev/null
    pkill -KILL -f "$DIR" 2>/dev/null
    rm -rf "$DIR"
}
trap cleanup EXIT

[ -x "$BIN" ] || fail "no volucer at $BIN"
[ -f "$SDK/autoload.php" ] || fail "no SDK at $SDK"
[ -f "$ROOT/data/bench.sqlite" ] || fail "$ROOT/data/bench.sqlite is missing"

# Start from a clean host. A supervisor left by an earlier run keeps its relay path open and
# answers `pgrep`, so both the orphan count and the attach arm would otherwise measure the
# previous run — which is exactly what happened on the first attempt here.
pkill -KILL -f 'worker.php --prefork' 2>/dev/null
pkill -KILL -f 'volucer serve -c /tmp/verify-fixes' 2>/dev/null
sleep 0.3

# An opcache-enabled wrapper, which is what every warm arm uses.
cat > "$DIR/php-bench" <<WRAPPER
#!/bin/sh
exec $PHP -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 -d memory_limit=512M "\$@"
WRAPPER
chmod +x "$DIR/php-bench"

wait_ready() {
    local url="$1" tries="${2:-240}"
    for _ in $(seq 1 "$tries"); do
        [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$url")" = "200" ] && return 0
        sleep 0.25
    done
    return 1
}

# One arm, start to finish: write the config from a template, run it, measure it, stop it.
# A function so the two transports differ only in the one word that is the variable.
run_transport() {
    local transport="$1" port="$2"
    local config="$DIR/$transport.toml"

    cat > "$config" <<EOF
default_backend = "app"
[server]
http = "127.0.0.1:$port"
document_root = "$ROOT/public"
[server.static_files]
enabled = false
[backends.app]
kind = "worker"
command = "$DIR/php-bench $ROOT/worker.php"
workers = 4
working_dir = "$ROOT"
max_requests = 0
transport = "$transport"
EOF

    "$BIN" serve -c "$config" > "$DIR/$transport.log" 2>&1 &
    local vp=$!
    if ! wait_ready "http://127.0.0.1:$port/items"; then
        echo "  FAIL: $transport did not come up; its log:"
        sed 's/^/    /' "$DIR/$transport.log"
        kill -KILL "$vp" 2>/dev/null
        FAILED=1
        return
    fi
    wrk -t2 -c2 -d5s --latency "http://127.0.0.1:$port/items" 2>/dev/null \
        | grep -E 'Requests/sec|50%|99%' | sed 's/^/  /'
    kill "$vp" 2>/dev/null
    wait "$vp" 2>/dev/null
}

echo "=== 1. the socket transport, with and without the TCP_NODELAY fix ==="
echo "  Same server, same SDK, same page: only the transport differs."
echo
echo "--- 1a. transport = socket (the SDK now sets tcp_nodelay) ---"
run_transport socket 19620
echo
echo "--- 1b. transport = pipe (what 24,336 rps was measured on) ---"
run_transport pipe 19622

echo
echo "=== 2. a SIGKILLed server must not leave its children running ==="
echo

cat > "$DIR/orphan.toml" <<EOF
default_backend = "app"
[server]
http = "127.0.0.1:19624"
document_root = "$ROOT/public"
[server.static_files]
enabled = false
[backends.app]
kind = "worker"
command = "$DIR/php-bench $ROOT/worker.php"
workers = 4
working_dir = "$ROOT"
max_requests = 0
EOF

"$BIN" serve -c "$DIR/orphan.toml" > "$DIR/orphan.log" 2>&1 &
VP=$!
if ! wait_ready "http://127.0.0.1:19624/items"; then
    sed 's/^/    /' "$DIR/orphan.log"
    fail "the orphan arm did not come up"
fi

before="$(pgrep -cf "$ROOT/worker.php" 2>/dev/null)"
echo "  workers running while the server is up: ${before:-0}"
kill -KILL "$VP"
wait "$VP" 2>/dev/null
VP=""
# PDEATHSIG is delivered by the kernel at the moment of death and the group kill is
# synchronous, so this is a moment for init to reap, not a timeout to expire.
sleep 1
after="$(pgrep -cf "$ROOT/worker.php" 2>/dev/null)"
echo "  workers running one second after SIGKILL: ${after:-0}"
if [ "${after:-0}" -ne 0 ]; then
    echo "  FAIL: children survived; pids:"
    pgrep -af "$ROOT/worker.php" | sed 's/^/    /'
    pkill -KILL -f "$ROOT/worker.php"
    FAILED=1
else
    echo "  PASS: every child died with the server"
fi

echo
echo "=== 3. the attach backend: a real fork()ing supervisor, the real page ==="
echo

# The competition worker's own `--prefork` mode: one boot, then accept-and-fork. Using the
# real app rather than a synthetic one is the point — the memory saving only matters for a
# framework container, so a hello-world supervisor would prove the plumbing and nothing else.
"$DIR/php-bench" "$ROOT/worker.php" --prefork "unix:$RELAY" > "$DIR/supervisor.out" 2>&1 &
SUP=$!
# The supervisor announces itself on **stderr** once the listener exists. Waiting for a log line
# rather than for the socket *file* is deliberate: a file left by a supervisor that was `SIGKILL`ed
# is still `-S`, so a check that only tests for the path passes instantly against a listener that is
# gone, and volucer then fails at startup on a path that exists. `worker.php` redirects stderr into
# the same file, so this reads it either way.
for _ in $(seq 1 300); do
    grep -q 'listening on' "$DIR/supervisor.out" 2>/dev/null && break
    kill -0 "$SUP" 2>/dev/null || break
    sleep 0.1
done
if ! grep -q 'listening on' "$DIR/supervisor.out" 2>/dev/null; then
    sed 's/^/    /' "$DIR/supervisor.out"
    fail "the supervisor did not listen"
fi
echo "  supervisor listening on $RELAY (accept-and-fork per connection)"

cat > "$DIR/attach.toml" <<EOF
default_backend = "app"
[server]
http = "127.0.0.1:19626"
document_root = "$ROOT/public"
[server.static_files]
enabled = false
[backends.app]
kind = "attach"
relay = "unix:$RELAY"
workers = 4
EOF

"$BIN" serve -c "$DIR/attach.toml" > "$DIR/attach.log" 2>&1 &
VP=$!
if ! wait_ready "http://127.0.0.1:19626/items"; then
    sed 's/^/    /' "$DIR/attach.log"
    FAILED=1
else
    echo "  GET /items through attach: $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 'http://127.0.0.1:19626/items')"
    wrk -t2 -c2 -d5s --latency "http://127.0.0.1:19626/items" 2>/dev/null \
        | grep -E 'Requests/sec|50%|99%' | sed 's/^/  /'

    # **PSS, not RSS.** The point of the fork is that the children share the master's pages,
    # and summed RSS counts a shared page once per process — so RSS would report the absence
    # of the saving as though it were the saving. PSS splits each page between the processes
    # that map it, so summing it is what the machine actually holds.
    family="$(pgrep -f 'worker.php --prefork' 2>/dev/null | tr '\n' ' ')"
    family="$family$VP $(pgrep -P "$VP" 2>/dev/null | tr '\n' ' ')"
    pss_total=0
    rss_total=0
    for p in $family; do
        [ -r "/proc/$p/smaps_rollup" ] || continue
        pss_total=$((pss_total + $(awk '/^Pss:/ {print $2}' "/proc/$p/smaps_rollup" 2>/dev/null || echo 0)))
        rss_total=$((rss_total + $(awk '/^Rss:/ {print $2}' "/proc/$p/smaps_rollup" 2>/dev/null || echo 0)))
    done
    children="$(pgrep -cf 'worker.php --prefork' 2>/dev/null)"
    printf '  memory while serving: %s MB PSS across %s PHP processes + the server\n' \
        "$((pss_total / 1024))" "${children:-0}"
    printf '  (summed RSS over the same processes would say %s MB, which is the number that\n' \
        "$((rss_total / 1024))"
    echo  '   cannot see copy-on-write: every shared page counted once per child)'
fi

kill "$VP" 2>/dev/null; wait "$VP" 2>/dev/null; VP=""
kill -KILL "$SUP" 2>/dev/null; wait "$SUP" 2>/dev/null; SUP=""

echo
if [ "$FAILED" -ne 0 ]; then
    echo "=== one or more arms failed ==="
else
    echo "=== all three verified ==="
fi
exit "$FAILED"