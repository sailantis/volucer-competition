#!/usr/bin/env bash
# Can a single volucer process scale? Five stages, each answering one question, because
# "scale" is not one number -- it is which knob runs out first.
#
#   STAGE=children  how many PHP children does it take, and where is the knee?
#   STAGE=conc      at a fixed child count, where does throughput stop rising?
#   STAGE=ceiling   does the front-end actually admit the connections offered to it?
#   STAGE=rt        does a different runtime thread count move the ceiling?
#   STAGE=clock     is the syscall-bound clock costing per-request CPU? (needs root)
#
# Every cell starts the supervisor and the front-end fresh, takes a DISCARDED warm-up pass,
# then times. The warm-up is part of the measurement, not a courtesy: the connection-adoption
# cascade happens inside the first second of load and was worth 6% of a run (Phase 20). A cell
# without a warm-up is measuring a pool being built twice.
#
#   probe-scale.sh <binary> [tag]
#
# Environment knobs:
#   STAGE        children | conc | ceiling | rt | clock   (default: children)
#   WORKERS      child count for stages that hold it fixed      (default: 96)
#   CONC         concurrency for stages that hold it fixed      (default: 100)
#   SECS         timed seconds per pass                        (default: 14)
#   PASSES       measured passes per cell, after the warm-up    (default: 2)
#   RT           runtime thread count for STAGE=children|conc   (default: unset = tokio's)
set -uo pipefail

# `wrk` reports "83657.18" and awk's output is dotted, but this host's locale is German,
# where `.` is not the decimal separator and bash's `printf %f` rejects the value outright
# ("Ungültige Zahl"). Every number in this script is machine-generated ASCII.
export LC_ALL=C

BIN=${1:?binary}
TAG=${2:-scale}
STAGE=${STAGE:-children}
WORKERS=${WORKERS:-96}
CONC=${CONC:-100}
SECS=${SECS:-14}
PASSES=${PASSES:-2}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORES=$(nproc)
PROBE="$ROOT/.probe/$TAG"

rm -rf "$PROBE"; mkdir -p "$PROBE"

# Leftovers are the worst bug class here: a previous run's supervisor still owns the relay,
# the new slot cannot bind, and the arm serves from a process nobody is looking at -- which
# reads as a configuration error rather than as a stale run. Anchored on this probe's own
# directory so it can only reach what this run started.
cleanup() {
    kill -TERM ${VOL:-} ${SUP:-} 2>/dev/null
    sleep 0.8
    kill -9 ${VOL:-} ${SUP:-} 2>/dev/null
    pkill -f "supervisor.php unix:$PROBE/" 2>/dev/null
    pkill -f "fastify-hello.js --port 22990" 2>/dev/null
    pkill -f "$PROBE/" 2>/dev/null
}
trap cleanup EXIT INT TERM

# ---- CPU accounting ----------------------------------------------------------------
# schedstat field 1 (ns), summed over every task: /proc/<pid>/schedstat reports the
# thread-group LEADER only, which reads as "0.00 cores" for a multi-threaded process while
# eleven threads are busy.
ns_of() {
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

threads_of() {
    local total=0 pid n
    for pid in "$@"; do
        n=$(ls /proc/"$pid"/task 2>/dev/null | wc -l)
        total=$(( total + ${n:-0} ))
    done
    echo "$total"
}

# ---- one cell ----------------------------------------------------------------------
# A cell is only valid on a quiet host. The previous cell ends at 100% box busy, so measuring
# straight into the next one charges the previous cell's tail to this one.
#
# Gated on *measured idle CPU*, not on loadavg. loadavg is an exponentially-damped average of
# runnable *and* uninterruptible tasks, so after a cell it reads 12-18 for minutes while
# nothing at all is running -- and a gate on it either waits forever or (worse, and what this
# probe did first) warns and measures anyway. `/proc/stat` sampled over a second says what the
# cores are doing right now, which is the thing that can contaminate a measurement.
cpu_idle() {
    local a b
    a=$(awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; print $5, t}' /proc/stat)
    sleep 1
    b=$(awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; print $5, t}' /proc/stat)
    awk -v a="$a" -v b="$b" 'BEGIN{
        split(a, x, " "); split(b, y, " ");
        di = y[1]-x[1]; dt = y[2]-x[2];
        if (dt <= 0) print 100; else printf "%.0f", 100*di/dt }'
}

wait_quiet() {
    local need=${1:-90} tries=${2:-120} idle
    for _ in $(seq 1 "$tries"); do
        idle=$(cpu_idle)
        [ "$idle" -ge "$need" ] && return 0
    done
    echo "    WARNING: host only ${idle}% idle after waiting; measuring anyway"
    return 0
}

