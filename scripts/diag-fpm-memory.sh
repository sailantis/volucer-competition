#!/bin/bash
# Why does FPM's summed PSS rise when opcache is turned off, while its RSS falls?
#
# `matrix.sh` records both columns for every arm, and for the FPM arm at w=24 after
# load they disagree in a way that matters: PSS goes 68.6 -> 128.1 MB when opcache
# is disabled, and RSS goes 631.9 -> 596.1 MB. One of those has to be the wrong way
# to read it, and a summed total cannot say which — the total is exactly what the
# two metrics disagree about.
#
# This script answers it by sampling each php-fpm child individually, so the shared
# and the private part of every child are visible separately:
#
#   PSS  charges a page once, split across the processes that map it. A shared
#        opcache segment therefore contributes ONE segment's worth to the sum.
#   RSS  charges every mapping in full. The same segment contributes its whole size
#        from every child that maps it.
#
# With opcache on, most of each child's resident set is that one shared segment, so
# RSS over-counts and PSS is right. With opcache off the segment is never mapped and
# every child compiles into its own heap: little is shared, so PSS rises honestly
# and RSS falls because a 128 MB mapping is gone.
#
# It uses the same private nginx prefix and generated pool as matrix.sh, so it runs
# without sudo and never touches the host's services.
#
# Usage:
#   bash scripts/diag-fpm-memory.sh
#   WORKERS=16 CONC=64 bash scripts/diag-fpm-memory.sh
#
# Environment:
#   WORKERS   pool size to sample            [24]
#   CONC      concurrency of the load burst  [64]
#   ROOT      the checkout                   [script's parent]
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(dirname "$SCRIPT_DIR")}"
PHP_FPM="${PHP_FPM:-$(command -v php-fpm8.3 || command -v php-fpm || true)}"
NGINX="${NGINX:-$(command -v nginx || true)}"
WORKERS="${WORKERS:-24}"
CONC="${CONC:-64}"
PORT="${PORT:-23500}"
D="$(mktemp -d)"

fail() { echo "FATAL: $*" >&2; rm -rf "$D"; exit 1; }

[ -n "$PHP_FPM" ] || fail "no php-fpm on PATH"
[ -n "$NGINX" ] || fail "no nginx on PATH"
[ -f "$ROOT/data/bench.sqlite" ] || fail "$ROOT/data/bench.sqlite is missing - run: php seed.php"
command -v wrk >/dev/null 2>&1 || fail "no wrk on PATH"

mkdir -p "$D"/{client,proxy,fastcgi,uwsgi,scgi}

cat > "$D/nginx.conf" <<EOF
daemon off;
worker_processes 2;
error_log $D/nginx.err warn;
pid $D/nginx.pid;
events { worker_connections 4096; }
http {
    access_log off;
    client_body_temp_path $D/client;
    proxy_temp_path       $D/proxy;
    fastcgi_temp_path     $D/fastcgi;
    uwsgi_temp_path       $D/uwsgi;
    scgi_temp_path        $D/scgi;
    server {
        listen 127.0.0.1:$PORT;
        location / {
            include /etc/nginx/fastcgi_params;
            fastcgi_pass unix:$D/fpm.sock;
            fastcgi_param SCRIPT_FILENAME $ROOT/public/index.php;
            fastcgi_param DOCUMENT_ROOT $ROOT/public;
        }
    }
}
EOF

cat > "$D/pool.conf" <<EOF
[global]
daemonize = no
error_log = $D/fpm.err
[bench]
listen = $D/fpm.sock
pm = static
pm.max_children = $WORKERS
pm.max_requests = 0
php_admin_value[memory_limit] = 512M
EOF

cleanup() {
    [ -n "${NP:-}" ] && kill "$NP" 2>/dev/null
    [ -n "${FP:-}" ] && kill "$FP" 2>/dev/null
    pkill -f "$D/nginx.conf" 2>/dev/null
    rm -rf "$D"
}
trap cleanup EXIT

