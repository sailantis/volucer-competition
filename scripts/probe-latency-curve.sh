#!/usr/bin/env bash
# Where does the 241 us that separates nginx from volucer actually live?
#
# Measured earlier, one pool, one socket, 96 children, c=32: nginx 338 us p50 against volucer
# 579 us, while PHP's own cost was 133 vs 137 us. So ~240 us is spent inside the front-end, and
# *not* inside the backend. At c=100 the ratio was the same (1.42x), so it is not saturation.
#
# A difference can be one of two things and they have opposite fixes:
#
#   (a) a fixed per-request cost -- the front-end does more work per request than nginx does;
#   (b) a concurrency effect -- the same work, serialised somewhere.
#
# The two are told apart by the *shape* of the latency curve. If (a), p50 is higher by a constant
# at every concurrency, including c=1 where nothing queues. If (b), p50 agrees at c=1 and diverges
# as concurrency rises.
#
# So this walks c = 1, 2, 4, 8, 16, 32, 64, 100 and prints p50/p99, with the front-end's own CPU
# time per request beside it. That last column is the discriminator between "busy" and "blocked":
# a front-end that is waiting on something shows low CPU per request and high latency, while one
# that is doing too much work shows both high.
#
# Usage: probe-latency-curve.sh [secs]
set -eu

SECS=${1:-12}
SETTLE=${SETTLE:-15}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-curve
BIN=${BIN:-$HOME/hello-bench/bin/volucer-adopt}
PORT_N=22990
PORT_X=22991
NGINX=${NGINX:-/usr/sbin/nginx}
NGX="$D/ngx"
CHILDREN=${CHILDREN:-96}
CONC_LIST=${CONC_LIST:-"1 2 4 8 16 32 64 100"}

rm -rf "$D"; mkdir -p "$D" "$NGX/tmp/client" "$NGX/tmp/proxy" "$NGX/tmp/fastcgi" \
    "$NGX/tmp/uwsgi" "$NGX/tmp/scgi"

cleanup() {
    for p in $(pgrep -f "probe-curve/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(pgrep -f "$D/pool.conf" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(ps -eo pid,args --no-headers 2>/dev/null \
               | grep "[p]hp-fpm: pool bench$" | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    [ -f "$NGX/nginx.pid" ] && kill -9 "$(cat "$NGX/nginx.pid")" 2>/dev/null || true
    sleep 0.3
}
trap cleanup EXIT INT TERM
cleanup

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
php_admin_value[error_log] = $D/fpm-worker-error.log
php_admin_flag[log_errors] = on
php_admin_value[memory_limit] = 512M
php_admin_value[date.timezone] = UTC
EOF
FPM=$(command -v php-fpm8.5 || command -v php-fpm || echo /usr/sbin/php-fpm8.5)
"$FPM" -y "$D/pool.conf" -F -d opcache.enable=1 -d opcache.validate_timestamps=0 \
    >"$D/fpm.log" 2>&1 &
for _ in $(seq 1 300); do [ -S "$D/fpm.sock" ] && break; sleep 0.05; done
[ -S "$D/fpm.sock" ] || { echo "=== FATAL: php-fpm never bound"; cat "$D/fpm.log"; exit 1; }

cat > "$D/nginx.conf" <<EOF
daemon off;
worker_processes 4;
error_log $NGX/error.log warn;
pid $NGX/nginx.pid;
events { worker_connections 4096; }
http {
    access_log off;
    client_body_temp_path $NGX/tmp/client;
    proxy_temp_path       $NGX/tmp/proxy;
    fastcgi_temp_path     $NGX/tmp/fastcgi;
    uwsgi_temp_path       $NGX/tmp/uwsgi;
    scgi_temp_path        $NGX/tmp/scgi;
    fastcgi_read_timeout 30s;
    fastcgi_send_timeout 30s;
    server {
        listen 127.0.0.1:$PORT_N;
        server_name bench.local;
        root $ROOT/apps/hello/public;
        location / {
            include /etc/nginx/fastcgi_params;
            fastcgi_pass unix:$D/fpm.sock;
            fastcgi_param SCRIPT_FILENAME $ROOT/apps/hello/public/index.php;
            fastcgi_param REQUEST_URI \$request_uri;
            fastcgi_param DOCUMENT_ROOT $ROOT/apps/hello/public;
        }
    }
}
EOF
"$NGINX" -p "$NGX" -c "$D/nginx.conf" >"$D/nginx.log" 2>&1 &
for _ in $(seq 1 100); do [ -s "$NGX/nginx.pid" ] && break; sleep 0.05; done

sed -e "s|{{PORT}}|$PORT_X|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{SOCKET}}|$D/fpm.sock|g" \
    "$ROOT/conf/hello-external-fpm.toml.template" > "$D/vol.toml"
"$BIN" serve -c "$D/vol.toml" >"$D/vol.log" 2>&1 &
sleep 2

for pair in "$PORT_N:nginx" "$PORT_X:volucer"; do
    port=${pair%%:*}; tag=${pair##*:}
    body=$(curl -s --max-time 5 "http://127.0.0.1:$port/" || echo "<no answer>")
    echo "  $tag -> $body"
    case $body in *'"hello"'*) ;; *) echo "=== FATAL: $tag is not serving"; exit 1 ;; esac
