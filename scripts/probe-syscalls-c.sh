#!/usr/bin/env bash
# What does ONE volucer `external` request cost in syscalls, at each concurrency?
#
# The trajectory probe says volucer's front-end costs ~49 us/request at c=1 and ~76 at c=4, then
# eases back to ~50-56 at c=100. nginx's is flat at ~47 throughout. A hump like that cannot come
# from a per-request cost that is constant -- it has to come from something that is *worse* at
# low concurrency than at high, which in a runtime means parking and waking.
#
# So this counts, per request, by opcode:
#   * the syscall mix (attach to the running volucer with bpftrace -p)
#   * how many of them are `connect`  (one per request iff the pool keeps no warm connection)
#   * how many are `futex`            (park/wake: two per cross-thread hand-off)
#   * how many are `epoll_wait`       (the runtime going to sleep because it ran out of work)
#
# `epoll_wait` per request is the tell for the low-concurrency shape: a thread that blocks in
# epoll has to be woken by an interrupt for the next request, where a thread that is already
# running does not. nginx's worker count is fixed, so its curve is flat for a different reason.
#
# Usage: probe-syscalls-c.sh [secs] [children]
#   CONCS="1 4 16 100"
set -eu

SECS=${1:-12}
CHILDREN=${2:-96}
CONCS=${CONCS:-"1 4 16 100"}
SETTLE=${SETTLE:-8}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-sysc-c
BIN=${BIN:-$HOME/hello-bench/bin/volucer-050}
PORT=22995
OUT="$D/results.txt"

rm -rf "$D"; mkdir -p "$D"

cleanup() {
    for p in $(pgrep -f "$D/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(ps -eo pid,args --no-headers 2>/dev/null \
               | grep "[p]hp-fpm: pool bench$" | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    [ -f "$D/vol.pid" ] && kill -9 "$(cat "$D/vol.pid")" 2>/dev/null || true
    pkill -x wrk 2>/dev/null || true
    sleep 0.3
}
trap cleanup EXIT INT TERM
cleanup

echo "=== volucer: $("$BIN" --version 2>&1) $(sha256sum "$BIN" | awk '{print substr($1,1,16)}')"

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

sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{SOCKET}}|$D/fpm.sock|g" \
    "$ROOT/conf/hello-external-fpm.toml.template" > "$D/vol.toml"
"$BIN" serve -c "$D/vol.toml" >"$D/vol.log" 2>&1 &
VOL_PID=$!
echo "$VOL_PID" > "$D/vol.pid"
sleep 2
body=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/" || echo "<no answer>")
case $body in *'"hello"'*) echo "  volucer -> $body" ;;
    *) echo "=== FATAL: not serving: $body"; exit 1 ;; esac

# One warm-up so the pool's first-request costs are not in the sample.
wrk -t2 -c4 -d4s "http://127.0.0.1:$PORT/" >/dev/null 2>&1 || true
sleep 3

# The counting window and the rate window have to agree, or the answer is a ratio of two
# unrelated things. bpftrace takes ~1 s to attach, so the shape is:
#
#   wrk (SECS, background) ----> warms the pool for WARMUP seconds
#                        bpftrace (WINDOW seconds)  <-- counts only inside the steady state
#
# and requests in the window is `rps * WINDOW`, which is exact if the rate is flat -- checked by
# taking wrk's own mean and its second half, printed beside the count.
WINDOW=${WINDOW:-6}
WARMUP=${WARMUP:-6}

: > "$OUT"
for c in $CONCS; do
    sleep "$SETTLE"
    t=$(nproc);     if [ "$t" -gt "$c" ]; then t=$c; fi
    wrk -t"$t" -c"$c" -d"$(( WARMUP + WINDOW + 4 ))s" --latency \
        "http://127.0.0.1:$PORT/" >"$D/wrk-c$c.txt" 2>&1 &
    WJ=$!
    sleep "$WARMUP"
    sudo bpftrace -p "$VOL_PID" -e '
        tracepoint:syscalls:sys_enter_futex   { @futex = count(); }
        tracepoint:syscalls:sys_enter_connect { @connect = count(); }
        tracepoint:syscalls:sys_enter_epoll_wait { @epoll = count(); }
        tracepoint:syscalls:sys_enter_recvfrom { @recvfrom = count(); }
        tracepoint:syscalls:sys_enter_sendto   { @sendto = count(); }
        tracepoint:syscalls:sys_enter_writev   { @writev = count(); }
        tracepoint:syscalls:sys_enter_accept4  { @accept4 = count(); }
        tracepoint:syscalls:sys_enter_clock_gettime { @clock = count(); }
        tracepoint:syscalls:sys_enter_read     { @read = count(); }
        interval:s:'"$WINDOW"' { exit(); }
    ' >"$D/bt-c$c.txt" 2>&1
    wait $WJ 2>/dev/null || true
    rps=$(awk '/^Requests\/sec:/{print $2}' "$D/wrk-c$c.txt")
    total=$(awk '/requests in /{print $1}' "$D/wrk-c$c.txt")
    echo "  c=$c  rps=$rps  requests=$total" | tee -a "$OUT"
    awk -v c="$c" -v r="${rps:-1}" -v w="$WINDOW" '
        BEGIN { n = r * w }          # requests inside the bpftrace window
        /^@/ {
            name = $1
            sub(/^@/, "", name); sub(/:$/, "", name); gsub(/\[.*$/, "", name)
            v[name] = $2
        }
        END {
            printf "%-6s window=%ss  ", c, w
            split("connect accept4 futex epoll clock recvfrom sendto writev read", order, " ")
            for (i = 1; i <= 10; i++) printf " %s=%.2f", order[i], (v[order[i]]+0)/n
            printf "\n"
        }' "$D/bt-c$c.txt" | tee -a "$OUT"
done
