#!/bin/bash
# Does anybody respect FCGI_MAX_CONNS / FCGI_MAX_REQS?
#
# The FastCGI spec has a capacity channel: a `FCGI_GET_VALUES` record with
# `FCGI_MAX_CONNS` and `FCGI_MAX_REQS` names asks the server how many connections and
# how many concurrent requests it can take. PHP fills both in — `sapi/cgi/cgi_main.c`
# from `PHP_FCGI_CHILDREN` and `sapi/fpm/fpm/fpm_php.c` from `pm.max_children` — so
# the question is not whether the numbers exist but what they are worth.
#
# Two different things could be true and they must be measured separately:
#
#   1. Does the server ANSWER? A connection that gets a `GET_VALUES_RESULT` can be
#      asked; one that is closed (or hangs) cannot, and a client that relies on the
#      answer then has to have a fallback anyway.
#   2. Does the server ENFORCE? A number that is advertised but not enforced is
#      documentation. This is measured by opening N connections and sending N
#      simultaneous requests, then counting how many distinct pids answered: if the
#      server refuses work beyond the advertised figure, the answer arrives late, the
#      connections are reset, or the same few children serve everything.
#
# Both servers here are PHP's own, so this is a question about php, not about volucer.
#
# Usage:
#   bash scripts/diag-fcgi-capacity.sh
#   SKIP_FPM=1 bash scripts/diag-fcgi-capacity.sh     # php-cgi only
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHP_CGI="${PHP_CGI:-$(command -v php-cgi8.5 || command -v php-cgi || true)}"
FPM_BIN="${FPM_BIN:-$(command -v php-fpm8.5 || command -v php-fpm8.3 || command -v php-fpm || true)}"
SKIP_FPM="${SKIP_FPM:-0}"
D="$(mktemp -d /tmp/fcgi-capacity.XXXXXX)"

fail() { echo "FATAL: $*" >&2; exit 1; }