done
echo "=== children: $(pgrep -cf 'php-fpm: pool bench$' || echo 0)  volucer: $("$BIN" --version 2>&1)"

NGX_MASTER=$(cat "$NGX/nginx.pid")
VOL_PID=$(pgrep -f "volucer.*$D/vol.toml" | head -1)

# Total CPU nanoseconds of every thread of every pid given, from `/proc/<pid>/task/*/`
# `schedstat` field 1. Includes children, so `nginx` here is the master plus its 4 workers, and
# `volucer` is the process plus every thread it owns.
cpu_ns() {
    local total=0 pid t v
    for pid in "$@"; do
        for t in /proc/"$pid"/task/*/schedstat; do
            [ -r "$t" ] || continue
            v=$(awk '{print $1}' "$t" 2>/dev/null)
            total=$(( total + ${v:-0} ))
        done
    done
    echo "$total"
}

ngx_pids() { echo "$NGX_MASTER $(pgrep -P "$NGX_MASTER" 2>/dev/null | tr '\n' ' ')"; }

run() {   # $1 tag  $2 port  $3 label  $4 conc
    local tag=$1 port=$2 label=$3 conc=$4
    local t=$conc
    [ "$t" -gt 12 ] && t=12        # wrk refuses -c < -t and then reports 0 rps
    local before after rps p50 p99
    if [ "$label" = "nginx" ]; then before=$(cpu_ns $(ngx_pids)); else before=$(cpu_ns "$VOL_PID"); fi
    wrk -t"$t" -c"$conc" -d"${SECS}s" --latency "http://127.0.0.1:$port/" >"$D/wrk-$tag-$conc.txt" 2>&1
    if [ "$label" = "nginx" ]; then after=$(cpu_ns $(ngx_pids)); else after=$(cpu_ns "$VOL_PID"); fi
    rps=$(awk '/^Requests\/sec:/{print $2}' "$D/wrk-$tag-$conc.txt")
    p50=$(awk '/^ +50%/{print $2}' "$D/wrk-$tag-$conc.txt")
    p99=$(awk '/^ +99%/{print $2}' "$D/wrk-$tag-$conc.txt")
    awk -v l="$label" -v c="$conc" -v r="${rps:-0}" -v p50="${p50:--}" -v p99="${p99:--}" \
        -v d="$(( after - before ))" -v s="$SECS" \
        'BEGIN{
            # Front-end CPU per request. The number that separates "doing too much work"
            # from "waiting on something": a blocked front-end is cheap per request and slow.
            us = (r > 0) ? (d / (r * s)) / 1000 : 0
            printf "  %-8s c=%-4s %7d rps  p50 %-9s p99 %-9s  fe-cpu %6.1f us\n", l, c, r, p50, p99, us
        }'
}

echo
echo "=== warm-up (discarded)"
wrk -t4 -c16 -d6s "http://127.0.0.1:$PORT_N/" >/dev/null 2>&1 || true
wrk -t4 -c16 -d6s "http://127.0.0.1:$PORT_X/" >/dev/null 2>&1 || true
sleep "$SETTLE"

for conc in $CONC_LIST; do
    echo "--- c=$conc (load $(awk '{print $1}' /proc/loadavg))"
    run N "$PORT_N" nginx "$conc"
    run X "$PORT_X" volucer "$conc"
    echo "    (load after $(awk '{print $1}' /proc/loadavg))"
    sleep "$SETTLE"
done

echo
echo "=== children at end: $(pgrep -cf 'php-fpm: pool bench$' || echo 0)"