cell() {
    local children=$1 conc=$2 label=$3 extra=${4:-}
    local d="$PROBE/$label"
    mkdir -p "$d"

    wait_quiet
    # A port derived from the label keeps concurrent cells from colliding; 22700+ is clear
    # of every other probe in this repo.
    local port=$(( 22700 + $(printf '%s' "$label" | cksum | cut -d' ' -f1) % 500 ))
    local relay="$d/relay"

    php -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 -d opcache.jit=off \
        -d xdebug.mode=off -d memory_limit=512M \
        "$ROOT/apps/hello/supervisor.php" "unix:$relay" >"$d/sup.log" 2>&1 &
    SUP=$!
    [ -n "${CELL_CORES:-}" ] && taskset -apc "0-$(( CELL_CORES - 1 ))" "$SUP" >/dev/null 2>&1
    local n=0
    for _ in $(seq 1 400); do [ -S "$relay" ] && break; sleep 0.05; n=$((n+1)); done
    if [ ! -S "$relay" ]; then
        echo "  $label: supervisor never listened"; cat "$d/sup.log" | head -5
        kill -9 $SUP 2>/dev/null; SUP=""; return 1
    fi

    sed -e "s|{{PORT}}|$port|g" -e "s|{{ROOT}}|$ROOT|g" \
        -e "s|{{WORKERS}}|$children|g" -e "s|{{SOCKET_DIR}}|$d|g" \
        "$ROOT/conf/hello-attach.toml.template" > "$d/cfg.toml"
    # The template already opens `[server]`, so appending a second `[server]` table is a
    # duplicate key and volucer refuses to start -- which surfaced as "REFUSING, not serving ()"
    # rather than as a parse error. Inject into the existing table instead, right after the
    # header, and fail loudly if the header is not where this expects it.
    if [ -n "$extra" ]; then
        awk -v extra="$extra" '
            /^\[server\]$/ && !done { print; print extra; done=1; next } { print }
            END { if (!done) { print "PATCH FAILED: no [server] header" > "/dev/stderr"; exit 1 } }
        ' "$d/cfg.toml" > "$d/cfg.toml.new" || return 1
        mv "$d/cfg.toml.new" "$d/cfg.toml"
    fi

    VOL=""
    env ${RT:+TOKIO_WORKER_THREADS=$RT} \
        "$BIN" serve -c "$d/cfg.toml" >"$d/volucer.log" 2>&1 &
    VOL=$!
    [ -n "${CELL_CORES:-}" ] && taskset -apc "0-$(( CELL_CORES - 1 ))" "$VOL" >/dev/null 2>&1

    for _ in $(seq 1 600); do curl -sf -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.05; done

    # Guard: a dead backend answers faster than a live one, so refuse rather than measure.
    local body; body=$(curl -s --max-time 5 "http://127.0.0.1:$port/")
    case "$body" in
        *'"hello"'*) : ;;
        *) echo "  $label: REFUSING, not serving ($body)"; cleanup; VOL=""; SUP=""; return 1 ;;
    esac

    local be_pat="supervisor.php unix:$relay"
    be_pids() { pgrep -f "$be_pat" 2>/dev/null; }

    # wrk refuses -c < -t, and -t<c> puts one generator thread per connection -- 138%
    # oversubscription at c=400 on a 12-core host, which biases every CPU figure against
    # whichever server schedules more threads. Fixed at the core count, capped at c.
    local wt=$CORES; [ "$wt" -gt "$conc" ] && wt=$conc
    [ -n "${CELL_CORES:-}" ] && { wt=$CELL_CORES; [ "$wt" -gt "$conc" ] && wt=$conc; }

    # DISCARDED warm-up. This is the pool being built, the adoption cascade, and the
    # OPcache being touched -- none of which is the thing being measured.
    wrk -t"$wt" -c"$conc" -d3s "http://127.0.0.1:$port/" >"$d/warm.txt" 2>&1

    local pass rps total p50 p99 bad
    local best_rps=0 sum_rps=0 sum_n=0 sum_fe=0 sum_be=0 sum_wrk=0 last_threads=0
    for pass in $(seq 1 "$PASSES"); do
        local f="$d/wrk-$pass.txt"
        local f0 f1 b0 b1 w0 w1
        f0=$(ns_of "$VOL"); b0=$(ns_of $(be_pids))
        wrk -t"$wt" -c"$conc" -d"${SECS}s" --latency "http://127.0.0.1:$port/" >"$f" 2>&1 &
        local wp=$!
        w0=$(ns_of "$wp" 2>/dev/null || echo 0)
        # wrk's threads vanish when it exits, so sample it near the end but while it lives.
        ( sleep $(( SECS > 4 ? SECS - 2 : 1 )); ns_of "$wp" >"$d/wrk-ns-$pass" 2>/dev/null ) &
        local samp=$!
        wait $wp
        wait $samp 2>/dev/null
        f1=$(ns_of "$VOL"); b1=$(ns_of $(be_pids))
        w1=$(cat "$d/wrk-ns-$pass" 2>/dev/null || echo "$w0")
        last_threads=$(threads_of "$VOL")

        rps=$(awk '/^Requests\/sec:/{print $2}' "$f")
        total=$(awk '/requests in /{print $1}' "$f")
        p50=$(awk '/^ +50%/{print $2}' "$f")
        p99=$(awk '/^ +99%/{print $2}' "$f")
        bad=$(awk -F: '/Non-2xx/{gsub(/ /,"",$2); print $2+0}' "$f"); bad=${bad:-0}

        sum_rps=$(awk -v a="$sum_rps" -v b="${rps:-0}" 'BEGIN{print a+b}')
        sum_n=$(( sum_n + ${total:-0} ))
        sum_fe=$(( sum_fe + (f1-f0) ))
        sum_be=$(( sum_be + (b1-b0) ))
        sum_wrk=$(( sum_wrk + (w1-w0) ))
        printf '    pass %s: %7.0f rps  p50 %-9s p99 %-9s  non2xx %s\n' \
            "$pass" "${rps:-0}" "${p50:-?}" "${p99:-?}" "$bad" \
            | tee -a "$d/passes.txt"
    done

    # The pool's own contention line, printed on graceful stop, is the instrument every
    # queueing claim in this record rests on -- so stop gracefully before reading it.
    kill -TERM "$VOL" 2>/dev/null
    for _ in $(seq 1 200); do kill -0 "$VOL" 2>/dev/null || break; sleep 0.05; done
    kill -9 "$VOL" 2>/dev/null
    # Reap it before moving on: an unreaped job makes bash announce "Killed" on the next
    # job-control event, which scrolls the result lines away and looks like a failure.
    wait "$VOL" 2>/dev/null
    VOL=""
    local slot; slot=$(grep '^slots:' "$d/volucer.log" 2>/dev/null | head -1)
    # `grep -c` prints 0 *and* exits 1 when it finds nothing, so `|| echo 0` appended a second
    # zero and the column read "rej 0\n0". Count with awk instead of compensating for grep.
    local refused replaced maxactive
    refused=$(awk '/refusing an HTTP connection/{n++} END{print n+0}' "$d/volucer.log" 2>/dev/null)
    replaced=$(awk '/replacing the worker|replacing it/{n++} END{print n+0}' "$d/volucer.log" 2>/dev/null)
    maxactive=$(grep -o 'active=[0-9]*' "$d/volucer.log" 2>/dev/null | sed 's/active=//' | sort -n | tail -1)

    kill -TERM "$SUP" 2>/dev/null; sleep 0.6; kill -9 "$SUP" 2>/dev/null
    wait "$SUP" 2>/dev/null
    SUP=""
    wait "$VOL" 2>/dev/null
    pkill -f "$be_pat" 2>/dev/null
    VOL=""; SUP=""

    local nreq=$sum_n
    awk -v t="$label" -v r="$sum_rps" -v p="$PASSES" \
        -v fe="$sum_fe" -v be="$sum_be" -v wk="$sum_wrk" \
        -v n="$nreq" -v s="$SECS" -v th="$last_threads" \
        -v rf="$refused" -v rc="$replaced" -v ma="${maxactive:-0}" -v ch="$children" -v c="$conc" \
        'BEGIN{
            rps = r/p; nr = (n>0? n : 1);
            fec = fe/1e9/s/p; bec = be/1e9/s/p; wkc = wk/1e9/s;
            box = (fec+bec+wkc);
            printf "  %-16s w=%-3s c=%-4s %7.0f rps | fe %5.2f c %5.1f us | be %5.2f c %5.1f us | wrk %4.2f | box %5.2f/12 %3.0f%% | thr %3d | rej %s repl %s maxact %s\n",
                   t, ch, c, rps, fec, fe/1e3/nr, bec, be/1e3/nr, wkc, box, box/12*100, th, rf, rc, ma;
        }'
    [ -n "$slot" ] && echo "                   $slot"
}

