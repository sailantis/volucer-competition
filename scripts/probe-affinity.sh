#!/usr/bin/env bash
# Is `ClientPool` losing to `CgiPool` because it has no *affinity* -- and can it even express one?
#
# The question this answers comes from a contradiction between two of this harness's own runs:
#
#     external -> php-fpm   52,718 rps   (probe-retention, cap=1)
#     external -> php-fpm   43,436 rps   (probe-sapi,      cap=1)
#
# Same binary family, same pool shape, same host. Either the host drifted, or one of those
# probes measured something other than what it said. Neither is safe to quote, so the *first*
# job here is a control: the shipped configuration measured twice, in both orders.
#
# The hypothesis under test is narrower than "retention is good". `ClientPool::release` does
# `idle.pop()` -- LIFO -- so even an unbounded cap hands back whichever connection was returned
# last, not the connection a given PHP child owns. A larger cap therefore cannot create
# affinity, which is why raising it to 512 measured *worse* (52,718 -> 50,007) and closed a
# question it never asked.
#
# There is a second reason retention may be unexpressible here, and it is arithmetic rather
# than a cache effect: `MAX_IDLE_CONNECTIONS` only ever holds a connection that is *between*
# requests. With `c = 100` against 96 children, all 100 requests are in flight at once, so in
# steady state a returning connection is taken by a waiter before it is ever released -- the
# pool has nothing to retain. Retention can only be observed when `c` is *below* the child
# count, which is why every run so far (all at c=100) could not have seen it.
#
# So this probe measures a grid rather than a point:
#
#     cap     1 (shipped)          vs   96 (one per child, i.e. unbounded in practice)
#     conc    8, 24, 48, 96        -- below the child count, so a warm slot can exist
#
# and, for each cell, the back-end microseconds. The claim that `CgiPool` wins because of
# affinity predicts that `cap=96` closes the gap to `CgiPool` in the *be* column specifically.
# The claim that the difference is intrinsic to `ClientPool` predicts no cell moves.
#
# Because it compares two binaries against one shared php-fpm pool, the pool is started once
# and never restarted, so a difference cannot be a different pool.
#
# Usage: probe-affinity.sh [secs] [children]
set -eu

SECS=${1:-12}
CHILDREN=${2:-96}
CONC_LIST=${CONC_LIST:-"8 24 48 96"}
SETTLE=${SETTLE:-25}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-affinity
BIN_1=${BIN_1:-/tmp/vol-cap1}
BIN_96=${BIN_96:-/tmp/vol-cap96}
PORT_A=22970
PORT_B=22971

rm -rf "$D"; mkdir -p "$D"

