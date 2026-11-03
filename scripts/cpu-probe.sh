#!/bin/sh
# Where the CPU goes, per arm, under load.
#
# The throughput table cannot answer the question that decides the fix: a path that is
# slower while using *less* CPU is starved or serialised, one that is slower while
# using *more* is doing more work. Those want opposite fixes.
#
# # Why processes are found by command line and not by process group
#
# `setsid` forks, so `$!` is the *pre-setsid* pid and not the new group's id — a probe
# that keys on it reads zero. Selecting by `ps -g` is worse: in procps `-g` means group
# *name*, so it silently summed the wrong set and reported a 110 s jump in a 20 s
# window. Each arm here already has a distinctive argv (a generated config path), so
# the argv is the identity and no pid bookkeeping is needed.
#
# # Why `/proc/<pid>/stat` and not `ps -o time=`
#
# Fields 13-16 of the raw stat line are utime, stime, **cutime and cstime** in clock
# ticks. The last two are the CPU of children the process has already reaped, which is
# exactly what a fork-per-connection supervisor accrues — its own `time=` would show a
# small fraction of the work it caused. Note the field numbers are for the *raw* line,
# whose field 1 is a parenthesised command name that may contain spaces: pgrp is `$4`
# (not `$5`, which is the session).
set -eu

ROOT="${ROOT:-$HOME/volucer-competition}"
BIN="${BIN:-$HOME/hello-bench/bin/volucer-fixed2}"
NODE="${NODE:-$HOME/hello-bench/bin/node-v24.11.1-linux-x64/bin/node}"
RUNDIR="${RUNDIR:-$HOME/cpu-probe}"
PORT="${PORT:-22600}"
ORIGIN=$((PORT + 100))
DUR="${DUR:-20}"
CONC="${CONC:-32}"
WORKERS="${WORKERS:-12}"

rm -rf "$RUNDIR"; mkdir -p "$RUNDIR"

# True when this process's argv contains any of the given markers.
matches() { # cmdline marker...
    line="$1"; shift
    for m in "$@"; do
        case "$line" in *"$m"*) return 0 ;; esac
    done
    return 1
}

cpu_of_markers() { # marker...
    for d in /proc/[0-9]*; do
        [ -r "$d/stat" ] && [ -r "$d/cmdline" ] || continue
        line=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null) || continue
        [ -n "$line" ] || continue
        matches "$line" "$@" || continue
        awk '{printf "%.2f\n", ($13 + $14 + $15 + $16) / 100.0}' "$d/stat" 2>/dev/null
    done | awk '{s += $1} END {printf "%.2f", s + 0}'
}

threads_of_markers() { # marker...
    total=0
    for d in /proc/[0-9]*; do
        [ -r "$d/stat" ] && [ -r "$d/cmdline" ] || continue
        line=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null) || continue
        [ -n "$line" ] || continue
        matches "$line" "$@" || continue
        n=$(awk '{print $20}' "$d/stat" 2>/dev/null)
        total=$((total + ${n:-0}))
    done
    echo "$total"
}

wait_url() {
    for _ in $(seq 1 120); do
        curl -s -o /dev/null --max-time 2 "$1" && return 0
        sleep 0.25
    done
    return 1
}

# One arm. The front-end markers come before `--`, the backend markers after. Reads a
# delta so that process boot is never charged to the load.
probe() { # label front_markers... -- backend_markers...
    label="$1"; shift
    front=""
    while [ "$1" != "--" ]; do front="$front $1"; shift; done
    shift
    back=$*

    # shellcheck disable=SC2086
    b_front=$(cpu_of_markers $front)
    # shellcheck disable=SC2086
    b_all=$(cpu_of_markers $front $back)

    wrk -t"$CONC" -c"$CONC" -d"${DUR}s" --latency "http://127.0.0.1:$PORT/" >"$RUNDIR/wrk-$label.txt" 2>&1 &
    wrkpid=$!
    sleep $((DUR - 2))
    # shellcheck disable=SC2086
    a_front=$(cpu_of_markers $front)
    # shellcheck disable=SC2086
    a_all=$(cpu_of_markers $front $back)
    wait "$wrkpid" 2>/dev/null || true

    rps=$(awk '/Requests\/sec/ {print $2}' "$RUNDIR/wrk-$label.txt")
    p50=$(awk '$1 == "50%" {print $2}' "$RUNDIR/wrk-$label.txt")
    window=$((DUR - 2))
    echo "  $label: $rps rps, p50 ${p50:-?}"
    # shellcheck disable=SC2086
    echo "    front-end $(awk -v a="$b_front" -v b="$a_front" -v w="$window" 'BEGIN{printf "%.2f", (b-a)/w}') cores, threads $(threads_of_markers $front)"
    if [ -n "$back" ]; then
        # shellcheck disable=SC2086
        echo "    backend   $(awk -v a="$b_all" -v b="$a_all" -v f="$b_front" -v g="$a_front" -v w="$window" 'BEGIN{printf "%.2f", ((b-a)-(g-f))/w}') cores, threads $(threads_of_markers $back)"
    fi
    # shellcheck disable=SC2086
    echo "    total     $(awk -v a="$b_all" -v b="$a_all" -v w="$window" 'BEGIN{printf "%.2f", (b-a)/w}') cores"
}

