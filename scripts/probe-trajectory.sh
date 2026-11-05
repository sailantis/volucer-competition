#!/usr/bin/env bash
# volucer `external` against nginx, both in front of ONE php-fpm pool, ACROSS CONCURRENCY.
#
# This exists because the recorded trajectory -- volucer matching nginx at c=1, losing 30 us of
# front-end CPU by c=4, then narrowing to ~19 us at c=100 -- is a *shape* claim, and it was taken
# with ONE 10 s pass per cell. A single pass per cell cannot distinguish a real curve from a
# first-pass artefact, and this record has already been burned by exactly that: Phase 20 found
# two scripts measuring "the same cell" 7% apart because one timed its own startup.
#
# So: ROUNDS passes per cell, order rotated, the first pass of each cell discarded (`SKIP`), and
# the median of what is left reported beside every cell. A hump that survives that is real.
#
# The arms are the same two as `probe-nginx-vs-volucer.sh` and are started identically -- one
# pool file, one socket, 96 children, one php.ini, one front controller -- so the only variable
# is the front-end. `NGINX_WORKERS` stays a knob for the reason that script documents.
#
# Usage: probe-trajectory.sh [secs] [children] [rounds]
#   CONCS="1 2 4 8 16 32 100 200"   the concurrency cells, in order
#   SKIP=1                          passes discarded at the head of each cell
set -eu

SECS=${1:-10}
CHILDREN=${2:-96}
ROUNDS=${3:-3}
SKIP=${SKIP:-1}
SETTLE=${SETTLE:-12}
CONCS=${CONCS:-"1 2 4 8 16 32 100 200"}
NGINX_WORKERS=${NGINX_WORKERS:-4}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-traj
BIN=${BIN:-$HOME/hello-bench/bin/volucer-050}
PORT_N=22990
PORT_X=22991
NGINX=${NGINX:-/usr/sbin/nginx}
NGX="$D/ngx"
OUT="$D/results.txt"

rm -rf "$D"; mkdir -p "$D" "$NGX/tmp/client" "$NGX/tmp/proxy" "$NGX/tmp/fastcgi" \
    "$NGX/tmp/uwsgi" "$NGX/tmp/scgi"

cleanup() {
    # Anchored on the probe directory: `pkill -f probe-traj` matches this script's own argv.
    for p in $(pgrep -f "$D/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(ps -eo pid,args --no-headers 2>/dev/null \
               | grep "[p]hp-fpm: pool bench$" | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    [ -f "$NGX/nginx.pid" ] && kill -9 "$(cat "$NGX/nginx.pid")" 2>/dev/null || true
    [ -f "$D/vol.pid" ] && kill -9 "$(cat "$D/vol.pid")" 2>/dev/null || true
    sleep 0.3
}
trap cleanup EXIT INT TERM
cleanup

echo "=== volucer: $("$BIN" --version 2>&1) $(sha256sum "$BIN" | awk '{print substr($1,1,16)}')"
echo "=== nginx:   $("$NGINX" -v 2>&1 | sed 's/^nginx version: //'), worker_processes $NGINX_WORKERS"
echo "=== cells:   c in {$CONCS}, ${SECS}s, $ROUNDS rounds (first $SKIP discarded) per cell"

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
worker_processes $NGINX_WORKERS;
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

# A dead backend answers faster than a live one. Prove both before timing anything.
for pair in "$PORT_N:nginx" "$PORT_X:volucer"; do
    port=${pair%%:*}; tag=${pair##*:}
    body=$(curl -s --max-time 5 "http://127.0.0.1:$port/" || echo "<no answer>")
    case $body in *'"hello"'*) echo "  $tag -> $body" ;;
        *) echo "=== FATAL: $tag is not serving: $body"; exit 1 ;; esac
done
echo "=== php-fpm children: $(pgrep -cf 'php-fpm: pool bench$' || echo 0)"

