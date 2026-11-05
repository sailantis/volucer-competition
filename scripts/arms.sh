#!/usr/bin/env bash
# The arms that answer "how do the runtimes compare", on one front-end where possible.
#
#   arms.sh [secs] [conc] [rounds]
#
#   attach     volucer `attach` -> PHP, N forked children behind one unix relay
#   worker     volucer `worker` -> PHP, N spawned processes over pipes (own interpreter + OPcache each)
#   worker_socket  the same, over unix sockets: the spawned worker a runtime can await
#   cgi        volucer `spawn_cgi` -> `php-cgi`, cold: a full CGI SAPI reset per request
#   cgi_dummy  volucer `spawn_cgi` -> a FastCGI dummy: the cold arm's own pool, no PHP
#   external_fpm  volucer `external` -> a REAL php-fpm pool (warm, no nginx in front)
#   upstream   volucer `upstream` -> Node/Fastify cluster
#   floor      volucer `external` -> a Node FastCGI responder: the transport's floor, no PHP
#   node       bare Node/Fastify, no front-end (a labelled ceiling, never the headline)
#
# `external_fpm` is the arm that separates the two halves of `fpm` (nginx + php-fpm), which no
# other row can do: it holds the pool, socket, pm.max_children and front controller fixed and
# changes only what sits in front of them. Against `fpm` it measures the front-end; against
# `cgi` it measures the application model (resident pool vs per-request SAPI reset). It needs
# `php-fpm` and `nginx` is NOT required — that is the point.
#
# Two of these are references rather than competitors, and they are the reason the
# table can be read at all:
#
#   floor is the **client** only -- `external` starts nothing, so it has no spawned
#   slots, no per-slot socket the pool waited for, no permits and no lifecycle
#   ownership. `spawn_cgi` -> any responder minus `floor` is the pool.
#   cgi_dummy starts through the path `php-cgi` starts through -- `spawn_every_slot`,
#   `drain`, `LifecycleGuard::adopt`, `wait_until_listening`, `SlotPermits` -- and
#   answers with an application that does nothing. So `cgi` - `cgi_dummy` is PHP,
#   `cgi_dummy` - `floor` is the pool, and `floor` - `upstream` is the blocking hop.
#
# Why `worker` is here rather than inferred: it is the arm `attach` is a control *for*. They
# run the same application with the same boot and differ only in who owns the fork, so the
# pair prices the memory model with the page held equal. Quoting one without the other is
# quoting half a decision.
#
# Guards, each because it has already produced a believable wrong number here:
#   - every arm's body is fetched and checked before anything is timed. A 502 is answered
#     *faster* than a real request, so a dead backend wins a race it never ran (Phase 11).
#   - `wrk -t` is the core count, never the connection count (Phase 5's oversubscription).
#   - `worker` gets the same PHP flags as `attach`. `attach` inherits them from the
#     supervisor's command line; `worker` starts `php` itself, so without the wrapper it
#     would silently run with the host's CLI defaults (xdebug). That is hazard 28, and it is
#     roughly a 2x difference -- it would look like a memory-model result and be a php.ini.
#   - PSS is sampled during load, because the reason to prefer `attach` is memory, and a
#     throughput table without it cannot justify the arm it is being compared to. PSS
#     rather than RSS: RSS counts a fork-shared heap once per process, which flattered
#     `attach` at 1,621 MB against its true 65.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Leftovers from an aborted or killed run are the worst kind of measurement bug here, because
# they do not fail: the previous run's `volucer` still owns the socket, the new arm's slot
# cannot bind, and the run reports "bad gateway ... No such file or directory" -- which reads
# like a missing binary and is actually a socket owned by a process nobody is looking at.
#
# So cleanup is one function installed on `EXIT`, `INT` and `TERM`, rather than a block at the
# bottom of the happy path. Nothing else in this script relies on the exit path being tidy.
PROBE_INITIALISED=""
cleanup() {
    local pids="$VOL_A $VOL_W ${VOL_WS:-} $VOL_U $ORIGIN $SUP_A ${VOL_C:-} ${VOL_D:-} ${VOL_F:-} ${VOL_X:-} ${FPM_EXT:-} ${FLOOR_NODE:-}"
    kill -TERM $pids 2>/dev/null
    sleep 1.5
    kill -9 $pids 2>/dev/null
    if [ -n "$PROBE_INITIALISED" ]; then
        # Anchored on the probe directory, so this can only ever reach processes this run
        # started -- not a stray `php-cgi` somebody else is serving with, and not the host's
        # own php-fpm children.
        pkill -f "$PROBE/" 2>/dev/null
        pkill -f "supervisor.php unix:$PROBE/attach/relay" 2>/dev/null
        pkill -f "fastify-hello.js --port $PORT_ORIGIN" 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM
SECS=${1:-16}
CONC=${2:-100}
ROUNDS=${3:-3}
BIN=${BIN:-$HOME/hello-bench/bin/volucer-adopt}
WORKERS=${WORKERS:-96}
# `external` dials one address and has no slots of its own, so the responder's process count
# is a free parameter -- and it decides the arm's ceiling rather than the FastCGI client's.
# Measured on this host, 96 slots against the responder, `wrk -t12 -c100`, 14 s:
#
#     2 responders    94,282 rps   be 21.3 us   fe 39.1 us     72 MB
#     4 responders   119,306 rps   be 25.4 us   fe 41.4 us    103 MB
#    12 responders    86,073 rps   be 40.3 us   fe 57.8 us    237 MB
#    96 responders    ~18,000 rps  be 156 us    fe 345 us   1,494 MB
#
# One responder (the original default) gives ~50k and 12 or more makes it *worse* -- 96 Node
# processes on an 8 GB host thrash, and one event loop is one core's worth of work. Four is
# the measured optimum and the default below; it is a floor, so the arm should be comfortably
# above the client's own cost rather than tied with it.
FLOOR_WORKERS=${FLOOR_WORKERS:-4}
NODE_BIN=$HOME/hello-bench/bin/node-v24.11.1-linux-x64/bin
CORES=$(nproc)
PROBE="$ROOT/.probe/fa"
rm -rf "$PROBE"; mkdir -p "$PROBE"
PROBE_INITIALISED=1

PORT_ATTACH=22950
PORT_WORKER=22951
PORT_WORKER_SOCKET=22955
PORT_CGI=22952
PORT_CGI_DUMMY=22954
PORT_EXTERNAL_FPM=22956
PORT_FLOOR=22953
PORT_UPSTREAM=22961
PORT_ORIGIN=22960

ns_of() {   # total CPU nanoseconds across every thread of every pid given
    local total=0 pid v
    for pid in "$@"; do
        for t in /proc/"$pid"/task/*/schedstat; do
            [ -r "$t" ] || continue
            v=$(awk '{print $1}' "$t" 2>/dev/null)
            total=$(( total + ${v:-0} ))
        done
    done
    echo "$total"
}

rss_of() {  # total resident MB across every pid matching the given pattern
    local total=0 pid kb
    for pid in $(pgrep -f "$1" 2>/dev/null); do
        kb=$(awk '/^VmRSS:/{print $2}' /proc/"$pid"/status 2>/dev/null)
        total=$(( total + ${kb:-0} ))
    done
    echo $(( total / 1024 ))
}

# RSS double-counts every shared page once per process, which flatters whichever arm shares
# the most -- and sharing is exactly what `attach` is for (`fork` from one heap). PSS splits
# each shared page across the processes mapping it, so the pool is counted once. The memory
# column has to be PSS or it cannot be used to justify the arm it describes.
pss_of() {   # $1 = arm
    local total=0 pid kb
    for pid in $(backend_pids "$1"); do
        kb=$(awk '/^Pss:/{print $2}' /proc/"$pid"/smaps_rollup 2>/dev/null)
        total=$(( total + ${kb:-0} ))
    done
    echo $(( total / 1024 ))
}

# Pids of one worker arm's PHP processes.
#
# **Not a pattern on the wrapper.** Both arms run the same `worker.php` through a wrapper, and the
# wrapper `exec`s php, so the wrapper's own path is *gone* from argv by the time the process is
# running — a pattern on it matches nothing, which was measured as "0 php processes" for a busy
# arm. A pattern on `worker.php` matches both arms at once, which was measured as "192".
#
# What actually distinguishes them is the transport: volucer exports `VOLUCER_WORKER_SOCKET` only
# for the socket transport, so the variable's presence in the process environment *is* the arm.
worker_pids() {   # $1 = pipe | socket
    local want=$1 pid
    for pid in $(pgrep -f "apps/hello/worker.php" 2>/dev/null); do
        if grep -qz "VOLUCER_WORKER_SOCKET=" "/proc/$pid/environ" 2>/dev/null; then
            [ "$want" = socket ] && echo "$pid"
        else
            [ "$want" = pipe ] && echo "$pid"
        fi
    done
}

# A pooled backend is matched by pattern, and so is a `node --cluster` origin: its master
# spends no CPU while twelve children do the work. Charging only the master reported
# "0.00 cores / 0.0 us per request" for the busiest process on the box.
#
# The two worker arms are the exception and go through the transport test above, because they are
# the only pair that runs the same program with the same arguments.
backend_pids() {   # $1 = arm
    case $1 in
        worker)        worker_pids pipe ;;
        worker_socket) worker_pids socket ;;
        # php-fpm names its children `php-fpm: pool <poolname>`, and the pool name is how this
        # arm is told apart from any other fpm on the host. Matched as `pool bench$` rather
        # than `bench-ext`: the section name in the pool file IS the pool name, and a guessed
        # "bench-ext" matched nothing while the run looked complete (measured `ext_fpm 0`, a
        # memory column of 0 MB, and a back-end of 0.0 cores for an arm that was serving).
        # The `$` keeps it from also matching `pool bench-something`.
        fpm)           pgrep -f "php-fpm: pool bench$" 2>/dev/null ;;
        *)             pgrep -f "${BACKEND[$1]}" 2>/dev/null ;;
    esac
}

ns_of_pattern() {   # $1 = arm
    local total=0 pid v
    for pid in $(backend_pids "$1"); do
        for t in /proc/"$pid"/task/*/schedstat; do
            [ -r "$t" ] || continue
            v=$(awk '{print $1}' "$t" 2>/dev/null)
            total=$(( total + ${v:-0} ))
        done
    done
    echo "$total"
}

echo "=== binary: $BIN"
echo "=== $(sha256sum "$BIN" | cut -c1-16)  workers=$WORKERS  c=$CONC  ${SECS}s x $ROUNDS"
echo "=== host load: $(awk '{print $1}' /proc/loadavg)"

# ---- the PHP wrapper, so `worker` and `attach` differ in ownership and nothing else ----
# Two of them, with identical flags and different filenames. The flags must match `attach`'s
# (hazard 28), and the *name* must differ: `worker` and `worker_socket` run the same
# `worker.php` with the same arguments, so one wrapper would make both populations match both
# arms' process patterns -- measured as "192 php processes" for a 96-worker arm, and a memory
# column that counted the pool twice.
PHP_WRAPPER="$PROBE/php-bench-pipe"
PHP_WRAPPER_SOCKET="$PROBE/php-bench-socket"
for wrapper in "$PHP_WRAPPER" "$PHP_WRAPPER_SOCKET"; do
    cat > "$wrapper" <<WRAPPER
#!/bin/sh
exec $(command -v php) -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \\
    -d opcache.jit=off -d xdebug.mode=off -d memory_limit=512M "\$@"
WRAPPER
    chmod +x "$wrapper"
done

# ---- attach ---------------------------------------------------------------------------
AT="$PROBE/attach"; mkdir -p "$AT"
# The supervisor's own -d flags are what `attach`'s children inherit, so they must be the
# wrapper's flags. Duplicating them here is deliberate: this is the reference arm.
php -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 -d opcache.jit=off \
    -d xdebug.mode=off -d memory_limit=512M \
    "$ROOT/apps/hello/supervisor.php" "unix:$AT/relay" >"$AT/sup.log" 2>&1 &
SUP_A=$!
for _ in $(seq 1 200); do [ -S "$AT/relay" ] && break; sleep 0.05; done
sed -e "s|{{PORT}}|$PORT_ATTACH|g" -e "s|{{ROOT}}|$ROOT|g" \
    -e "s|{{WORKERS}}|$WORKERS|g" -e "s|{{SOCKET_DIR}}|$AT|g" \
    "$ROOT/conf/hello-attach.toml.template" > "$AT/cfg.toml"
"$BIN" serve -c "$AT/cfg.toml" >"$AT/volucer.log" 2>&1 &
VOL_A=$!

# ---- worker ---------------------------------------------------------------------------
WK="$PROBE/worker"; mkdir -p "$WK"
sed -e "s|{{PORT}}|$PORT_WORKER|g" -e "s|{{ROOT}}|$ROOT|g" \
    -e "s|{{WORKERS}}|$WORKERS|g" -e "s|{{PHP}}|$PHP_WRAPPER|g" \
    "$ROOT/conf/hello-worker-pipe.toml.template" > "$WK/cfg.toml"
"$BIN" serve -c "$WK/cfg.toml" >"$WK/volucer.log" 2>&1 &
VOL_W=$!

# ---- worker over a socket, which a runtime can adopt: the awaited spawned worker ------
# The same server, the same page, the same process model as the arm above. Only the transport
# differs -- a unix socket instead of stdin/stdout -- and a socket is a descriptor a runtime can
# register, so this slot awaits its worker instead of parking a thread on a pipe it cannot.
#
# Its purpose is to split one question in two. `worker`'s front-end costs ~11 us more than
# `attach`'s, and there were two candidate causes: the pipe, or the exchange thread a spawned slot
# still owns. This arm keeps the thread and removes the pipe.
WKS="$PROBE/worker-socket"; mkdir -p "$WKS"
sed -e "s|{{PORT}}|$PORT_WORKER_SOCKET|g" -e "s|{{ROOT}}|$ROOT|g" \
    -e "s|{{WORKERS}}|$WORKERS|g" -e "s|{{PHP}}|$PHP_WRAPPER_SOCKET|g" \
    -e "s|{{SOCKET_DIR}}|$WKS|g" \
    "$ROOT/conf/hello-worker-socket.toml.template" > "$WKS/cfg.toml"
"$BIN" serve -c "$WKS/cfg.toml" >"$WKS/volucer.log" 2>&1 &
VOL_WS=$!

# ---- spawn_cgi (cold: a full CGI SAPI reset per request) -------------------------------
# `php-cgi` is a different binary from `php`, and the arm is the *cold model* -- the
# framework boots inside the timed request -- so it gets its own entry point
# (`apps/hello/public/index.php`) and its own `document_root`, not the repository's
# `public/`, which is the Azera + SQLite page.
#
# The same flags as every other arm, through a wrapper, for the same reason as the
# `worker` arm: this host's `php-cgi` defaults to `opcache.enable_cli=Off` and
# `opcache.validate_timestamps=On`, so an unwrapped `php-cgi` would re-check and
# re-compile the front controller on every request. That is hazard 28 again, and it
# would look like a verdict on the cold model.
CG="$PROBE/cgi"; mkdir -p "$CG"
PHP_CGI_BIN=$(command -v php-cgi || true)
if [ -n "$PHP_CGI_BIN" ]; then
    PHP_CGI_WRAPPER="$PROBE/php-cgi-bench"
    cat > "$PHP_CGI_WRAPPER" <<WRAPPER
#!/bin/sh
exec $PHP_CGI_BIN -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \\
    -d opcache.jit=off -d xdebug.mode=off -d memory_limit=512M "\$@"
WRAPPER
    chmod +x "$PHP_CGI_WRAPPER"
    sed -e "s|{{PORT}}|$PORT_CGI|g" -e "s|{{ROOT}}|$ROOT|g" \
        -e "s|{{WORKERS}}|$WORKERS|g" -e "s|{{SOCKET_DIR}}|$CG|g" \
        -e "s|{{PHP_CGI}}|$PHP_CGI_WRAPPER|g" \
        "$ROOT/conf/hello-cgi.toml.template" > "$CG/cfg.toml"
    "$BIN" serve -c "$CG/cfg.toml" >"$CG/volucer.log" 2>&1 &
    VOL_C=$!
else
    echo "=== NOTE: no php-cgi on PATH, the spawn_cgi arm is skipped"
    VOL_C=""
fi

# ---- spawn_cgi -> a dummy: the cold arm's pool, with no PHP behind it -------------------
# The same `kind` as the arm above and therefore the same `CgiPool`: slots spawned,
# drained, adopted, waited for, permit-counted and recycled by the same code. What
# differs is the program. So `cgi - cgi_dummy` is PHP's per-request boot and nothing
# else, which is the one decomposition `external` cannot give -- `external` starts
# nothing, so it has no pool in it.
CD="$PROBE/cgi-dummy"; mkdir -p "$CD"
PYTHON_BIN=$(command -v python3 || true)
if [ -n "$PYTHON_BIN" ]; then
    sed -e "s|{{PORT}}|$PORT_CGI_DUMMY|g" -e "s|{{ROOT}}|$ROOT|g" \
        -e "s|{{WORKERS}}|$WORKERS|g" -e "s|{{SOCKET_DIR}}|$CD|g" \
        -e "s|{{PYTHON}}|$PYTHON_BIN|g" \
        "$ROOT/conf/hello-cgi-dummy.toml.template" > "$CD/cfg.toml"
    "$BIN" serve -c "$CD/cfg.toml" >"$CD/volucer.log" 2>&1 &
    VOL_D=$!
else
    echo "=== NOTE: no python3 on PATH, the spawn_cgi-dummy arm is skipped"
    VOL_D=""
fi

# ---- the FastCGI floor: the same client, a responder that does nothing -----------------
# Not a competitor. `spawn_cgi` and this arm reach the same `ClientPool`/`CgiPool` and the
# same blocking FastCGI client over a unix socket, with the same per-request scope and the
# same CGI header translation. The difference is only what answers. So `spawn_cgi` minus
# this arm is PHP's own cost, and this arm minus `upstream` is the price of the transport.
#
# Without it a `spawn_cgi` figure cannot say whether the socket or the framework is
# expensive, which is exactly the question the cold arm exists to answer.
FL="$PROBE/floor"; mkdir -p "$FL"
if [ -n "${NODE_BIN:-}" ] && [ -x "$NODE_BIN/node" ]; then
    # `--workers` is the responder count, and 4 is measured rather than assumed: see the
    # sweep in the header. One process caps this arm at one core (~50k), 12 or more thrashes
    # on an 8 GB host, and the arm must sit above the client's cost to be a floor at all.
    PATH="$NODE_BIN:$PATH" node "$ROOT/apps/hello/cgi-echo.js" "$FL/cgi.sock" \
        --workers "$FLOOR_WORKERS" >"$FL/node.log" 2>&1 &
    FLOOR_NODE=$!
    for _ in $(seq 1 200); do [ -S "$FL/cgi.sock" ] && break; sleep 0.05; done
    if [ -S "$FL/cgi.sock" ]; then
        sed -e "s|{{PORT}}|$PORT_FLOOR|g" -e "s|{{ROOT}}|$ROOT|g" \
            -e "s|{{SOCKET_DIR}}|$FL|g" \
            "$ROOT/conf/hello-cgi-node.toml.template" > "$FL/cfg.toml"
        "$BIN" serve -c "$FL/cfg.toml" >"$FL/volucer.log" 2>&1 &
        VOL_F=$!
    else
        echo "=== NOTE: the FastCGI responder never bound, its arm is skipped"
        VOL_F=""
    fi
else
    VOL_F=""
fi

# ---- php-fpm pool for `external_fpm`, and the volucer in front of it -------------------
#
# The pool is a *real* php-fpm with a real `pm = static`, not a responder standing in for one,
# because the comparison this arm exists for is against the `fpm` arm — where the pool is
# exactly this. `nginx` is deliberately absent: a difference against `fpm` must be the
# front-end, and putting nginx in front of volucer would measure nothing nameable.
#
# The opcache mode goes to the master as `-d`, not into the pool file; see fpm-pool-ext.sh.
EX="$PROBE/external"
mkdir -p "$EX"
FPM_BIN="${PHP_FPM:-}"
if [ -z "$FPM_BIN" ]; then
    # `php-fpm` lives in `/usr/sbin`, which a non-root PATH usually omits — so `command -v`
    # alone reports "no php-fpm" on a host that has one, and this arm is skipped for a
    # reason that has nothing to do with the host. Searched explicitly rather than by
    # asking the caller to fix their PATH.
    for cand in php-fpm8.5 php-fpm8.4 php-fpm8.3 php-fpm; do
        FPM_BIN=$(command -v "$cand" 2>/dev/null) && break
        for dir in /usr/sbin /usr/local/sbin /sbin; do
            if [ -x "$dir/$cand" ]; then FPM_BIN="$dir/$cand"; break 2; fi
        done
    done
fi
if [ -n "$FPM_BIN" ] && [ -x "$FPM_BIN" ]; then
    sh "$ROOT/scripts/fpm-pool-ext.sh" "$EX/pool.conf" "$WORKERS" "$EX/fpm.sock" "$EX" on
    "$FPM_BIN" -y "$EX/pool.conf" -F -d opcache.enable=1 -d opcache.validate_timestamps=0 \
        >"$EX/fpm.log" 2>&1 &
    FPM_EXT=$!
    # The socket appears before the pool can serve, so a connect is the only proof. This is a
    # probe against the pool, not against the arm, so it cannot disturb what is measured.
    for _ in $(seq 1 400); do [ -S "$EX/fpm.sock" ] && break; sleep 0.05; done
    if [ -S "$EX/fpm.sock" ]; then
        sed -e "s|{{PORT}}|$PORT_EXTERNAL_FPM|g" -e "s|{{ROOT}}|$ROOT|g" \
            -e "s|{{SOCKET}}|$EX/fpm.sock|g" \
            "$ROOT/conf/hello-external-fpm.toml.template" > "$EX/cfg.toml"
        "$BIN" serve -c "$EX/cfg.toml" >"$EX/volucer.log" 2>&1 &
        VOL_X=$!
    else
        echo "=== NOTE: the php-fpm pool never bound $EX/fpm.sock, its arm is skipped"
        tail -4 "$EX/fpm.log" 2>/dev/null | sed 's/^/    /'
        VOL_X=""
    fi
else
    echo "=== NOTE: no php-fpm on PATH, the external_fpm arm is skipped"
    VOL_X=""
fi

# ---- node origin, shared by `upstream` (proxied) and `node` (bare) ---------------------
UP="$PROBE/upstream"; mkdir -p "$UP"
PATH="$NODE_BIN:$PATH" node "$ROOT/apps/hello/fastify-hello.js" \
    --port "$PORT_ORIGIN" --workers 12 --cluster reuseport >"$UP/origin.log" 2>&1 &
ORIGIN=$!
for _ in $(seq 1 400); do curl -sf -o /dev/null "http://127.0.0.1:$PORT_ORIGIN/" && break; sleep 0.05; done
sed -e "s|{{PORT}}|$PORT_UPSTREAM|g" -e "s|{{ROOT}}|$ROOT|g" \
    -e "s|{{ORIGIN_PORT}}|$PORT_ORIGIN|g" \
    "$ROOT/conf/hello-upstream.toml.template" > "$UP/cfg.toml"
"$BIN" serve -c "$UP/cfg.toml" >"$UP/volucer.log" 2>&1 &
VOL_U=$!

for _ in $(seq 1 400); do curl -sf -o /dev/null "http://127.0.0.1:$PORT_ATTACH/" && break; sleep 0.05; done
for _ in $(seq 1 400); do curl -sf -o /dev/null "http://127.0.0.1:$PORT_WORKER/" && break; sleep 0.05; done
for _ in $(seq 1 400); do curl -sf -o /dev/null "http://127.0.0.1:$PORT_WORKER_SOCKET/" && break; sleep 0.05; done
if [ -n "$VOL_C" ]; then
    # A cold arm needs longer: every one of its workers is a fresh `php-cgi` that has to
    # bind before it can answer.
    for _ in $(seq 1 900); do curl -sf -o /dev/null "http://127.0.0.1:$PORT_CGI/" && break; sleep 0.05; done
fi
if [ -n "$VOL_D" ]; then
    for _ in $(seq 1 900); do curl -sf -o /dev/null "http://127.0.0.1:$PORT_CGI_DUMMY/" && break; sleep 0.05; done
fi
if [ -n "$VOL_F" ]; then
    for _ in $(seq 1 400); do curl -sf -o /dev/null "http://127.0.0.1:$PORT_FLOOR/" && break; sleep 0.05; done
fi
if [ -n "$VOL_X" ]; then
    # Longer than the warm arms: php-fpm has to fork `pm.max_children` processes and each one
    # loads the interpreter before the first request can be answered.
    for _ in $(seq 1 900); do curl -sf -o /dev/null "http://127.0.0.1:$PORT_EXTERNAL_FPM/" && break; sleep 0.05; done
fi
for _ in $(seq 1 400); do curl -sf -o /dev/null "http://127.0.0.1:$PORT_UPSTREAM/" && break; sleep 0.05; done
sleep 2

# ---- guards ---------------------------------------------------------------------------
echo "=== bodies"
declare -A BODY PORT PID BACKEND
PORT[attach]=$PORT_ATTACH;   PID[attach]=$VOL_A;  BACKEND[attach]="supervisor.php unix:$AT/relay"
PORT[worker]=$PORT_WORKER;   PID[worker]=$VOL_W;  BACKEND[worker]="php-bench-pipe"
PORT[worker_socket]=$PORT_WORKER_SOCKET; PID[worker_socket]=$VOL_WS; BACKEND[worker_socket]="php-bench-socket"
PORT[upstream]=$PORT_UPSTREAM; PID[upstream]=$VOL_U; BACKEND[upstream]="fastify-hello.js --port $PORT_ORIGIN"
PORT[node]=$PORT_ORIGIN;     PID[node]=$ORIGIN;   BACKEND[node]="fastify-hello.js --port $PORT_ORIGIN"
ARMS="attach worker worker_socket upstream node"
if [ -n "$VOL_C" ]; then
    PORT[cgi]=$PORT_CGI; PID[cgi]=$VOL_C; BACKEND[cgi]="php-cgi"
    ARMS="attach worker worker_socket cgi upstream node"
fi
if [ -n "$VOL_D" ]; then
    PORT[cgi_dummy]=$PORT_CGI_DUMMY; PID[cgi_dummy]=$VOL_D
    # Matched by the program's own path: `spawn_cgi` starts it once per slot, so this
    # is the population that costs CPU, not the volucer process that supervises it.
    BACKEND[cgi_dummy]="apps/hello/fcgi-dummy.py"
    ARMS="attach worker worker_socket cgi cgi_dummy upstream node"
fi
if [ -n "$VOL_F" ]; then
    PORT[floor]=$PORT_FLOOR; PID[floor]=$VOL_F; BACKEND[floor]="apps/hello/cgi-echo.js"
    ARMS="$ARMS floor"
fi
if [ -n "$VOL_X" ]; then
    PORT[external_fpm]=$PORT_EXTERNAL_FPM; PID[external_fpm]=$VOL_X
    # The pool, not the front-end: this column is the population that costs CPU, and php-fpm
    # names each child `php-fpm: pool bench-ext`. Not `php-fpm` alone — that would count a pool
    # this run did not start.
    BACKEND[external_fpm]="php-fpm: pool bench$"
    ARMS="$ARMS external_fpm"
fi

# `ARMS="cgi cgi_dummy" ./arms.sh ...` measures a subset. It exists because seven arms
# resident at 96 children is ~200 processes on an 8 GB host, and a focused pair is both
# faster and less likely to disturb the arm it is comparing against. Requesting an arm
# that did not start is refused rather than skipped, for the same reason a failed body
# check is: a table missing a row looks complete.
if [ -n "${ARMS_FILTER:-}" ]; then
    keep=""
    for arm in $ARMS_FILTER; do
        case " $ARMS " in
            *" $arm "*) keep="$keep $arm" ;;
            *) echo "=== FATAL: requested arm '$arm' is not available (have:$ARMS)"; exit 2 ;;
        esac
    done
    ARMS="${keep# }"
