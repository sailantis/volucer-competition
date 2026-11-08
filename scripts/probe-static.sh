#!/usr/bin/env bash
# Does a mutable class static survive between requests in php-fpm?
#
# `apps/azera/Bootstrap.php` memoises the wired container in a static,
# `self::$wired`, with a comment saying it exists so "a worker-mode re-bootstrap
# (same process, same database) can skip straight to the request loop", and that
# re-registering ~120 routes on every warm recycle "cost ~0.38 ms of pure rebuild".
#
# `probe-phases.sh` measures 211 us inside `bootstrap()` on *every* framed request
# in php-fpm, which is cold-boot money. If the memo were live, most of that would
# be gone. So the memo is either not hit or not cheap.
#
# The plausible reason it is never hit: with opcache the class entry lives in
# shared memory, so PHP restores mutable statics to their compile-time defaults at
# the start of every request. Anything a worker stores in a static is discarded,
# which is what makes `self::$wired` a no-op on any SAPI that reuses a process.
#
# This measures it rather than citing it: one fpm child, N requests, read the
# counter back from inside the child each time.
#
# Usage: bash scripts/probe-static.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHP_FPM="${PHP_FPM:-/usr/sbin/php-fpm8.5}"
D="${D:-/tmp/static-probe}"
PORT="${PORT:-18095}"
N="${N:-5}"

mkdir -p "$D"
rm -f "$D"/*.log "$D"/*.tsv 2>/dev/null

cat > "$D/pool.conf" <<EOF
[global]
pid = $D/fpm.pid
error_log = $D/fpm.err
daemonize = no

[www]
listen = 127.0.0.1:$PORT
pm = static
pm.max_children = 1
pm.max_requests = 0
catch_workers_output = yes
clear_env = no
env[BENCH_STATIC_LOG] = $D/log.tsv
php_admin_flag[opcache.enable] = 1
php_admin_value[opcache.validate_timestamps] = 0
php_admin_value[memory_limit] = 512M
EOF

cat > "$D/nginx.conf" <<EOF
daemon off;
worker_processes 1;
error_log $D/nginx.err crit;
pid $D/nginx.pid;
events { worker_connections 64; }
http {
    access_log off;
    client_body_temp_path $D;
    proxy_temp_path $D;
    fastcgi_temp_path $D;
    uwsgi_temp_path $D;
    scgi_temp_path $D;
    server {
        listen 127.0.0.1:$((PORT + 1));
        root $ROOT/public;
        location / { fastcgi_pass 127.0.0.1:$PORT;
                     include /etc/nginx/fastcgi_params;
                     fastcgi_param SCRIPT_FILENAME \$document_root/probe-static.php;
                     fastcgi_param REQUEST_URI \$request_uri;
                     fastcgi_param REQUEST_METHOD \$request_method; }
    }
}
EOF

cleanup() {
    [ -f "$D/fpm.pid" ] && kill "$(cat "$D/fpm.pid")" 2>/dev/null
    [ -f "$D/nginx.pid" ] && kill "$(cat "$D/nginx.pid")" 2>/dev/null
    sleep 0.4
}
trap cleanup EXIT

"$PHP_FPM" -y "$D/pool.conf" -F -d opcache.enable=1 > "$D/fpm.log" 2>&1 &
FPM_BG=$!
sleep 1.2
nginx -c "$D/nginx.conf" -p "$D" > "$D/nginx.log" 2>&1 &
sleep 0.7

# Sequential, one connection, so every request lands in the same child.
for i in $(seq 1 "$N"); do
    printf '  request %d -> body %s\n' "$i" "$(curl -s --max-time 5 "http://127.0.0.1:$((PORT + 1))/")"
done

echo
if [ -s "$D/log.tsv" ]; then
    printf '%-8s %-9s %-8s %-10s\n' pid counter store mem
    awk -F'\t' '{printf "%-8s %-9s %-8s %-10s\n", $1, $2, $3, $4}' "$D/log.tsv"
    echo
    awk -F'\t' '
        { pid[$1] = 1; if ($2 > max) max = $2; if ($3 > maxs) maxs = $3 }
        END {
            n = 0; for (p in pid) n++
            printf "children used: %d   highest counter: %d   longest store: %d\n", n, max, maxs
            if (max <= 1 && n == 1 && NR > 1)
                print "static did NOT survive: it was restored to its default at each request"
            else if (max > 1)
                print "static DID survive across requests in this child"
        }
    ' "$D/log.tsv"
else
    echo "no log written -- see $D/fpm.err"
fi

echo "raw: $D"
