#!/usr/bin/env bash
# The fine-grained front-end cost curve. One number per concurrency, no other variables.
#
# The coarse cells (c=1,4,16,100) found a hump -- ~46 us at c=1, ~76 at c=4, back to ~55 at c=100 --
# and a runtime-thread sweep localised it: with `TOKIO_WORKER_THREADS=1` the curve is flat at
# ~44-47 us at every concurrency, and every thread count above one shows the hump. So it is a
# property of *having more than one thread*, not of the request path.
#
# The threshold is what this probe measures. If the jump is between c=1 and c=2, the trigger is
# "more than one task in flight"; if it is between c=<rt> and c=<rt>+1, the trigger is "more tasks
# in flight than threads". The two imply different fixes, so the shape decides.
#
# `fe` is the whole thread group's CPU divided by requests, from schedstat -- the same instrument
# every other figure in this record uses, so the numbers are comparable to them.
#
# Usage: probe-fe-curve.sh [secs] [children]
#   CONCS="1 2 3 4 6 8 12 16 24 32 50 100"  RTS="12"
set -eu

SECS=${1:-10}
CHILDREN=${2:-96}
CONCS=${CONCS:-"1 2 3 4 6 8 12 16 24 32 50 100"}
RTS=${RTS:-"12"}
SETTLE=${SETTLE:-5}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-fe-curve
BIN=${BIN:-$HOME/hello-bench/bin/volucer-050}
PORT=23001
OUT="$D/curve.txt"

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

ns_of() { local total=0 pid t v; for pid in "$@"; do for t in /proc/"$pid"/task/*/schedstat; do
    [ -r "$t" ] || continue; v=$(awk '{print $1}' "$t" 2>/dev/null); total=$(( total + ${v:-0} )); done; done; echo "$total"; }

: > "$OUT"
for rt in $(echo "$RTS" | tr ',' ' '); do
    echo
    echo "########## TOKIO_WORKER_THREADS=$rt"
    TOKIO_WORKER_THREADS=$rt "$BIN" serve -c "$D/vol.toml" >"$D/vol-rt$rt.log" 2>&1 &
    VOL_PID=$!
    echo "$VOL_PID" > "$D/vol.pid"
    sleep 2
    body=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/" || echo "<no answer>")
    case $body in *'"hello"'*) ;; *) echo "=== FATAL rt=$rt: $body"; exit 1 ;; esac
    wrk -t4 -c8 -d5s "http://127.0.0.1:$PORT/" >/dev/null 2>&1 || true

    printf "%-6s %10s %10s %10s\n" "conc" "rps" "fe_us" "cores"
    for c in $CONCS; do
        sleep "$SETTLE"
        t=$(nproc); if [ "$t" -gt "$c" ]; then t=$c; fi
        f0=$(ns_of "$VOL_PID")
        wrk -t"$t" -c"$c" -d"${SECS}s" "http://127.0.0.1:$PORT/" >"$D/wrk-$c.txt" 2>&1
        f1=$(ns_of "$VOL_PID")
        rps=$(awk '/^Requests\/sec:/{print $2}' "$D/wrk-$c.txt")
        total=$(awk '/requests in /{print $1}' "$D/wrk-$c.txt")
        awk -v rt="$rt" -v c="$c" -v r="${rps:-0}" -v n="${total:-1}" -v d="$(( f1 - f0 ))" -v s="$SECS" '
            BEGIN { printf "%-6s %10d %10.1f %10.2f\n", c, r, (n>0?d/1e3/n:0), d/1e9/s }' \
            | tee -a "$OUT"
    done
    kill -9 "$VOL_PID" 2>/dev/null || true
    sleep 2
done

echo
echo "=== the curve, both thread counts side by side"
awk '/^####/{rt=$0; sub(/.*=/,"",rt); next}
     /^[0-9]+ +[0-9]+/ { c=$1; v[rt, c]=$3; rp[rt, c]=$2; cs[c]=1; rts[rt]=1 }
     END {
        printf "%-6s", "conc"
        n=0; for (r in rts) { order[++n]=r }
        for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) if (order[i]+0 > order[j]+0) { t=order[i]; order[i]=order[j]; order[j]=t }
        for (i=1;i<=n;i++) printf " %12s", "rt=" order[i] " us"
        printf "\n"
        m=0; for (c in cs) cc[++m]=c
        for (i=1;i<=m;i++) for (j=i+1;j<=m;j++) if (cc[i]+0 > cc[j]+0) { t=cc[i]; cc[i]=cc[j]; cc[j]=t }
        for (i=1;i<=m;i++) { printf "%-6s", cc[i]
            for (k=1;k<=n;k++) printf " %12.1f", v[order[k], cc[i]]
            printf "\n" }
     }' "$OUT"