fi

fail=0
for arm in $ARMS; do
    BODY[$arm]=$(curl -s --max-time 5 "http://127.0.0.1:${PORT[$arm]}/")
    printf "  %-9s %s\n" "$arm" "${BODY[$arm]}"
    printf '%s' "${BODY[$arm]}" | grep -q '"hello"' || fail=1
done
if [ "$fail" -ne 0 ]; then
    echo "REFUSING TO MEASURE: an arm is not serving the page. A dead backend answers faster"
    echo "than a live one, so a timing here would be meaningless or backwards."
    # The `EXIT` trap reaps every process this run started; killing here as well would race it.
    exit 1
fi

echo "=== backend processes"
printf "  attach    %s php children\n" "$(pgrep -fc "supervisor.php unix:$AT/relay" 2>/dev/null || echo 0)"
printf "  worker    %s php processes (pipe)\n" "$(worker_pids pipe | wc -l)"
printf "  wk-socket %s php processes (socket)\n" "$(worker_pids socket | wc -l)"
printf "  cgi       %s php-cgi processes\n" "$(pgrep -c -x php-cgi 2>/dev/null || echo 0)"
printf "  cgi_dummy %s dummy processes\n" "$(pgrep -fc "apps/hello/fcgi-dummy.py" 2>/dev/null || echo 0)"
printf "  ext_fpm   %s php-fpm children\n" "$(pgrep -fc "php-fpm: pool bench$" 2>/dev/null || echo 0)"
printf "  floor     %s cgi-echo processes\n" "$(pgrep -fc "apps/hello/cgi-echo.js" 2>/dev/null || echo 0)"
printf "  node      %s node processes\n" "$(pgrep -fc "fastify-hello.js --port $PORT_ORIGIN" 2>/dev/null || echo 0)"

