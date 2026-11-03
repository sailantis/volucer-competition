#!/bin/bash
# Hello-world, two runtimes, one VM: volucer+attach/PHP against Node.js+Fastify.
#
# `bench.sh` answers "how fast is each deployment" with one blocked sweep per arm.
# That layout is right for independent arms and wrong for a close question, because a
# host that drifts over twenty minutes charges the drift to whichever arm ran last.
# This repository has already published a 22% "effect" that reversed sign when the
# same two binaries were interleaved (hazard 49). So this harness runs every variant
# **inside the same round**, rotates which variant goes first, and reports the rate
# ratio of each round plus its spread. A number here is a ratio, not a rate.
#
# What is compared
# ----------------
#
#   volucer+attach   volucer `attach`, PHP. One boot, then accept-and-fork; the
#                    server dials a unix relay and holds one connection per slot.
#   volucer+worker   volucer `worker`, PHP. The control for the fork: one `exec`ed
#                    process per slot, so its own OPcache and its own boot.
#   fastify-reuse    Node 24 + Fastify 5, one process per core, `SO_REUSEPORT` so
#                    the kernel places each connection. No master in the data path.
#   fastify-cluster  Node 24 + Fastify 5, the reference `pm2 -i max` shape: a master
#                    accepts and distributes round-robin. One extra process and one
#                    extra hop per connection.
#
# The page is the same on all four: `GET /` -> `{"hello":"world"}`, serialised by
# Fastify's response schema on the Node side and by `json_encode()` on the PHP side,
# so each arm pays its own runtime's "tiny object to JSON" cost and neither gets a
# shortcut the other cannot take.
#
# Why wrk is primary and autocannon is the cross-check
# ----------------------------------------------------
#
# The Fastify benchmark this arm comes from uses `autocannon -c 100 -d 40 -p 10`.
# `-p 10` pipelines ten requests per connection, so at `-c 100` there are 1000
# requests outstanding: that measures how a server queues rather than how it serves,
# and a runtime that answers faster is rewarded with a longer queue rather than a
# higher rate. autocannon is also a single-threaded Node process, so on this 12-core
# box it becomes the bottleneck before a clustered server does — both arms would then
# read the *generator's* ceiling, and the comparison would be of nothing.
#
# So `wrk` is the primary instrument: one epoll thread per connection, it is what the
# published volucer numbers were measured with, and it does not pipeline by default.
# autocannon at the reference settings is run as a **published cross-check**, so the
# numbers can be tied back to the benchmark this arm is quoting. Rows record which
# generator produced them; they are never averaged together.
#
# Usage
# -----
#   bash scripts/hello-bench.sh                       # the full comparison
#   ARMS=volucer+attach,fastify-reuse bash scripts/hello-bench.sh
#   PROC_LIST=12 bash scripts/hello-bench.sh          # one process count
#   GEN=wrk bash scripts/hello-bench.sh               # primary instrument only
#   ROUNDS=3 DUR=3s bash scripts/hello-bench.sh       # a smoke run
#
# Environment
# -----------
#   BIN           volucer release binary   (default ~/hello-bench/bin/volucer)
#   NODE          node binary              (default `node` on PATH)
#   ROOT          this checkout            (default the script's parent directory)
#   RUNDIR        scratch + results        (default ~/hello-bench-run)
#   ARMS          variants to measure      (default all four)
#   PROC_LIST     one entry per arm size   (default 12,16,32)
#   CONC_LIST     wrk connections          (default 32,100)
#   DUR           seconds per cell         (default 10s)
#   ROUNDS        rotations                (default 5)
#   GEN           wrk | autocannon | both  (default both)
#   AC_CONC       autocannon connections   (default 100)
#   AC_PIPE       autocannon pipeline      (default 10)
#   KEEP          1 to leave the run dir    (default 0 for the servers, results stay)
set -uo pipefail

# The rows are TAB-separated numbers that other tools read back. Under a comma-decimal
# locale `printf '%.3f'` writes `1,000` where the reader expects `1.000`, and the row
# silently becomes a different measurement.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(dirname "$SCRIPT_DIR")}"
BIN="${BIN:-$HOME/hello-bench/bin/volucer}"
NODE="${NODE:-$(command -v node || true)}"
RUNDIR="${RUNDIR:-$HOME/hello-bench-run}"

