#!/usr/bin/env bash
# Where do volucer's ~85 us of front-end CPU per request go?
#
# The latency curve settled what the 241 us is *not*. At c=1 volucer beat nginx (4,748 against
# 4,361 rps, p50 204 against 219 us), so there is no fixed per-request deficit -- no extra
# syscall, no missing fast path, no slower parsing. nginx overtakes only as concurrency rises,
# and the column that explains why is the front-end's own CPU per request:
#
#     c=1    nginx 48.8 us   volucer 84.9 us   1.74x
#     c=32   nginx 41.5 us   volucer 82.8 us   2.00x
#     c=100  nginx 35.5 us   volucer 78.0 us   2.20x
#
# 78 us x 45,763 rps is 3.8 cores of front-end CPU against nginx's 2.3, so volucer is CPU-bound
# against a cheaper front-end. That is the 1.42x. So the question is a profile question, not an
# architecture question: which instructions are those 78 us?
#
# `perf` has no PMU in this guest (`cycles` returns <not supported>), but `cpu-clock` is a
# software event and samples fine -- verified before this probe was written. `-p` needs root,
# which this VM allows without a password.
#
# Usage: probe-profile.sh [conc] [secs]
set -eu

CONC=${1:-100}
SECS=${2:-20}
SETTLE=${SETTLE:-20}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-profile
BIN=${BIN:-$HOME/hello-bench/bin/volucer-adopt}
PORT_N=22995
PORT_X=22996
NGINX=${NGINX:-/usr/sbin/nginx}
NGX="$D/ngx"
CHILDREN=${CHILDREN:-96}

rm -rf "$D"; mkdir -p "$D" "$NGX/tmp/client" "$NGX/tmp/proxy" "$NGX/tmp/fastcgi" \
    "$NGX/tmp/uwsgi" "$NGX/tmp/scgi"

cleanup() {
    for p in $(pgrep -f "probe-profile/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
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
    case $body in *'"hello"'*) echo "  $tag -> $body" ;;
        *) echo "=== FATAL: $tag is not serving: $body"; exit 1 ;; esac
done

VOL_PID=$(pgrep -f "volucer.*$D/vol.toml" | head -1)
NGX_MASTER=$(cat "$NGX/nginx.pid")
[ -n "$VOL_PID" ] || { echo "=== FATAL: no volucer pid"; exit 1; }
echo "=== volucer pid $VOL_PID, nginx master $NGX_MASTER, c=$CONC"

echo "--- settling ${SETTLE}s (load $(awk '{print $1}' /proc/loadavg))"
sleep "$SETTLE"

profile() {   # $1 label  $2 port  $3 pids (space separated)  $4 out-prefix
    local label=$1 port=$2 pids=$3 out=$4
    # Load first, profile second, so the profile describes steady state rather than ramp-up.
    echo "--- load $label at c=$CONC"
    wrk -t12 -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:$port/" >"$D/wrk-$out.txt" 2>&1 &
    local wrk=$!
    sleep 5      # let the run reach steady state before sampling
    # `-g` for call graphs would need frame pointers this build may not keep; `--no-children`
    # is what makes the percentages attribute to the function itself rather than to callers.
    sudo perf record -F 999 -e cpu-clock -o "$D/$out.data" \
        $(for p in $pids; do printf -- '-p %s ' "$p"; done) -- sleep 10 \
        >"$D/$out.record.log" 2>&1 || true
    wait "$wrk" || true
    awk '/^Requests\/sec:/{printf "    %s rps: %s\n", "'"$label"'", $2}' "$D/wrk-$out.txt"
    sudo perf report -i "$D/$out.data" --stdio --no-children --percent-limit 0.7 \
        >"$D/$out.report.txt" 2>&1 || true
}

profile volucer "$PORT_X" "$VOL_PID" volucer
sleep 25
profile nginx "$PORT_N" "$NGX_MASTER $(pgrep -P "$NGX_MASTER" | tr '\n' ' ')" nginx

echo
echo "================ volucer hot functions ================"
grep -vE "^#|^$" "$D/volucer.report.txt" | head -40
echo
echo "================ nginx hot functions ================"
grep -vE "^#|^$" "$D/nginx.report.txt" | head -30
echo
echo "=== artefacts under $D"
