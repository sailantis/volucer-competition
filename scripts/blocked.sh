#!/usr/bin/env bash
# What are the runtime threads blocked in, and how long does each block last?
#
# c=100 runs at 63k rps with p50 1.44 ms while the front-end uses 4.2 of 12 cores: ~1.3 ms of each
# request is waiting for something that is not CPU. This names the syscall and divides its total
# latency by the request count, so "waiting" becomes a per-request figure.
set -uo pipefail
cd ~/volucer-competition || exit 1
BIN=${1:-~/hello-bench/bin/volucer-async-attach}
WORKERS=${2:-96}; CONC=${3:-100}; SECS=${4:-20}
OUT=.probe/blocked; rm -rf "$OUT"; mkdir -p "$OUT"
PORT=22612; SOCK="$OUT/relay"
sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$PWD|g" -e "s|{{WORKERS}}|$WORKERS|g" \
    -e "s|{{SOCKET_DIR}}|$OUT|g" conf/hello-attach.toml.template > "$OUT/attach.toml"
php -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 -d opcache.jit=off \
    apps/hello/supervisor.php "unix:$SOCK" >"$OUT/sup.log" 2>&1 &
SUP=$!
for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.05; done
"$BIN" serve -c "$OUT/attach.toml" >"$OUT/volucer.log" 2>&1 &
VOL=$!
for _ in $(seq 1 200); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.05; done
CORES=$(nproc)
wrk -t"$CORES" -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:$PORT/" >"$OUT/wrk.txt" 2>&1 &
WRK=$!
sleep 3
# Latency AND count per syscall, so a frequent fast call is distinguishable from a rare slow one.
sudo -n timeout $((SECS - 4)) bpftrace -e '
BEGIN { printf "%-14s %10s %12s %12s\n", "syscall", "calls", "total_ms", "us_per_call" }
tracepoint:syscalls:sys_enter_epoll_wait /comm == "tokio-rt-worker"/ { @s["epoll_wait"] = nsecs; }
tracepoint:syscalls:sys_exit_epoll_wait /comm == "tokio-rt-worker" && @s["epoll_wait"]/
{ @n["epoll_wait"] = count(); @t["epoll_wait"] = sum(nsecs - @s["epoll_wait"]); delete(@s["epoll_wait"]); }
tracepoint:syscalls:sys_enter_recvfrom /comm == "tokio-rt-worker"/ { @s["recvfrom"] = nsecs; }
tracepoint:syscalls:sys_exit_recvfrom /comm == "tokio-rt-worker" && @s["recvfrom"]/
{ @n["recvfrom"] = count(); @t["recvfrom"] = sum(nsecs - @s["recvfrom"]); delete(@s["recvfrom"]); }
tracepoint:syscalls:sys_enter_recvmsg /comm == "tokio-rt-worker"/ { @s["recvmsg"] = nsecs; }
tracepoint:syscalls:sys_exit_recvmsg /comm == "tokio-rt-worker" && @s["recvmsg"]/
{ @n["recvmsg"] = count(); @t["recvmsg"] = sum(nsecs - @s["recvmsg"]); delete(@s["recvmsg"]); }
tracepoint:syscalls:sys_enter_futex /comm == "tokio-rt-worker"/ { @s["futex"] = nsecs; }
tracepoint:syscalls:sys_exit_futex /comm == "tokio-rt-worker" && @s["futex"]/
{ @n["futex"] = count(); @t["futex"] = sum(nsecs - @s["futex"]); delete(@s["futex"]); }
tracepoint:syscalls:sys_enter_sendto /comm == "tokio-rt-worker"/ { @s["sendto"] = nsecs; }
tracepoint:syscalls:sys_exit_sendto /comm == "tokio-rt-worker" && @s["sendto"]/
{ @n["sendto"] = count(); @t["sendto"] = sum(nsecs - @s["sendto"]); delete(@s["sendto"]); }
tracepoint:syscalls:sys_enter_writev /comm == "tokio-rt-worker"/ { @s["writev"] = nsecs; }
tracepoint:syscalls:sys_exit_writev /comm == "tokio-rt-worker" && @s["writev"]/
{ @n["writev"] = count(); @t["writev"] = sum(nsecs - @s["writev"]); delete(@s["writev"]); }
interval:s:1 { clear(@s); }
' >"$OUT/blocked.txt" 2>&1 &
BPF=$!
wait $WRK; W=$?
wait $BPF 2>/dev/null
cat "$OUT/wrk.txt" | grep -E 'Requests/sec:|^ +50%|requests in '
REQ=$(awk '/requests in /{print $1}' "$OUT/wrk.txt")
echo "=== blocking syscalls on tokio-rt-worker (raw)"
cat "$OUT/blocked.txt"
echo "=== per request ($REQ requests)"
awk -v r="${REQ:-1}" '
  /^@n\[/ { gsub(/[\[\]"]/,""); split($0,a," "); x=a[1]; sub(/^@n\[/,"",x); v=a[2]; n[x]=v }
  /^@t\[/ { x=$0; sub(/^@t\[/,"",x); sub(/\]:.*/,"",x); gsub(/"/,"",x); v=$2; t[x]=v }
  END { for (k in n) printf "  %-12s %10.3f calls/req  %10.1f us/req\n", k, n[k]/r, t[k]/1000/r }
' "$OUT/blocked.txt"
echo "=== slots"
grep '^slots:' "$OUT/volucer.log" || echo "(none)"
kill -TERM $VOL 2>/dev/null; sleep 1; kill -9 $VOL 2>/dev/null
kill -TERM $SUP 2>/dev/null; sleep 0.5; kill -9 $SUP 2>/dev/null
pkill -f "supervisor.php unix:$SOCK" 2>/dev/null
exit $W