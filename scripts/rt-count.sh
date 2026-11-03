#!/usr/bin/env bash
# Does the front-end read TOKIO_WORKER_THREADS at all?
#
# rt-sweep.sh varied it and concluded "thread count is not the limit" from three runs that
# agreed within noise. That conclusion is only worth anything if the variable was read: this
# crate builds its runtime with `tokio::runtime::Builder::new_multi_thread().enable_all()`,
# and a bare `Builder` takes `num_cpus()` -- `TOKIO_WORKER_THREADS` is read by the
# `#[tokio::main]` macro, which this binary does not use. Counting the threads is the only
# way to know, so this counts them per setting and prints nothing else.
#
#   rt-count.sh <binary> <tag>
set -uo pipefail

BIN=${1:?binary}
TAG=${2:-rtcount}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.probe/$TAG"
PORT=22711
rm -rf "$OUT"; mkdir -p "$OUT"

sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{WORKERS}}|12|g" \
    -e "s|{{SOCKET_DIR}}|$OUT|g" \
    "$ROOT/conf/hello-attach.toml.template" > "$OUT/attach.toml"
SOCK="$OUT/relay"

php -d opcache.enable_cli=1 -d opcache.jit=off "$ROOT/apps/hello/supervisor.php" \
    "unix:$SOCK" >"$OUT/sup.log" 2>&1 &
SUP_PID=$!
for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.05; done

for rt in unset 12 6 4; do
    if [ "$rt" = unset ]; then
        "$BIN" serve -c "$OUT/attach.toml" >"$OUT/v.log" 2>&1 &
    else
        TOKIO_WORKER_THREADS=$rt "$BIN" serve -c "$OUT/attach.toml" >"$OUT/v.log" 2>&1 &
    fi
    VOL=$!
    for _ in $(seq 1 200); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.05; done
    sleep 0.5
    # `tokio-runtime-w` is the runtime's own threads; the blocking pool shares the name, so
    # the idle count above the twelve is what a bigger setting would show.
    RT=$(grep -l '^tokio' /proc/$VOL/task/*/comm 2>/dev/null | wc -l)
    TOT=$(ls /proc/$VOL/task | wc -l)
    printf '%-8s runtime-named=%-3s total-threads=%s\n' "$rt" "$RT" "$TOT"
    kill -TERM $VOL 2>/dev/null; sleep 0.5; kill -9 $VOL 2>/dev/null
done

kill -TERM $SUP_PID 2>/dev/null; sleep 0.3; kill -9 $SUP_PID 2>/dev/null
pkill -f "supervisor.php unix:$SOCK" 2>/dev/null
