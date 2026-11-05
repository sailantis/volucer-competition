#!/usr/bin/env bash
# Census of what the front-end's runtime threads still ask the kernel for.
#
# The profile's top entry is `_raw_spin_unlock_irqrestore` at 22.7% of self time, which is where a
# futex wake spends its cost. Shares say "expensive"; counts say "how many". Earlier phases chased
# 6.2 futexes per request down to 1.2 by removing a hand-off, so the question here is what the
# remaining ones are, and whether anything else in the census is large enough to be worth a change.
#
# Usage: probe-syscalls.sh [secs] [conc] [children]
set -eu

SECS=${1:-20}
CONC=${2:-100}
CHILDREN=${3:-96}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-sysc
BIN=${BIN:-$HOME/hello-bench/bin/volucer-adopt}
PORT_X=23003

rm -rf "$D"; mkdir -p "$D"

cleanup() {
    for p in $(pgrep -f "probe-sysc/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(ps -eo pid,args --no-headers 2>/dev/null \
               | grep "[p]hp-fpm: pool bench$" | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    sleep 0.3
}
trap cleanup EXIT INT TERM
cleanup

echo "=== volucer: $BIN $("$BIN" --version 2>&1) $(sha256sum "$BIN" | cut -c1-16)"

# Run the pool as the account that owns the workspace, not as whoever invoked the probe: php-fpm
# refuses to run children as root, and `perf`/`bpftrace` need root. `SUDO_USER` is the bridge.
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

sed -e "s|{{PORT}}|$PORT_X|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{SOCKET}}|$D/fpm.sock|g" \
    "$ROOT/conf/hello-external-fpm.toml.template" > "$D/vol.toml"
"$BIN" serve -c "$D/vol.toml" >"$D/vol.log" 2>&1 &
for _ in $(seq 1 100); do
    curl -sf --max-time 2 "http://127.0.0.1:$PORT_X/" >/dev/null 2>&1 && break
    sleep 0.1
done
body=$(curl -s --max-time 5 "http://127.0.0.1:$PORT_X/" || echo "<no answer>")
echo "  body -> $body"
case $body in *'"hello"'*) ;; *) echo "=== FATAL: not serving"; exit 1 ;; esac

PID=$(pgrep -f "$D/vol.toml" | head -1)
CORES=$(nproc)
T=$CORES
[ "$T" -gt "$CONC" ] && T=$CONC

echo "--- warm-up (discarded)"
wrk -t"$T" -c"$CONC" -d5s "http://127.0.0.1:$PORT_X/" >/dev/null 2>&1 || true
sleep 3

cat > "$D/sysc.bt" <<'BT'
tracepoint:raw_syscalls:sys_enter
/comm == "vol-fixlimit" || comm == "volucer"/
{
    @name[args.id] = count();
}
BT

cat > "$D/futex.bt" <<'BT'
tracepoint:syscalls:sys_enter_futex
/comm == "vol-fixlimit" || comm == "volucer"/
{
    @op[args.op] = count();
}
BT

cat > "$D/stacks.bt" <<'BT'
tracepoint:syscalls:sys_enter_futex
/comm == "vol-fixlimit" || comm == "volucer"/
{
    @[ustack(6)] = count();
}
BT

echo "--- counting $SECS s at c=$CONC"
wrk -t"$T" -c"$CONC" -d"$SECS"s "http://127.0.0.1:$PORT_X/" >"$D/wrk.txt" 2>&1 &
WRK=$!
sleep 2
bpftrace -p "$PID" -e "$(cat "$D/sysc.bt")" >"$D/sysc.out" 2>&1 &
BPF1=$!
bpftrace -p "$PID" -e "$(cat "$D/futex.bt")" >"$D/futex.out" 2>&1 &
BPF2=$!
sleep 4
bpftrace -p "$PID" -e "$(cat "$D/stacks.bt")" >"$D/stacks.out" 2>&1 &
BPF3=$!
wait "$WRK" || true
sleep 1
for p in $BPF1 $BPF2 $BPF3; do kill -INT "$p" 2>/dev/null || true; done
sleep 3
for p in $BPF1 $BPF2 $BPF3; do kill -9 "$p" 2>/dev/null || true; done

REQ=$(awk '/^Requests\/sec:/{print $2 * '"$SECS"'}' "$D/wrk.txt")
awk -v r="${REQ:-1}" 'BEGIN{ printf "  requests in the window: %.0f\n\n", r }'

echo "=== syscalls per request"
# syscall ids are decoded by bpftrace's `syscalls` map when available; fall back to the number.
awk -v r="${REQ:-1}" '
    /^@name\[/ {
        line = $0
        gsub(/^@name\[|\]:? */, "", line)
        split(line, kv, ": ")
        id = kv[1]; n = kv[2]
        if (n > 0) printf "  syscall %-4s %10d  %8.2f /req\n", id, n, n / r
    }
' "$D/sysc.out" | sort -k4 -rn | head -20

echo
echo "=== futex operations (128 = PRIVATE flag; WAIT=0/+128, WAKE=1/+128, WAIT_BITSET=9/+128, WAKE_BITSET=10/+128)"
awk -v r="${REQ:-1}" '
    /^@op\[/ {
        line = $0
        gsub(/^@op\[|\]:? */, "", line)
        split(line, kv, ": ")
        op = kv[1]; n = kv[2]
        if (n > 0) printf "  op %-6s %10d  %8.3f /req\n", op, n, n / r
    }
' "$D/futex.out" | sort -k4 -rn | head -12

echo
echo "=== futex call sites (top 15 by count)"
head -60 "$D/stacks.out" 2>/dev/null | grep -E '^@\[|^\s+-|^\s+[a-zA-Z_]' | head -40

echo
echo "=== total futex per request"
awk '/^\@op\[/ { s += $NF } END { if (r > 0) printf "  %.3f\n", s / r }' r="${REQ:-1}" "$D/futex.out" 2>/dev/null || \
    python3 - "$D/futex.out" "${REQ:-1}" <<'PY'
import re, sys
total = 0
for line in open(sys.argv[1]):
    m = re.match(r'^@op\[(\d+)\]: (\d+)', line)
    if m:
        total += int(m.group(2))
print(f"  {total / float(sys.argv[2]):.3f}")
PY