ns_of() {   # CPU nanoseconds across every thread of every pid given
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
children_ns() { ns_of $(pgrep -f 'php-fpm: pool bench$' 2>/dev/null || true); }
front_ns() {
    case $1 in
        nginx)
            if [ -n "$NGX_MASTER" ]; then
                ns_of $(pgrep -P "$NGX_MASTER" 2>/dev/null || true)
            else
                ns_of $(pgrep -f "nginx: worker process" 2>/dev/null || true)
            fi ;;
        volucer) ns_of "$VOL_PID" ;;
    esac
}
CORES=$(nproc)

# One cell. Prints a machine-readable row; `awk` formats, because this host's locale rejects a
# decimal point in the shell's `printf %f` and `set -e` turns that into a dead run.
cell() {   # $1 label  $2 port  $3 conc  $4 round
    local label=$1 port=$2 c=$3 round=$4
    local t=$CORES
    if [ "$t" -gt "$c" ]; then t=$c; fi
    local f="$D/wrk-$label-c$c-r$round.txt"
    local b0 b1 f0 f1
    b0=$(children_ns); f0=$(front_ns "$label")
    wrk -t"$t" -c"$c" -d"${SECS}s" --latency "http://127.0.0.1:$port/" >"$f" 2>&1
    b1=$(children_ns); f1=$(front_ns "$label")
    local rps total p50 bad
    rps=$(awk '/^Requests\/sec:/{print $2}' "$f")
    total=$(awk '/requests in /{print $1}' "$f")
    p50=$(awk '/^ +50%/{print $2}' "$f")
    bad=$(awk -F: '/Non-2xx/{gsub(/ /,"",$2); print $2+0}' "$f")
    awk -v l="$label" -v c="$c" -v rnd="$round" -v r="${rps:-0}" -v p="${p50:--}" \
        -v bd="$(( b1 - b0 ))" -v fd="$(( f1 - f0 ))" -v s="$SECS" \
        -v bad="${bad:-0}" -v n="${total:-1}" '
        BEGIN{
            be = (r > 0) ? (bd / (r * s)) / 1000 : 0
            fe = (n > 0)  ? (fd / 1e3 / n)     : 0
            printf "ROW %s c=%d r=%d rps=%d p50=%s be=%.1f fe=%.1f bad=%d\n",
                   l, c, rnd, r, p, be, fe, bad
        }' | tee -a "$OUT"
}

: > "$OUT"
for c in $CONCS; do
    for r in $(seq 0 "$ROUNDS"); do
        if [ $(( r % 2 )) -eq 0 ]; then order="nginx volucer"; else order="volucer nginx"; fi
        for label in $order; do
            port=$PORT_X; [ "$label" = nginx ] && port=$PORT_N
            if [ "$r" -lt "$SKIP" ]; then
                cell "$label" "$port" "$c" "$r" | sed 's/^ROW /WARM /'
            else
                cell "$label" "$port" "$c" "$r"
            fi
        done
        sleep "$SETTLE"
    done
done

echo
echo "=== php-fpm children at end: $(pgrep -cf 'php-fpm: pool bench$' || echo 0)"
echo
echo "=== median of the measured passes per cell (front-end us/request)"
awk '/^ROW /{
        for(i=2;i<=NF;i++){split($i,kv,"="); v[kv[1]]=kv[2]}
        key = v["c"] " " $2
        n[key]++; fe[key, n[key]] = v["fe"]; rp[key, n[key]] = v["rps"]
        cells[v["c"]] = 1
     }
     END{
        printf "%-6s %-9s %10s %10s %10s\n", "conc", "front-end", "rps", "fe us/req", "n"
        for (c in cells) {
            for (a in n) { split(a, p, " "); if (p[1] != c) continue
                k = n[a]; for (i = 1; i <= k; i++) for (j = i+1; j <= k; j++) {
                    if (fe[a, i] > fe[a, j]) { t = fe[a,i]; fe[a,i]=fe[a,j]; fe[a,j]=t }
                    if (rp[a, i] > rp[a, j]) { t = rp[a,i]; rp[a,i]=rp[a,j]; rp[a,j]=t }
                }
                mid = int((k+1)/2)
                printf "%-6d %-9s %10d %10.1f %10d\n", c, p[2], rp[a,mid], fe[a,mid], k
            }
        }
     }' "$OUT" | sort -n
