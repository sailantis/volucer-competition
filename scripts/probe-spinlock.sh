#!/usr/bin/env bash
# Who calls the spinlock that is 22.7% of the front-end's self time?
#
# `probe-volucer-profile.sh` ranks `_raw_spin_unlock_irqrestore` first by self time. A leaf symbol
# cannot be optimised — what matters is the *caller*, and on this kernel the symbol is shared by at
# least four unrelated mechanisms that all end in the same unlock:
#
#   - futex_wake  -> wake_up_q -> try_to_wake_up  (cross-thread wakeups)
#   - futex_wait  -> schedule                    (parking)
#   - the TCP path -> __local_bh_enable_ip        (softirq enabling after xmit)
#   - the scheduler -> finish_task_switch
#
# They have completely different fixes (fewer wakeups, fewer threads, batched writes, nothing), so
# a share is not actionable. This probe aggregates by the frame *above* the spinlock instead.
#
# `perf script` is used rather than `perf report -g` because the question is "group every sample
# whose stack contains this symbol by its nearest caller", which `perf report` will not do: it
# builds a tree and leaves the summing to the reader.
#
# Usage: probe-spinlock.sh [secs] [conc] [children]
set -eu

SECS=${1:-24}
CONC=${2:-100}
CHILDREN=${3:-96}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-spin
BIN=${BIN:-$HOME/hello-bench/bin/volucer-adopt}
PORT_X=23007

rm -rf "$D"; mkdir -p "$D"

cleanup() {
    for p in $(pgrep -f "probe-spin/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(ps -eo pid,args --no-headers 2>/dev/null \
               | grep "[p]hp-fpm: pool bench$" | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    sleep 0.3
}
trap cleanup EXIT INT TERM
cleanup

echo "=== volucer: $BIN $("$BIN" --version 2>&1) $(sha256sum "$BIN" | cut -c1-16)"

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

echo "--- sampling $SECS s at c=$CONC"
wrk -t"$T" -c"$CONC" -d"${SECS}s" "http://127.0.0.1:$PORT_X/" >"$D/wrk.txt" 2>&1 &
WRK=$!
sleep 3
perf record -e cpu-clock -F999 -g -p "$PID" -o "$D/perf.data" -- sleep $(( SECS - 5 )) \
    >"$D/perf.log" 2>&1 || true
wait "$WRK" || true
echo "  rps: $(awk '/^Requests\/sec:/{print $2}' "$D/wrk.txt")"
echo "  samples: $(perf report -i "$D/perf.data" --stdio 2>/dev/null | awk '/^# Samples/{print}')"

perf script -i "$D/perf.data" >"$D/script.txt" 2>/dev/null || true
echo "  stack lines: $(wc -l <"$D/script.txt")"

python3 - "$D/script.txt" <<'PY'
import re
import sys
from collections import Counter

path = sys.argv[1]

# perf script emits one block per sample: a header line, then indented frames, deepest first.
# A sample's *self* frame is the first indented frame; the callers follow it.
SPIN = "_raw_spin_unlock_irqrestore"

blocks = 0
spin_blocks = 0
callers = Counter()
spin_self = Counter()

# perf script frames look like
#     `\t    ffffffffa6611af0 tcp_check_space+0x0 ([kernel.kallsyms])`
# so the symbol is the *second* whitespace token after the address, not the parenthesised text —
# which is the DSO. My first version took the parenthesised part and matched nothing but
# `kernel.kallsyms`, so every sample looked like it lacked the spinlock.
def symbol(frame_line):
    parts = frame_line.split()
    if len(parts) < 2:
        return None
    name = parts[1]
    return name.split("+0x")[0]


cur = None
samples = []
for line in open(path, errors="replace"):
    stripped = line.rstrip("\n")
    if stripped and not stripped[0].isspace():
        if cur is not None:
            samples.append(cur)
        cur = []
    elif cur is not None:
        sym = symbol(stripped)
        if sym:
            cur.append(sym)
if cur is not None:
    samples.append(cur)

for frames in samples:
    if not frames:
        continue
    blocks += 1
    if frames[0] == SPIN:
        spin_self[frames[1] if len(frames) > 1 else "<none>"] += 1
    # Nearest ancestor that is not the spinlock machinery itself. A wake chain is
    # `spin_unlock <- pv_queued_spin_unlock <- _raw_spin_unlock_irqrestore <- try_to_wake_up ...`,
    # so walk past the lock helpers to the first meaningful caller.
    if SPIN in frames:
        spin_blocks += 1
        i = frames.index(SPIN) + 1
        helpers = {
            "_raw_spin_unlock_irqrestore", "__raw_callee_save___pv_queued_spin_unlock",
            "pv_queued_spin_unlock", "queued_spin_unlock", "_raw_spin_unlock",
            "native_queued_spin_unlock", "queued_spin_unlock_wait",
        }
        while i < len(frames) and frames[i] in helpers:
            i += 1
        callers[frames[i] if i < len(frames) else "<none>"] += 1


def show(title, counter, total, limit=18):
    print()
    print(title)
    print(f"  {'caller':<58} {'samples':>9}  {'share':>7}")
    for name, n in counter.most_common(limit):
        short = name if len(name) <= 58 else "..." + name[-55:]
        print(f"  {short:<58} {n:>9}  {100.0 * n / total:>6.2f}%")


if not blocks:
    print("\n!! no samples parsed — perf may have failed; see perf.log")
    sys.exit(0)

print()
print(f"samples: {blocks}   containing the spinlock: {spin_blocks} ({100.0 * spin_blocks / blocks:.1f}%)")
show(f"=== nearest caller of {SPIN}", callers, spin_blocks)
show("=== what the spinlock frame sits under (immediate parent)", spin_self, spin_blocks, 10)
PY

echo
echo "(perf data: $D/perf.data)"