# ---- measure --------------------------------------------------------------------------
measure() {
    local arm=$1 tag=$2
    local vol=${PID[$arm]} be="${BACKEND[$arm]}"
    local b0 b1 f0 f1 peak=0
    local sample="$PROBE/pss-$tag"

    b0=$(ns_of_pattern "$arm"); f0=$(ns_of "$vol")
    wrk -t"$CORES" -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:${PORT[$arm]}/" \
        >"$PROBE/wrk-$tag.txt" 2>&1 &
    local wrk_pid=$!
    # Sample PSS while the load runs: the figure that matters is the backend's steady-state
    # footprint, not what it had before anything connected.
    ( while kill -0 $wrk_pid 2>/dev/null; do pss_of "$arm"; sleep 0.5; done ) >"$sample" 2>/dev/null &
    local sampler=$!
    wait $wrk_pid
    kill $sampler 2>/dev/null
    b1=$(ns_of_pattern "$arm"); f1=$(ns_of "$vol")
    peak=$(sort -n "$sample" 2>/dev/null | tail -1); peak=${peak:-0}

    local f="$PROBE/wrk-$tag.txt"
    local rps total p50 bad
    rps=$(awk '/^Requests\/sec:/{print $2}' "$f")
    total=$(awk '/requests in /{print $1}' "$f")
    p50=$(awk '/^ +50%/{print $2}' "$f")
    bad=$(awk -F: '/Non-2xx/{gsub(/ /,"",$2); print $2+0}' "$f")
    awk -v t="$tag" -v r="${rps:-0}" -v p="$p50" -v bd="$((b1-b0))" -v fd="$((f1-f0))" \
        -v n="${total:-1}" -v s="$SECS" -v bad="${bad:-0}" -v m="$peak" \
        'BEGIN{ printf "  %-14s %7.0f rps  p50 %-9s  be %5.2f c %5.1f us | fe %5.2f c %5.1f us | pss %5d MB%s\n",
                 t, r, p, bd/1e9/s, bd/1e3/n, fd/1e9/s, fd/1e3/n, m,
                 (bad>0 ? "  <<< NON-2xx: " bad : "") }'
}

