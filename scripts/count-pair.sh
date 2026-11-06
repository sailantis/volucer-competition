#!/usr/bin/env bash
# CPU and futex counts per request for one running volucer front-end.
#
# Why this rather than throughput: on this host `wrk` reproduces to only ~±20% between
# blocks because the Windows side is busy, so a rps A/B cannot resolve anything smaller
# than a rewrite. CPU time per request and syscalls per request are per-process and do not
# depend on how fast the host is -- only on how much work the process does for a request.
#
#   count-pair.sh <pid> <port> [secs]
#
# The request count comes from wrk's own total rather than from a counter in the process, so
# it is the number of requests the front-end *answered*, not the number it accepted.
set -uo pipefail
PID=${1:?pid}
PORT=${2:?port}
SECS=${3:-10}
PERF=/usr/lib/linux-tools/6.18.54.1-microsoft-standard-WSL2/bin/perf
CONC=${CONC:-100}
WRK_T=$(nproc); [ "$WRK_T" -gt "$CONC" ] && WRK_T=$CONC
OUT=${OUT:-/tmp}
mkdir -p "$OUT"

wrk -t"$WRK_T" -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:$PORT/" >"$OUT/wrk-count.txt" 2>&1 &
wrk_pid=$!
sleep 1
sudo -n "$PERF" stat -p "$PID" -e task-clock,syscalls:sys_enter_futex,syscalls:sys_enter_epoll_wait \
    -o "$OUT/perf-count.txt" -- sleep $(( SECS - 2 )) >/dev/null 2>&1
wait $wrk_pid

rps=$(awk '/^Requests\/sec:/{print $2}' "$OUT/wrk-count.txt")
total=$(awk '/requests in /{print $1}' "$OUT/wrk-count.txt")
tc=$(awk '/task-clock/{gsub(/,/,"",$1); print $1}' "$OUT/perf-count.txt" | head -1)
fx=$(awk '/sys_enter_futex/{gsub(/,/,"",$1); print $1}' "$OUT/perf-count.txt" | head -1)
ep=$(awk '/sys_enter_epoll_wait/{gsub(/,/,"",$1); print $1}' "$OUT/perf-count.txt" | head -1)
# perf's task-clock is in msec but counts only the sampled window; scale it to the window
# so µs/request uses the requests answered in that window, not the whole run.
win=$(( SECS - 2 ))
sampled=$(python3 -c "print(int(${total:-0} * $win / $SECS))")
python3 - "$rps" "$total" "$tc" "$fx" "$ep" "$sampled" "$win" <<'PY'
import sys
rps, total, tc, fx, ep, sampled, win = sys.argv[1:]
rps = float(rps or 0); total = float(total or 1)
tc = float(tc or 0)/1e9           # task-clock is nanoseconds
fx = float(fx.replace(' ','') or 0); ep = float(ep.replace(' ','') or 0)
sampled = float(sampled or 1)
print(f"  rps {rps:>9,.0f}   cpu {tc:>6.2f} core-s over {sampled:,.0f} req "
      f"= {tc*1e6/sampled:>6.1f} us/req ({tc/float(win):.2f} cores)")
print(f"  futex {fx/sampled:>5.2f}/req   epoll_wait {ep/sampled:>5.2f}/req")
PY
