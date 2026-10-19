#!/bin/bash
# Does the "forking worker" proposal work against real volucer?
#
# `scripts/fork-demo.php` measures what fork() would SAVE. This measures whether the
# design that would collect it actually holds up when a server owns the processes,
# because the saving is only real if the server can still do the four things it does
# to a worker it spawned itself:
#
#   1. reach it          the protocol channel is the process's stdin/stdout
#   2. route to it       one worker per slot, one slot per request
#   3. notice it died    `try_wait()` on the child it started
#   4. kill it           `child.kill()`, and the leak check behind it
#
# The rig is volucer `workers = 1` running `fork-worker-demo.php`, which forks N
# children of its own. Whatever the run prints about throughput, the interesting
# part is what happens to the pids.
#
# Usage:
#   bash scripts/fork-worker-demo.sh
#   CHILDREN=8 CONC=32 bash scripts/fork-worker-demo.sh
#
# Environment:
#   CHILDREN  children the master forks        [4]
#   CONC      wrk concurrency                 [16]
#   DUR       wrk duration                    [5s]
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(dirname "$SCRIPT_DIR")}"
BIN="${BIN:-$HOME/volucer-bench/target/release/volucer}"
PHP="${PHP:-$(command -v php || true)}"
CHILDREN="${CHILDREN:-4}"
CONC="${CONC:-16}"
DUR="${DUR:-5s}"
PORT="${PORT:-18700}"
# `pipe` (the default transport) or `socket`. The distinction is the experiment:
# the protocol channel is the worker's own stdin/stdout, and `fork()` inherits one
# *file description* per fd, not a private copy — so N children sharing it race
# over a single frame stream. On the socket transport each child would have to
# connect for itself, and the pool accepts exactly one connection per worker.
TRANSPORT="${TRANSPORT:-pipe}"
# How to stop the server at the end: `term` lets the master cooperate, `kill`
# gives it no chance at all. The second is the case that decides whether the
# server needs to reap the group itself.
STOP="${STOP:-term}"
D="$(mktemp -d)"

fail() { echo "FATAL: $*" >&2; rm -rf "$D"; exit 1; }

# `pgrep -c` prints the count *and* exits non-zero when it is 0, so `|| echo 0`
# appended a second line and every later `[ "$n" -gt 0 ]` broke on "0\n0".
count_php() {
    local n
    n="$(pgrep -cf 'fork-worker-demo.php' 2>/dev/null)"
    echo "${n:-0}"
}

[ -x "$BIN" ] || fail "no volucer binary at $BIN (set BIN)"
[ -f "$ROOT/data/bench.sqlite" ] || fail "$ROOT/data/bench.sqlite is missing - run: php seed.php"
command -v wrk >/dev/null 2>&1 || fail "no wrk on PATH"

# The pid log is the point of the exercise: it is how a child that outlives the
# server becomes visible.
PIDLOG="$D/pids.log"
: > "$PIDLOG"

cat > "$D/volucer.toml" <<'EOF'
default_backend = "app"

[server]
http = "127.0.0.1:@PORT@"
document_root = "@ROOT@"

[server.static_files]
enabled = false

[backends.app]
kind = "worker"
command = "@PHP@ @ROOT@/scripts/fork-worker-demo.php"
# ONE process, which then forks its own children. That is the whole proposal:
# volucer's `workers` would count masters, not PHP processes.
workers = 1
working_dir = "@ROOT@"
max_requests = 0
transport = "@TRANSPORT@"
env = { VOLUCER_WORKER_FORK = "1", VOLUCER_WORKER_CHILDREN = "@CHILDREN@", VOLUCER_WORKER_LOG = "@PIDLOG@" }
EOF

# Substituted after the fact, and every token is delimited by `@` on both sides:
# a bare `PORT_PLACEHOLDER` is a substring of `TRANSPORT_PLACEHOLDER`, so the
# first version rewrote the transport into `TRANS18700` and volucer rejected the
# configuration before it ever listened.
sed -i \
    -e "s|@PORT@|$PORT|" \
    -e "s|@PHP@|$PHP|" \
    -e "s|@ROOT@|$ROOT|g" \
    -e "s|@CHILDREN@|$CHILDREN|" \
    -e "s|@TRANSPORT@|$TRANSPORT|" \
    -e "s|@PIDLOG@|$PIDLOG|" \
    "$D/volucer.toml"

cleanup() {
    [ -n "${VP:-}" ] && kill "$VP" 2>/dev/null
    sleep 0.3
    for p in $(pgrep -f 'fork-worker-demo.php' 2>/dev/null); do
        kill -KILL "$p" 2>/dev/null
    done
    rm -rf "$D"
}
trap cleanup EXIT

echo "=== starting volucer workers=1, master forking $CHILDREN children ==="
"$BIN" serve -c "$D/volucer.toml" > "$D/volucer.log" 2>&1 &
VP=$!

for _ in $(seq 1 240); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$PORT/items")" = "200" ] && break
    sleep 0.25
done

