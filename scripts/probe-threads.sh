#!/usr/bin/env bash
# Does volucer's thread count scale with concurrency? If it does, the FastCGI path is parking a
# blocking-pool thread per in-flight request, and that is where the concurrency-dependent cost is.
#
# The gate is `volucer_server::dispatch::answers_asynchronously`, which is `matches!(backend,
# Backend::Worker { .. })` -- ONLY the worker pool. So `external` and `spawn_cgi` both reach
# `Backend::request`, and `listener.rs` answers them inside
#
#     tokio::task::spawn_blocking(move || { ... dispatcher.request(&request) ... })
#
# because `if !streaming_dispatch && awaits_its_backend` is false for them. Each in-flight request
# therefore holds a blocking-pool thread for the whole FastCGI exchange. `Backend::request_async`
# exists, but its fallback arm is `other => other.request(request)` -- synchronous.
#
# Threads are counted from /proc/<pid>/status, which is the number the process itself sees. A
# front-end that never parks anything stays flat; one that parks per request grows with `c`.
#
# Usage: probe-threads.sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-threads
BIN=${BIN:-$HOME/hello-bench/bin/volucer-adopt}
PORT=22998
NGX_PORT=22999
NGINX=${NGINX:-/usr/sbin/nginx}
NGX="$D/ngx"
CHILDREN=${CHILDREN:-96}

rm -rf "$D"; mkdir -p "$D" "$NGX/tmp/client" "$NGX/tmp/proxy" "$NGX/tmp/fastcgi" \
    "$NGX/tmp/uwsgi" "$NGX/tmp/scgi"

cleanup() {
    # Anchored on the *directory* rather than on the script name: `pgrep -f probe-threads` matches
    # the shell running this script (its own argv contains the path), which killed the session in
    # an earlier probe. A pid file is checked too, because an nginx from a killed run keeps
    # listening and the next run then fails to bind *after* `rm -rf` deleted the file that would
    # have found it.
    # **Not** `pgrep -f "probe-threads/"`: that string is in nginx's own command line (`-p $NGX
    # -c $D/nginx.conf`) and in this script's, so the first cleanup killed the run it belonged to.
    # The pid file and the exact volucer config path are the two identifiers that only ever
    # describe processes this run started.
    [ -s "$NGX/nginx.pid" ] && kill -9 "$(cat "$NGX/nginx.pid")" 2>/dev/null || true
    for p in $(pgrep -f "volucer.*$D/vol.toml" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(pgrep -f "$D/pool.conf" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(ps -eo pid,args --no-headers 2>/dev/null \
               | grep "[p]hp-fpm: pool bench$" | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    # An nginx from a killed run keeps listening, and the next run then fails to bind with
    # "Address already in use" *after* `rm -rf` has deleted the pid file that would have found it.
    # Anchored on this probe's own prefix, so the host's nginx is never touched.
    for p in $(ps -eo pid,args --no-headers 2>/dev/null \
               | grep "[n]ginx: .*$D/nginx.conf" | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    [ -s "$NGX/nginx.pid" ] && kill -9 "$(cat "$NGX/nginx.pid")" 2>/dev/null || true
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
php_admin_value[memory_limit] = 512M
EOF
FPM=$(command -v php-fpm8.5 || command -v php-fpm || echo /usr/sbin/php-fpm8.5)
"$FPM" -y "$D/pool.conf" -F -d opcache.enable=1 -d opcache.validate_timestamps=0 >"$D/fpm.log" 2>&1 &
for _ in $(seq 1 300); do [ -S "$D/fpm.sock" ] && break; sleep 0.05; done

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
    server {
        listen 127.0.0.1:$NGX_PORT;
        root $ROOT/apps/hello/public;
        location / {
            include /etc/nginx/fastcgi_params;
            fastcgi_pass unix:$D/fpm.sock;
            fastcgi_param SCRIPT_FILENAME $ROOT/apps/hello/public/index.php;
            fastcgi_param REQUEST_URI \$request_uri;
        }
    }
}
EOF
"$NGINX" -p "$NGX" -c "$D/nginx.conf" >"$D/nginx.log" 2>&1 &
for _ in $(seq 1 100); do [ -s "$NGX/nginx.pid" ] && break; sleep 0.05; done

sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{SOCKET}}|$D/fpm.sock|g" \
    "$ROOT/conf/hello-external-fpm.toml.template" > "$D/vol.toml"
"$BIN" serve -c "$D/vol.toml" >"$D/vol.log" 2>&1 &
sleep 2

# Found by the config path alone, not by ``volucer.*': the binary under test is often an
# experiment copied to /tmp (``/tmp/vol-async-ext``), and requiring the product name in its argv
# made this return nothing while the server was up and serving.
VOL=$(pgrep -f "serve -c $D/vol.toml" | head -1)
NGX_MASTER=$(cat "$NGX/nginx.pid")
for pair in "$PORT:volucer" "$NGX_PORT:nginx"; do
    port=${pair%%:*}; tag=${pair##*:}
    body=$(curl -s --max-time 5 "http://127.0.0.1:$port/" || echo "<none>")
    case $body in *'"hello"'*) ;; *) echo "=== FATAL: $tag not serving: $body"; exit 1 ;; esac
done

threads() { awk '/^Threads:/{print $2}' /proc/"$1"/status; }

echo "=== idle"
n=0
for p in $NGX_MASTER $(pgrep -P "$NGX_MASTER"); do n=$(( n + $(threads "$p") )); done
printf "  volucer %s threads   nginx %s threads (all processes)\n" "$(threads "$VOL")" "$n"

for c in 1 8 32 100; do
    wrk -t"$([ "$c" -gt 12 ] && echo 12 || echo "$c")" -c"$c" -d10s \
        "http://127.0.0.1:$PORT/" >/dev/null 2>&1 &
    w1=$!
    sleep 6
    v=$(threads "$VOL")
    # nginx: master plus workers, so the number reflects every process that could park.
    n=0
    for p in $NGX_MASTER $(pgrep -P "$NGX_MASTER"); do n=$(( n + $(threads "$p") )); done
    echo "  c=$c  volucer $v threads    nginx $n threads (all processes)"
    wait $w1 2>/dev/null || true
    sleep 8
done

echo
echo "=== after the runs"
echo "  volucer $(threads "$VOL") threads"
