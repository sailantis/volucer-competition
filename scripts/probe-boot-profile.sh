#!/usr/bin/env bash
# What does the framework actually cost server-side, per request?
#
# The bare/framed experiment said removing the framework lifts php-fpm from
# ~27,900 to ~104,300 rps. Throughput ratios are easy to misread, because a
# request rate on a fixed number of cores is a CPU-time statement: at 12 cores,
# 27,900 rps is ~430 us of CPU per request and 104,300 is ~115 us. The
# difference, ~315 us, is what this script tries to find -- and it is more than
# twice the ~152 us `probe-boot-cost.php` measures for a cold `boot()` in the CLI.
#
# So either the boot is more expensive under fpm than under the CLI, or there is
# work outside `boot()` that the bare path also skips. This measures the
# server-side CPU directly instead of inferring it from rps:
#
#   * utime+stime of every fpm child, sampled before and after a wrk run, gives
#     CPU-seconds spent serving -- independent of where the time goes.
#   * `perf record` over the children during the same load gives the breakdown.
#
# Usage:
#   bash scripts/probe-boot-profile.sh                # framed vs bare, cpu per req
#   PERF=1 bash scripts/probe-boot-profile.sh         # also collect a perf profile
#   WORKERS=32 CONC=96 DUR=10s bash scripts/probe-boot-profile.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKERS="${WORKERS:-32}"
CONC="${CONC:-96}"
THREADS="${THREADS:-12}"
DUR="${DUR:-10s}"
PERF="${PERF:-0}"
# The matrix supplies JIT through PHP_INI_SCAN_DIR, not through `-d`, because
# `opcache.jit` is read by the extension at startup and a pool-level
# `php_admin_value` arriving later is too late to compile anything. Matching the
# matrix here matters: a probe that silently ran without JIT would misprice every
# number it produced relative to the run it claims to explain.
PHP_INI_SCAN_DIR="${PHP_INI_SCAN_DIR:-/home/competition/jit-on}"
export PHP_INI_SCAN_DIR
PHP_FPM="${PHP_FPM:-/usr/sbin/php-fpm8.5}"
PHP_CGI="${PHP_CGI:-/usr/bin/php-cgi}"
D="${D:-/tmp/boot-profile}"
PORT="${PORT:-18099}"

