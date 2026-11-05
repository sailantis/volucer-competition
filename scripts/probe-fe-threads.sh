#!/usr/bin/env bash
# WHO spends the front-end's CPU, by thread, at each concurrency?
#
# The trajectory says volucer `external` costs 49 us of front-end CPU per request at c=1 but 76 at
# c=4, easing back to ~56 by c=100, while nginx's is flat at ~47 and then falls. `fe` is a sum over
# /proc/<pid>/task/*/schedstat -- the *whole* thread group -- so a thread that burns CPU without
# serving a request is charged to the request. That is the first thing to rule out, and a
# per-thread breakdown rules it in or out in one run:
#
#   * 12 `tokio-rt-worker` threads that are all busy  -> the hump is real work
#   * 8 of them idle-but-spinning                     -> the hump is the scheduler
#   * one thread doing everything                     -> the hump is serialisation
#
# `TOKIO_WORKER_THREADS` is swept as well, because a hump caused by having more runtime threads
# than in-flight requests disappears when the two are equal, and a hump caused by per-request work
# does not.
#
# Usage: probe-fe-threads.sh [secs] [children]
#   CONCS="1 4 16 100"  RT="12"        (RT = comma-separated runtime thread counts)
set -eu

SECS=${1:-14}
CHILDREN=${2:-96}
CONCS=${CONCS:-"1 4 16 100"}
RTS=${RTS:-"12"}
SETTLE=${SETTLE:-10}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-fe-threads
BIN=${BIN:-$HOME/hello-bench/bin/volucer-050}
PORT=22996

rm -rf "$D"; mkdir -p "$D"

cleanup() {
    for p in $(pgrep -f "$D/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(ps -eo pid,args --no-headers 2>/dev/null \
               | grep "[p]hp-fpm: pool bench$" | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    [ -f "$D/vol.pid" ] && kill -9 "$(cat "$D/vol.pid")" 2>/dev/null || true
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

sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{SOCKET}}|$D/fpm.sock|g" \
    "$ROOT/conf/hello-external-fpm.toml.template" > "$D/vol.toml"

start_vol() {   # $1 = TOKIO_WORKER_THREADS
    if [ -f "$D/vol.pid" ]; then kill -9 "$(cat "$D/vol.pid")" 2>/dev/null || true; sleep 1; fi
    TOKIO_WORKER_THREADS=$1 "$BIN" serve -c "$D/vol.toml" >"$D/vol-rt$1.log" 2>&1 &
    echo $! > "$D/vol.pid"
    sleep 2
    body=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/" || echo "<no answer>")
    case $body in *'"hello"'*) ;; *) echo "=== FATAL rt=$1: $body"; exit 1 ;; esac
}

# One sample of the whole thread group, per thread.
#
# `local t` matters: without it the `for t in /proc/.../task/*` loop overwrites the caller's `t`,
# which is the wrk thread count -- the run then calls `wrk -t/proc/<pid>/task/...` and dies.
snapshot() {   # $1 = output file
    local pid t tid ns comm
    pid=$(cat "$D/vol.pid")
    : > "$1"
    for t in /proc/"$pid"/task/*; do
        tid=${t##*/}
        ns=$(awk '{print $1}' "$t/schedstat" 2>/dev/null || echo 0)
        comm=$(cat "$t/comm" 2>/dev/null || echo "?")
        echo "$tid $ns $comm" >> "$1"
    done
}

report() {   # $1 label  $2 conc  $3 before  $4 after  $5 requests  $6 rps  $7 rt
    awk -v lab="$1" -v c="$2" -v b="$3" -v a="$4" -v n="$5" -v r="$6" -v rt="$7" \
        -v secs="$SECS" '
        FNR==NR { nb[$1] = $2; next }
        { d = $2 - nb[$1]; if (d < 0) d = 0
          tot += d; cnt[$3] += d; seen[$3] = 1 }
        END {
            # schedstat field 1 is nanoseconds of on-CPU time for the thread. Summed over the
            # group it is the front-end cost; grouped by `comm` it says which population paid it,
            # which is what separates "the request path got slower" from "a thread that serves no
            # request got busy".
            fe = (n > 0) ? (tot / 1e3 / n) : 0
            printf "SAMPLE rt=%-3s c=%-4s rps=%-9s fe=%6.1f us  cores=%.2f\n",
                   rt, c, r, fe, tot / 1e9 / secs
            for (g in seen)
                printf "    %-18s %8.3f cores  %6.1f us/req\n",
                       g, cnt[g] / 1e9 / secs, (n > 0 ? cnt[g]/1e3/n : 0)
        }' "$3" "$4"
}

for rt in $(echo "$RTS" | tr ',' ' '); do
    echo
    echo "########## TOKIO_WORKER_THREADS=$rt"
    start_vol "$rt"
    wrk -t4 -c8 -d5s "http://127.0.0.1:$PORT/" >/dev/null 2>&1 || true
    for c in $CONCS; do
        sleep "$SETTLE"
        t=$(nproc); if [ "$t" -gt "$c" ]; then t=$c; fi
        snapshot "$D/before.txt"
        wrk -t"$t" -c"$c" -d"${SECS}s" --latency "http://127.0.0.1:$PORT/" >"$D/wrk-$c.txt" 2>&1
        snapshot "$D/after.txt"
        rps=$(awk '/^Requests\/sec:/{print $2}' "$D/wrk-$c.txt")
        total=$(awk '/requests in /{print $1}' "$D/wrk-$c.txt")
        report "$rt/$c" "$c" "$D/before.txt" "$D/after.txt" "${total:-1}" "${rps:-0}" "$rt"
        bad=$(awk -F: '/Non-2xx/{gsub(/ /,"",$2); print $2+0}' "$D/wrk-$c.txt")
        [ "${bad:-0}" -gt 0 ] && echo "    <<< NON-2xx $bad"
    done
done