ARMS="${ARMS:-volucer+attach,volucer+worker,fastify-reuse,fastify-cluster,volucer+upstream}"
PROC_LIST="${PROC_LIST:-12,16,32}"
CONC_LIST="${CONC_LIST:-32,100}"
DUR="${DUR:-10s}"
ROUNDS="${ROUNDS:-5}"
GEN="${GEN:-both}"
AC_CONC="${AC_CONC:-100}"
AC_PIPE="${AC_PIPE:-10}"
AC_DUR="${AC_DUR:-${DUR%s}}"
# Seconds of unmeasured load before an arm's first measured cell of a round. The pool
# must be saturated before the first cell, or round 1 of the first arm is a cold-start
# number — exactly the asymmetry the rotation exists to remove.
WARMUP="${WARMUP:-3}"
# Sequential per-request latency, the published methodology, run once per (arm, size)
# after the sweep. Set to 0 to skip: it adds about a minute per arm.
LATENCY="${LATENCY:-1}"
LAT_ITERS="${LAT_ITERS:-1000}"
LAT_RUNS="${LAT_RUNS:-5}"

BASE_PORT="${BASE_PORT:-21300}"
# The `volucer+upstream` arm's Fastify origin listens above the front-end port, far
# enough that no (arm, size) cell can collide with another arm's front-end. It is a
# fixed offset rather than a second base so the port stays derivable from one number.
ORIGIN_PORT_OFFSET="${ORIGIN_PORT_OFFSET:-100}"
SOCKET_DIR="$RUNDIR/sockets"
CFG="$RUNDIR/config"
LOG="$RUNDIR/log"
RESULTS="$RUNDIR/hello.tsv"
LATENCY_RESULTS="$RUNDIR/latency.tsv"
META="$RUNDIR/meta.txt"

