#!/usr/bin/env bash
# Is volucer's 1.36x against nginx a *limit*, or is it a ceiling in volucer's own config?
#
# `probe-nginx-cpu.sh` at concurrency 1600 showed volucer refusing connections with
# `at the limit active=513` while nginx's `worker_connections 4096` refused nothing. volucer's
# default `[server] max_connections` is 512 and the nginx arm's is 4096, so past 512 concurrent
# clients the two arms are not being compared — one is being throttled. This probe holds every
# other number fixed and varies only that one, so the answer is whether the default ceiling is
# what caps the published arm at c>=100.
set -eu

SECS=${1:-16}
CONC=${2:-400}
CHILDREN=${3:-96}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-limit
BIN=${BIN:-$HOME/hello-bench/bin/volucer-adopt}
PORT_X=22999

rm -rf "$D"; mkdir -p "$D"

cleanup() {
    for p in $(pgrep -f "probe-limit/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(ps -eo pid,args --no-headers 2>/dev/null \
               | grep "[p]hp-fpm: pool bench$" | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    sleep 0.3
}
trap cleanup EXIT INT TERM
cleanup

echo "=== volucer: $BIN $("$BIN" --version 2>&1) $(sha256sum "$BIN" | cut -c1-16)"

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

wait_quiet() {
    local n=0 l
    while :; do
        l=$(cut -d' ' -f1 /proc/loadavg)
        awk -v v="$l" 'BEGIN{exit !(v<1.2)}' && return 0
        n=$(( n + 1 )); [ "$n" -ge 24 ] && return 0
        sleep 5
    done
}

start_server() {   # $1 = max_connections ("default" means omit)
    local limit=$1
    sed -e "s|{{PORT}}|$PORT_X|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{SOCKET}}|$D/fpm.sock|g" \
        "$ROOT/conf/hello-external-fpm.toml.template" > "$D/vol.toml"
    if [ "$limit" != "default" ]; then
        awk -v l="$limit" '
            /^\[server\]$/ { print; print "max_connections = " l; next }
            { print }
        ' "$D/vol.toml" > "$D/vol2.toml"
        mv "$D/vol2.toml" "$D/vol.toml"
    fi
    grep -q '^max_connections' "$D/vol.toml" && \
        echo "  (server ceiling: $(grep '^max_connections' "$D/vol.toml" | head -1))" || \
        echo "  (server ceiling: default 512)"
    "$BIN" serve -c "$D/vol.toml" >"$D/vol.log" 2>&1 &
    local p=$!
    for _ in $(seq 1 100); do
        curl -sf --max-time 2 "http://127.0.0.1:$PORT_X/" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    echo "=== FATAL: volucer did not answer"; tail -20 "$D/vol.log"; return 1
}

stop_server() {
    local p
    p=$(pgrep -f "$D/vol.toml" 2>/dev/null | head -1)
    [ -n "$p" ] && kill -9 "$p" 2>/dev/null || true
    sleep 0.5
}

ns_of_pid() {
    local total=0 t v
    for t in /proc/"$1"/task/*/schedstat; do
        [ -r "$t" ] || continue
        v=$(awk '{print $1}' "$t" 2>/dev/null); total=$(( total + ${v:-0} ))
    done
    echo "$total"
}

CORES=$(nproc)
T=$CORES
[ "$T" -gt "$CONC" ] && T=$CONC

run_cell() {   # $1 label
    local label=$1 p n0 n1 rps p50 bad refused
    p=$(pgrep -f "$D/vol.toml" 2>/dev/null | head -1)
    [ -n "$p" ] || { echo "  !! no server for $label"; return 1; }
    # Discarded warm-up: the first pass after a start pays the pool being built.
    wrk -t"$T" -c"$CONC" -d5s "http://127.0.0.1:$PORT_X/" >/dev/null 2>&1 || true
    wait_quiet
    n0=$(ns_of_pid "$p")
    : >"$D/mark.log"
    local before
    before=$(wc -l <"$D/vol.log")
    wrk -t"$T" -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:$PORT_X/" >"$D/wrk.txt" 2>&1 || true
    n1=$(ns_of_pid "$p")
    rps=$(awk '/^Requests\/sec:/{print $2}' "$D/wrk.txt")
    p50=$(awk '/^ +50%/{print $2}' "$D/wrk.txt")
    bad=$(awk -F: '/Non-2xx/{gsub(/ /,"",$2); print $2+0}' "$D/wrk.txt")
    refused=$(tail -n +"$(( before + 1 ))" "$D/vol.log" | grep -c "at the limit" || true)
    awk -v l="$label" -v r="${rps:-0}" -v p="${p50:--}" -v d="$(( n1 - n0 ))" -v s="$SECS" \
        -v bad="${bad:-0}" -v ref="${refused:-0}" -v c="$CONC" \
        'BEGIN{
            printf "  %-22s c=%-5s %7d rps  p50 %-9s  fe %6.1f us   refused %d%s\n",
                   l, c, r, p, (r>0 ? (d/(r*s))/1000 : 0), ref,
                   (bad > 0 ? "   NON-2xx " bad : "")
        }'
}

echo
echo "--- ${SECS}s cells at concurrency $CONC, $CHILDREN php-fpm children"
for limit in default 0 4096; do
    wait_quiet
    echo "--- ceiling $limit (load $(cut -d' ' -f1 /proc/loadavg))"
    start_server "$limit"
    run_cell "max_connections=$limit"
    run_cell "max_connections=$limit (2)"
    stop_server
done

echo
echo "=== php-fpm children at end: $(pgrep -cf 'php-fpm: pool bench$' || echo 0)"
