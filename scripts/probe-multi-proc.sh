#!/usr/bin/env bash
# One process with N threads, or N processes with ONE thread each?
#
# This is the experiment the whole trace points at. Summary of what is established, on this box:
#
#   external, rt=12   c=1 44.6   c=2 62.0   c=4 75.7   c=16 71.1   c=100 54.4
#   external, rt=1    c=1 47.8      --      c=4 45.5   c=16 43.9   c=100 43.7
#   upstream, rt=12   c=1 43.5               c=4 61.6               c=100 51.9
#   upstream, rt=1    c=1 45.6               c=4 31.3               c=100 34.6
#
# So a single runtime thread is CHEAPER PER REQUEST at every concurrency above one -- by 24% at
# c=100 -- but it cannot use more than one core, so its throughput stops at ~21k. A multi-threaded
# runtime buys parallelism and pays for it in per-request cost.
#
# That is a bad trade only because it is being made in ONE process. nginx and Node's cluster both
# take the other option: several processes, each with its own event loop, each on its own core,
# each connection staying inside one process for its whole life. If the per-request cost in that
# shape is the rt=1 cost, the aggregate is N x the single-threaded rate and nothing pays the
# coherence tax.
#
# Measured here as `N` volucer processes, each `TOKIO_WORKER_THREADS=1`, each pinned to its own
# core, each fed by its own generator. Total rps is the sum; `us/req` is the population-weighted
# mean over all of them, which is the number comparable to the single-process figures above.
#
# (Each process needs its own listening port -- volucer has no SO_REUSEPORT -- so the generator is
# split too. That does not change what is being measured: the comparison is per-request CPU of the
# front-end work, which is a property of how many threads share a connection's data.)
#
# Usage: probe-multi-proc.sh [secs] [children]
#   LAYOUTS="1x12 4x1 8x1"   where MxT = M processes, T runtime threads each
set -eu

SECS=${1:-10}
CHILDREN=${2:-96}
LAYOUTS=${LAYOUTS:-"1x12 4x1 8x1"}
CONC=${CONC:-100}
PIN=${PIN:-1}
# Generator shape, held constant across every layout so it cannot account for a difference.
GEN_PROCS=${GEN_PROCS:-4}
GEN_THREADS=${GEN_THREADS:-3}
SETTLE=${SETTLE:-6}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-multi-proc
BIN=${BIN:-$HOME/hello-bench/bin/volucer-050}
PORT_BASE=23080
OUT="$D/results.txt"

rm -rf "$D"; mkdir -p "$D"

