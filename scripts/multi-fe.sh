#!/usr/bin/env bash
# One supervisor, N front-end instances, so capacity can be told apart from the
# request rate.
#
# The question: the front-end uses ~5.5 of 12 cores at ~57k rps while the box is
# ~75% busy. If the spare capacity is real, a second instance against the same relay
# should serve more requests. If throughput is flat, the limit is not the front-end.
#
#   multi-fe.sh <instances> <workers-each> <concurrency> <seconds> <tag> [extra.toml]
set -uo pipefail
ROOT="/home/competition/volucer-competition"
BIN=${BIN:-/home/competition/hello-bench/bin/volucer-async}
N=${1:?instances}
WORKERS=${2:?workers}
CONC=${3:?concurrency}
SECS=${4:?seconds}
TAG=${5:?tag}
EXTRA=${6:-}

OUT="$ROOT/.probe/$TAG"
SOCK="$OUT/relay"
rm -rf "$OUT"; mkdir -p "$OUT"

PHP_ARGS=(-d opcache.enable_cli=1 -d opcache.validate_timestamps=0
          -d opcache.jit=off -d xdebug.mode=off -d memory_limit=512M)

php "${PHP_ARGS[@]}" "$ROOT/apps/hello/supervisor.php" "unix:$SOCK" >"$OUT/sup.log" 2>&1 &
SUP=$!
for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.05; done

PIDS=""
for i in $(seq 1 "$N"); do
    PORT=$((22700 + i))
    sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$ROOT|g" \
        -e "s|{{WORKERS}}|$WORKERS|g" -e "s|{{SOCKET_DIR}}|$OUT|g" \
        "$ROOT/conf/hello-attach.toml.template" > "$OUT/fe$i.toml"
    [ -n "$EXTRA" ] && { printf '\n' >> "$OUT/fe$i.toml"; cat "$EXTRA" >> "$OUT/fe$i.toml"; }
    "$BIN" serve -c "$OUT/fe$i.toml" >"$OUT/fe$i.log" 2>&1 &
    PIDS="$PIDS $!"
    for _ in $(seq 1 200); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.05; done
done

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
php_pids() { pgrep -f "supervisor.php unix:$SOCK" 2>/dev/null; }

# Round-robin over the instances, one wrk process per instance so the generator's
# own threads stay balanced and no single connection set dominates.
URLS=""
for i in $(seq 1 "$N"); do URLS="$URLS http://127.0.0.1:$((22700+i))/"; done

fe0=$(ns_of $PIDS); php0=$(ns_of $(php_pids)); wrk0=$(ns_of $(pgrep -x wrk))

WRKPIDS=""
for u in $URLS; do
    wrk -t"$(( $(nproc) / N ))" -c"$((CONC / N))" -d"${SECS}s" "$u" >"$OUT/wrk-$RANDOM.txt" 2>&1 &
    WRKPIDS="$WRKPIDS $!"
done
wait $WRKPIDS

fe1=$(ns_of $PIDS); php1=$(ns_of $(php_pids))

TOTALRPS=$(cat "$OUT"/wrk-*.txt | awk '/^Requests\/sec:/{s+=$2} END{print s+0}')
TOTALREQ=$(cat "$OUT"/wrk-*.txt | awk '/requests in /{s+=$1} END{print s+0}')

awk -v f="$((fe1-fe0))" -v p="$((php1-php0))" -v s="$SECS" -v n="$TOTALREQ" -v r="$TOTALRPS" 'BEGIN{
    printf "rps        %8.0f\n", r
    printf "front-end  %8.2f cores  %6.1f us/req\n", f/1e9/s, (n>0? f/1e3/n : 0)
    printf "php        %8.2f cores  %6.1f us/req\n", p/1e9/s, (n>0? p/1e3/n : 0)
    printf "box        %8.2f cores of 12\n", (f+p)/1e9/s
}'

for p in $PIDS; do kill -TERM "$p" 2>/dev/null; done
sleep 2
for p in $PIDS; do kill -9 "$p" 2>/dev/null; done
kill -TERM $SUP 2>/dev/null; sleep 1; kill -9 $SUP 2>/dev/null
pkill -f "supervisor.php unix:$SOCK" 2>/dev/null
echo "--- slots"
for i in $(seq 1 "$N"); do grep '^slots:' "$OUT/fe$i.log" | sed "s/^/  fe$i /"; done
