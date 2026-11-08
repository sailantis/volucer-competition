#!/usr/bin/env bash
# Attribute the per-request CPU of a framed request, inside a real FPM child.
#
# Why this exists
# ---------------
# `probe-boot-profile.sh` measures the framework's cost on the wire as CPU per
# request (utime+stime of the fpm children, divided by requests served). That
# number is trustworthy -- it is the kernel's accounting, not ours -- and it says
# framed `/echo` costs ~426 us of CPU where bare costs ~71.
#
# What it cannot say is *where*. And the obvious candidate does not add up:
# `probe-boot-cost.php` measures a cold `Bootstrap::boot()` at ~152 us, and in a
# resident FPM child `Bootstrap::$wired` is memoised, so from the second request
# onward `boot()` should be nearly free. If that were the whole story, framed
# would be ~80 us, not 426.
#
# So something outside `boot()` is expensive, or the memo is not doing what its
# comment claims. Both are worth knowing and neither can be reasoned out. This
# runs one FPM child and times every phase from inside it.
#
# Usage:
#   bash scripts/probe-phases.sh              # framed, then bare
#   WORKERS=1 CONC=1 bash scripts/probe-phases.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKERS="${WORKERS:-1}"
CONC="${CONC:-1}"
THREADS="${THREADS:-1}"
DUR="${DUR:-4s}"
PHP_FPM="${PHP_FPM:-/usr/sbin/php-fpm8.5}"
# JIT comes from the ini scan dir the matrix uses, not from `-d`: the extension
# reads `opcache.jit` at startup, so a later `php_admin_value` cannot enable it.
PHP_INI_SCAN_DIR="${PHP_INI_SCAN_DIR:-/home/competition/jit-on}"
export PHP_INI_SCAN_DIR
D="${D:-/tmp/phases}"
PORT="${PORT:-18097}"

mkdir -p "$D"
rm -f "$D"/*.tsv "$D"/*.log 2>/dev/null

write_pool() { # file bare
    cat > "$1" <<EOF
[global]
pid = $D/fpm.pid
error_log = $D/fpm.err
daemonize = no

[www]
listen = 127.0.0.1:$PORT
listen.backlog = 511
pm = static
pm.max_children = $WORKERS
pm.max_requests = 0
catch_workers_output = yes
clear_env = no
env[BENCH_BARE] = $2
env[BENCH_FILLERS] = "${FILLERS:-100}"
php_admin_flag[opcache.enable] = 1
php_admin_value[opcache.validate_timestamps] = 0
php_admin_value[opcache.jit] = tracing
php_admin_value[opcache.jit_buffer_size] = 64M
php_admin_value[memory_limit] = 512M
php_admin_value[date.timezone] = UTC
EOF
}

write_nginx() {
    cat > "$D/nginx.conf" <<EOF
daemon off;
worker_processes 2;
error_log $D/nginx.err crit;
pid $D/nginx.pid;
events { worker_connections 4096; }
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
                     fastcgi_param SCRIPT_FILENAME \$document_root/probe-phases.php;
                     fastcgi_param REQUEST_URI \$request_uri;
                     fastcgi_param REQUEST_METHOD \$request_method; }
    }
}
EOF
}

cleanup() {
    [ -f "$D/fpm.pid" ] && kill "$(cat "$D/fpm.pid")" 2>/dev/null
    [ -f "$D/nginx.pid" ] && kill "$(cat "$D/nginx.pid")" 2>/dev/null
    sleep 0.4
}
trap cleanup EXIT

run() { # name bare
    local name="$1"
    local bare="$2"
    local tsv="$D/$name.tsv"
    rm -f "$tsv"

    write_pool "$D/pool.conf" "$bare"
    write_nginx

    BENCH_PHASES="$tsv" "$PHP_FPM" -y "$D/pool.conf" -F \
        -d opcache.enable=1 -d opcache.validate_timestamps=0 > "$D/fpm.log" 2>&1 &
    local fpm_bg=$!
    sleep 1.2
    nginx -c "$D/nginx.conf" -p "$D" > "$D/nginx.log" 2>&1 &
    sleep 0.7

    # One child, one connection at a time: the timings are per request and must
    # not interleave, and a cold child's first request is not the steady state
    # this is trying to explain.
    wrk -t"$THREADS" -c"$CONC" -d1s "http://127.0.0.1:$((PORT + 1))${PATH_RUN:-/echo}" > /dev/null 2>&1

    # Warm up on the path actually measured, not on /echo: a bare run of /items is
    # the same fixed body as bare /echo, but a framed /items touches the DB, the
    # entity manager and the template, and charging those first-touch faults to the
    # measurement would price the first request rather than the steady state.
    wrk -t"$THREADS" -c"$CONC" -d1s "http://127.0.0.1:$((PORT + 1))${PATH_RUN:-/echo}" > /dev/null 2>&1
    : > "$tsv"
    wrk -t"$THREADS" -c"$CONC" -d"$DUR" "http://127.0.0.1:$((PORT + 1))${PATH_RUN:-/echo}" > "$D/wrk-$name.txt" 2>&1

    kill "$fpm_bg" 2>/dev/null; wait "$fpm_bg" 2>/dev/null
    [ -f "$D/nginx.pid" ] && kill "$(cat "$D/nginx.pid")" 2>/dev/null
    sleep 1

    echo "$name: $(wc -l < "$tsv") requests recorded"
}

run framed 0
run bare 1

echo
echo "Per-request phase cost inside an FPM child (median us of recorded requests)"
echo "--------------------------------------------------------------------------"
awk -F'\t' '
    { n[$1]++ }
    { for (i = 2; i <= 7; i++) v[$1, i, n[$1]] = $i }
    END {
        split("autoload benchapp construct bootstrap dispatch respond", names, " ")
        printf "%-10s", "phase"
        for (m in n) printf "%12s", m
        printf "\n"
        for (i = 2; i <= 7; i++) {
            printf "%-10s", names[i - 1]
            for (m in n) {
                c = n[m]; split("", a)
                for (j = 1; j <= c; j++) a[j] = v[m, i, j]
                # insertion-free median: use asort via a simple sort on a copy
                for (x = 2; x <= c; x++) { k = a[x]; y = x - 1
                    while (y >= 1 && a[y] > k) { a[y + 1] = a[y]; y-- }
                    a[y + 1] = k }
                med = (c % 2) ? a[(c + 1) / 2] : (a[c / 2] + a[c / 2 + 1]) / 2
                printf "%12.1f", med / 1000
            }
            printf "\n"
        }
        printf "%-10s", "total"
        for (m in n) {
            c = n[m]; split("", a)
            for (j = 1; j <= c; j++) { s = 0; for (i = 2; i <= 7; i++) s += v[m, i, j]; a[j] = s }
            for (x = 2; x <= c; x++) { k = a[x]; y = x - 1
                while (y >= 1 && a[y] > k) { a[y + 1] = a[y]; y-- }
                a[y + 1] = k }
            med = (c % 2) ? a[(c + 1) / 2] : (a[c / 2] + a[c / 2 + 1]) / 2
            printf "%12.1f", med / 1000
        }
        printf "\n"
    }
' "$D/framed.tsv" "$D/bare.tsv"

echo
echo "raw: $D"
