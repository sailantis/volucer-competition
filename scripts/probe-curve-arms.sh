#!/usr/bin/env bash
# Does the concurrency hump belong to the runtime, to php-fpm, or to this ARM?
#
# `probe-fe-curve.sh` measured, on the `external` arm:
#
#     c      1     2     3     4     6     8    12    16    24    50   100
#     us  44.6  62.0  71.8  75.7  75.9  74.7  71.9  71.1  62.7  57.1  54.4
#
# and flat (~44) with `TOKIO_WORKER_THREADS=1`. Three explanations survive that:
#
#   (1) the runtime      -- >1 thread means tasks can move between threads
#   (2) php-fpm          -- the pool's own accept/dispatch scales differently from the client
#   (3) this arm         -- the FastCGI conversation has a shape that only hurts in the middle
#
# Only a comparison against a DIFFERENT BACKEND over the SAME runtime separates them, so this runs
# the same curve on `upstream` (a Node origin, hyper's client, no FastCGI at all) as well as on
# `external`. `upstream` shares the runtime and shares nothing else.
#
# A second control is the same arm with `TOKIO_WORKER_THREADS=1`, because a hump that vanishes when
# the thread count is one is a runtime-scheduling property no matter which backend it appeared on.
#
# Usage: probe-curve-arms.sh [secs] [children]
#   CONCS="1 2 4 8 16 100"   ARMS="external upstream"
set -eu

SECS=${1:-10}
CHILDREN=${2:-96}
CONCS=${CONCS:-"1 2 4 8 16 100"}
ARMS=${ARMS:-"external upstream"}
RTS=${RTS:-"12"}
NODE_WORKERS=${NODE_WORKERS:-4}
SETTLE=${SETTLE:-6}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-curve-arms
BIN=${BIN:-$HOME/hello-bench/bin/volucer-050}
NODE=${NODE:-$HOME/hello-bench/bin/node-v24.11.1-linux-x64/bin/node}
PORT=23020
ORIGIN_PORT=23021
OUT="$D/curve.txt"

rm -rf "$D"; mkdir -p "$D"

cleanup() {
    for p in $(pgrep -f "$D/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(ps -eo pid,args --no-headers 2>/dev/null \
               | grep "[p]hp-fpm: pool bench$" | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    [ -f "$D/vol.pid" ] && kill -9 "$(cat "$D/vol.pid")" 2>/dev/null || true
    [ -f "$D/node.pid" ] && kill -9 "$(cat "$D/node.pid")" 2>/dev/null || true
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

# A Node origin for the `upstream` arm, clustered so the origin is not the limit.
"$NODE" "$ROOT/apps/hello/fastify-hello.js" --port "$ORIGIN_PORT" --workers "$NODE_WORKERS" \
    >"$D/node.log" 2>&1 &
echo $! > "$D/node.pid"
for _ in $(seq 1 100); do
    curl -sf --max-time 1 "http://127.0.0.1:$ORIGIN_PORT/" >/dev/null 2>&1 && break; sleep 0.1
done
body=$(curl -s --max-time 5 "http://127.0.0.1:$ORIGIN_PORT/" || echo "<no answer>")
case $body in *'"hello"'*) echo "  origin -> $body" ;;
    *) echo "=== FATAL: origin not serving: $body"; cat "$D/node.log"; exit 1 ;; esac