cleanup() {
    for p in $(pgrep -f "$D/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(ps -eo pid,args --no-headers 2>/dev/null \
               | grep "[p]hp-fpm: pool bench$" | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    pkill -x wrk 2>/dev/null || true
    sleep 0.3
}
trap cleanup EXIT INT TERM
cleanup

echo "=== volucer: $("$BIN" --version 2>&1) $(sha256sum "$BIN" | awk '{print substr($1,1,16)}')"

cat > "$D/pool.conf" <<EOF
[global]
daemonize = no
error_log = $D/fpm-error.log
[bench]
listen = $D/fpm.sock
pm = static
pm.max_children = $CHILDREN
pm.max_requests = 0
catch_workers_output = yes
php_admin_value[memory_limit] = 512M
php_admin_value[date.timezone] = UTC
EOF
FPM=$(command -v php-fpm8.5 || command -v php-fpm || echo /usr/sbin/php-fpm8.5)
"$FPM" -y "$D/pool.conf" -F -d opcache.enable=1 -d opcache.validate_timestamps=0 \
    >"$D/fpm.log" 2>&1 &
for _ in $(seq 1 300); do [ -S "$D/fpm.sock" ] && break; sleep 0.05; done
[ -S "$D/fpm.sock" ] || { echo "=== FATAL: php-fpm never bound"; cat "$D/fpm.log"; exit 1; }

ns_of() { local total=0 pid t v; for pid in "$@"; do for t in /proc/"$pid"/task/*/schedstat; do
    [ -r "$t" ] || continue; v=$(awk '{print $1}' "$t" 2>/dev/null); total=$(( total + ${v:-0} )); done; done; echo "$total"; }

start_layout() {   # $1 = M  $2 = T   -> writes pid list to $D/pids
    : > "$D/pids"
    local i port
    for i in $(seq 0 $(( $1 - 1 ))); do
        port=$(( PORT_BASE + i ))
        sed -e "s|{{PORT}}|$port|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{SOCKET}}|$D/fpm.sock|g" \
            "$ROOT/conf/hello-external-fpm.toml.template" > "$D/vol-$i.toml"
        # `PIN=0` leaves every process unpinned, which is the control for the pinning itself: with
        # M processes on M cores the two differ only in whether the scheduler may move them, and
        # with T > 1 threads per process they differ a lot more.
        if [ "$1" -eq 1 ] || [ "${PIN:-1}" = "0" ]; then
            TOKIO_WORKER_THREADS=$2 "$BIN" serve -c "$D/vol-$i.toml" >"$D/vol-$i.log" 2>&1 &
        else
            taskset -c "$i" env TOKIO_WORKER_THREADS=$2 "$BIN" serve -c "$D/vol-$i.toml" \
                >"$D/vol-$i.log" 2>&1 &
        fi
        echo $! >> "$D/pids"
    done
    sleep 3
    for i in $(seq 0 $(( $1 - 1 ))); do
        port=$(( PORT_BASE + i ))
        body=$(curl -s --max-time 5 "http://127.0.0.1:$port/" || echo "<no answer>")
        case $body in *'"hello"'*) ;; *) echo "=== FATAL proc $i: $body"; tail -4 "$D/vol-$i.log"; exit 1 ;; esac
    done
}

stop_layout() {
    while read -r p; do kill -9 "$p" 2>/dev/null || true; done < "$D/pids"
    sleep 2
}

: > "$OUT"
for layout in $LAYOUTS; do
    M=${layout%x*}; T=${layout#*x}
    echo
    echo "########## layout=${M}x${T}  (${M} process(es) x ${T} runtime thread(s)), c=$CONC"
    start_layout "$M" "$T"
    PIDS=$(tr '\n' ' ' < "$D/pids")

    # One warm-up pass across every port, so no layout is charged for its own startup.
    for i in $(seq 0 $(( M - 1 ))); do
        wrk -t2 -c8 -d4s "http://127.0.0.1:$(( PORT_BASE + i ))/" >/dev/null 2>&1 || true
    done
    sleep "$SETTLE"

    f0=$(ns_of $PIDS)
    # **The generator shape is held constant across layouts**, because it is otherwise a confound:
    # one `wrk` process at c=100 and four `wrk` processes at c=25 have different overhead, and an
    # arm that got the cheaper generator would look faster for a reason that has nothing to do with
    # the server. So there are always exactly `GEN_PROCS` generator processes with `GEN_THREADS`
    # threads each, and the connections are split across the arm's ports -- for M=1 that means
    # several generators against one port, which is what the single-process arms have always had.
    #
    # `wait` on explicit job pids, never bare `wait`: the volucer processes were started by this
    # same shell, so a bare `wait` blocks until the servers exit and the run hangs.
    ports=""
    for i in $(seq 0 $(( M - 1 ))); do ports="$ports $(( PORT_BASE + i ))"; done
    per=$(( CONC / GEN_PROCS )); [ "$per" -lt 1 ] && per=1
    jobs=""
    for g in $(seq 0 $(( GEN_PROCS - 1 ))); do
        port=$(echo $ports | tr ' ' '\n' | sed -n "$(( g % M + 1 ))p")
        wrk -t"$GEN_THREADS" -c"$per" -d"${SECS}s" --latency "http://127.0.0.1:$port/" \
            >"$D/wrk-$layout-g$g.txt" 2>&1 &
        jobs="$jobs $!"
    done
    for j in $jobs; do wait "$j" 2>/dev/null || true; done
    f1=$(ns_of $PIDS)

    rps=0; total=0; bad=0; worst=0
    for g in $(seq 0 $(( GEN_PROCS - 1 ))); do
        f="$D/wrk-$layout-g$g.txt"
        r=$(awk '/^Requests\/sec:/{print $2}' "$f"); rps=$(( rps + ${r%.*} ))
        t2=$(awk '/requests in /{print $1}' "$f"); total=$(( total + ${t2:-0} ))
        b=$(awk -F: '/Non-2xx/{gsub(/ /,"",$2); print $2+0}' "$f"); bad=$(( bad + ${b:-0} ))
        q=$(awk '/^ +50%/{v=$2; sub(/ms/,"",v); print v+0}' "$f")
        u=$(awk '/^ +50%/{print $2}' "$f")
        case $u in *ms) : ;; *) q=$(awk -v v="$q" 'BEGIN{printf "%.3f", v/1000}') ;; esac
        worst=$(awk -v a="$worst" -v b="$q" 'BEGIN{print (b>a)?b:a}')
    done
    p50=$(awk -v v="$worst" 'BEGIN{printf "%.2fms", v}')
    # `-v` splits on whitespace, so the generator description is passed without spaces.
    genshape="${GEN_PROCS}x-t${GEN_THREADS}-c${per}"
    awk -v lay="$layout" -v r="$rps" -v d="$(( f1 - f0 ))" -v s="$SECS" -v n="$total" \
        -v bad="$bad" -v c="$CONC" -v m="$M" -v t="$T" -v p="$p50" -v gs="$genshape" '
        BEGIN {
            printf "%-8s c=%-4s rps=%-9d p50 %-9s fe=%6.1f us  cores=%.2f  layout %dx%d  gen %s%s\n",
                   lay, c, r, p, (n>0?d/1e3/n:0), d/1e9/s, m, t, gs,
                   (bad>0?"  <<< NON-2xx " bad:"")
        }' | tee -a "$OUT"
    stop_layout
done