fail() { echo "FATAL: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1; }

# --- preflight ---------------------------------------------------------------
[ -x "$BIN" ] || fail "no volucer binary at $BIN (set BIN)"
[ -n "$NODE" ] && [ -x "$NODE" ] || fail "no node on PATH (set NODE)"
[ -f "$ROOT/composer.json" ] || fail "no checkout at $ROOT (set ROOT)"
[ -d "$ROOT/vendor" ] || fail "$ROOT/vendor is missing - run: composer install"
need wrk || fail "wrk is not installed"
need curl || fail "curl is not installed"
need php || fail "php is not installed"

# The Node arm needs its dependencies. Installed here rather than assumed, because a
# checkout that never ran the Node arm has no `node_modules` and the failure would
# otherwise appear as a listen error inside a log file.
if [ ! -d "$ROOT/node_modules/fastify" ]; then
    echo "hello-bench: installing the Node arm's dependencies (fastify, autocannon)"
    ( cd "$ROOT" && "$NODE" "$(dirname "$NODE")/npm" install --no-audit --no-fund >/dev/null 2>&1 ) ||
        fail "could not install fastify/autocannon in $ROOT (run: npm install)"
fi

mkdir -p "$RUNDIR" "$CFG" "$LOG"
rm -rf "$SOCKET_DIR"
mkdir -p "$SOCKET_DIR"

# --- the fair PHP ------------------------------------------------------------
#
# `php` as installed is not configured like the other arms' PHP, and hazard 28 is the
# record of what that costs: `opcache.enable_cli` is Off for CLI PHP, so a worker
# started this way recompiles every file per *process start* rather than sharing a
# precompiled segment. On a hello page that is small, and it is still the wrong
# configuration to compare against a JIT-less Node runtime that precompiles its JS
# once at require time.
#
# The wrapper is a shell script rather than a `-d` list because volucer runs the
# configured command through its own tokenizer, not through a shell.
PHP_WORKER_WRAPPER="$RUNDIR/php-hello-worker"
cat > "$PHP_WORKER_WRAPPER" <<WRAPPER
#!/bin/sh
exec $(command -v php) -d opcache.enable_cli=1 \\
    -d opcache.validate_timestamps=0 \\
    -d opcache.jit=off \\
    -d xdebug.mode=off \\
    -d memory_limit=512M "\$@"
WRAPPER
chmod +x "$PHP_WORKER_WRAPPER"

# `attach` runs the supervisor itself, so it gets the same settings by the same route.
# A supervisor started bare would boot the application under a different ini than the
# worker arm — two arms differing in something other than the fork.
PHP_SUPERVISOR="$RUNDIR/php-hello-supervisor"
cat > "$PHP_SUPERVISOR" <<WRAPPER
#!/bin/sh
exec $(command -v php) -d opcache.enable_cli=1 \\
    -d opcache.validate_timestamps=0 \\
    -d opcache.jit=off \\
    -d xdebug.mode=off \\
    -d memory_limit=512M "\$@"
WRAPPER
chmod +x "$PHP_SUPERVISOR"

stamp() {
    # stamp <template> <output> [ more sed args... ]
    local template="$1" output="$2"
    shift 2
    sed -e "s#{{ROOT}}#$ROOT#g" \
        -e "s#{{PHP}}#$PHP_WORKER_WRAPPER#g" \
        -e "s#{{SOCKET_DIR}}#$SOCKET_DIR#g" \
        "$@" "$template" > "$output"
}

# --- lifecycle ---------------------------------------------------------------
#
# Two arms are process *trees*: a supervisor forks children, and a cluster master
# forks workers. The `volucer+upstream` arm is a tree of trees — volucer plus a
# Fastify cluster behind it. Killing the process it was started with would leave the
# children holding a port, and the next arm would then be measured against a pool that
# is still serving. The group is the unit that shutdown can address.
ARM_PGID=""
SUPERVISOR_PGID=""
ORIGIN_PGID=""

stop_arm() {
    local pgid
    # The origin is a cluster master whose children hold the origin port, so it has to
    # be reaped before volucer is stopped and before the next arm binds. It is listed
    # with the supervisor rather than the arm because it is *not* part of the thing
    # being measured.
    for pgid in "$SUPERVISOR_PGID" "$ORIGIN_PGID" "$ARM_PGID"; do
        [ -n "$pgid" ] || continue
        kill -TERM -- "-$pgid" 2>/dev/null
        for _ in $(seq 1 40); do
            kill -0 -- "-$pgid" 2>/dev/null || break
            sleep 0.25
        done
        kill -KILL -- "-$pgid" 2>/dev/null
    done
    for pgid in "$SUPERVISOR_PGID" "$ORIGIN_PGID" "$ARM_PGID"; do
        [ -n "$pgid" ] && wait "$pgid" 2>/dev/null
    done
    ARM_PGID=""
    SUPERVISOR_PGID=""
    ORIGIN_PGID=""
    # The relay is a file: a leftover one makes the next `attach` arm connect to a
    # supervisor that is gone, which looks like an attach bug and is a harness bug.
    rm -f "$SOCKET_DIR"/relay*
}

finish() {
    stop_arm
    reap_strays
}

trap finish EXIT

# --- the leak guard ----------------------------------------------------------
#
# A run that leaks processes corrupts the next one, and every arm here is a process
# tree. Leftover children hold the port they were started on, so the arm that follows
# is measured against a host that is still serving the previous one. This is the same
# guard `bench.sh` carries, extended to the Node arms.
#
# `ps -eww` is required: without `-ww` the argument column is truncated to the
# terminal width, and a long wrapper command line would lose its marker.
arm_pids() {
    ps -eww -o pid=,args= 2>/dev/null | awk '
        /hello\/(supervisor|worker)\.php|fastify-hello\.js/ && $0 !~ /awk/ { print $1 }'
}

count_arm_pids() {
    arm_pids | wc -w | tr -d " "
}

reap_strays() {
    local pids
    pids="$(arm_pids)"
    [ -n "${pids// /}" ] || return 0
    kill $pids 2>/dev/null
    sleep 1
    pids="$(arm_pids)"
    if [ -n "${pids// /}" ]; then
        echo "  survivors after SIGTERM: $(arm_pids | tr '\n' ' ')"
        kill -9 $pids 2>/dev/null
        sleep 1
    fi
    return 0
}

guard_arm() {
    local arm="$1" n
    n="$(count_arm_pids)"
    if [ "$n" = "0" ]; then
        echo "  leak check [$arm]: clean"
        return 0
    fi
    echo "  leak check [$arm]: $n processes left behind, reaping"
    reap_strays
    n="$(count_arm_pids)"
    if [ "$n" != "0" ]; then
        echo "  leak check [$arm]: FAILED - $n survived SIGTERM and SIGKILL"
        echo "  argv: $(ps -eww -o args= -p "$(arm_pids | tr '\n' ',' | sed 's/,$//')" 2>/dev/null | head -1)"
        echo "  refusing to continue: the next arm would be measured against a leaked pool"
        exit 1
    fi
    echo "  leak check [$arm]: cleared"
    return 0
}

wait_port() {
    local port="$1"
    for _ in $(seq 1 240); do
        curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/" 2>/dev/null && return 0
        sleep 0.25
    done
    return 1
}

wait_socket() {
    local path="$1"
    for _ in $(seq 1 160); do
        [ -S "$path" ] && return 0
        sleep 0.25
    done
    return 1
}

# --- one request that must succeed, or the arm is not measured ---------------
#
# A server that starts but answers the wrong thing would otherwise publish a
# real-looking throughput number for an arm that never served the page. The body, the
# content type and the status are all checked, and the body is the exact bytes the
# Fastify arm produces: a comparison of two different documents measures the
# documents.
check_page() {
    local port="$1"
    local body code ctype
    body="$(curl -sS --max-time 10 "http://127.0.0.1:$port/" 2>/dev/null)"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$port/" 2>/dev/null)"
    ctype="$(curl -s -o /dev/null -w '%{content_type}' --max-time 10 "http://127.0.0.1:$port/" 2>/dev/null)"

    if [ "$code" != "200" ]; then
        echo "  sanity FAILED /: HTTP $code"
        [ -n "$body" ] && echo "  body: $(echo "$body" | head -c 200)"
        return 1
    fi
    if [ "$body" != '{"hello":"world"}' ]; then
        echo "  sanity FAILED /: body is $(echo "$body" | head -c 120)"
        return 1
    fi
    case "$ctype" in
        application/json*) return 0 ;;
        *)
            echo "  sanity FAILED /: content type is $ctype"
            return 1
            ;;
    esac
}

