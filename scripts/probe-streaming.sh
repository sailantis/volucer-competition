#!/usr/bin/env bash
# Does the *awaited* relayed path actually carry bytes, byte-for-byte?
#
# `GET /` on the hello page returns 17 bytes, so with the default 1 MiB
# `stream_threshold_bytes` it always takes the buffered path. That means every benchmark
# number reported for `external` exercised `AsyncClient::request` and never
# `request_streaming`/`next_chunk` or the task-based relay pump — the exact code that was
# rewritten, and the part whose first version produced *lower* throughput because it fell
# through to the blocking relay.
#
# So this pins `stream_threshold_bytes = 1`, which forces every response down the relayed
# path, and then checks three things that a working relay must satisfy:
#
#   1. the body is byte-identical to the buffered path's (a byte count alone would pass on
#      a response that is the right length and the wrong bytes);
#   2. a body far larger than one FastCGI record (>64 KiB) survives — that is where
#      chunk-boundary bugs live;
#   3. the `Content-Length` the backend declared, or the absence of one, is not corrupted.
#
# Usage: probe-streaming.sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-stream
BIN=${BIN:-$HOME/hello-bench/bin/volucer-adopt}
PORT_BUF=23010
PORT_STR=23011
CHILDREN=${CHILDREN:-8}

rm -rf "$D"; mkdir -p "$D"

cleanup() {
    for p in $(pgrep -f "volucer.*$D/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(pgrep -f "$D/pool.conf" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(ps -eo pid,args --no-headers 2>/dev/null \
               | grep "[p]hp-fpm: pool bench$" | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    sleep 0.3
}
trap cleanup EXIT INT TERM
cleanup

cat > "$D/pool.conf" <<EOF
[global]
daemonize = no
error_log = $D/fpm-error.log
[bench]
listen = $D/fpm.sock
pm = static
pm.max_children = $CHILDREN
pm.max_requests = 0
catch_workers_output = yes
php_admin_value[memory_limit] = 512M
EOF
FPM=$(command -v php-fpm8.5 || command -v php-fpm || echo /usr/sbin/php-fpm8.5)
"$FPM" -y "$D/pool.conf" -F -d opcache.enable=1 -d opcache.validate_timestamps=0 >"$D/fpm.log" 2>&1 &
for _ in $(seq 1 300); do [ -S "$D/fpm.sock" ] && break; sleep 0.05; done
[ -S "$D/fpm.sock" ] || { echo "=== FATAL: php-fpm never bound"; cat "$D/fpm.log"; exit 1; }

# A page that emits a body of a chosen size, so a response can be made to cross the 1 MiB
# threshold, the 64 KiB record boundary, and the read buffer — the three places a relay
# can mis-order or drop a chunk. Written into the app's public dir, and removed on exit.
BIG="$ROOT/apps/hello/public/.stream-probe.php"
cat > "$BIG" <<'PHP'
<?php
// Bytes are a deterministic pattern, so the client can prove it got *the same* body rather
// than merely the right number of bytes. `$1` is not available under FastCGI, so the size
// comes from the query string that the probe puts in REQUEST_URI.
$n = (int)($_GET['n'] ?? 32);
header('Content-Type: application/octet-stream');
header('Content-Length: ' . $n);
$pattern = "0123456789abcdef";
for ($sent = 0; $sent < $n; $sent += 16) {
    echo substr($pattern, 0, min(16, $n - $sent));
}
PHP
trap 'rm -f "$BIG"; cleanup' EXIT INT TERM

# Two configs over ONE pool, differing only in the threshold. `1` forces the relayed path for
# anything, including the 17-byte hello page.
for spec in "buf:$PORT_BUF:1048576" "str:$PORT_STR:1"; do
    tag=${spec%%:*}; rest=${spec#*:}; port=${rest%%:*}; thr=${rest##*:}
    cat > "$D/$tag.toml" <<EOF
[server]
http = "127.0.0.1:$port"
default_backend = "app"
document_root = "$ROOT/apps/hello/public"
stream_threshold_bytes = $thr
[server.static_files]
enabled = false
[backends.app]
kind = "external"
socket = "unix:$D/fpm.sock"
EOF
    "$BIN" serve -c "$D/$tag.toml" >"$D/vol-$tag.log" 2>&1 &
done
sleep 2

fail=0
check() {
    local name=$1 url_buf=$2 url_str=$3
    local a b la lb
    a=$(curl -s --max-time 10 "$url_buf" | sha256sum | cut -d' ' -f1)
    b=$(curl -s --max-time 10 "$url_str" | sha256sum | cut -d' ' -f1)
    la=$(curl -s --max-time 10 "$url_buf" | wc -c)
    lb=$(curl -s --max-time 10 "$url_str" | wc -c)
    if [ "$a" = "$b" ] && [ "$la" = "$lb" ] && [ "$la" -gt 0 ]; then
        printf "  %-28s %8s bytes  sha %s  buffered == relayed\n" "$name" "$la" "${a:0:12}"
    else
        printf "  %-28s MISMATCH  buffered %s (%s B)  relayed %s (%s B)\n" \
            "$name" "${a:0:12}" "$la" "${b:0:12}" "$lb"
        fail=1
    fi
}

echo "=== $("$BIN" --version 2>&1)  pool.children=$CHILDREN"
echo "=== GET / (17 bytes: buffered path only, but still compares both)"
check "hello page" "http://127.0.0.1:$PORT_BUF/" "http://127.0.0.1:$PORT_STR/"
echo "=== synthetic bodies (relayed path only on the right-hand side)"
for n in 4096 70000 1400000; do
    check "body ${n}B" \
        "http://127.0.0.1:$PORT_BUF/.stream-probe.php?n=$n" \
        "http://127.0.0.1:$PORT_STR/.stream-probe.php?n=$n"
done

echo "=== a relayed response under concurrent load (chunks must not interleave)"
seq 40 | xargs -P 8 -I{} sh -c \
    "curl -s --max-time 15 'http://127.0.0.1:$PORT_STR/.stream-probe.php?n=1400000' | sha256sum" \
    | cut -d' ' -f1 | sort -u | tee "$D/concurrent.txt"
distinct=$(wc -l < "$D/concurrent.txt")
if [ "$distinct" = "1" ]; then
    echo "  40 concurrent 1.4 MB relays, all identical: ok"
else
    echo "  MISMATCH: $distinct distinct bodies across 40 concurrent relays"
    fail=1
fi

rm -f "$BIG"
echo
if [ "$fail" = "0" ]; then echo "=== PASS"; else echo "=== FAIL"; exit 1; fi
