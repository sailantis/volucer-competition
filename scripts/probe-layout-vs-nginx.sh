#!/usr/bin/env bash
# nginx vs volucer, three layouts, one pool, one socket, one php.ini -- rotated, repeated.
#
# This is the comparison the layout work was for. Every earlier nginx-vs-volucer table in this
# repo ran volucer as ONE process with twelve runtime threads. That shape was measured today to
# carry a per-request penalty nginx's shape does not have:
#
#   * volucer rt=12, external   c=1 44.6 | c=2 62.0 | c=4 75.7 | c=16 71.1 | c=100 54.4 us
#   * volucer rt=1,  external   c=1 47.8 |          | c=4 45.5 | c=16 43.9 | c=100 43.7 us
#
# One runtime thread is cheaper per request at every concurrency above one -- the hump is what a
# connection's data moving between twelve threads' caches costs -- and nginx is the same shape
# (several processes, each running one event loop). So the fair table needs volucer in nginx's
# shape, and that is what `4x1` and `6x1` are.
#
# nginx stays a single process group with `worker_processes 4`, because that is the published
# arm and changing it here would make this table incomparable to every earlier one.
#
# Usage: probe-layout-vs-nginx.sh [secs] [children] [rounds]
set -eu

SECS=${1:-16}
CHILDREN=${2:-96}
ROUNDS=${3:-3}
CONC=${CONC:-100}
SETTLE=${SETTLE:-20}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-layout-nginx
BIN=${BIN:-$HOME/hello-bench/bin/volucer-050}
PORT_N=23090
PORT_X=23091
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
    if [ -f "$D/pids" ]; then while read -r p; do kill -9 "$p" 2>/dev/null || true; done < "$D/pids"; fi
    pkill -x wrk 2>/dev/null || true
    sleep 0.3
}
trap cleanup EXIT INT TERM
cleanup

echo "=== volucer: $("$BIN" --version 2>&1) $(sha256sum "$BIN" | awk '{print substr($1,1,16)}')"
echo "=== nginx:   $("$NGINX" -v 2>&1 | sed 's/^nginx version: //'), worker_processes 4"
echo "=== conc $CONC, ${SECS}s x $ROUNDS rounds, $CHILDREN children"

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
NGX_MASTER=$(cat "$NGX/nginx.pid" 2>/dev/null || echo "")

# One volucer process per core, each with one runtime thread -- nginx's shape. Ports are per
# process because volucer has no SO_REUSEPORT; the generator is split to match, so the offered
# load is the same CONC in total for every arm.
NP=${NP:-4}
VOL_LAYOUT=${VOL_LAYOUT:-4x1}
start_vol_multi() {
    : > "$D/pids"
    local M T
    M=${VOL_LAYOUT%x*}; T=${VOL_LAYOUT#*x}
    for i in $(seq 0 $(( M - 1 ))); do
        sed -e "s|{{PORT}}|$(( PORT_X + i ))|g" -e "s|{{ROOT}}|$ROOT|g" \
            -e "s|{{SOCKET}}|$D/fpm.sock|g" \
            "$ROOT/conf/hello-external-fpm.toml.template" > "$D/vol-$i.toml"
        taskset -c "$i" env TOKIO_WORKER_THREADS="$T" "$BIN" serve -c "$D/vol-$i.toml" \
            >"$D/vol-$i.log" 2>&1 &
        echo $! >> "$D/pids"
    done
    sleep 3
    NP=$M
    for i in $(seq 0 $(( M - 1 ))); do
        body=$(curl -s --max-time 5 "http://127.0.0.1:$(( PORT_X + i ))/" || echo "<no answer>")
        case $body in *'"hello"'*) ;; *) echo "=== FATAL vol $i: $body"; exit 1 ;; esac
    done
}

# ...and one with twelve threads, the shape every earlier table used.
start_vol_single() {
    : > "$D/pids"
    sed -e "s|{{PORT}}|$PORT_X|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{SOCKET}}|$D/fpm.sock|g" \
        "$ROOT/conf/hello-external-fpm.toml.template" > "$D/vol-1x12.toml"
    "$BIN" serve -c "$D/vol-1x12.toml" >"$D/vol-1x12.log" 2>&1 &
    echo $! >> "$D/pids"
    sleep 3
    body=$(curl -s --max-time 5 "http://127.0.0.1:$PORT_X/" || echo "<no answer>")
    case $body in *'"hello"'*) ;; *) echo "=== FATAL vol 1x12: $body"; exit 1 ;; esac
}

stop_vol() {
    if [ -f "$D/pids" ]; then while read -r p; do kill -9 "$p" 2>/dev/null || true; done < "$D/pids"; fi
    : > "$D/pids"
    sleep 2
}

