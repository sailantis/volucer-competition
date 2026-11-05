#!/usr/bin/env bash
# volucer `external` against nginx, both in front of ONE php-fpm pool.
#
# This is the comparison a published table needs, and the arm table cannot give it: `fpm` is
# nginx+php-fpm and `external_fpm` is volucer+php-fpm, but the two are started by different
# scripts (`matrix.sh` and `arms.sh`) which write *different pool files*, and the pool file
# alone has been measured to move this arm from ~44k to ~50k. Comparing those two rows compares
# two configurations wearing one another's labels.
#
# So: one pool file, one socket, one child count, one php.ini, two front-ends.
#
#     A  nginx   -> unix:sock  -> 96 php-fpm children
#     B  volucer -> unix:sock  -> 96 php-fpm children   (kind = "external")
#
# Both are recorded from the SAME children, so the back-end microseconds are directly
# comparable between them and a difference in that column is a difference in what the front-end
# makes PHP do, not in what PHP has to do.
#
# Usage: probe-nginx-vs-volucer.sh [secs] [conc] [children]
set -eu

SECS=${1:-16}
CONC=${2:-100}
CHILDREN=${3:-96}
SETTLE=${SETTLE:-45}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-nginx
BIN=${BIN:-$HOME/hello-bench/bin/volucer-adopt}
PORT_N=22980
PORT_X=22981
NGINX=${NGINX:-/usr/sbin/nginx}
NGX="$D/ngx"

rm -rf "$D"; mkdir -p "$D" "$NGX/tmp/client" "$NGX/tmp/proxy" "$NGX/tmp/fastcgi" \
    "$NGX/tmp/uwsgi" "$NGX/tmp/scgi"

cleanup() {
    # Anchored on the probe directory. `pkill -f probe-nginx` matches this script's own argv and
    # killed the session in an earlier probe.
    for p in $(pgrep -f "probe-nginx/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(pgrep -f "$D/pool.conf" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    # php-fpm children survive a master kill and keep the socket; see arms.sh.
    for p in $(ps -eo pid,args --no-headers 2>/dev/null \
               | grep "[p]hp-fpm: pool bench$" | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    [ -f "$NGX/nginx.pid" ] && kill -9 "$(cat "$NGX/nginx.pid")" 2>/dev/null || true
    sleep 0.3
}
trap cleanup EXIT INT TERM
cleanup

echo "=== volucer: $BIN $("$BIN" --version 2>&1) $(sha256sum "$BIN" | cut -c1-16)"
echo "=== nginx:   $NGINX $("$NGINX" -v 2>&1 | sed 's/^nginx version: //')"

# One pool. `pm = static` so the child count cannot drift, `pm.max_requests = 0` so no child is
# recycled mid-round, and the same `php_admin_*` set `matrix.sh` uses for its `fpm` arm -- so
# this pool is the published one, not a tidier variant of it.
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

# nginx, configured exactly as the published `fpm` arm: 4 workers, one `location /`, every
# request to the front controller, `access_log off`.
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

# volucer `external`, which starts nothing: it dials the pool that is already there.
sed -e "s|{{PORT}}|$PORT_X|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{SOCKET}}|$D/fpm.sock|g" \
    "$ROOT/conf/hello-external-fpm.toml.template" > "$D/vol.toml"
"$BIN" serve -c "$D/vol.toml" >"$D/vol.log" 2>&1 &
sleep 2

# A dead backend answers *faster* than a live one: both bodies are proved before anything is
# timed. (This guard has caught a headline 502 in an earlier phase.)
for pair in "$PORT_N:nginx" "$PORT_X:volucer"; do
    port=${pair%%:*}; tag=${pair##*:}
    body=$(curl -s --max-time 5 "http://127.0.0.1:$port/" || echo "<no answer>")
    echo "  $tag -> $body"
    case $body in *'"hello"'*) ;; *) echo "=== FATAL: $tag is not serving"; exit 1 ;; esac
done
echo "=== php-fpm children: $(pgrep -cf 'php-fpm: pool bench$' || echo 0)"

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

run() {   # $1 tag  $2 port  $3 label
    local tag=$1 port=$2 label=$3
    local t=$CORES
    [ "$t" -gt "$CONC" ] && t=$CONC
    local b0 b1 rps p50 bad
    b0=$(children_ns)
    wrk -t"$t" -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:$port/" >"$D/wrk-$tag-$label.txt" 2>&1
    b1=$(children_ns)
    rps=$(awk '/^Requests\/sec:/{print $2}' "$D/wrk-$tag-$label.txt")
    p50=$(awk '/^ +50%/{print $2}' "$D/wrk-$tag-$label.txt")
    bad=$(awk -F: '/Non-2xx/{gsub(/ /,"",$2); print $2+0}' "$D/wrk-$tag-$label.txt")
    # Formatted in awk: this host's locale rejects a decimal point in the shell's `printf %f`,
    # which under `set -e` aborts the whole run after the first cell.
    awk -v l="$label" -v r="${rps:-0}" -v p="${p50:--}" -v d="$(( b1 - b0 ))" \
        -v s="$SECS" -v bad="${bad:-0}" -v c="$CONC" \
        'BEGIN{
            be = (r > 0) ? (d / (r * s)) / 1000 : 0
            printf "  %-10s c=%-4s %7d rps  p50 %-9s  be %6.1f us%s\n",
                   l, c, r, p, be, (bad > 0 ? "   <<< NON-2xx " bad : "")
        }'
}

echo
echo "--- settling ${SETTLE}s (load $(awk '{print $1}' /proc/loadavg))"
sleep "$SETTLE"

echo "--- warm-up (discarded; the first pass pays the pool being built)"
wrk -t"$CORES" -c"$CONC" -d8s "http://127.0.0.1:$PORT_N/" >/dev/null 2>&1 || true
wrk -t"$CORES" -c"$CONC" -d8s "http://127.0.0.1:$PORT_X/" >/dev/null 2>&1 || true
sleep 15

for round in 1 2 3; do
    # 45 s, not 15: a 96-child pool plus 12 wrk threads needs 200-300 s to decay, and the earlier
    # grid showed a cell starting at load 22 and reporting a number that belonged to that heat.
    echo "--- settling before round $round (load $(awk '{print $1}' /proc/loadavg))"
    sleep "$SETTLE"
    echo "--- round $round (load $(awk '{print $1}' /proc/loadavg))"
    # Rotated, so a drift in the host over the run cannot favour one front-end.
    if [ $(( round % 2 )) -eq 1 ]; then
        run N "$PORT_N" "nginx"
        run X "$PORT_X" "volucer"
    else
        run X "$PORT_X" "volucer"
        run N "$PORT_N" "nginx"
    fi
done

echo
echo "=== php-fpm children at end: $(pgrep -cf 'php-fpm: pool bench$' || echo 0)"