cleanup() {
    # Anchored on the probe directory: `pkill -f probe-affinity` matches the shell running this
    # script (its own argv contains that string), which killed the session in an earlier probe
    # and reported nothing at all.
    for p in $(pgrep -f "probe-affinity/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(pgrep -f "$D/pool.conf" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    # php-fpm children outlive a master kill and keep the listening socket; see arms.sh.
    for p in $(ps -eo pid,args --no-headers 2>/dev/null \
               | grep "[p]hp-fpm: pool bench$" | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    sleep 0.3
}
trap cleanup EXIT INT TERM
cleanup

for b in "$BIN_1" "$BIN_96"; do
    [ -x "$b" ] || { echo "=== FATAL: $b is missing; see the header" >&2; exit 2; }
done
echo "=== A(cap=1)  $BIN_1  $("$BIN_1" --version 2>&1)  $(sha256sum "$BIN_1" | cut -c1-16)"
echo "=== B(cap=$CHILDREN) $BIN_96 $("$BIN_96" --version 2>&1)  $(sha256sum "$BIN_96" | cut -c1-16)"

# One pool for the whole grid. `pm = static` so the child count cannot drift mid-grid, and
# `pm.max_requests = 0` so no child is recycled between cells.
cat > "$D/pool.conf" <<EOF
[global]
daemonize = no
error_log = $D/fpm-err.log
[bench]
listen = $D/fpm.sock
pm = static
pm.max_children = $CHILDREN
pm.max_requests = 0
catch_workers_output = yes
EOF
FPM=$(command -v php-fpm8.5 || command -v php-fpm || echo /usr/sbin/php-fpm8.5)
"$FPM" -y "$D/pool.conf" -F -d opcache.enable=1 -d opcache.validate_timestamps=0 \
    >"$D/fpm.log" 2>&1 &
for _ in $(seq 1 200); do [ -S "$D/fpm.sock" ] && break; sleep 0.05; done
[ -S "$D/fpm.sock" ] || { echo "=== FATAL: php-fpm never bound"; cat "$D/fpm.log"; exit 1; }

for pair in "A:$PORT_A" "B:$PORT_B"; do
    tag=${pair%%:*}; port=${pair##*:}
    sed -e "s|{{PORT}}|$port|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{SOCKET}}|$D/fpm.sock|g" \
        "$ROOT/conf/hello-external-fpm.toml.template" > "$D/$tag.toml"
done
"$BIN_1"  serve -c "$D/A.toml" >"$D/vol-A.log" 2>&1 &
"$BIN_96" serve -c "$D/B.toml" >"$D/vol-B.log" 2>&1 &
sleep 2

# A dead backend answers *faster* than a live one. Every cell is proved before it is timed.
for pair in "$PORT_A:A" "$PORT_B:B"; do
    port=${pair%%:*}; tag=${pair##*:}
    body=$(curl -s --max-time 5 "http://127.0.0.1:$port/" || echo "<no answer>")
    echo "  $tag -> $body"
    case $body in *'"hello"'*) ;; *) echo "=== FATAL: $tag is not serving"; exit 1 ;; esac
done
echo "=== php-fpm children: $(pgrep -cf 'php-fpm: pool bench$' || echo 0)"

vol_pid() { pgrep -f "volucer.*$D/$1.toml" 2>/dev/null | head -1 || true; }

# Back-end microseconds per request, from the children's own CPU time over the round, taken
# from `/proc/<pid>/task/*/schedstat` field 1 in nanoseconds and summed across every child. The
# agreement between that and `utime+stime` was measured on this host at ~2%. The division is
# done inside `awk` in `run`, because this host's locale rejects a decimal point in `printf %f`.
children_ns() {
    local total=0 pid t v
    for pid in $(pgrep -f 'php-fpm: pool bench$' 2>/dev/null); do
        for t in /proc/"$pid"/task/*/schedstat; do
            [ -r "$t" ] || continue
            v=$(awk '{print $1}' "$t" 2>/dev/null)
            total=$(( total + ${v:-0} ))
        done
    done
    echo "$total"
}

CORES=$(nproc)

run() {   # $1 tag  $2 port  $3 conc  $4 order label
    local tag=$1 port=$2 conc=$3 label=$4
    local t=$CORES
    [ "$t" -gt "$conc" ] && t=$conc     # wrk refuses -c < -t and reports 0 rps if given it
    local b0 f0
    b0=$(children_ns); f0=$(awk '{print $1}' /proc/loadavg)
    wrk -t"$t" -c"$conc" -d"${SECS}s" --latency "http://127.0.0.1:$port/" \
        >"$D/wrk-$tag-$label.txt" 2>&1
    local rps bad p50
    rps=$(awk '/^Requests\/sec:/{print $2}' "$D/wrk-$tag-$label.txt")
    p50=$(awk '/^ +50%/{print $2}' "$D/wrk-$tag-$label.txt")
    bad=$(awk -F: '/Non-2xx/{gsub(/ /,"",$2); print $2+0}' "$D/wrk-$tag-$label.txt")
    local b1
    b1=$(children_ns)
    # Formatted inside `awk`, never by the shell's `printf`: this host's locale is German, and
    # `printf %f "22963.96"` is rejected as "Ungültige Zahl", which under `set -e` aborts the
    # whole grid after the first cell and leaves a log that looks like a clean partial run.
    awk -v l="$label" -v c="$conc" -v r="${rps:-0}" -v p="${p50:--}" \
        -v d="$(( b1 - b0 ))" -v s="$SECS" -v bad="${bad:-0}" \
        'BEGIN{
            be = (r > 0) ? (d / (r * s)) / 1000 : 0
            printf "  %-22s c=%-3s %7d rps  p50 %-9s be %6.1f us%s\n",
                   l, c, r, p, be, (bad > 0 ? "   <<< NON-2xx " bad : "")
        }'
}

echo
# Load is a *lagging* signal here: a 96-child pool plus 12 wrk threads needs 200-300 s to decay,
# and the first version of this probe started the c=8 cell straight out of the c=100 warm-up and
# measured load 8.86 for it -- which is why that cell read 22k rps against 50k at c=96, a shape
# no pool has. Every cell therefore settles first, and is warmed at *its own* concurrency so the
# discarded pass pays this cell's pool building rather than the previous cell's heat.
for conc in $CONC_LIST; do
    echo "--- settling ${SETTLE}s before c=$conc (load now $(awk '{print $1}' /proc/loadavg))"
    sleep "$SETTLE"
    echo "--- c=$conc (children=$CHILDREN, load $(awk '{print $1}' /proc/loadavg))"
    run A "$PORT_A" "$conc" "warm" >/dev/null 2>&1 || true
    run B "$PORT_B" "$conc" "warm" >/dev/null 2>&1 || true
    # Both orders, so a drift in the host across the cell cannot favour one cap.
    run A "$PORT_A" "$conc" "cap=1   (shipped)"
    run B "$PORT_B" "$conc" "cap=$CHILDREN (affinity)"
    run B "$PORT_B" "$conc" "cap=$CHILDREN (affinity)"
    run A "$PORT_A" "$conc" "cap=1   (shipped)"
    echo "=== host load after c=$conc: $(awk '{print $1}' /proc/loadavg)"
done

echo
echo "=== php-fpm children at end: $(pgrep -cf 'php-fpm: pool bench$' || echo 0)"
