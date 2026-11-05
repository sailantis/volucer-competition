#!/usr/bin/env bash
# WHERE does the front-end's per-request CPU go, at each concurrency?
#
# The trajectory probe establishes the shape and this one has to explain it:
#
#     c=1   45-49 us/req        c=4   76-77 us/req
#     c=16  72 us/req           c=100 50-56 us/req
#
# A per-request cost that RISES then FALLS with concurrency is not a constant cost and it is not
# CPU saturation (the front-end uses 0.3 cores at c=1 and 2.9 at c=100, of 12). It is something
# whose *share* moves, so the honest instrument is a sample-based profile at each cell rather
# than a count of one syscall.
#
# This records `perf` on the volucer pid inside each cell's steady state and buckets self time by
# symbol. The buckets are chosen to separate the candidates this record has already named:
#
#   futex/spin/switch   parking and waking: the exchange hand-off and the runtime's parker
#   epoll/io            the readiness path
#   net (tcp/skb)       kernel softirq running in our own context
#   alloc               jemalloc
#   hyper               HTTP/1 parse, headers, Date
#   fcgi                record framing, PARAMS encode, response parse
#   tokio               task poll, waker, timer
#   clock               clock_gettime via syscall
#
# `perf_event_paranoid` must be <= 1 (`echo 1 | sudo tee /proc/sys/kernel/perf_event_paranoid`).
# On this box there is no PMU, so `cpu-clock` is the event; `cycles` returns <not supported>.
#
# Usage: probe-perf-by-conc.sh [secs] [children]
#   CONCS="1 4 16 100"
set -eu

SECS=${1:-14}
CHILDREN=${2:-96}
CONCS=${CONCS:-"1 4 16 100"}
SETTLE=${SETTLE:-8}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-perf-conc
BIN=${BIN:-$HOME/hello-bench/bin/volucer-050}
PORT=22998

rm -rf "$D"; mkdir -p "$D"
[ "$(cat /proc/sys/kernel/perf_event_paranoid)" -le 1 ] || {
    echo "=== FATAL: perf_event_paranoid is $(cat /proc/sys/kernel/perf_event_paranoid), need <= 1"; exit 1; }

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

wrk -t2 -c4 -d5s "http://127.0.0.1:$PORT/" >/dev/null 2>&1 || true
sleep 4

for c in $CONCS; do
    sleep "$SETTLE"
    t=$(nproc); if [ "$t" -gt "$c" ]; then t=$c; fi
    # perf and wrk run together for the whole cell; the profile therefore covers the same
    # requests the rate describes. `--latency` is dropped here: it changes wrk's own cost and
    # this probe only needs the rate.
    wrk -t"$t" -c"$c" -d"${SECS}s" "http://127.0.0.1:$PORT/" >"$D/wrk-c$c.txt" 2>&1 &
    WJ=$!
    sleep 3
    perf record -F 999 -e cpu-clock -g -p "$VOL_PID" -o "$D/perf-c$c.data" \
        -- sleep "$(( SECS - 5 ))" >"$D/perf-c$c.log" 2>&1 || true
    wait $WJ 2>/dev/null || true
    rps=$(awk '/^Requests\/sec:/{print $2}' "$D/wrk-c$c.txt")
    total=$(awk '/requests in /{print $1}' "$D/wrk-c$c.txt")
    echo "  c=$c rps=$rps requests=$total"
    perf report -i "$D/perf-c$c.data" --stdio --no-children -g none --sort symbol,dso 2>/dev/null \
        > "$D/syms-c$c.txt" || true
done

echo
echo "=== self time by bucket, share of samples"
for c in $CONCS; do
    awk -v c="$c" '
        # `--sort symbol,dso` gives "    27.71%  [k] _raw_spin_unlock_irqrestore": the scope marker
        # is $2 and the symbol is $3. Parsing the default layout instead (where the command and the
        # dso sit between them) silently bucketed everything as "other".
        /^ +[0-9]+\.[0-9]+%/ {
            pct = $1; sub(/%/, "", pct)
            sym = ($2 == "[k]" || $2 == "[.]") ? $3 : $NF

            b = "other"
            if (sym ~ /futex|spin_lock|spin_unlock|task_switch|wake_up|try_to_wake|schedule|mutex|rwsem|lll_lock/) b = "futex/spin/switch"
            else if (sym ~ /epoll|_poll|select/) b = "epoll/io"
            else if (sym ~ /tcp_|ip_|skb|netif|napi|softirq|unix_stream|unix_dgram|__sys_recv|__sys_send/) b = "net"
            else if (sym ~ /malloc|free|cfree|_rjem_|alloc|ralloc|sdallocx/) b = "alloc"
            else if (sym ~ /hyper/) b = "hyper"
            else if (sym ~ /fcgi|nvpair|record|param/) b = "fcgi"
            else if (sym ~ /tokio/) b = "tokio"
            else if (sym ~ /clock_gettime|pvclock|ktime|gettime/) b = "clock"
            else if (sym ~ /memcpy|memmove|copy_user|clear_page|rep_movs/) b = "memcpy"
            else if (sym ~ /getrandom|crng/) b = "getrandom"
            else if (sym ~ /syscall|entry_SYSCALL|do_syscall|sys_enter|sys_exit/) b = "syscall"
            else if (sym ~ /writev|sys_write|sendmsg|recvmsg|__libc_recv|__libc_send|__libc_read|__libc_write/) b = "write/read"
            else if (sym ~ /^0x/) b = "unresolved-kernel"
            tb[b] += pct; total += pct
            if (pct > 1.5) hot[b] = hot[b] " " sym
        }
        END {
            printf "c=%-4s", c
            n = split("futex/spin/switch net epoll/io alloc hyper tokio fcgi clock memcpy write/read syscall getrandom other unresolved-kernel", o, " ")
            for (i = 1; i <= n; i++) if (tb[o[i]] > 0.4) printf " %s=%.1f", o[i], tb[o[i]]
            printf " | total=%.1f\n", total
        }' "$D/syms-c$c.txt"
done