ns_of() { local total=0 pid t v; for pid in "$@"; do for t in /proc/"$pid"/task/*/schedstat; do
    [ -r "$t" ] || continue; v=$(awk '{print $1}' "$t" 2>/dev/null); total=$(( total + ${v:-0} )); done; done; echo "$total"; }

start_vol() {   # $1 = arm  $2 = rt
    if [ -f "$D/vol.pid" ]; then kill -9 "$(cat "$D/vol.pid")" 2>/dev/null || true; sleep 1; fi
    case $1 in
        external)
            sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{SOCKET}}|$D/fpm.sock|g" \
                "$ROOT/conf/hello-external-fpm.toml.template" > "$D/vol-$1.toml" ;;
        upstream)
            sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$ROOT/apps/hello|g" \
                -e "s|{{ORIGIN_PORT}}|$ORIGIN_PORT|g" \
                "$ROOT/conf/hello-upstream.toml.template" > "$D/vol-$1.toml" ;;
        *) echo "=== FATAL: unknown arm $1"; exit 1 ;;
    esac
    TOKIO_WORKER_THREADS=$2 "$BIN" serve -c "$D/vol-$1.toml" >"$D/vol-$1-rt$2.log" 2>&1 &
    echo $! > "$D/vol.pid"
    sleep 2
    body=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/" || echo "<no answer>")
    case $body in *'"hello"'*) ;; *) echo "=== FATAL $1 rt=$2: $body"; tail -5 "$D/vol-$1-rt$2.log"; exit 1 ;; esac
}

: > "$OUT"
for arm in $ARMS; do
    for rt in $(echo "$RTS" | tr ',' ' '); do
        echo
        echo "########## arm=$arm TOKIO_WORKER_THREADS=$rt"
        start_vol "$arm" "$rt"
        VOL_PID=$(cat "$D/vol.pid")
        wrk -t4 -c8 -d5s "http://127.0.0.1:$PORT/" >/dev/null 2>&1 || true
        printf "%-6s %10s %10s %10s\n" "conc" "rps" "fe_us" "cores"
        for c in $CONCS; do
            sleep "$SETTLE"
            t=$(nproc); if [ "$t" -gt "$c" ]; then t=$c; fi
            f0=$(ns_of "$VOL_PID")
            wrk -t"$t" -c"$c" -d"${SECS}s" "http://127.0.0.1:$PORT/" >"$D/wrk-$arm-$rt-$c.txt" 2>&1
            f1=$(ns_of "$VOL_PID")
            rps=$(awk '/^Requests\/sec:/{print $2}' "$D/wrk-$arm-$rt-$c.txt")
            total=$(awk '/requests in /{print $1}' "$D/wrk-$arm-$rt-$c.txt")
            bad=$(awk -F: '/Non-2xx/{gsub(/ /,"",$2); print $2+0}' "$D/wrk-$arm-$rt-$c.txt")
            awk -v a="$arm" -v rt="$rt" -v c="$c" -v r="${rps:-0}" -v n="${total:-1}" \
                -v d="$(( f1 - f0 ))" -v s="$SECS" -v bad="${bad:-0}" '
                BEGIN {
                    printf "%-6s %10d %10.1f %10.2f%s\n", c, r, (n>0?d/1e3/n:0), d/1e9/s,
                           (bad>0 ? "   <<< NON-2xx " bad : "")
                }' | tee -a "$OUT"
        done
    done
done

echo
echo "=== fe us/request, every arm and thread count measured"
awk '/^####/{ hdr=$0; sub(/.*arm=/,"",hdr); sub(/ TOKIO_WORKER_THREADS=/," rt",hdr); next }
     /^[0-9]+ +[0-9]+/ { k=hdr; v[k, $1]=$3; ks[k]=1; cs[$1]=1 }
     END {
        n=0; for (k in ks) kk[++n]=k
        m=0; for (c in cs) cc[++m]=c
        for (i=1;i<=m;i++) for (j=i+1;j<=m;j++) if (cc[i]+0 > cc[j]+0) { t=cc[i]; cc[i]=cc[j]; cc[j]=t }
        printf "%-6s", "conc"; for (i=1;i<=n;i++) printf " %14s", kk[i]; printf "\n"
        for (i=1;i<=m;i++) { printf "%-6s", cc[i]
            for (j=1;j<=n;j++) printf " %14.1f", v[kk[j], cc[i]]
            printf "\n" }
     }' "$OUT"