# ---- stages ------------------------------------------------------------------------
echo "=== binary: $BIN"
echo "=== version: $("$BIN" --version 2>/dev/null | awk '{print $2}')  sha $("$BIN" 2>/dev/null; sha256sum "$BIN" | cut -c1-12)"
echo "=== host: $(awk '{print $1}' /proc/loadavg) load, $CORES cores, $(cat /sys/devices/system/clocksource/clocksource0/current_clocksource) clock"
echo "=== stage=$STAGE workers=$WORKERS conc=$CONC secs=$SECS passes=$PASSES rt=${RT:-default} cores=${CELL_CORES:-all}"

case "$STAGE" in
children)
    # The front-end's per-request cost (Phase 18: ~38 us, flat) multiplied by the rate the
    # pool can sustain is the throughput. Children are what the pool draws from, so find the
    # knee: past it, extra processes are memory and context switches for no requests.
    for n in 12 24 48 96 144; do
        cell "$n" "$CONC" "w$n"
    done
    ;;
conc)
    # At a fixed child count, does throughput rise with concurrency, and where does it stop?
    # Constant throughput with rising p50 means queueing, and the p50 is what a client feels.
    for c in 50 100 200 400 800; do
        cell "$WORKERS" "$c" "c$c"
    done
    ;;
