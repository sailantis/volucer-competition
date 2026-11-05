#!/usr/bin/env bash
# Does php-cgi really beat php-fpm, or is that the *backend kind* wearing PHP's clothes?
#
# `cgi_prefork` and `external_fpm` differ in two things at once:
#
#     cgi_prefork   volucer `spawn_cgi` -> CgiPool      -> php-cgi  -b      (preforked)
#     external_fpm  volucer `external`  -> ClientPool   -> php-fpm  pool    (preforked)
#
# Both are one listening unix socket with N forked children behind it. So the 40k-vs-55k gap in
# the four-arm table could be either the SAPI or the pool implementation, and no table so far
# separates them -- which is why the earlier conclusion "php-cgi beats php-fpm" was not yet
# earned.
#
# This probe holds volucer completely constant: both arms are `kind = "external"`, same
# `ClientPool`, same socket type, same child count, same document root, same ini flags. Only
# the process listening on the socket changes:
#
#     A  external -> php-cgi  -b  (PHP_FCGI_CHILDREN=N)
#     B  external -> php-fpm  pool  (pm.max_children=N)
#
# A difference here is the SAPI and nothing else. A difference between A and `cgi_prefork`
# would be `CgiPool` instead.
#
# Usage: probe-sapi.sh [secs] [conc] [children]
set -eu

SECS=${1:-14}
CONC=${2:-100}
CHILDREN=${3:-96}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=/tmp/probe-sapi
# The default is the 0.5.0 release. It used to be `volucer-adopt` while that file was still a
# 0.4.0 build, which meant this probe and the arm table could silently describe different
# releases; `arms.sh` now refuses a version mismatch, and this one names the release it wants.
BIN=${BIN:-$HOME/hello-bench/bin/volucer-adopt}
PORT_CGI_ONLY=22960
PORT_FPM_ONLY=22961
CORES=$(nproc)
[ "$CORES" -gt "$CONC" ] && CORES=$CONC

rm -rf "$D"; mkdir -p "$D"

cleanup() {
    # Anchored on the probe directory, not on the script name: `pgrep -f probe-sapi` matches
    # the shell that is *running* this probe (its own argv contains the path), so the first
    # version killed its own session and reported nothing. The directory can only ever be
    # matched by processes this run started.
    for p in $(pgrep -f "probe-sapi/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(pgrep -f "php-cgi -b $D/" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    for p in $(pgrep -f "$D/pool.conf" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
    sleep 0.3
}
trap cleanup EXIT INT TERM
cleanup

# The same flags every other arm gets, so the comparison is not a php.ini.
PHP_FLAGS="-d opcache.enable_cli=1 -d opcache.validate_timestamps=0 -d opcache.jit=off -d xdebug.mode=off -d memory_limit=512M"

# ---- A: php-cgi, preforked, behind `external` -------------------------------------------
# shellcheck disable=SC2086
PHP_FCGI_CHILDREN=$CHILDREN php-cgi $PHP_FLAGS -b "$D/cgi.sock" >"$D/cgi.log" 2>&1 &
for _ in $(seq 1 200); do [ -S "$D/cgi.sock" ] && break; sleep 0.05; done

# ---- B: php-fpm, same pool shape, behind `external` -------------------------------------
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

sed -e "s|{{PORT}}|$PORT_CGI_ONLY|g" -e "s|{{ROOT}}|$ROOT|g" \
    -e "s|{{SOCKET}}|$D/cgi.sock|g" \
    "$ROOT/conf/hello-external-fpm.toml.template" > "$D/cgi.toml"
sed -e "s|{{PORT}}|$PORT_FPM_ONLY|g" -e "s|{{ROOT}}|$ROOT|g" \
    -e "s|{{SOCKET}}|$D/fpm.sock|g" \
    "$ROOT/conf/hello-external-fpm.toml.template" > "$D/fpm.toml"

"$BIN" serve -c "$D/cgi.toml" >"$D/vol-cgi.log" 2>&1 &
"$BIN" serve -c "$D/fpm.toml" >"$D/vol-fpm.log" 2>&1 &
sleep 2

# Guard: a dead backend answers *faster* than a live one, so both bodies are checked before
# anything is timed. This is the bug that produced a headline 502 in an earlier phase.
for pair in "$PORT_CGI_ONLY:cgi" "$PORT_FPM_ONLY:fpm"; do
    port=${pair%%:*}; name=${pair##*:}
    body=$(curl -s --max-time 5 "http://127.0.0.1:$port/" || echo "<no answer>")
    echo "  $name -> $body"
    case $body in *'"hello"'*) ;; *) echo "=== FATAL: $name is not serving"; exit 1 ;; esac
done

echo "=== children"
echo "  php-cgi (master + forked): $(ps -eo args --no-headers | grep -c "[p]hp-cgi .*-b $D/cgi.sock")"
echo "  php-fpm (pool bench):      $(ps -eo args --no-headers | grep -c "[p]hp-fpm: pool bench")"

cpu_of() { awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }

run() {
    local name=$1 port=$2
    wrk -t"$CORES" -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:$port/" >"$D/wrk-$name.txt" 2>&1
    local rps p50 bad
    rps=$(awk '/^Requests\/sec:/{print $2}' "$D/wrk-$name.txt")
    p50=$(awk '/^ +50%/{print $2}' "$D/wrk-$name.txt")
    bad=$(awk -F: '/Non-2xx/{gsub(/ /,"",$2); print $2+0}' "$D/wrk-$name.txt")
    # `awk` emits a dot decimal, and a German locale's `printf %f` rejects it outright
    # ("Ungültige Zahl") -- which under `set -e` aborts the whole run mid-round and looks like
    # a crash rather than a formatting bug. Formatted by awk instead of by the shell.
    awk -v n="$name" -v r="${rps:-0}" -v p="$p50" -v b="${bad:-0}" 'BEGIN {
        printf "  %-8s %7d rps  p50 %-9s %s\n", n, r, (length(p) ? p : "-"),
               (b > 0 ? "<<< NON-2xx " b : "")
    }'
}

# A warm pass each, discarded: the first pass after a fresh start pays the pool building.
echo "=== warm-up"
wrk -t"$CORES" -c"$CONC" -d"${SECS}s" "http://127.0.0.1:$PORT_CGI_ONLY/" >/dev/null 2>&1
wrk -t"$CORES" -c"$CONC" -d"${SECS}s" "http://127.0.0.1:$PORT_FPM_ONLY/" >/dev/null 2>&1

for round in 1 2 3; do
    echo "--- round $round"
    if [ $(( round % 2 )) -eq 1 ]; then
        run cgi "$PORT_CGI_ONLY"; run fpm "$PORT_FPM_ONLY"
    else
        run fpm "$PORT_FPM_ONLY"; run cgi "$PORT_CGI_ONLY"
    fi
done

echo "=== PSS"
for pair in "cgi:$D/cgi.sock" "fpm:$D/fpm.sock"; do
    name=${pair%%:*}
    case $name in
        cgi) pat="php-cgi" ;;
        fpm) pat='php-fpm: pool bench$' ;;
    esac
    total=0
    for p in $(pgrep -f "$pat" 2>/dev/null || true); do
        v=$(awk '/^Pss:/{print $2}' "/proc/$p/smaps_rollup" 2>/dev/null || echo 0)
        total=$((total + ${v:-0}))
    done
    printf "  %-8s %5d MB\n" "$name" $((total / 1024))
done