# --- starting one arm -------------------------------------------------------
#
# `setsid` puts the arm in a new process group so `stop_arm` can address the tree.
# A readiness *port* poll rather than a sleep: the arms boot very differently (PHP
# boots a framework, Node compiles Fastify's route table), and a fixed sleep would
# either waste a run or measure one.
start_arm() { # arm port workers
    local arm="$1" port="$2" workers="$3"

    case "$arm" in
        volucer+attach)
            rm -f "$SOCKET_DIR/relay"
            stamp "$ROOT/conf/hello-attach.toml.template" "$CFG/attach-$workers.toml" \
                -e "s#{{PORT}}#$port#g" -e "s#{{WORKERS}}#$workers#g"
            # The supervisor first: volucer only dials, so starting it second would
            # make the pool's boot fail on a socket that is not there yet — which
            # looks like an attach bug and is an ordering bug in the harness.
            setsid "$PHP_SUPERVISOR" "$ROOT/apps/hello/supervisor.php" "unix:$SOCKET_DIR/relay" \
                >"$LOG/$arm-$workers-supervisor.log" 2>&1 &
            SUPERVISOR_PGID=$!
            wait_socket "$SOCKET_DIR/relay" || {
                echo "  $arm: the supervisor never created $SOCKET_DIR/relay" >&2
                tail -4 "$LOG/$arm-$workers-supervisor.log" 2>/dev/null | sed 's/^/    /' >&2
                return 1
            }
            setsid "$BIN" serve -c "$CFG/attach-$workers.toml" >"$LOG/$arm-$workers.log" 2>&1 &
            ARM_PGID=$!
            ;;
        volucer+worker)
            stamp "$ROOT/conf/hello-worker.toml.template" "$CFG/worker-$workers.toml" \
                -e "s#{{PORT}}#$port#g" -e "s#{{WORKERS}}#$workers#g"
            setsid "$BIN" serve -c "$CFG/worker-$workers.toml" >"$LOG/$arm-$workers.log" 2>&1 &
            ARM_PGID=$!
            ;;
        fastify-reuse | fastify-cluster)
            local mode="reuseport"
            [ "$arm" = "fastify-cluster" ] && mode="cluster"
            setsid "$NODE" "$ROOT/apps/hello/fastify-hello.js" \
                --port "$port" --workers "$workers" --cluster "$mode" \
                >"$LOG/$arm-$workers.log" 2>&1 &
            ARM_PGID=$!
            ;;
        volucer+upstream)
            # The origin first, and on its own port: volucer's `upstream` backend dials
            # one address, so the fan-out has to come from Node's own clustering. Same
            # worker count as the PHP arm, which is what keeps the comparison about the
            # runtime rather than about how many processes each side happens to run.
            local origin_port=$((port + ORIGIN_PORT_OFFSET))
            setsid "$NODE" "$ROOT/apps/hello/fastify-hello.js" \
                --port "$origin_port" --workers "$workers" --cluster reuseport \
                >"$LOG/$arm-$workers-origin.log" 2>&1 &
            ORIGIN_PGID=$!
            if ! wait_port "$origin_port"; then
                echo "  $arm: the Fastify origin never became ready on port $origin_port" >&2
                tail -6 "$LOG/$arm-$workers-origin.log" 2>/dev/null | sed 's/^/    /' >&2
                return 1
            fi
            stamp "$ROOT/conf/hello-upstream.toml.template" "$CFG/upstream-$workers.toml" \
                -e "s#{{PORT}}#$port#g" -e "s#{{ORIGIN_PORT}}#$origin_port#g"
            setsid "$BIN" serve -c "$CFG/upstream-$workers.toml" >"$LOG/$arm-$workers.log" 2>&1 &
            ARM_PGID=$!
            ;;
        *)
            echo "  unknown arm '$arm'" >&2
            return 1
            ;;
    esac

    if ! wait_port "$port"; then
        echo "  $arm: never became ready on port $port" >&2
        tail -6 "$LOG/$arm-$workers.log" 2>/dev/null | sed 's/^/    /' >&2
        return 1
    fi

    return 0
}

