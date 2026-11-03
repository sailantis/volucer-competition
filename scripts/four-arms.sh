#!/usr/bin/env bash
# The four arms that answer "how do the runtimes compare", on one front-end where possible.
#
#   four-arms.sh [secs] [conc] [rounds]
#
#   attach   volucer `attach` -> PHP, N forked children behind one unix relay
#   worker   volucer `worker` -> PHP, N spawned processes (own interpreter + OPcache each)
#   upstream volucer `upstream` -> Node/Fastify cluster
#   node     bare Node/Fastify, no front-end (a labelled ceiling, never the headline)
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
#   - RSS is sampled during load, because the reason to prefer `attach` is memory, and a
#     throughput table without it cannot justify the arm it is being compared to.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECS=${1:-16}
CONC=${2:-100}
ROUNDS=${3:-3}
BIN=${BIN:-$HOME/hello-bench/bin/volucer-adopt}
WORKERS=${WORKERS:-96}
NODE_BIN=$HOME/hello-bench/bin/node-v24.11.1-linux-x64/bin
CORES=$(nproc)
PROBE="$ROOT/.probe/fa"
rm -rf "$PROBE"; mkdir -p "$PROBE"

PORT_ATTACH=22950
PORT_WORKER=22951
PORT_CGI=22952
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
pss_of() {
    local total=0 pid kb
    for pid in $(pgrep -f "$1" 2>/dev/null); do
        kb=$(awk '/^Pss:/{print $2}' /proc/"$pid"/smaps_rollup 2>/dev/null)
        total=$(( total + ${kb:-0} ))
    done
    echo $(( total / 1024 ))
}

# A pooled backend is matched by pattern, and so is a `node --cluster` origin: its master
# spends no CPU while twelve children do the work. Charging only the master reported
# "0.00 cores / 0.0 us per request" for the busiest process on the box.
ns_of_pattern() {
    local total=0 pid v
    for pid in $(pgrep -f "$1" 2>/dev/null); do
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
PHP_WRAPPER="$PROBE/php-bench"
cat > "$PHP_WRAPPER" <<WRAPPER
#!/bin/sh
exec $(command -v php) -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \\
    -d opcache.jit=off -d xdebug.mode=off -d memory_limit=512M "\$@"
WRAPPER
chmod +x "$PHP_WRAPPER"

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
    "$ROOT/conf/hello-worker.toml.template" > "$WK/cfg.toml"
"$BIN" serve -c "$WK/cfg.toml" >"$WK/volucer.log" 2>&1 &
VOL_W=$!

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
if [ -n "$VOL_C" ]; then
    # A cold arm needs longer: every one of its workers is a fresh `php-cgi` that has to
    # bind before it can answer.
    for _ in $(seq 1 900); do curl -sf -o /dev/null "http://127.0.0.1:$PORT_CGI/" && break; sleep 0.05; done
fi
for _ in $(seq 1 400); do curl -sf -o /dev/null "http://127.0.0.1:$PORT_UPSTREAM/" && break; sleep 0.05; done
sleep 2

# ---- guards ---------------------------------------------------------------------------
echo "=== bodies"
declare -A BODY PORT PID BACKEND
PORT[attach]=$PORT_ATTACH;   PID[attach]=$VOL_A;  BACKEND[attach]="supervisor.php unix:$AT/relay"
PORT[worker]=$PORT_WORKER;   PID[worker]=$VOL_W;  BACKEND[worker]="apps/hello/worker.php"
PORT[upstream]=$PORT_UPSTREAM; PID[upstream]=$VOL_U; BACKEND[upstream]="fastify-hello.js --port $PORT_ORIGIN"
PORT[node]=$PORT_ORIGIN;     PID[node]=$ORIGIN;   BACKEND[node]="fastify-hello.js --port $PORT_ORIGIN"
ARMS="attach worker upstream node"
if [ -n "$VOL_C" ]; then
    PORT[cgi]=$PORT_CGI; PID[cgi]=$VOL_C; BACKEND[cgi]="php-cgi"
    ARMS="attach worker cgi upstream node"
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
    kill $VOL_A $VOL_W $VOL_U $ORIGIN $SUP_A $VOL_C 2>/dev/null
    pkill -f "supervisor.php unix:$AT/relay" 2>/dev/null
    pkill -f "apps/hello/worker.php" 2>/dev/null
    exit 1
fi

echo "=== backend processes"
printf "  attach    %s php children\n" "$(pgrep -fc "supervisor.php unix:$AT/relay" 2>/dev/null || echo 0)"
printf "  worker    %s php processes\n" "$(pgrep -fc "apps/hello/worker.php" 2>/dev/null || echo 0)"
printf "  cgi       %s php-cgi processes\n" "$(pgrep -c -x php-cgi 2>/dev/null || echo 0)"
printf "  node      %s node processes\n" "$(pgrep -fc "fastify-hello.js --port $PORT_ORIGIN" 2>/dev/null || echo 0)"

# ---- measure --------------------------------------------------------------------------
measure() {
    local arm=$1 tag=$2
    local vol=${PID[$arm]} be="${BACKEND[$arm]}"
    local b0 b1 f0 f1 peak=0
    local sample="$PROBE/pss-$tag"

    b0=$(ns_of_pattern "$be"); f0=$(ns_of "$vol")
    wrk -t"$CORES" -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:${PORT[$arm]}/" \
        >"$PROBE/wrk-$tag.txt" 2>&1 &
    local wrk_pid=$!
    # Sample PSS while the load runs: the figure that matters is the backend's steady-state
    # footprint, not what it had before anything connected.
    ( while kill -0 $wrk_pid 2>/dev/null; do pss_of "$be"; sleep 0.5; done ) >"$sample" 2>/dev/null &
    local sampler=$!
    wait $wrk_pid
    kill $sampler 2>/dev/null
    b1=$(ns_of_pattern "$be"); f1=$(ns_of "$vol")
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
    # Rotate the order so no arm always gets the coldest or the quietest slot.
    if [ -n "$VOL_C" ]; then
        case $(( round % 5 )) in
            1) ORDER="attach worker cgi upstream node" ;;
            2) ORDER="node upstream cgi worker attach" ;;
            3) ORDER="cgi node attach upstream worker" ;;
            4) ORDER="upstream attach node worker cgi" ;;
            0) ORDER="worker cgi upstream node attach" ;;
        esac
    else
        case $(( round % 4 )) in
            1) ORDER="attach worker upstream node" ;;
            2) ORDER="node upstream worker attach" ;;
            3) ORDER="worker node attach upstream" ;;
            0) ORDER="upstream attach node worker" ;;
        esac
    fi
    for arm in $ORDER; do measure "$arm" "$arm-r$round"; done
done

kill -TERM $VOL_A $VOL_W $VOL_U $ORIGIN 2>/dev/null
[ -n "$VOL_C" ] && kill -TERM "$VOL_C" 2>/dev/null
sleep 1.5
kill -9 $VOL_A $VOL_W $VOL_U $ORIGIN 2>/dev/null
[ -n "$VOL_C" ] && kill -9 "$VOL_C" 2>/dev/null
kill -TERM $SUP_A 2>/dev/null; sleep 0.5; kill -9 $SUP_A 2>/dev/null
pkill -f "supervisor.php unix:$AT/relay" 2>/dev/null
pkill -f "apps/hello/worker.php" 2>/dev/null
pkill -x php-cgi 2>/dev/null
pkill -f "fastify-hello.js --port $PORT_ORIGIN" 2>/dev/null
echo "--- detail: $PROBE/wrk-*.txt"