ceiling)
    # The front-end's `max_connections` defaults to 512. Offered more than that, it must
    # either refuse (and log it) or admit -- so offer 1000 and 2000 both ways. This is also
    # the stage that proves PR #2's leak fix: on an unfixed binary the refused connection
    # never gives its slot back, so `active` climbs away from the ceiling forever.
    for c in 600 1200; do
        cell "$WORKERS" "$c" "default-c$c"
    done
    # `cell` injects this immediately after the template's own `[server]` header, so it must
    # carry keys only -- a `[server]` line here would be the duplicate key above.
    printf 'max_connections = 0\n' > "$PROBE/uncapped.toml"
    # `cell`'s fourth argument is TOML *text*, not a path. Passing the path injected the
    # filename into the `[server]` table, which volucer refused to parse -- and the arm then
    # read as "REFUSING, not serving ()" rather than as a config error.
    for c in 600 1200; do
        cell "$WORKERS" "$c" "uncapped-c$c" "$(cat "$PROBE/uncapped.toml")"
    done
    ;;
rt)
    # Does the runtime thread count move the ceiling? Phase 18 recorded the front-end's cost
    # as flat at 38-40 us across c=48..200, which says the limit is not CPU -- so more threads
    # should not help either. This measures rather than assumes.
    RT=""
    cell "$WORKERS" "$CONC" "rt-default"
    for n in 6 8 16 24 48; do
        RT=$n
        cell "$WORKERS" "$CONC" "rt$n"
    done
    RT=""
    ;;
cores)
    # Does throughput track cores? This is what decides how to scale: if rps is linear in
    # cores, a bigger host or more hosts is the whole answer and nothing per-process is
    # limiting. If it plateaus on a subset of the cores offered, there is serialisation to
    # find. The two are very different problems.
    #
    # CELL_CORES pins the front-end *and* the supervisor, so the fork-shared children
    # inherit it -- pinning only the front-end would leave PHP free on the cores the cell is
    # supposed to have removed, and every cell would report "12 cores available".
    for n in 12 8 6 4 2; do
        CELL_CORES=$n
        cell "$WORKERS" "$CONC" "cores$n"
    done
    CELL_CORES=""
    ;;
clock)
    # The host's clocksource is `xen`, which is not vDSO-eligible -- so every clock read is a
    # syscall. Phase 18 counted 15.9 per request, ~3 us of a 38 us path. `tsc` with
    # constant_tsc is vDSO-eligible and would remove them. Needs root to switch.
    printf '    before: %s\n' "$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)"
    RT=""
    cell "$WORKERS" "$CONC" "clk-xen"
    if sudo -n bash -c 'echo tsc > /sys/devices/system/clocksource/clocksource0/current_clocksource' 2>/dev/null; then
        printf '    after:  %s\n' "$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)"
        cell "$WORKERS" "$CONC" "clk-tsc"
        # Put it back: the host's own choice is not this probe's to keep.
        sudo -n bash -c 'echo xen > /sys/devices/system/clocksource/clocksource0/current_clocksource' 2>/dev/null
        printf '    restored: %s\n' "$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)"
    else
        echo "    cannot switch clocksource without root; skipping the tsc arm"
    fi
    ;;
*)
    echo "unknown STAGE=$STAGE" >&2; exit 2 ;;
esac

echo "=== done"