kill_markers() { # marker...
    for sig in TERM KILL; do
        for d in /proc/[0-9]*; do
            [ -r "$d/cmdline" ] || continue
            line=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null) || continue
            [ -n "$line" ] || continue
            matches "$line" "$@" || continue
            kill -"$sig" "${d#/proc/}" 2>/dev/null || true
        done
        # An `if`, not `[ ... ] && sleep`: the latter returns 1 on the KILL pass, and
        # `set -e` then exits the whole probe after the first arm.
        if [ "$sig" = "TERM" ]; then sleep 2; fi
    done
}

echo "=== volucer+attach ($WORKERS PHP workers) ==="
rm -f "$RUNDIR"/relay*
sed -e "s#{{PORT}}#$PORT#g" -e "s#{{WORKERS}}#$WORKERS#g" -e "s#{{SOCKET_DIR}}#$RUNDIR#g" \
    "$ROOT/conf/hello-attach.toml.template" >"$RUNDIR/attach.toml"
php -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \
    "$ROOT/apps/hello/supervisor.php" "unix:$RUNDIR/relay" >"$RUNDIR/sup.log" 2>&1 &
for _ in $(seq 1 40); do [ -S "$RUNDIR/relay" ] && break; sleep 0.25; done
"$BIN" serve -c "$RUNDIR/attach.toml" >"$RUNDIR/attach.log" 2>&1 &
wait_url "http://127.0.0.1:$PORT/" || { echo "  attach never started"; tail -3 "$RUNDIR/attach.log"; }
probe attach "$RUNDIR/attach.toml" -- supervisor.php
kill_markers "$RUNDIR/attach.toml" supervisor.php
echo

echo "=== volucer+upstream ($WORKERS Fastify origins) ==="
sed -e "s#{{PORT}}#$PORT#g" -e "s#{{ORIGIN_PORT}}#$ORIGIN#g" -e "s#{{ROOT}}#$ROOT#g" \
    "$ROOT/conf/hello-upstream.toml.template" >"$RUNDIR/upstream.toml"
"$NODE" "$ROOT/apps/hello/fastify-hello.js" --port "$ORIGIN" --workers "$WORKERS" --cluster reuseport \
    >"$RUNDIR/origin.log" 2>&1 &
wait_url "http://127.0.0.1:$ORIGIN/" || { echo "  origin never started"; tail -3 "$RUNDIR/origin.log"; }
"$BIN" serve -c "$RUNDIR/upstream.toml" >"$RUNDIR/upstream.log" 2>&1 &
wait_url "http://127.0.0.1:$PORT/" || { echo "  upstream never started"; tail -3 "$RUNDIR/upstream.log"; }
probe upstream "$RUNDIR/upstream.toml" -- "fastify-hello.js --port $ORIGIN"
kill_markers "$RUNDIR/upstream.toml" "fastify-hello.js --port $ORIGIN"
echo

echo "=== fastify-reuse ($WORKERS processes, no front-end) ==="
"$NODE" "$ROOT/apps/hello/fastify-hello.js" --port "$PORT" --workers "$WORKERS" --cluster reuseport \
    >"$RUNDIR/fastify.log" 2>&1 &
wait_url "http://127.0.0.1:$PORT/" || { echo "  fastify never started"; tail -3 "$RUNDIR/fastify.log"; }
probe fastify "fastify-hello.js --port $PORT" -- "nothing-matches-this"
kill_markers "fastify-hello.js --port $PORT"

echo "done"