# A warm pass per arm before the first timed round. Every table in this record shows ~20
# non-2xx on its first pass against a freshly started process -- workers still coming up --
# so the first measurement of a process is biased down and is not the one to quote.
echo "=== warm-up pass (${SECS}s each, discarded)"
for arm in $ARMS; do
    wrk -t"$CORES" -c"$CONC" -d"${SECS}s" "http://127.0.0.1:${PORT[$arm]}/" >/dev/null 2>&1
done

for round in $(seq 1 "$ROUNDS"); do
    echo "--- round $round"
    # Rotate the arm list instead of writing one ORDER per round. A hand-maintained list
    # silently drops an arm the day one is added -- which is exactly what happened when the
    # floor arm arrived: it was guarded, launched, and then never timed, and the table looked
    # complete without it. The offset changes every round and even rounds run backwards, so
    # no arm keeps a fixed neighbour or a fixed position.
    read -r -a ARM_LIST <<< "$ARMS"
    n=${#ARM_LIST[@]}
    offset=$(( (round - 1) % n ))
    ORDER=""
    for ((i = 0; i < n; i++)); do
        ORDER="$ORDER ${ARM_LIST[$(( (i + offset) % n ))]}"
    done
    if [ $(( round % 2 )) -eq 0 ]; then
        REVERSED=""
        for arm in $ORDER; do REVERSED="$arm $REVERSED"; done
        ORDER="$REVERSED"
    fi
    for arm in $ORDER; do measure "$arm" "$arm-r$round"; done
done

# The `EXIT` trap tears everything down on the way out, so the happy path does not duplicate
# it: `cleanup` is idempotent and the trap runs it again after this line.
cleanup
echo "--- detail: $PROBE/wrk-*.txt"
