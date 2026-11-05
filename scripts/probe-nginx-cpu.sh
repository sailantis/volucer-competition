#!/usr/bin/env bash
# Where does nginx's advantage over volucer actually live — work, or waiting?
#
# `probe-nginx-vs-volucer.sh` says the two differ by ~1.36x through one php-fpm pool. That
# ratio alone cannot say whether volucer *does more* per request (work) or *waits more*
# per request (latency that concurrency fails to hide). The two have opposite fixes, so this
# probe counts CPU for both front-ends against the SAME children.
#
# Both numbers come from /proc/<pid>/task/*/schedstat field 1, summed over every thread, which
# is the same instrument `arms.sh` uses for its `fe` column. A per-request figure above nginx's
# means work; a per-request figure *below* nginx's at a lower request rate means waiting.
#
# Usage: probe-nginx-cpu.sh [secs] [conc] [children]
set -eu

SECS=${1:-16}
CONC=${2:-100}
CHILDREN=${3:-96}
SETTLE=${SETTLE:-30}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-ngxcpu
BIN=${BIN:-$HOME/hello-bench/bin/volucer-adopt}
PORT_N=22990
PORT_X=22991
NGINX=${NGINX:-/usr/sbin/nginx}
NGX="$D/ngx"

rm -rf "$D"; mkdir -p "$D" "$NGX/tmp/client" "$NGX/tmp/proxy" "$NGX/tmp/fastcgi" \
    "$NGX/tmp/uwsgi" "$NGX/tmp/scgi"

cleanup() {
    for p in $(pgrep -f "probe-ngxcpu/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
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

echo "=== volucer: $BIN $("$BIN" --version 2>&1) $(sha256sum "$BIN" | cut -c1-16)"
echo "=== nginx:   $NGINX $("$NGINX" -v 2>&1 | sed 's/^nginx version: //')"

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

# ns of CPU over every thread of a pid population. `/proc/<pid>/schedstat` is the thread-group
# leader only; a multi-threaded front-end read that way reports ~0. Must sum task/*.
ns_of_pids() {
    local total=0 pid t v
    for pid in "$@"; do
        [ -d /proc/"$pid" ] || continue
        for t in /proc/"$pid"/task/*/schedstat; do
            [ -r "$t" ] || continue
            v=$(awk '{print $1}' "$t" 2>/dev/null)
            total=$(( total + ${v:-0} ))
        done
    done
    echo "$total"
}

nginx_pids()  { pgrep -f "nginx: worker process" 2>/dev/null || true; }
volucer_pids(){ local p; p=$(pgrep -f "$D/vol.toml" 2>/dev/null | head -1); [ -n "$p" ] && echo "$p"; }
fpm_pids()    { pgrep -f 'php-fpm: pool bench$' 2>/dev/null || true; }

CORES=$(nproc)

# A cell is only a measurement if the host is quiet. `load1` alone is not enough: it takes
# ~300 s to decay after a 96-child pool, so a run started five minutes early reports the heat of
# the previous run (an earlier attempt measured its whole grid at load 7-40 and every number in
# it was meaningless). Gate on both, and wait rather than sampling regardless.
wait_quiet() {
    local want=${1:-$SETTLE} l1 l5 n=0
    while :; do
        read -r l1 l5 _ </proc/loadavg
        # `load1` only. `load5` remembers the previous 96-child pool for minutes after it is gone,
        # so gating on it refuses to measure a host that measurement itself made busy.
        local a
        a=$(awk -v v="$l1" 'BEGIN{printf "%d", v*100}')
        if [ "$a" -lt 120 ]; then return 0; fi
        n=$(( n + 1 ))
        if [ "$n" -ge 24 ]; then
            echo "  !! still at load $l1 after $(( n * 5 ))s; measuring anyway"
            return 0
        fi
        sleep 5
    done
}

run() {   # $1 tag  $2 port  $3 label
    local tag=$1 port=$2 label=$3
    local t=$CORES
    [ "$t" -gt "$CONC" ] && t=$CONC
    # shellcheck disable=SC2207
    local fe_pids=""
    case $tag in
        N) fe_pids=$(nginx_pids) ;;
        X) fe_pids=$(volucer_pids) ;;
        *) echo "  !! unknown arm tag $tag"; return 1 ;;
    esac
    local be_pids
    be_pids=$(fpm_pids)
    local fe0 fe1 b0 b1 rps p50 bad
    fe0=$(ns_of_pids $fe_pids)
    b0=$(ns_of_pids $be_pids)
    f0=$(awk '{print $1}' /proc/loadavg)
    wrk -t"$t" -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:$port/" >"$D/wrk-$tag.txt" 2>&1
    fe1=$(ns_of_pids $fe_pids)
    b1=$(ns_of_pids $be_pids)
    rps=$(awk '/^Requests\/sec:/{print $2}' "$D/wrk-$tag.txt")
    p50=$(awk '/^ +50%/{print $2}' "$D/wrk-$tag.txt")
    bad=$(awk -F: '/Non-2xx/{gsub(/ /,"",$2); print $2+0}' "$D/wrk-$tag.txt")
    # Formatted in awk: this host's locale rejects a decimal point in the shell's printf %f.
    awk -v l="$label" -v r="${rps:-0}" -v p="${p50:--}" \
        -v fe="$(( fe1 - fe0 ))" -v bb="$(( b1 - b0 ))" -v s="$SECS" \
        -v bad="${bad:-0}" -v c="$CONC" -v ld="$f0" \
        'BEGIN{
            req = r * s
            fcpu = (req > 0) ? (fe / req / 1000) : 0
            bcpu = (req > 0) ? (bb / req / 1000) : 0
            cores = (s > 0) ? (fe / s / 1e9) : 0
            printf "  %-9s c=%-4s %7d rps  p50 %-9s  fe %6.1f us (%4.2f cores)  be %6.1f us%s\n",
                   l, c, r, p, fcpu, cores, bcpu, (bad > 0 ? "   <<< NON-2xx " bad : "")
        }'
}

echo
echo "--- settling (waiting for load below 1.5)"
wait_quiet 60
echo "--- warm-up (discarded; the first pass pays the pool being built)"
wrk -t"$CORES" -c"$CONC" -d5s "http://127.0.0.1:$PORT_N/" >/dev/null 2>&1 || true
wrk -t"$CORES" -c"$CONC" -d5s "http://127.0.0.1:$PORT_X/" >/dev/null 2>&1 || true
# The warm-up itself is the biggest load this probe creates, so it must be waited out rather
# than slept for. An earlier run measured its c=1 row at load 2.4 -- the warm-up's own heat.
wait_quiet "$SETTLE"

for conc in ${CONCS:-1 8 32 100}; do
    CONC=$conc
    wait_quiet "$SETTLE"
    echo "--- c=$conc (load $(awk '{print $1}' /proc/loadavg))"
    run N "$PORT_N" "nginx"
    run X "$PORT_X" "volucer"
done

echo
echo "=== php-fpm children at end: $(pgrep -cf 'php-fpm: pool bench$' || echo 0)"
