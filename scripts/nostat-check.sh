#!/usr/bin/env bash
# Does the hop-less preparation actually fire, and for which requests?
#
#   nostat-check.sh <binary> <tag> [extra.toml]
#
# The change is a predicate on the request path, so the first question is not "is it faster"
# but "does it take the branch at all". `strace` counting `newfstatat`/`stat` inside the
# front-end is the direct read: a request prepared on the runtime thread cannot stat, so a
# path that used to pay a hop for a lookup that found nothing now costs none.
#
# The same run also proves the answers are unchanged: both the hop and the hop-less path must
# serve the same body, and the script-shaped and traversal cases must keep their hop.
set -uo pipefail

BIN=${1:?binary}
TAG=${2:?tag}
EXTRA=${3:-}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.probe/$TAG"
PORT=22713
SOCK="$OUT/relay"
rm -rf "$OUT"; mkdir -p "$OUT"

sed -e "s|{{PORT}}|$PORT|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{WORKERS}}|12|g" \
    -e "s|{{SOCKET_DIR}}|$OUT|g" \
    "$ROOT/conf/hello-attach.toml.template" > "$OUT/attach.toml"
[ -n "$EXTRA" ] && { printf '\n' >> "$OUT/attach.toml"; cat "$EXTRA" >> "$OUT/attach.toml"; }

php -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 -d opcache.jit=off \
    "$ROOT/apps/hello/supervisor.php" "unix:$SOCK" >"$OUT/sup.log" 2>&1 &
SUP_PID=$!
for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.05; done

"$BIN" serve -c "$OUT/attach.toml" >"$OUT/volucer.log" 2>&1 &
VOL_PID=$!
for _ in $(seq 1 200); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.05; done

echo "=== bodies (must be identical across binaries)"
for p in / /items /api/orders/42; do
    printf '  %-16s %s\n' "$p" "$(curl -s -o - -w ' [%{http_code}]' "http://127.0.0.1:$PORT$p" | head -c 90)"
done
for p in /index.php /../etc/passwd /.env; do
    printf '  %-16s %s\n' "$p" "$(curl -s -o /dev/null -w '[%{http_code}]' --path-as-is "http://127.0.0.1:$PORT$p")"
done

# One thousand requests of each shape, syscalls counted in the front-end only.
stat_count() {
    local path=$1 n=${2:-600}
    local label
    label=$(printf '%s' "$path" | tr -c 'a-zA-Z0-9' '_')
    sudo -n timeout 40 strace -f -qq -c -e trace=newfstatat,stat,lstat,statx \
        -p "$VOL_PID" -o "$OUT/st-$label.txt" &
    local sp=$!
    sleep 1
    # `-t1 -c1` keeps this sequential so the count is per-request rather than per-connection.
    wrk -t1 -c1 -d"$(( n / 1000 + 1 ))s" "http://127.0.0.1:$PORT$path" >"$OUT/wrk-$label.txt" 2>&1
    local req=$(awk '/requests in /{print $1}' "$OUT/wrk-$label.txt")
    sleep 0.5
    sudo -n kill -INT $sp 2>/dev/null
    wait $sp 2>/dev/null
    local stats=$(awk '/newfstatat|statx|stat/ {s+=$4} END{print s+0}' "$OUT/st-$label.txt")
    printf '  %-16s %6s requests  %8s stats  %s per request\n' \
        "$path" "${req:-?}" "$stats" \
        "$(awk -v s="$stats" -v r="${req:-0}" 'BEGIN{ if (r+0>0) printf "%.3f", s/r; else print "?" }')"
}
echo "=== filesystem stats per request (front-end process only)"
stat_count / 600
stat_count /api/orders/42 600
stat_count /index.php 600

kill -TERM $VOL_PID 2>/dev/null; sleep 1; kill -9 $VOL_PID 2>/dev/null
kill -TERM $SUP_PID 2>/dev/null; sleep 0.5; kill -9 $SUP_PID 2>/dev/null
pkill -f "supervisor.php unix:$SOCK" 2>/dev/null
echo "--- out: $OUT"
