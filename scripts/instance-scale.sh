#!/usr/bin/env bash
# Would `SO_REUSEPORT` help? That depends on a question this answers first: is the ceiling
# per-*process*, or does the box simply run out of cores?
#
#   instance-scale.sh [secs] [conc-per-instance] [rounds]
#
# It runs the same total number of PHP children in one, two and three volucer processes:
#
#   1 x 96 workers      2 x 48 workers       3 x 32 workers
#
# The child count is held equal on purpose. If throughput rises with the process count, the
# limit is per-process and several listeners in one process (which is what SO_REUSEPORT
# gives) would capture it. If it falls, the box is the limit and SO_REUSEPORT buys nothing
# but complexity -- and that is worth knowing before writing it.
#
# Total offered load is held equal too: `conc / instances` connections per generator against
# `instances` generators, at a fixed thread count per generator.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECS=${1:-14}
CONC=${2:-100}
ROUNDS=${3:-2}
BIN=${BIN:-$HOME/hello-bench/bin/volucer-rng}
CORES=$(nproc)
PROBE="$ROOT/.probe/is"
rm -rf "$PROBE"; mkdir -p "$PROBE"

ns_of() {
    local total=0 pid v
    for pid in "$@"; do
        for t in /proc/"$pid"/task/*/schedstat; do
            [ -r "$t" ] || continue
            v=$(awk '{print $1}' "$t" 2>/dev/null); total=$(( total + ${v:-0} ))
        done
    done
    echo "$total"
}

ns_pattern() {
    local total=0 pid v
    for pid in $(pgrep -f "$1" 2>/dev/null); do
        for t in /proc/"$pid"/task/*/schedstat; do
            [ -r "$t" ] || continue
            v=$(awk '{print $1}' "$t" 2>/dev/null); total=$(( total + ${v:-0} ))
        done
    done
    echo "$total"
}

# One cell: `instances` volucer processes each with `workers` children, `instances` generators.
cell() {
    local instances=$1 workers=$2 tag=$3
    local -a vols sups relays ports
    local i port d

    for i in $(seq 0 $(( instances - 1 ))); do
        d="$PROBE/$tag-$i"; mkdir -p "$d"
        port=$((23200 + instances * 10 + i))
        ports[$i]=$port
        relays[$i]="$d/relay"
        php -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 -d opcache.jit=off \
            -d xdebug.mode=off -d memory_limit=512M \
            "$ROOT/apps/hello/supervisor.php" "unix:$d/relay" >"$d/sup.log" 2>&1 &
        sups[$i]=$!
        for _ in $(seq 1 200); do [ -S "$d/relay" ] && break; sleep 0.05; done
        sed -e "s|{{PORT}}|$port|g" -e "s|{{ROOT}}|$ROOT|g" \
            -e "s|{{WORKERS}}|$workers|g" -e "s|{{SOCKET_DIR}}|$d|g" \
            "$ROOT/conf/hello-attach.toml.template" > "$d/cfg.toml"
        "$BIN" serve -c "$d/cfg.toml" >"$d/volucer.log" 2>&1 &
        vols[$i]=$!
    done
    for i in $(seq 0 $(( instances - 1 ))); do
        for _ in $(seq 1 400); do
            curl -sf -o /dev/null "http://127.0.0.1:${ports[$i]}/" && break; sleep 0.05
        done
    done

    # Guard: a dead backend answers faster than a live one, so refuse rather than measure it.
    for i in $(seq 0 $(( instances - 1 ))); do
        local body; body=$(curl -s --max-time 5 "http://127.0.0.1:${ports[$i]}/")
        if ! printf '%s' "$body" | grep -q '"hello"'; then
            echo "  REFUSING: instance $i is not serving the page ($body)"
            for p in "${vols[@]}" "${sups[@]}"; do kill -9 "$p" 2>/dev/null; done
            return 1
        fi
    done

    local be_pat="supervisor.php unix:$PROBE/$tag"
    local b0 b1 f0 f1
    f0=$(ns_of "${vols[@]}"); b0=$(ns_pattern "$be_pat")

    local tpc=$(( CORES / instances )); [ "$tpc" -lt 1 ] && tpc=1
    local cpc=$(( CONC / instances )); [ "$cpc" -lt 1 ] && cpc=1
    local -a wrks
    for i in $(seq 0 $(( instances - 1 ))); do
        wrk -t"$tpc" -c"$cpc" -d"${SECS}s" --latency \
            "http://127.0.0.1:${ports[$i]}/" >"$PROBE/wrk-$tag-$i.txt" 2>&1 &
        wrks[$i]=$!
    done
    for i in $(seq 0 $(( instances - 1 ))); do wait "${wrks[$i]}"; done

    f1=$(ns_of "${vols[@]}"); b1=$(ns_pattern "$be_pat")

    local rps=0 total=0 bad=0 r p t b
    for i in $(seq 0 $(( instances - 1 ))); do
        r=$(awk '/^Requests\/sec:/{print $2}' "$PROBE/wrk-$tag-$i.txt")
        t=$(awk '/requests in /{print $1}' "$PROBE/wrk-$tag-$i.txt")
        b=$(awk -F: '/Non-2xx/{gsub(/ /,"",$2); print $2+0}' "$PROBE/wrk-$tag-$i.txt")
        rps=$(awk -v a="$rps" -v b="${r:-0}" 'BEGIN{print a+b}')
        total=$(( total + ${t:-0} )); bad=$(( bad + ${b:-0} ))
    done
    awk -v t="$tag" -v r="$rps" -v d="$((f1-f0))" -v e="$((b1-b0))" -v n="${total:-1}" \
        -v s="$SECS" -v bad="$bad" -v inst="$instances" -v w="$workers" \
        'BEGIN{ printf "  %-18s %7.0f rps  fe %5.2f c %5.1f us | php %5.2f c %5.1f us | box %5.2f c%s\n",
                 t, r, d/1e9/s, d/1e3/n, e/1e9/s, e/1e3/n, (d+e)/1e9/s,
                 (bad>0 ? "  NON-2xx: " bad : "") }'

    for p in "${vols[@]}" "${sups[@]}"; do kill -TERM "$p" 2>/dev/null; done
    sleep 1.2
    for p in "${vols[@]}" "${sups[@]}"; do kill -9 "$p" 2>/dev/null; done
    pkill -f "supervisor.php unix:$PROBE/$tag" 2>/dev/null
    sleep 0.5
}

echo "=== binary: $BIN ($(sha256sum "$BIN" | cut -c1-12))  c=$CONC  ${SECS}s x $ROUNDS"
for round in $(seq 1 "$ROUNDS"); do
    echo "--- round $round (96 children total in every cell)"
    if [ $(( round % 2 )) -eq 1 ]; then
        cell 1 96 "1p-r$round"
        cell 2 48 "2p-r$round"
        cell 3 32 "3p-r$round"
    else
        cell 3 32 "3p-r$round"
        cell 2 48 "2p-r$round"
        cell 1 96 "1p-r$round"
    fi
done
