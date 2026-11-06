#!/usr/bin/env bash
# Per-request syscall mix and task-clock for one running volucer front-end.
#
# Syscall counts per request are the instrument for a change that adds a `tokio::time::timeout`
# to the request path: a timeout arms a `timerfd`/`epoll` timer, and whether that shows up as a
# syscall, as an `epoll_wait` wakeup, or as nothing at all is the question. Counts are per
# process and per request, so host noise cancels instead of dominating.
#
#   mix.sh <pid> <port> [secs]
set -uo pipefail
PID=${1:?pid}
PORT=${2:?port}
SECS=${3:-10}
PERF=/usr/lib/linux-tools/6.18.54.1-microsoft-standard-WSL2/bin/perf
CONC=${CONC:-100}
WRK_T=$(nproc); [ "$WRK_T" -gt "$CONC" ] && WRK_T=$CONC
OUT=${OUT:-/tmp}; mkdir -p "$OUT"

wrk -t"$WRK_T" -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:$PORT/" >"$OUT/wrk-mix.txt" 2>&1 &
wrk_pid=$!
sleep 1
sudo -n "$PERF" stat -p "$PID" \
    -e task-clock,syscalls:sys_enter_futex,syscalls:sys_enter_epoll_wait,syscalls:sys_enter_epoll_ctl \
    -e syscalls:sys_enter_timerfd_settime,syscalls:sys_enter_clock_gettime,syscalls:sys_enter_getrandom \
    -e syscalls:sys_enter_sendto,syscalls:sys_enter_recvfrom,syscalls:sys_enter_writev \
    -o "$OUT/perf-mix.txt" -- sleep $(( SECS - 2 )) >/dev/null 2>&1
wait $wrk_pid

total=$(awk '/requests in /{print $1}' "$OUT/wrk-mix.txt")
win=$(( SECS - 2 ))
[ -z "${total:-}" ] && { echo "  (no wrk total)"; exit 1; }
sampled=$(python3 -c "print(int($total * $win / $SECS))")
echo "  requests sampled ~$sampled (of $total in ${SECS}s)"
python3 - "$OUT/perf-mix.txt" "$sampled" "$win" <<'PY'
import sys, re
path, sampled, win = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
want = None
for line in open(path):
    m = re.match(r'\s*([\d,]+)\s+(\S+)\s', line)
    if not m: continue
    n, name = int(m.group(1).replace(',', '')), m.group(2)
    if name == 'task-clock':
        print(f"  task-clock      {n/1e9:7.2f} core-s   {n/1e3/sampled:7.1f} us/req   {n/1e9/win:.2f} cores")
    elif name.startswith('syscalls:'):
        print(f"  {name[9:]:<15} {n/sampled:7.3f}/req")
PY