# `attach` needs both of its process groups stopped, and both are already tracked, so
# this is `stop_arm` by another name — kept as a separate call site because it is the
# point at which a reader asks "does the supervisor get stopped too".
stop_arm_full() {
    stop_arm
}

# --- the instruments ---------------------------------------------------------
#
# The primary: wrk, `nproc` load-generator threads, no pipelining.
#
# **`-t` is the core count, not the connection count.** It used to be `-t"$conc"`, which
# puts one *load-generator* thread per connection: at `c=400` that is 400 threads on a
# 12-core host, i.e. 138% oversubscription, and the resulting churn lands hardest on
# whichever server schedules more threads of its own. Measured on a 12-core VM, the same
# arm went 44,031 rps at `-t400` to 107,510 at `-t12`. Every cross-arm CPU figure taken
# with `-t<c>` was partly measuring the scheduler.
run_wrk() { # arm workers conc
    local arm="$1" workers="$2" conc="$3"
    local port=$((BASE_PORT + workers))
    local url="http://127.0.0.1:$port/"
    local threads=${WRK_THREADS:-$(nproc)}
    local out rps p50 p99

    out=$(wrk -t"$threads" -c"$conc" -d"$DUR" --latency "$url" 2>/dev/null)
    # `exit` after the first match, and the percentile patterns anchored to a leading
    # percentage: without both, a second matching line is concatenated into the field
    # and the TAB-separated row silently splits in two. Found by reading a summary
    # whose arm column contained "3.77ms".
    rps=$(echo "$out" | awk '/^Requests\/sec:/ {print $2; exit}')
    p50=$(echo "$out" | awk '/^[[:space:]]+50%/ {print $2; exit}')
    p99=$(echo "$out" | awk '/^[[:space:]]+99%/ {print $2; exit}')

    if [ -z "$rps" ] || [ -z "$p50" ] || [ -z "$p99" ]; then
        echo "  wrk conc $conc $arm  FAILED (incomplete wrk output)"
        printf '%s\t%s\t%s\t%s\t%s\tFAIL\t?\t?\t?\n' \
            "wrk" "$arm" "$workers" "$conc" "$ROUND" >> "$RESULTS"
        return 1
    fi

    printf "  %-22s procs %3s  wrk c%-4s  %10s rps  p50 %8s  p99 %8s\n" \
        "$arm" "$workers" "$conc" "$rps" "$p50" "$p99"
    printf '%s\t%s\t%s\t%s\t%s\tOK\t%s\t%s\t%s\n' \
        "wrk" "$arm" "$workers" "$conc" "$ROUND" "$rps" "$p50" "$p99" >> "$RESULTS"
}

