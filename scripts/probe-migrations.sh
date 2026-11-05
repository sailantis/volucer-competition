#!/usr/bin/env bash
# Why does volucer's per-request front-end cost RISE from c=1 to c=4 and then FALL to c=100?
#
# Measured shape (probe-fe-curve.sh, 12-core VM, 96 php-fpm children):
#
#     c      1     2     3     4     6     8    12    16    24    50   100
#     us  44.6  62.0  71.8  75.7  75.9  74.7  71.9  71.1  62.7  57.1  54.4
#
# and, with `TOKIO_WORKER_THREADS=1`, flat: 46.6 49.3 47.5 45.5 44.0 42.9 44.7 44.5 43.7 43.7 43.9.
#
# So the hump is a property of having MORE THAN ONE runtime thread, not of the request path. The
# two candidate mechanisms inside a work-stealing runtime are:
#
#   migration  -- a task is picked up by a different thread than the one that queued it. Each
#                 migration is an `sched_migrate_task`: the target core must be woken from idle
#                 (an IPI on Xen, which is where `_raw_spin_unlock_irqrestore` 27.7% lives) and its
#                 cache is cold. At LOW concurrency there is always an idle thread to move to, so
#                 the runtime keeps moving work; at HIGH concurrency every thread is busy and the
#                 work stays put, which is why the cost FALLS again.
#
#   wakeups     -- a parked thread woken per request. Constant per request would give a flat
#                 curve, so on its own it cannot explain the hump -- measured anyway.
#
# `sched:sched_migrate_task` is keyed by the pid it happens TO, so `-p <volucer>` counts exactly the
# migrations of the front-end's own threads.
#
# Both arms get the same treatment, because "nginx has no hump" is a claim about nginx that should
# be measured by the same instrument rather than inferred from its throughput curve.
#
# Usage: probe-migrations.sh [secs] [children]
#   CONCS="1 2 4 8 16 100"
set -eu

SECS=${1:-12}
CHILDREN=${2:-96}
CONCS=${CONCS:-"1 2 4 8 16 100"}
ARMS=${ARMS:-"volucer nginx"}
SETTLE=${SETTLE:-6}
WINDOW=${WINDOW:-6}
WARMUP=${WARMUP:-5}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-migr
BIN=${BIN:-$HOME/hello-bench/bin/volucer-050}
PORT_N=23010
PORT_X=23011
NGINX=${NGINX:-/usr/sbin/nginx}
NGX="$D/ngx"

rm -rf "$D"; mkdir -p "$D" "$NGX/tmp/client" "$NGX/tmp/proxy" "$NGX/tmp/fastcgi" \
    "$NGX/tmp/uwsgi" "$NGX/tmp/scgi"

cleanup() {
    for p in $(pgrep -f "$D/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(ps -eo pid,args --no-headers 2>/dev/null \
               | grep "[p]hp-fpm: pool bench$" | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    [ -f "$NGX/nginx.pid" ] && kill -9 "$(cat "$NGX/nginx.pid")" 2>/dev/null || true
    [ -f "$D/vol.pid" ] && kill -9 "$(cat "$D/vol.pid")" 2>/dev/null || true
    pkill -x wrk 2>/dev/null || true
    sleep 0.3
}
trap cleanup EXIT INT TERM
cleanup

echo "=== volucer: $("$BIN" --version 2>&1) $(sha256sum "$BIN" | awk '{print substr($1,1,16)}')"
echo "=== nginx:   $("$NGINX" -v 2>&1 | sed 's/^nginx version: //')"

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
NGX_MASTER=$(cat "$NGX/nginx.pid" 2>/dev/null || echo "")

sed -e "s|{{PORT}}|$PORT_X|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{SOCKET}}|$D/fpm.sock|g" \
    "$ROOT/conf/hello-external-fpm.toml.template" > "$D/vol.toml"
"$BIN" serve -c "$D/vol.toml" >"$D/vol.log" 2>&1 &
VOL_PID=$!
echo "$VOL_PID" > "$D/vol.pid"
sleep 2

for pair in "$PORT_N:nginx" "$PORT_X:volucer"; do
    port=${pair%%:*}; tag=${pair##*:}
    body=$(curl -s --max-time 5 "http://127.0.0.1:$port/" || echo "<no answer>")
    case $body in *'"hello"'*) echo "  $tag -> $body" ;;
        *) echo "=== FATAL: $tag is not serving: $body"; exit 1 ;; esac
done
echo "=== php-fpm children: $(pgrep -cf 'php-fpm: pool bench$' || echo 0)"

ns_of() { local total=0 pid t v; for pid in "$@"; do for t in /proc/"$pid"/task/*/schedstat; do
    [ -r "$t" ] || continue; v=$(awk '{print $1}' "$t" 2>/dev/null); total=$(( total + ${v:-0} )); done; done; echo "$total"; }
pids_of() {   # $1 = arm
    case $1 in
        volucer) echo "$VOL_PID" ;;
        nginx)   [ -n "$NGX_MASTER" ] && pgrep -P "$NGX_MASTER" 2>/dev/null || true ;;
    esac
}

wrk -t4 -c8 -d5s "http://127.0.0.1:$PORT_N/" >/dev/null 2>&1 || true
wrk -t4 -c8 -d5s "http://127.0.0.1:$PORT_X/" >/dev/null 2>&1 || true
sleep 5

for c in $CONCS; do
    for arm in $ARMS; do
        sleep "$SETTLE"
        case $arm in nginx) port=$PORT_N ;; volucer) port=$PORT_X ;; esac
        t=$(nproc); if [ "$t" -gt "$c" ]; then t=$c; fi

        # `-p` takes one pid or a comma list; for nginx that is four workers, which bpftrace
        # accepts. Trailing comma stripped, and the assignment cannot abort the run under `set -e`
        # when the pattern matches nothing -- that is a skip, not a failure.
        PIDS=$(pids_of "$arm" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)
        if [ -z "$PIDS" ]; then echo "  $arm c=$c: no pids matched, skipped"; continue; fi

        wrk -t"$t" -c"$c" -d"$(( WARMUP + WINDOW + 3 ))s" "http://127.0.0.1:$port/" \
            >"$D/wrk-$arm-$c.txt" 2>&1 &
        WJ=$!
        sleep "$WARMUP"
        sudo bpftrace -p "$PIDS" -e '
            tracepoint:sched:sched_migrate_task { @migrate = count(); }
            tracepoint:sched:sched_wakeup       { @wakeup = count(); }
            tracepoint:sched:sched_switch       { @switch = count(); }
            interval:s:'"$WINDOW"' { exit(); }
        ' >"$D/bt-$arm-$c.txt" 2>&1
        wait $WJ 2>/dev/null || true

        rps=$(awk '/^Requests\/sec:/{print $2}' "$D/wrk-$arm-$c.txt")
        awk -v a="$arm" -v c="$c" -v r="${rps:-0}" -v w="$WINDOW" '
            BEGIN { n = (r > 0) ? r * w : 1 }
            /^@/ { name=$1; sub(/^@/,"",name); sub(/:$/,"",name); v[name]=$2 }
            END {
                printf "%-8s c=%-4s rps=%-8d  migrate/req=%5.2f  wakeup/req=%5.2f  switch/req=%5.2f\n",
                       a, c, r, (v["migrate"]+0)/n, (v["wakeup"]+0)/n, (v["switch"]+0)/n
            }' "$D/bt-$arm-$c.txt"
    done
done