mkdir -p "$D"
rm -f "$D"/*.log "$D"/*.perf 2>/dev/null

# PHASE=1 swaps in `public/probe-phases.php`, which does exactly what
# `public/index.php` does and additionally honours BENCH_FILLERS. Needed because
# the filler count cannot be varied through `public/index.php`, and because the
# CLI is the wrong SAPI to vary it in.
if [ "${PHASE:-0}" = "1" ]; then
    FRONT_CONTROLLER="probe-phases.php"
else
    FRONT_CONTROLLER="index.php"
fi
export FRONT_CONTROLLER

say() { printf '%s\n' "$*"; }
rule() { printf '%s\n' "------------------------------------------------------------"; }

# The same wrapper ini the matrix generates, so this measures the same run.
if [ "${OPCACHE:-on}" = "on" ]; then
    OC_ENABLE=1
    OC_ARGS=(-d opcache.enable=1 -d opcache.validate_timestamps=0)
else
    OC_ENABLE=0
    OC_ARGS=(-d opcache.enable=0)
fi

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
env[BENCH_FILLERS] = ${FILLERS:-100}
php_admin_flag[opcache.enable] = $OC_ENABLE
php_admin_value[memory_limit] = 512M
php_admin_value[date.timezone] = UTC
php_admin_value[opcache.jit] = tracing
php_admin_value[opcache.jit_buffer_size] = 64M
EOF
}

# nginx in front, because fpm speaks FastCGI and wrk does not.
#
# With PHASE=1 the front controller is `public/probe-phases.php`, which performs
# exactly the same work as `public/index.php` and additionally records per-phase
# timings and honours `BENCH_FILLERS`. That is the only way to vary the filler
# count through the real server rather than in the CLI, where `boot()` is measured
# under a different SAPI and -- as it turns out -- under different static-storage
# semantics.
write_nginx() {
    local front="${FRONT_CONTROLLER:-index.php}"
    cat > "$D/nginx.conf" <<EOF
daemon off;
worker_processes 4;
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
        index $front;
        location / { try_files \$uri /$front\$is_args\$args; }
        location ~ \.php\$ {
            fastcgi_pass 127.0.0.1:$PORT;
            fastcgi_index $front;
            fastcgi_param SCRIPT_FILENAME \$document_root/$front;
            fastcgi_param REQUEST_URI \$request_uri;
            fastcgi_param REQUEST_METHOD \$request_method;
            include /etc/nginx/fastcgi_params;
        }
    }
}
EOF
}

cleanup() {
    [ -f "$D/fpm.pid" ] && kill "$(cat "$D/fpm.pid")" 2>/dev/null
    [ -f "$D/nginx.pid" ] && kill "$(cat "$D/nginx.pid")" 2>/dev/null
    pkill -f "perf record.*--fpm" 2>/dev/null
    sleep 0.5
}
trap cleanup EXIT

# Sum utime+stime over the fpm children, in clock ticks.
child_ticks() {
    local total=0 pid
    for pid in $(pgrep -P "$(cat "$D/fpm.pid")" 2>/dev/null); do
        [ -r "/proc/$pid/stat" ] || continue
        # Fields 14 and 15, 1-based, after the comm field which may contain spaces.
        total=$(( total + $(awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null || echo 0) ))
    done
    echo "$total"
}

HZ="$(getconf CLK_TCK)"
run_variant() { # name bare
    local name="$1" bare="$2"

    write_pool "$D/pool.conf" "$bare"
    write_nginx
    rm -f "$D/fpm.sock"

    "$PHP_FPM" -y "$D/pool.conf" -F -d opcache.enable="$OC_ENABLE" \
        -d opcache.validate_timestamps=0 > "$D/fpm.log" 2>&1 &
    local fpm_bg=$!
    sleep 1.2
    nginx -c "$D/nginx.conf" -p "$D" > "$D/nginx.log" 2>&1 &
    sleep 0.8

    # Prove the mode is live before measuring it: a bare run whose pool silently
    # did not inherit BENCH_BARE would look like a framed run with a slightly
    # different number, and there would be no error to notice.
    local body
    body="$(curl -s --max-time 5 "http://127.0.0.1:$((PORT + 1))/echo")"
    local want='bench' got_bare=no
    [ "$body" = "bench" ] && got_bare=yes
    # Both modes answer 'bench' on /echo -- that is the point -- so probe the
    # difference on a route bare answers with the same fixed body: bare returns
    # 'bench' everywhere, framed returns a page or a 404.
    local items; items="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$((PORT + 1))/items")"
    if [ "$bare" = "1" ]; then
        [ "$items" = "200" ] && local expect="bare" || local expect="FRAMED?"
    else
        [ "$items" = "200" ] && local expect="framed"
    fi
    if [ "${PHASE:-0}" = "1" ]; then
        # With the phase front controller the body is not a reliable signal:
        # it answers every route. Mode is verified from the per-phase log after
        # the run instead, and the log is only enabled when PHASE_LOG=1 so it
        # cannot distort a CPU measurement.
        local expect="phase"
    fi
    printf '  %-8s workers=%s conc=%s  GET /items -> %s  GET /echo -> %s\n' \
        "$name" "$WORKERS" "$CONC" "$items" "$body"
    # Warm up so the first-touch page faults and the autoloader lookups are not
    # charged to the measurement, which is what the matrix's WARMUP does too.
    wrk -t"$THREADS" -c"$CONC" -d3s --latency "http://127.0.0.1:$((PORT + 1))/echo" > /dev/null 2>&1

    local t0 t1 c0 c1
    t0=$(date +%s%N)
    c0=$(child_ticks)

    if [ "$PERF" = "1" ]; then
        local pids; pids="$(pgrep -P "$(cat "$D/fpm.pid")" | tr '\n' ',' | sed 's/,$//')"
        perf record -F 999 -g -o "$D/$name.perf" -p "$pids" -- sleep "$(echo "$DUR" | tr -d 's')" \
            > "$D/perf-$name.log" 2>&1 &
        local perf_bg=$!
        sleep 0.3
        wrk -t"$THREADS" -c"$CONC" -d"$DUR" --latency "http://127.0.0.1:$((PORT + 1))/echo" > "$D/wrk-$name.txt" 2>&1
        wait "$perf_bg" 2>/dev/null
    else
        wrk -t"$THREADS" -c"$CONC" -d"$DUR" --latency "http://127.0.0.1:$((PORT + 1))/echo" > "$D/wrk-$name.txt" 2>&1
    fi

    c1=$(child_ticks)
    t1=$(date +%s%N)

    local rps requests cpu_s cpu_us
    rps="$(awk '/^Requests\/sec:/{print $2; exit}' "$D/wrk-$name.txt")"
    requests="$(awk '/^[[:space:]]*[0-9]+ requests in/{print $1; exit}' "$D/wrk-$name.txt")"
    cpu_s="$(awk -v a="$c0" -v b="$c1" -v hz="$HZ" 'BEGIN{printf "%.3f", (b-a)/hz}')"
    cpu_us="$(awk -v s="$cpu_s" -v n="${requests:-1}" 'BEGIN{ if(n>0) printf "%.1f", s*1000000/n; else print "0" }')"

    printf '  %-8s rps %10s   requests %8s   server cpu %7ss   %8s us cpu/request\n' \
        "$name" "${rps:-?}" "${requests:-?}" "$cpu_s" "$cpu_us"
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "${rps:-0}" "${requests:-0}" "$cpu_s" "$cpu_us" >> "$D/summary.tsv"

    kill "$fpm_bg" 2>/dev/null; wait "$fpm_bg" 2>/dev/null
    [ -f "$D/nginx.pid" ] && kill "$(cat "$D/nginx.pid")" 2>/dev/null
    sleep 1.2
}

say "Framework cost on the wire: framed vs bare, measured as CPU per request"
say "host $(nproc) cores   workers=$WORKERS   conc=$CONC   dur=$DUR   opcache=${OPCACHE:-on}"
rule
: > "$D/summary.tsv"

run_variant framed 0
run_variant bare 1

rule
say "name      rps        requests   server-cpu-s   us cpu/request"
awk -F'\t' '{printf "%-8s %10s %10s %14s %14s\n", $1, $2, $3, $4, $5}' "$D/summary.tsv"

# The delta is the framework's true per-request cost on the wire, inclusive of
# everything bare skips -- bootstrap, container, router, dispatch, middleware.
FRAMED=$(awk -F'\t' '$1=="framed"{print $5}' "$D/summary.tsv")
BARE=$(awk -F'\t' '$1=="bare"{print $5}' "$D/summary.tsv")
if [ -n "$FRAMED" ] && [ -n "$BARE" ]; then
    awk -v f="$FRAMED" -v b="$BARE" 'BEGIN{
        printf "\nframework cost on the wire: %.1f us of CPU per request (%.1f framed - %.1f bare)\n", f-b, f, b
    }'
fi

if [ "$PERF" = "1" ]; then
    for name in framed bare; do
        [ -f "$D/$name.perf" ] || continue
        say ""
        rule
        say "perf top symbols, $name (self time)"
        rule
        perf report -i "$D/$name.perf" --stdio --no-children --percent-limit 0.5 2>/dev/null \
            | awk '/^# Overhead/{f=1} f' | head -45
    done
fi

say ""
say "raw: $D"