# The cross-check: the Fastify benchmark's own settings, so the result can be tied
# back to the benchmark this arm comes from. A single-threaded Node generator with ten
# requests pipelined per connection, at the reference 100 connections — 1000 requests
# outstanding. Published beside the wrk rows, never merged with them.
run_autocannon() { # arm workers
    local arm="$1" workers="$2"
    local port=$((BASE_PORT + workers))
    local out rps p50 p99

    out=$("$NODE" "$SCRIPT_DIR/hello-autocannon.js" \
        --url "http://127.0.0.1:$port/" \
        --connections "$AC_CONC" --pipeline "$AC_PIPE" --duration "$AC_DUR" 2>/dev/null)
    rps=$(echo "$out" | awk -F'\t' '$1=="rps" {print $2; exit}')
    p50=$(echo "$out" | awk -F'\t' '$1=="p50" {print $2; exit}')
    p99=$(echo "$out" | awk -F'\t' '$1=="p99" {print $2; exit}')

    if [ -z "$rps" ] || [ -z "$p50" ] || [ -z "$p99" ]; then
        echo "  autocannon $arm  FAILED"
        printf '%s\t%s\t%s\t%s\t%s\tFAIL\t?\t?\t?\n' \
            "autocannon" "$arm" "$workers" "$AC_CONC" "$ROUND" >> "$RESULTS"
        return 1
    fi

    printf "  %-22s procs %3s  ac  c%-4s  %10s rps  p50 %8s  p99 %8s\n" \
        "$arm" "$workers" "$AC_CONC" "$rps" "$p50" "$p99"
    printf '%s\t%s\t%s\t%s\t%s\tOK\t%s\t%s\t%s\n' \
        "autocannon" "$arm" "$workers" "$AC_CONC" "$ROUND" "$rps" "$p50" "$p99" >> "$RESULTS"
}

# --- sequential latency ------------------------------------------------------
#
# Reuses `scripts/latency.php` — the same instrument the published sequential figures
# came from — rather than a second implementation, so a number here is measured the
# same way as one there. It takes positional arguments and one line per run; the
# aggregation across runs happens here.
#
# A different question from the sweep, and worth having beside it: a 32-slot server at
# concurrency 1 has 31 idle slots, so a cell here is the cost of ONE request, while the
# sweep is the behaviour of a busy pool. Reporting only the sweep is what let this
# project compare its numbers against published latency ratios without noticing it was
# measuring something else.
#
# The marker is the exact body, because a 200 is not evidence: a 404 page is served
# faster than a rendered one, and an arm that never served the page would otherwise
# look like the fastest arm in the run.
run_latency() { # arm workers
    local arm="$1" workers="$2"
    [ "$LATENCY" = "1" ] || return 0

    local port=$((BASE_PORT + workers))
    local out p50 p95

    out=$(php "$SCRIPT_DIR/latency.php" "http://127.0.0.1:$port" "/" \
        "$LAT_ITERS" "$LAT_RUNS" "$arm" '{"hello":"world"}' 2>/dev/null)

    # Column 3 is the per-run median and column 6 the per-run p95. The reported figure
    # is the median of the per-run medians: robust to one slow run without hiding it,
    # and the spread across runs is what the report shows.
    p50=$(echo "$out" | awk -F'\t' 'NF>=6 && $2 ~ /^[0-9]+$/ {print $3}' | sort -n |
        awk '{a[NR]=$1} END {if (NR) print a[int((NR+1)/2)]}')
    p95=$(echo "$out" | awk -F'\t' 'NF>=6 && $2 ~ /^[0-9]+$/ {print $6}' | sort -n |
        awk '{a[NR]=$1} END {if (NR) print a[int((NR+1)/2)]}')

    if [ -z "$p50" ] || [ -z "$p95" ]; then
        echo "  latency $arm  FAILED"
        return 1
    fi

    printf "  %-22s procs %3s  seq c1       p50 %8s ms  p95 %8s ms\n" \
        "$arm" "$workers" "$p50" "$p95"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$arm" "$workers" "$ROUND" "$p50" "$p95" >> "$LATENCY_RESULTS"
}

