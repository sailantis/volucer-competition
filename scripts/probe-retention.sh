#!/usr/bin/env bash
# Is the `external_fpm` deficit volucer's connection retention, or PHP?
#
# Evidence that made this the question: `external` -> php-cgi measures ~40.6k, the same as
# `external` -> php-fpm, while `spawn_cgi` -> php-cgi (preforked) measures ~55k. So the SAPI is
# *not* what separates those two arms -- the backend kind is, and php-cgi and php-fpm behind
# the same `external` backend land within noise of each other.
#
# `ClientPool` (the `external` backend) retains `MAX_IDLE_CONNECTIONS = 1` warm connection,
# while `CgiPool` (the `spawn_cgi` backend) retains one per slot and has `workers` slots. At
# concurrency 100 against 96 children, "retain one" means nearly every request pays a fresh
# `connect(2)` that the prefork arm does not.
#
# This holds everything else fixed -- same php-fpm, same pool, same config, same host -- and
# varies only that constant, using two binaries built from the same commit:
#
#     vol-cap1     MAX_IDLE_CONNECTIONS = 1    (shipped)
#     vol-cap512   MAX_IDLE_CONNECTIONS = 512  (retention effectively unbounded)
#
# Usage: probe-retention.sh [secs] [conc] [children]
set -eu

SECS=${1:-14}
CONC=${2:-100}
CHILDREN=${3:-96}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-retention
PORT_A=22962
PORT_B=22963
BIN_A=${BIN_A:-/tmp/vol-cap1}
BIN_B=${BIN_B:-/tmp/vol-cap512}
CORES=$(nproc)
[ "$CORES" -gt "$CONC" ] && CORES=$CONC

rm -rf "$D"; mkdir -p "$D"

cleanup() {
    for p in $(pgrep -f "probe-retention/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(pgrep -f "$D/pool.conf" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    sleep 0.3
}
trap cleanup EXIT INT TERM
cleanup

for b in "$BIN_A" "$BIN_B"; do
    [ -x "$b" ] || { echo "=== FATAL: $b is missing; see the header for how it is built" >&2; exit 2; }
done
echo "=== A=$BIN_A $(sha256sum "$BIN_A" | cut -c1-16)"
echo "=== B=$BIN_B $(sha256sum "$BIN_B" | cut -c1-16)"

# One php-fpm pool, shared by both front-ends: the backend must be identical for the
# comparison to be about the front-end. `pm = static` so the child count cannot drift.
cat > "$D/pool.conf" <<EOF
[global]
daemonize = no
error_log = $D/fpm-err.log
[bench]
listen = $D/fpm.sock
pm = static
pm.max_children = $CHILDREN
pm.max_requests = 0
EOF
FPM=$(command -v php-fpm8.5 || command -v php-fpm || echo /usr/sbin/php-fpm8.5)
"$FPM" -y "$D/pool.conf" -F -d opcache.enable=1 -d opcache.validate_timestamps=0 \
    >"$D/fpm.log" 2>&1 &
for _ in $(seq 1 200); do [ -S "$D/fpm.sock" ] && break; sleep 0.05; done
[ -S "$D/fpm.sock" ] || { echo "=== FATAL: php-fpm never bound"; cat "$D/fpm.log"; exit 1; }

for pair in "A:$PORT_A" "B:$PORT_B"; do
    tag=${pair%%:*}; port=${pair##*:}
    sed -e "s|{{PORT}}|$port|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{SOCKET}}|$D/fpm.sock|g" \
        "$ROOT/conf/hello-external-fpm.toml.template" > "$D/$tag.toml"
done
"$BIN_A" serve -c "$D/A.toml" >"$D/vol-A.log" 2>&1 &
"$BIN_B" serve -c "$D/B.toml" >"$D/vol-B.log" 2>&1 &
sleep 2

for pair in "$PORT_A:A" "$PORT_B:B"; do
    port=${pair%%:*}; tag=${pair##*:}
    body=$(curl -s --max-time 5 "http://127.0.0.1:$port/" || echo "<no answer>")
    echo "  $tag -> $body"
    case $body in *'"hello"'*) ;; *) echo "=== FATAL: $tag is not serving"; exit 1 ;; esac
done
echo "=== php-fpm children: $(pgrep -cf 'php-fpm: pool bench$' || echo 0)"

run() {
    local tag=$1 port=$2 label=$3
    wrk -t"$CORES" -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:$port/" >"$D/wrk-$tag-$label.txt" 2>&1
    awk -v t="$tag" -v l="$label" -v f="$D/wrk-$tag-$label.txt" 'BEGIN{ while ((getline line < f) > 0) {
            if (line ~ /^Requests\/sec:/) { split(line, a, " "); r = a[2] }
            if (line ~ /^ +50%/) { p = $2 }
            if (line ~ /Non-2xx/) { split(line, b, ":"); gsub(/ /, "", b[2]); bad = b[2] }
        }
        printf "  %-26s %7d rps  p50 %-9s %s\n", l, r + 0, (p == "" ? "-" : p),
               (bad + 0 > 0 ? "<<< NON-2xx " bad : "") }'
}

echo "=== warm-up (discarded: the first pass pays the pool building)"
wrk -t"$CORES" -c"$CONC" -d"${SECS}s" "http://127.0.0.1:$PORT_A/" >/dev/null 2>&1
wrk -t"$CORES" -c"$CONC" -d"${SECS}s" "http://127.0.0.1:$PORT_B/" >/dev/null 2>&1

for round in 1 2; do
    echo "--- round $round"
    if [ $(( round % 2 )) -eq 1 ]; then
        run A "$PORT_A" "cap=1   (shipped)"
        run B "$PORT_B" "cap=512 (retention)"
    else
        run B "$PORT_B" "cap=512 (retention)"
        run A "$PORT_A" "cap=1   (shipped)"
    fi
done
