#!/usr/bin/env bash
# Measure both arms with the *same* probe, so the only difference is the backend.
#
# The question: `upstream` and `attach` are both "a connection carrying data". Why is
# one ~99k and the other ~60k? The answer is not in the profile — it is that they use
# two different I/O stacks. This measures what each side costs so the comparison is
# concrete rather than an argument.
set -uo pipefail
ROOT="/home/competition/volucer-competition"
BIN=${BIN:-/home/competition/hello-bench/bin/volucer-async-jemalloc}
NODE_BIN=/home/competition/hello-bench/bin/node-v24.11.1-linux-x64/bin
SECS=${SECS:-20}
CONC=${CONC:-100}

ns_of() {
    local total=0 pid v
    for pid in "$@"; do
        for t in /proc/"$pid"/task/*/schedstat; do
            [ -r "$t" ] || continue
            v=$(awk '{print $1}' "$t" 2>/dev/null)
            total=$(( total + ${v:-0} ))
        done
    done
    echo "$total"
}

# ---- attach ------------------------------------------------------------------
AT="$ROOT/.probe/up-attach"
rm -rf "$AT"; mkdir -p "$AT"
PHP_ARGS=(-d opcache.enable_cli=1 -d opcache.validate_timestamps=0
          -d opcache.jit=off -d xdebug.mode=off -d memory_limit=512M)
php "${PHP_ARGS[@]}" "$ROOT/apps/hello/supervisor.php" "unix:$AT/relay" >"$AT/sup.log" 2>&1 &
SUP=$!
for _ in $(seq 1 100); do [ -S "$AT/relay" ] && break; sleep 0.05; done
sed -e "s|{{PORT}}|22910|g" -e "s|{{ROOT}}|$ROOT|g" \
    -e "s|{{WORKERS}}|12|g" -e "s|{{SOCKET_DIR}}|$AT|g" \
    "$ROOT/conf/hello-attach.toml.template" > "$AT/attach.toml"
"$BIN" serve -c "$AT/attach.toml" >"$AT/volucer.log" 2>&1 &
AV=$!
for _ in $(seq 1 200); do curl -sf -o /dev/null http://127.0.0.1:22910/ && break; sleep 0.05; done

# ---- upstream ---------------------------------------------------------------
UP="$ROOT/.probe/up-upstream"
rm -rf "$UP"; mkdir -p "$UP"
# Named flags, not positional ones. `fastify-hello.js` reads only `--port`/`--workers`, so
# `--cluster reuseport 22920 12` left the origin on its default 18410 while the template
# pointed at 22920 — every measured request was a 502, and because `upstream` answers a dead
# origin fast the arm then *looked* 1.9x quicker than attach. A one-line check below is what
# stops that from being believed a second time.
PATH="$NODE_BIN:$PATH" node "$ROOT/apps/hello/fastify-hello.js" \
    --port 22920 --workers 12 --cluster reuseport >"$UP/origin.log" 2>&1 &
ORIGIN=$!
for _ in $(seq 1 200); do curl -sf -o /dev/null http://127.0.0.1:22920/ && break; sleep 0.05; done
sed -e "s|{{PORT}}|22911|g" -e "s|{{ROOT}}|$ROOT|g" \
    -e "s|{{ORIGIN_PORT}}|22920|g" \
    "$ROOT/conf/hello-upstream.toml.template" > "$UP/upstream.toml"
"$BIN" serve -c "$UP/upstream.toml" >"$UP/volucer.log" 2>&1 &
UV=$!
for _ in $(seq 1 200); do curl -sf -o /dev/null http://127.0.0.1:22911/ && break; sleep 0.05; done

# Both arms must answer the page before anything is timed. A 502 is answered faster than a
# real request and would read as a win, which is exactly how the positional-flag bug produced
# "upstream 128,699 rps" from a run in which every response was an error.
for _port in 22910 22911; do
    _body=$(curl -s "http://127.0.0.1:$_port/")
    if [ "$_body" != '{"hello":"world"}' ]; then
        echo "arm on port $_port answers '$_body', not the page — refusing to measure" >&2
        kill -TERM "$AV" "$UV" "$SUP" "$ORIGIN" 2>/dev/null
        exit 1
    fi
done

# ---- measure both, one after the other --------------------------------------
# `pgrep -f fastify-hello.js` also returns the `bash -c` wrapper that launched the
# cluster, and `pgrep -x node` returns nothing at all because the comm is truncated.
# Resolving `exe` is the only reliable way to count the node processes themselves.
node_pids() {
    local pid
    for pid in $(pgrep -f "fastify-hello.js" 2>/dev/null); do
        case "$(readlink "/proc/$pid/exe" 2>/dev/null)" in
            *node*) echo "$pid" ;;
        esac
    done
}

run() { # label port volucer_pid origin_pattern
    local label=$1 port=$2 vp=$3 opat=$4
    local v0 p0 o0 v1 p1 o1 total rps p50
    wrk -t"$(nproc)" -c"$CONC" -d"${SECS}s" "http://127.0.0.1:$port/" >"/tmp/wrk-$label.txt" 2>&1 &
    local W=$!
    sleep 2
    v0=$(ns_of "$vp")
    p0=$(ns_of $(pgrep -f "supervisor.php unix:$AT/relay"))
    # The origin is a *cluster*: the master holds the port but the forked workers serve
    # the requests, so matching the pid the harness started measures nothing.
    [ -n "$opat" ] && o0=$(ns_of $(node_pids))
    ( sleep $((SECS - 4)); ns_of "$W" >"/tmp/wrk1-$label" ) &
    wait $W
    v1=$(ns_of "$vp")
    p1=$(ns_of $(pgrep -f "supervisor.php unix:$AT/relay"))
    [ -n "$opat" ] && o1=$(ns_of $(node_pids))
    local w1; w1=$(cat "/tmp/wrk1-$label" 2>/dev/null || echo 0)
    total=$(awk '/requests in /{print $1}' "/tmp/wrk-$label.txt")
    rps=$(awk '/^Requests\/sec:/{print $2}' "/tmp/wrk-$label.txt")
    p50=$(awk '$1=="50%"{print $2; exit}' "/tmp/wrk-$label.txt")
    # A non-2xx response is cheaper than a real one, so a run that returns them must not be
    # reported as a throughput figure at all.
    local bad; bad=$(awk '/Non-2xx/{print $NF}' "/tmp/wrk-$label.txt")
    awk -v l="$label" -v v=$((v1-v0)) -v p=$(( ${p1:-0} - ${p0:-0} )) \
        -v o=$(( ${o1:-0} - ${o0:-0} )) -v opat="$opat" -v bad="${bad:-0}" \
        -v n="$total" -v r="$rps" -v q="$p50" -v s="$SECS" -v w="$w1" 'BEGIN{
        printf "%-9s %7.0f rps  p50 %-7s | front-end %5.2f cores %6.1f us",
               l, r, (q==""?"-":q), v/1e9/s, v/1e3/n
        if (p > 0)        printf " | php  %5.2f cores %6.1f us", p/1e9/s, p/1e3/n
        if (opat != "")   printf " | node %5.2f cores %6.1f us", o/1e9/s, o/1e3/n
        printf " | wrk %4.2f", w/1e9/(s-4)
        if (bad+0 > 0)    printf "  !! %d non-2xx — NOT a measurement", bad
        printf "\n"
    }'
}

run attach   22910 "$AV" ""
run upstream 22911 "$UV" "node"

kill -TERM "$AV" "$UV" 2>/dev/null; sleep 2
kill -9 "$AV" "$UV" 2>/dev/null
pkill -f "$AT/relay" 2>/dev/null
kill -TERM "$SUP" "$ORIGIN" 2>/dev/null; sleep 2
kill -9 "$SUP" "$ORIGIN" 2>/dev/null
pkill -f "supervisor.php unix:$AT/relay" 2>/dev/null
pkill -f "fastify-hello.js --cluster reuseport 22920" 2>/dev/null
echo "--- slots"
grep -h '^slots:' "$AT/volucer.log" "$UP/volucer.log" 2>/dev/null