# A server that refused the configuration exits before it ever listens, and the
# first run of this script reported "no orphans" for a run in which nothing had
# started at all. Silence has to be an error here.
if ! kill -0 "$VP" 2>/dev/null; then
    echo "FATAL: volucer exited before it served anything. Its log:" >&2
    sed 's/^/  /' "$D/volucer.log" >&2
    exit 1
fi

echo
echo "--- what the master reported ---"
cat "$PIDLOG" 2>/dev/null || echo "(the master wrote nothing to the pid log)"
echo
echo "--- who is actually running ---"
echo "volucer pid: $VP"
ps -o pid=,ppid=,pgid=,args= -p "$VP" 2>/dev/null
for p in $(pgrep -f 'fork-worker-demo.php' 2>/dev/null); do
    ps -o pid=,ppid=,pgid=,args= -p "$p" 2>/dev/null
done

echo
echo "--- QUESTION 1: the transport. Do N children share one channel? ---"
echo "transport: $TRANSPORT, children: $CHILDREN"
echo "A child inherits the master's stdin/stdout as ONE file description per fd,"
echo "so N children read one frame stream between them and each gets a fragment."
wrk -t"$CONC" -c"$CONC" -d"$DUR" --latency "http://127.0.0.1:$PORT/items" 2>&1 |
    grep -E "Requests/sec|50%|99%|requests in|Socket errors|Non-2xx"

echo
echo "--- QUESTION 1b: the same children, each on its OWN channel? ---"
# One process group would not change this; one channel per child does. The only
# way a forked child gets a private channel is to connect for itself, which the
# pool supports - it binds a listener and the worker connects back. But it accepts
# exactly ONE connection per spawned worker, so this needs a change on the server
# side either way: a listener per child, or a protocol that multiplexes children
# over one connection.
echo "  (needs a server-side change: one listener per forked child, or request ids"
echo "   that let N children share one connection - see the README)"

echo
echo "--- QUESTION 2: one process group for everything (your idea) ---"
echo "master pgid: $(ps -o pgid= -p "$(pgrep -f 'fork-worker-demo.php' | head -1)" 2>/dev/null | tr -d ' ')"
echo "volucer's pgid: $(ps -o pgid= -p "$VP" 2>/dev/null | tr -d ' ')"
echo "children in the MASTER's group (inherited from process_group(0)):"
for p in $(pgrep -f 'fork-worker-demo.php' 2>/dev/null); do
    printf '  pid %s pgid %s\n' "$p" "$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')"
done
echo "Putting the server AND all workers in ONE new group makes 'kill -TERM -PGID'"
echo "reach everything at once, which is what the Unix half of lifecycle.rs describes."
echo "It does NOT tell volucer which worker died, nor which slot to route to."

echo
echo "--- QUESTION 3: does the server notice a worker dying? ---"
# Kill one grandchild. volucer's `try_wait` only ever watches the master, so this
# asks whether the pool can tell - and whether the master replaces it.
VICTIM="$(pgrep -f 'fork-worker-demo.php' | tail -1)"
if [ -n "$VICTIM" ]; then
    echo "killing grandchild pid $VICTIM (the master should replace it)"
    kill -KILL "$VICTIM" 2>/dev/null
    sleep 1
    echo "master log now:"
    tail -3 "$PIDLOG" 2>/dev/null | sed 's/^/  /'
    echo "surviving fork-worker-demo processes: $(count_php)"
else
    echo "no grandchild found - the fork never happened"
fi

echo
echo "--- QUESTION 4: what does stopping the server leave behind? (stop=$STOP) ---"
BEFORE="$(count_php)"
if [ "$STOP" = "kill" ]; then
    # SIGKILL: the master gets no chance to forward anything. This is the case that
    # decides whether the SERVER must be responsible for the group, because
    # `PR_SET_PDEATHSIG` is described in lifecycle.rs but never actually set - so a
    # forked child has no kernel-level link to the process that started its master.
    echo "kill -KILL the server: the master cannot cooperate"
    kill -KILL "$VP" 2>/dev/null
else
    echo "kill -TERM the server: the master has a chance to forward it"
    kill -TERM "$VP" 2>/dev/null
fi
wait "$VP" 2>/dev/null
sleep 1.5
AFTER="$(count_php)"
echo "PHP processes before the stop: $BEFORE, after: $AFTER"
if [ "$AFTER" -gt 0 ]; then
    echo "ORPHANS SURVIVED - they still hold the server's pipes open:"
    for p in $(pgrep -f 'fork-worker-demo.php' 2>/dev/null); do
        ps -o pid=,ppid=,args= -p "$p" 2>/dev/null
    done
    echo
    echo "Their parent is now: $(ps -o ppid= -p "$(pgrep -f 'fork-worker-demo.php' | head -1)" 2>/dev/null | tr -d ' ') (1 = reparented to init)"
    echo
    echo "This is the case ONE PROCESS GROUP fixes: 'kill -KILL -PGID' would reach"
    echo "them without the master's cooperation. What it does not fix is that volucer"
    echo "still believes slot 0 is alive, because try_wait() watches the master."
else
    echo "no orphans - the master killed its children on the way out"
fi
VP=""