ns_of() { local total=0 pid t v; for pid in "$@"; do for t in /proc/"$pid"/task/*/schedstat; do
    [ -r "$t" ] || continue; v=$(awk '{print $1}' "$t" 2>/dev/null); total=$(( total + ${v:-0} )); done; done; echo "$total"; }

# Run one arm; $1 = label, $2 = "nginx" | "volucer". Prints one row.
run_arm() {
    label=$1; kind=$2
    case $kind in
        nginx)
            pids=$(pgrep -P "$NGX_MASTER" 2>/dev/null | tr '\n' ' ')
            f0=$(ns_of $pids)
            wrk -t12 -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:$PORT_N/" \
                >"$D/wrk-$label.txt" 2>&1
            f1=$(ns_of $pids) ;;
        volucer-multi)
            pids=$(tr '\n' ' ' < "$D/pids")
            f0=$(ns_of $pids)
            # The generator shape is held identical to the single-process arm: four `wrk` processes
            # at `-t3 -c25`. Splitting it by port instead would give the multi-process arm a
            # different generator, which is a confound this record has already been bitten by.
            jobs=""
            per=$(( CONC / 4 ))
            for i in $(seq 0 $(( NP - 1 ))); do
                wrk -t3 -c"$per" -d"${SECS}s" --latency "http://127.0.0.1:$(( PORT_X + i ))/" \
                    >"$D/wrk-$label-$i.txt" 2>&1 &
                jobs="$jobs $!"
            done
            for j in $jobs; do wait "$j" 2>/dev/null || true; done
            f1=$(ns_of $pids) ;;
        volucer-single)
            pids=$(cat "$D/pids")
            f0=$(ns_of $pids)
            jobs=""
            for i in 0 1 2 3; do
                wrk -t3 -c$(( CONC / 4 )) -d"${SECS}s" --latency "http://127.0.0.1:$PORT_X/" \
                    >"$D/wrk-$label-$i.txt" 2>&1 &
                jobs="$jobs $!"
            done
            for j in $jobs; do wait "$j" 2>/dev/null || true; done
            f1=$(ns_of $pids) ;;
    esac

    if [ "$kind" = nginx ]; then
        rps=$(awk '/^Requests\/sec:/{print $2}' "$D/wrk-$label.txt")
        total=$(awk '/requests in /{print $1}' "$D/wrk-$label.txt")
        p50=$(awk '/^ +50%/{print $2}' "$D/wrk-$label.txt")
        bad=$(awk -F: '/Non-2xx/{gsub(/ /,"",$2); print $2+0}' "$D/wrk-$label.txt")
    else
        rps=0; total=0; bad=0; p50="-"
        # Each generator answered its own share, so the arm's p50 is the worst of them, not their
        # mean: the arm is only as good as its slowest share and averaging would hide a straggler.
        worst=0
        nfiles=$NP
        [ "$kind" = volucer-single ] && nfiles=4
        for i in $(seq 0 $(( nfiles - 1 ))); do
            f="$D/wrk-$label-$i.txt"
            r=$(awk '/^Requests\/sec:/{print $2}' "$f"); rps=$(( rps + ${r%.*} ))
            t=$(awk '/requests in /{print $1}' "$f"); total=$(( total + ${t:-0} ))
            b=$(awk -F: '/Non-2xx/{gsub(/ /,"",$2); print $2+0}' "$f"); bad=$(( bad + ${b:-0} ))
            q=$(awk '/^ +50%/{v=$2; sub(/ms/,"",v); print v+0}' "$f")
            unit=$(awk '/^ +50%/{print $2}' "$f"); case $unit in *ms) : ;; *) q=$(awk -v v="$q" 'BEGIN{printf "%.3f", v/1000}') ;; esac
            worst=$(awk -v a="$worst" -v b="$q" 'BEGIN{print (b>a)?b:a}')
        done
        p50=$(awk -v v="$worst" 'BEGIN{printf "%.2fms", v}')
    fi
    awk -v l="$label" -v r="${rps:-0}" -v d="$(( f1 - f0 ))" -v s="$SECS" -v n="${total:-1}" \
        -v p="${p50:--}" -v c="$CONC" -v bad="${bad:-0}" '
        BEGIN {
            printf "  %-12s c=%-4s %7d rps  p50 %-9s  fe %5.2f c %6.1f us%s\n",
                   l, c, r, p, d/1e9/s, (n>0?d/1e3/n:0),
                   (bad>0 ? "   <<< NON-2xx " bad : "")
        }'
}

echo
for round in $(seq 1 "$ROUNDS"); do
    echo "--- round $round (load $(awk '{print $1}' /proc/loadavg))"
    # Rotated: the arms are started and stopped in a different order each round, so a drift in the
    # host cannot favour the arm that always runs first.
    if [ $(( round % 2 )) -eq 1 ]; then order="nginx single multi"; else order="multi single nginx"; fi
    for which in $order; do
        # Only the volucer processes are stopped between arms. nginx stays up for the whole run and
        # so does the php-fpm pool: killing and restarting either would charge an arm for a warm-up
        # 96 others are not paying.
        if [ "$which" = nginx ]; then
            stop_vol
        elif [ "$which" = single ]; then
            stop_vol; start_vol_single
        else
            stop_vol; start_vol_multi
        fi
        sleep "$SETTLE"
        sleep 3
        case $which in
            nginx)          run_arm "nginx" "nginx" ;;
            single)         run_arm "volucer-1x12" "volucer-single" ;;
            multi)          run_arm "volucer-${VOL_LAYOUT}" "volucer-multi" ;;
        esac
    done
done