printf '%-9s %-10s %-10s %-10s %-12s %-12s %-12s\n' mode children sum_pss_mb sum_rss_mb sum_private_mb per_child_pss per_child_peak
for mode in on off; do
    oc=$([ "$mode" = "on" ] && echo 1 || echo 0)
    rm -f "$D/fpm.sock"
    "$PHP_FPM" -y "$D/pool.conf" -F -d opcache.enable="$oc" \
        -d opcache.validate_timestamps=0 >>"$D/fpm.out" 2>&1 &
    FP=$!
    "$NGINX" -p "$D" -c "$D/nginx.conf" >>"$D/nginx.out" 2>&1 &
    NP=$!

    ok=0
    for _ in $(seq 1 80); do
        if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
            "http://127.0.0.1:$PORT/items")" = "200" ]; then ok=1; break; fi
        sleep 0.25
    done
    [ "$ok" = "1" ] || { echo "FPM pool never became ready (opcache $mode)"; tail -5 "$D/fpm.out"; exit 1; }

    # Wake every child and let each compile what it needs, then measure. A shorter
    # burst would sample a pool where some children have never served a request.
    wrk -t"$WORKERS" -c"$WORKERS" -d2s "http://127.0.0.1:$PORT/items" >/dev/null 2>&1
    wrk -t12 -c"$CONC" -d5s "http://127.0.0.1:$PORT/items" >/dev/null 2>&1
    sleep 1

    # Sample the children WHILE they are working, not only after the burst. A
    # drained pool reports the floor - and the floor is exactly what makes FPM
    # look implausibly small: a child that is between requests has freed the
    # request's allocations, so 2 MB is a true reading of a true state and a
    # misleading answer to "what does this pool cost".
    PEAK="$(mktemp "$D/peak.XXXXXX")"
    wrk -t12 -c"$CONC" -d3s "http://127.0.0.1:$PORT/items" >/dev/null 2>&1 &
    WPID=$!
    sleep 1.5
    for p in $(pgrep -P "$FP"); do
        s="$(awk '/^Pss:/{print $2; exit}' "/proc/$p/smaps_rollup" 2>/dev/null)"
        c="$(awk '/^Private_Clean:/{print $2; exit}' "/proc/$p/smaps_rollup" 2>/dev/null)"
        d="$(awk '/^Private_Dirty:/{print $2; exit}' "/proc/$p/smaps_rollup" 2>/dev/null)"
        echo "$s ${c:-0} ${d:-0}" >> "$PEAK"
    done
    wait $WPID 2>/dev/null

    pss=0; rss=0; n=0; priv=0; ppeak=0; pn=0
    for p in $(pgrep -P "$FP"); do
        s="$(awk '/^Pss:/{print $2; exit}' "/proc/$p/smaps_rollup" 2>/dev/null)"
        r="$(awk '/^VmRSS:/{print $2; exit}' "/proc/$p/status" 2>/dev/null)"
        [ -n "$s" ] || continue
        pss=$((pss + s)); rss=$((rss + r)); n=$((n + 1))
        c="$(awk '/^Private_Clean:/{print $2; exit}' "/proc/$p/smaps_rollup" 2>/dev/null)"
        d="$(awk '/^Private_Dirty:/{print $2; exit}' "/proc/$p/smaps_rollup" 2>/dev/null)"
        priv=$((priv + ${c:-0} + ${d:-0}))
    done
    while read -r s c d; do
        [ -n "$s" ] || continue
        ppeak=$((ppeak + s)); pn=$((pn + 1))
    done < "$PEAK"
    rm -f "$PEAK"
    per="$(awk -v p="$pss" -v n="$n" 'BEGIN { printf "%.2f", (n > 0 ? p / n / 1024 : 0) }')"
    # Only the pool's children are summed: the FPM master and nginx's workers are
    # constant across the two modes, so including them would dilute the thing being
    # measured. `matrix.sh` sums the whole deployment instead, which is why its
    # totals are larger than these by the master and nginx's four workers.
    #
    # `private` is the column that decides whether a number is honest: it is the
    # part of each child's resident set that no other process maps, so it is the
    # same whether you sum it, average it, or count it once. Shared pages are what
    # make PSS and RSS disagree, and this is neither.
    printf '%-9s %-10s %-10s %-10s %-12s %-12s %-12s\n' "$mode" "$n" \
        "$(awk -v k="$pss" 'BEGIN{printf "%.0f", k/1024}')" \
        "$(awk -v k="$rss" 'BEGIN{printf "%.0f", k/1024}')" \
        "$(awk -v k="$priv" 'BEGIN{printf "%.0f", k/1024}')" "$per" \
        "$(awk -v k="$ppeak" -v n="$pn" 'BEGIN { printf "%.2f", (n > 0 ? k / n / 1024 : 0) }')"

    kill "$NP" "$FP" 2>/dev/null
    wait "$NP" 2>/dev/null
    wait "$FP" 2>/dev/null
    NP=""; FP=""
    pkill -f "$D/nginx.conf" 2>/dev/null
    sleep 1
done

echo
echo "If PSS rises when opcache is off while RSS falls, the reason is the shared"
echo "segment: opcache is one mapping every child shares (RSS counts it per child,"
echo "PSS once), and without it each child compiles privately."