cleanup() {
    [ -n "${CGI:-}" ] && kill -KILL "$CGI" 2>/dev/null
    if [ "$fpm_installed" = "1" ]; then
        sudo rm -f /etc/php/*/fpm/pool.d/bench-capacity.conf 2>/dev/null
        sudo systemctl restart "$FPM_SERVICE" 2>/dev/null
    fi
    pkill -KILL -f "$D" 2>/dev/null
    rm -rf "$D"
}
trap cleanup EXIT

cat > "$D/probe.php" <<'PHP'
<?php

// A response that identifies the process, so "who served this" is answerable.
usleep((int) ($_GET['delay'] ?? 0) * 1000);
echo 'served-by-' . getmypid();
PHP

# ---------------------------------------------------------------------------
# 1. Is GET_VALUES answered?
# ---------------------------------------------------------------------------
cat > "$D/getvalues.py" <<'PY'
"""Send FCGI_GET_VALUES and report whether a GET_VALUES_RESULT comes back.

Exit codes: 0 answered, 2 closed without a reply, 3 hung, 4 malformed reply.
"""
import socket
import struct
import sys

BEGIN_REQUEST, END_REQUEST = 1, 3
GET_VALUES, GET_VALUES_RESULT = 9, 10


def record(kind, rid, body=b""):
    pad = (-len(body)) % 8
    return struct.pack("!BBHHBB", 1, kind, rid, len(body), pad, 0) + body + b"\x00" * pad


def nv(pairs):
    out = b""
    for key, value in pairs:
        for item in (key, value):
            raw = item.encode()
            out += bytes([len(raw)]) if len(raw) < 128 else struct.pack("!I", len(raw) | 0x80000000)
            out += raw
    return out


def decode(payload):
    """The reply's name-value pairs, as a list of (name, value)."""
    pairs, i = [], 0
    while i < len(payload):
        values = []
        for _ in range(2):
            n = payload[i]
            i += 1
            if n & 0x80:
                n = struct.unpack("!I", bytes([n & 0x7F]) + payload[i:i + 3])[0]
                i += 3
            values.append(payload[i:i + n].decode(errors="replace"))
            i += n
        pairs.append(tuple(values))
    return pairs


host, port = sys.argv[1], int(sys.argv[2])
sock = socket.create_connection((host, port), timeout=5)
sock.sendall(record(GET_VALUES, 0, nv([("FCGI_MAX_CONNS", ""), ("FCGI_MAX_REQS", ""), ("FCGI_MPXS_CONNS", "")])))
sock.settimeout(4)

buffer = b""
try:
    while len(buffer) < 8192:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buffer += chunk
        if len(buffer) >= 8:
            _, kind, _, length, padding, _ = struct.unpack("!BBHHBB", buffer[:8])
            if len(buffer) >= 8 + length + padding:
                break
except socket.timeout:
    print("  GET_VALUES: no reply within 4 s")
    sys.exit(3)
finally:
    sock.close()

if not buffer:
    print("  GET_VALUES: the connection was closed without a reply")
    sys.exit(2)

_, kind, _, length, padding, _ = struct.unpack("!BBHHBB", buffer[:8])
payload = buffer[8:8 + length]
if kind != GET_VALUES_RESULT:
    print("  GET_VALUES: got record type %d, expected %d" % (kind, GET_VALUES_RESULT))
    sys.exit(4)

pairs = decode(payload)
for name, value in pairs:
    print("  GET_VALUES: %-16s = %s" % (name, value or "(empty)"))
if not pairs:
    print("  GET_VALUES: answered with an empty result")
sys.exit(0)
PY

# ---------------------------------------------------------------------------
# 2. Does anything enforce it? Fire N simultaneous requests over N connections.
# ---------------------------------------------------------------------------
cat > "$D/burst.py" <<'PY'
"""N simultaneous requests, each on its own connection. Prints "<pid> <elapsed_ms>"."""
import socket
import struct
import sys
import threading
import time

BEGIN_REQUEST, PARAMS, STDIN, STDOUT, END_REQUEST = 1, 4, 5, 6, 3


def record(kind, rid, body=b""):
    pad = (-len(body)) % 8
    return struct.pack("!BBHHBB", 1, kind, rid, len(body), pad, 0) + body + b"\x00" * pad


def nv(pairs):
    out = b""
    for key, value in pairs:
        for item in (key, value):
            raw = item.encode()
            out += bytes([len(raw)]) if len(raw) < 128 else struct.pack("!I", len(raw) | 0x80000000)
            out += raw
    return out


def one(host, port, script, results, index):
    started = time.time()
    try:
        sock = socket.create_connection((host, port), timeout=15)
    except OSError as err:
        results[index] = ("CONNECT-ERR", (time.time() - started) * 1000, str(err))
        return
    params = nv([
        ("GATEWAY_INTERFACE", "CGI/1.1"),
        ("REQUEST_METHOD", "GET"),
        ("SCRIPT_FILENAME", script),
        ("SCRIPT_NAME", "/probe.php"),
        ("QUERY_STRING", "delay=0"),
        ("REQUEST_URI", "/probe.php?delay=0"),
        ("SERVER_PROTOCOL", "HTTP/1.1"),
        ("SERVER_SOFTWARE", "diag"),
        ("REMOTE_ADDR", "127.0.0.1"),
    ])
    sock.sendall(
        record(BEGIN_REQUEST, 1, struct.pack("!HBxxxxx", 1, 0))
        + record(PARAMS, 1, params)
        + record(PARAMS, 1, b"")
        + record(STDIN, 1, b"")
    )
    sock.settimeout(15)
    body = b""
    try:
        while True:
            head = b""
            while len(head) < 8:
                piece = sock.recv(8 - len(head))
                if not piece:
                    raise ConnectionResetError("closed mid-frame")
                head += piece
            _, kind, _, length, padding, _ = struct.unpack("!BBHHBB", head)
            payload = b""
            while len(payload) < length:
                piece = sock.recv(length - len(payload))
                if not piece:
                    raise ConnectionResetError("closed mid-payload")
                payload += piece
            if padding:
                sock.recv(padding)
            if kind == STDOUT:
                body += payload
            elif kind == END_REQUEST:
                break
    except (OSError, ConnectionResetError) as err:
        results[index] = ("IO-ERR", (time.time() - started) * 1000, str(err))
        sock.close()
        return
    sock.close()
    text = body.decode(errors="replace")
    pid = text.rsplit("served-by-", 1)[-1].strip() if "served-by-" in text else "?"
    results[index] = (pid, (time.time() - started) * 1000, "")


host, port, script, count = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
results = [None] * count
threads = [threading.Thread(target=one, args=(host, port, script, results, i)) for i in range(count)]
started = time.time()
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()
print("  all %d finished in %.0f ms" % (count, (time.time() - started) * 1000))
for index, (pid, elapsed, err) in enumerate(results):
    print("RESULT %s %.0f %s" % (pid, elapsed, err))
PY

report_burst() { # label count
    local label="$1" count="$2" out
    out="$(python3 "$D/burst.py" 127.0.0.1 "$PORT" "$D/probe.php" "$count" 2>&1)"
    echo "$out" | grep -v '^RESULT' | sed 's/^/  /'
    local served errors slow
    served="$(echo "$out" | awk '$1 == "RESULT" && $2 ~ /^[0-9]+$/ && $2 != "?" { print $2 }' | sort -u | wc -l)"
    errors="$(echo "$out" | awk '$1 == "RESULT" && $2 !~ /^[0-9]+$/ || $2 == "?"' | wc -l)"
    slow="$(echo "$out" | awk '$1 == "RESULT" { if ($3 + 0 > 1000) n++ } END { print n + 0 }')"
    printf '  %s: %s distinct pid(s) served %s request(s), %s error(s), %s over 1 s\n' \
        "$label" "$served" "$count" "$errors" "$slow"
}

PORT=19890
fpm_installed=0
FPM_SERVICE=""
for unit in php8.5-fpm php8.3-fpm php-fpm; do
    systemctl list-unit-files 2>/dev/null | grep -q "^${unit}\.service" && { FPM_SERVICE="$unit"; break; }
done

echo "=== what FCGI_MAX_CONNS / FCGI_MAX_REQS are worth ==="
echo

if [ -z "$PHP_CGI" ]; then
    echo "no php-cgi on PATH; skipping the php-cgi arm"
else
    for children in 4 16; do
        echo "--- php-cgi, PHP_FCGI_CHILDREN=$children, advertised capacity should be $children ---"
        pkill -KILL -f "php-cgi.*-b 127.0.0.1:$PORT" 2>/dev/null
        sleep 0.3
        env PHP_FCGI_CHILDREN=$children PHP_FCGI_MAX_REQUESTS=0 \
            "$PHP_CGI" -b "127.0.0.1:$PORT" > "$D/cgi-$children.log" 2>&1 &
        CGI=$!
        for _ in $(seq 1 80); do
            (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break
            sleep 0.1
        done
        python3 "$D/getvalues.py" 127.0.0.1 "$PORT" || true
        report_burst "burst of 32" 32
        kill -KILL "$CGI" 2>/dev/null
        pkill -KILL -f "php-cgi.*-b 127.0.0.1:$PORT" 2>/dev/null
        CGI=""
        sleep 0.5
        echo
    done
fi

if [ "$SKIP_FPM" = "1" ]; then
    echo "(SKIP_FPM=1: not testing php-fpm)"
elif [ -z "$FPM_BIN" ] || ! command -v nginx >/dev/null 2>&1; then
    echo "no php-fpm or nginx; skipping the php-fpm arm"
elif ! sudo -n true 2>/dev/null; then
    echo "no passwordless sudo; skipping the php-fpm arm"
else
    # php-fpm only answers GET_VALUES once a child serves the connection, and a child is
    # what the pool has: 4 here, so the advertised figure should be 4.
    echo "--- php-fpm, pm.max_children=4, advertised capacity should be 4 ---"
    for unit in "$FPM_SERVICE"; do
        version="$(echo "$unit" | sed -E 's/php(.*)-fpm/\1/')"
    done
    pool_dir="/etc/php/$version/fpm/pool.d"
    if [ ! -d "$pool_dir" ]; then
        echo "no $pool_dir; skipping"
    else
        fpm_installed=1
        xdebug_ini="$(ls "/etc/php/$version/fpm/conf.d/"*xdebug*.ini 2>/dev/null | head -1)"
        [ -n "$xdebug_ini" ] && sudo mv "$xdebug_ini" "$xdebug_ini.capacity-bench" 2>/dev/null

        sudo rm -f /etc/php/*/fpm/pool.d/bench-capacity.conf 2>/dev/null
        sudo tee "$pool_dir/bench-capacity.conf" >/dev/null <<EOF
[bench]
listen = 127.0.0.1:$PORT
pm = static
pm.max_children = 4
pm.max_requests = 0
user = $(id -un)
group = $(id -gn)
catch_workers_output = yes
php_admin_value[memory_limit] = 512M
php_admin_flag[opcache.enable] = 1
php_admin_value[opcache.validate_timestamps] = 0
EOF
        if sudo "$FPM_BIN" -t >/dev/null 2>&1; then
            sudo systemctl restart "$FPM_SERVICE" 2>/dev/null
            for _ in $(seq 1 60); do
                (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break
                sleep 0.25
            done
            python3 "$D/getvalues.py" 127.0.0.1 "$PORT" || true
            report_burst "burst of 32" 32
        else
            echo "  php-fpm rejected the pool; skipping"
        fi
    fi
fi

echo
echo "Read the two answers separately. 'does not answer' means a client cannot discover"
echo "the figure at all and needs a configured fallback; 'answered but not enforced'"
echo "means the figure is documentation, and capping concurrency to it would be right"
echo "only because the server would queue anyway."
