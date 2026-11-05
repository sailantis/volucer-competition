#!/usr/bin/env bash
# How many socket-readiness wakeups does each front-end pay per request?
#
# `probe-spinlock.sh` attributes 94.6% of the front-end's largest self-time symbol to
# `__wake_up_sync_key`, which is what `sock_def_readable` calls when data arrives on a socket:
# it takes the socket's wait-queue lock, runs every registered callback (`ep_poll_callback` for a
# tokio task, nginx's own handler for an nginx worker), and wakes whoever was waiting.
#
# That is a *per-I/O-event* cost, not a per-thread contention cost, so the question that decides
# whether it is reducible is not "which thread" but "how many events". A request that is one read
# from the client and one read from the backend costs two. If volucer pays two and nginx pays two,
# the share is inherent and nothing here is worth changing; if volucer pays four, that is a defect
# with a shape.
#
# Both arms are measured in the same run, against the same pool of children, with the same request
# count divisor taken from wrk itself rather than assumed.
#
# Usage: probe-wakeups.sh [secs] [conc] [children]
set -eu

SECS=${1:-14}
CONC=${2:-100}
CHILDREN=${3:-96}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-wake
BIN=${BIN:-$HOME/hello-bench/bin/volucer-adopt}
PORT_N=23009
PORT_X=23011
NGINX=${NGINX:-/usr/sbin/nginx}
NGX="$D/ngx"

rm -rf "$D"; mkdir -p "$D" "$NGX/tmp/client" "$NGX/tmp/proxy" "$NGX/tmp/fastcgi" \
    "$NGX/tmp/uwsgi" "$NGX/tmp/scgi"

cleanup() {
    for p in $(pgrep -f "probe-wake/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
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
echo "=== nginx:   $("$NGINX" -v 2>&1 | sed 's/^nginx version: //')"

FPM_USER=${SUDO_USER:-$(id -un)}
FPM_GROUP=$(id -gn "$FPM_USER" 2>/dev/null || id -gn)
cat > "$D/pool.conf" <<EOF
[global]
daemonize = no
error_log = $D/fpm-error.log
[bench]
listen = $D/fpm.sock
listen.owner = $FPM_USER
listen.group = $FPM_GROUP
listen.mode = 0660
user = $FPM_USER
group = $FPM_GROUP
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

# `user` is set explicitly, because under `sudo` nginx otherwise runs its workers as `www-data`
# while the pool's socket is owned by the invoking account. The symptom is a 502 with
# `connect() ... (13: Permission denied)` in nginx's own error log, which is easy to misread as a
# missing socket. (A comment inside this heredoc would have its backticks executed by the shell.)
cat > "$D/nginx.conf" <<EOF
daemon off;
worker_processes 4;
user $FPM_USER;
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

# The binary's own name is the comm. Taken from the file rather than hard-coded, so a binary
# named something else does not silently count zero.
VOL_COMM=$(basename "$BIN")
VOL_COMM=${VOL_COMM:0:15}

# Both comms counted in one script; a kprobe rather than a tracepoint, because the question is
# which kernel function is entered and there is no tracepoint for `__wake_up_sync_key`.
cat > "$D/wake.bt" <<BT
kprobe:__wake_up_sync_key
{
    @wakes[comm] = count();
    @tids[comm, tid] = count();
}
interval:s:2
{
    clear(@tids);
}
BT

CORES=$(nproc)
T=$CORES
[ "$T" -gt "$CONC" ] && T=$CONC

measure() {   # $1 tag  $2 port  $3 label
    local tag=$1 port=$2 label=$3
    wrk -t"$T" -c"$CONC" -d5s "http://127.0.0.1:$port/" >/dev/null 2>&1 || true
    sleep 2
    : >"$D/wake-$tag.out"
    bpftrace -e "$(cat "$D/wake.bt")" >"$D/wake-$tag.out" 2>&1 &
    local bpf=$!
    sleep 2
    local mark
    mark=$(date +%s%N)
    wrk -t"$T" -c"$CONC" -d"${SECS}s" "http://127.0.0.1:$port/" >"$D/wrk-$tag.txt" 2>&1 || true
    sleep 1
    kill -INT "$bpf" 2>/dev/null || true
    sleep 3
    kill -9 "$bpf" 2>/dev/null || true

    local rps reqs
    rps=$(awk '/^Requests\/sec:/{print $2}' "$D/wrk-$tag.txt")
    reqs=$(awk -v r="${rps:-0}" -v s="$SECS" 'BEGIN{printf "%.0f", r * s}')
    echo
    echo "--- $label  (${rps:-0} rps, ~$reqs requests)"
    python3 - "$D/wake-$tag.out" "${reqs:-1}" "$VOL_COMM" <<'PY'
import re
import sys

path, reqs, volcomm = sys.argv[1], float(sys.argv[2]), sys.argv[3]
wakes = {}
tid_detail = {}
for line in open(path, errors="replace"):
    m = re.match(r"^@wakes\[([^\]]+)\]: (\d+)", line)
    if m:
        wakes[m.group(1)] = int(m.group(2))
        continue
    m = re.match(r"^@tids\[([^,]+), (\d+)\]: (\d+)", line)
    if m:
        tid_detail.setdefault(m.group(1), []).append((int(m.group(2)), int(m.group(3))))

if not wakes:
    print("    !! no wake counts captured")
    raise SystemExit(0)

for comm, n in sorted(wakes.items(), key=lambda kv: -kv[1]):
    if n < 1000:
        continue
    per = n / reqs if reqs else 0
    threads = len(tid_detail.get(comm, []))
    print(f"    {comm:<20} {n:>12,} wakes  {per:>7.3f} /request   threads seen {threads}")
PY
}

echo
echo "--- counting __wake_up_sync_key at c=$CONC, ${SECS}s per arm"
measure N "$PORT_N" "nginx (4 workers)"
sleep 3
measure X "$PORT_X" "volucer (${VOL_COMM})"

echo
echo "=== php-fpm children at end: $(pgrep -cf 'php-fpm: pool bench$' || echo 0)"