# --- the sweep ---------------------------------------------------------------
#
# The rotation is the estimator. Within one round every arm is measured back to back,
# and the order rotates each round, so a drift of *any* shape lands on every arm
# equally often. What is reported per round is the ratio between arms, not the rate,
# and the spread across rounds is the error bar.
round_order() { # round -> the arms, rotated
    local round="$1"
    local -a all
    IFS=',' read -ra all <<< "$ARMS"
    local n=${#all[@]}
    local shift=$(( (round - 1) % n ))
    local i
    for (( i = 0; i < n; i++ )); do
        echo "${all[$(( (i + shift) % n ))]}"
    done
}

: > "$RESULTS"
: > "$LATENCY_RESULTS"
: > "$META"

{
    echo "hello-bench"
    echo "  date        $(date -Is)"
    echo "  host        $(nproc) cores, $(free -m | awk '/Mem:/ {print $2}') MB, $(uname -sr)"
    echo "  volucer     $("$BIN" version 2>/dev/null | head -1)"
    echo "  node        $("$NODE" --version 2>/dev/null)"
    echo "  npm         $("$NODE" "$(dirname "$NODE")/npm" --version 2>/dev/null)"
    echo "  fastify     $("$NODE" -e 'console.log(require(process.argv[1] + "/node_modules/fastify/package.json").version)' "$ROOT" 2>/dev/null)"
    echo "  autocannon  $("$NODE" -e 'console.log(require(process.argv[1] + "/node_modules/autocannon/package.json").version)' "$ROOT" 2>/dev/null)"
    echo "  php         $(php -v 2>/dev/null | head -1)"
    echo "  php opcache $(php -d opcache.enable_cli=1 -r 'echo opcache_get_status(false)["opcache_enabled"] ? "on" : "off";' 2>/dev/null)"
    echo "  wrk         $(wrk --version 2>/dev/null | head -1)"
    echo "  arms        $ARMS"
    echo "  procs       $PROC_LIST"
    echo "  conc        $CONC_LIST"
    echo "  duration    $DUR  rounds $ROUNDS  warmup ${WARMUP}s"
    echo "  generator   $GEN (wrk primary; autocannon c$AC_CONC -p$AC_PIPE as cross-check)"
} | tee "$META"
echo

PROC_LIST_ARR="${PROC_LIST//,/ }"
CONC_LIST_ARR="${CONC_LIST//,/ }"
LAST_CONC="$(echo $CONC_LIST_ARR | awk '{print $NF}')"

# The one arm whose PHP is forked from a shared heap is `attach`; the worker arm
# `exec`s, so its process count is exactly the number it was asked for. Both are
# recorded per row so the process count is never inferred from the rate.
for ROUND in $(seq 1 "$ROUNDS"); do
    echo "=== round $ROUND/$ROUNDS ==="

    for arm in $(round_order "$ROUND"); do
        for workers in $PROC_LIST_ARR; do
            port=$((BASE_PORT + workers))
            # A port per (arm, size) would be tidier, but the rotation means only one
            # arm is ever up at a time, and reusing the port is what makes an orphan
            # from a previous arm visible as a bind failure rather than as a silent
            # second server on a different port.
            stop_arm_full
            guard_arm "$arm"

            if ! start_arm "$arm" "$port" "$workers"; then
                printf '%s\t%s\t%s\t-\t%s\t%s\tSTARTFAIL\t?\t?\t?\n' \
                    "wrk" "$arm" "$workers" "$ROUND" "start" >> "$RESULTS"
                continue
            fi

            if ! check_page "$port"; then
                printf '%s\t%s\t%s\t-\t%s\t%s\tCHECKFAIL\t?\t?\t?\n' \
                    "wrk" "$arm" "$workers" "$ROUND" "check" >> "$RESULTS"
                stop_arm_full
                continue
            fi

            # Saturate before the first measured cell. Same rule as `run_wrk`: the
            # generator's thread count is the core count, not the connection count.
            wrk -t"${WRK_THREADS:-$(nproc)}" -c"$workers" -d"${WARMUP}s" "http://127.0.0.1:$port/" >/dev/null 2>&1

            for conc in $CONC_LIST_ARR; do
                case "$GEN" in
                    wrk) run_wrk "$arm" "$workers" "$conc" ;;
                    autocannon) run_autocannon "$arm" "$workers" ;;
                    both)
                        run_wrk "$arm" "$workers" "$conc"
                        # The cross-check is a different question, so it is run once per
                        # (arm, size) rather than once per cell: its settings do not
                        # change with the wrk concurrency, and repeating it at every
                        # concurrency would multiply the run time for copies of one
                        # measurement.
                        if [ "$conc" = "$LAST_CONC" ]; then
                            run_autocannon "$arm" "$workers"
                        fi
                        ;;
                esac
            done

            run_latency "$arm" "$workers"

            stop_arm_full
            guard_arm "$arm"
            echo
        done
    done
done

echo "=== rows: $RESULTS ==="
echo "=== latency: $LATENCY_RESULTS ==="
echo
echo "Summarise with: python3 scripts/hello-report.py $RESULTS"

if [ "${KEEP:-0}" != "1" ]; then
    rm -rf "$CFG" "$LOG"
fi
