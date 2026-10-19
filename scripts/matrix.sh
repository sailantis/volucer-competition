#!/bin/bash
# The worker-count x opcache x concurrency matrix, for the five servers this
# repository already compares, on one host, with memory measured alongside.
#
# `bench.sh` answers "how fast is each deployment" at one configuration, and
# `ab-perf.sh` answers "did this change move the needle" by interleaving variants
# inside a round. Neither sweeps the two knobs an operator actually turns:
#
#     workers      how many PHP processes/threads serve the site
#     opcache      whether compiled scripts survive between requests
#
# and neither reports memory, which is the cost side of the first knob. This
# script exists for that grid:
#
#     for arm in <5 servers>:
#       for workers in 12,16,20,24:
#         for opcache in on,off:
#           start the server at that configuration
#           for round in 1..ROUNDS:
#             for conc in 16,32,48,64:
#               wrk -> rps, p50, p99, errors
#             sample PSS + RSS of the whole process tree
#
# The arms are the same five `bench.sh` measures, with the same application:
#
#     volucer-worker   volucer `worker` backend       warm, pipe
#     volucer-fastcgi  volucer `spawn_cgi` backend    cold, unix socket
#     rr               RoadRunner `worker`            warm, pipe
#     frankenphp       FrankenPHP worker mode         warm, embedded (PHP 8.5)
#     fpm              nginx + php-fpm                cold, unix socket
#
# Three things about the setup are deliberate and are the difference between a
# matrix and a table of numbers that only look comparable:
#
#  1. Every arm runs as this user, from a dedicated config, with no sudo.
#     `bench.sh` installs a pool into /etc/php/8.3/fpm/pool.d and reloads the
#     host's service; that is right on a machine dedicated to one run and wrong
#     for a matrix that restarts 40 times, because it also restarts whatever else
#     the host's php-fpm is serving. Here php-fpm is started directly with `-y`
#     against a generated pool and nginx with `-p`/`-c` against a private prefix,
#     so the host's services are never touched and a failed cell cannot take them
#     down.
#
#  2. The worker count means the same thing everywhere. volucer `workers`,
#     RoadRunner `num_workers`, FrankenPHP `num`, FPM `pm.max_children` and the
#     `spawn_cgi` pool are all set to the same N, and FPM is `pm = static` for the
#     same reason the others are static: a spawn burst is process management, not
#     a request.
#
#  3. The ini is pinned per arm and then READ BACK from inside the server.
#     Hazard 28 in the volucer plan is a difference of ini mistaken for a
#     difference of server, and `opcache.enable` on this axis IS the variable
#     under test, so an arm that silently ignores it would produce a plausible
#     table of nothing. Every cell proves its mode:
#       - worker arms: the wrapper's own php reports whether opcache is active
#       - frankenphp:  the worker logs the ini its thread ended up with
#       - fpm:         a probe request through nginx reports it from inside the pool
#
# Memory is reported two ways because neither alone is honest across process
# models, which the repository already learned once (the PSS/RSS table in
# README.md): summed PSS charges a shared page once, summed RSS charges it once
# per process and therefore penalises an arm with 24 spawned PHP processes
# against an arm whose interpreter is one set of threads. Both are recorded so the
# difference stays visible instead of being argued about.
#
# Usage:
#   bash scripts/matrix.sh
#   ARMS=volucer-worker,fpm WORKERS_LIST=12 CONC=16 ROUNDS=1 DUR=3s bash scripts/matrix.sh
#
# Environment (defaults in brackets):
#   ARMS          comma list of arms                      [all five]
#   WORKERS_LIST  worker counts to sweep                  [12,16,20,24]
#   OPCACHE_MODES on,off                                  [on,off]
#   CONC          concurrency levels                      [16,32,48,64]
#   DUR           wrk duration per cell                   [5s]
#   ROUNDS        repeats per cell                        [3]
#   THREADS       wrk threads, FIXED across cells         [12]
#   ENDPOINT      the page measured                       [/items]
#   WARMUP        unmeasured load before each cell        [2s]
#   BIN / RR / FP volucer, RoadRunner, FrankenPHP binaries
#   RUNDIR        configs, logs, rows                     [$HOME/matrix-run]
#
# Output:
#   $RUNDIR/matrix.tsv   one row per (arm, workers, opcache, conc, round)
#   $RUNDIR/memory.tsv   one row per (arm, workers, opcache, phase, conc)
#   $RUNDIR/meta.txt     versions, host, effective ini, skipped cells
#
# `scripts/matrix-report.py` reads the two TSVs and writes the markdown tables.
set -uo pipefail

# The rows are TAB-separated numbers other tools read back; a comma-decimal
# locale would write `1,000` where the reader expects `1.000`.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(dirname "$SCRIPT_DIR")}"
BIN="${BIN:-$HOME/volucer-bench/target/release/volucer}"
RR="${RR:-$HOME/bin/rr}"
FP="${FP:-$HOME/bin/frankenphp}"
PHP="${PHP:-$(command -v php || true)}"
PHP_CGI="${PHP_CGI:-$(command -v php-cgi || true)}"
PHP_FPM="${PHP_FPM:-$(command -v php-fpm8.3 || command -v php-fpm || true)}"
NGINX="${NGINX:-$(command -v nginx || true)}"
RUNDIR="${RUNDIR:-$HOME/matrix-run}"

ARMS="${ARMS:-volucer-worker,volucer-fastcgi,rr,frankenphp,fpm}"
WORKERS_LIST="${WORKERS_LIST:-12,16,20,24}"
OPCACHE_MODES="${OPCACHE_MODES:-on,off}"
CONC="${CONC:-16,32,48,64}"
DUR="${DUR:-5s}"
ROUNDS="${ROUNDS:-3}"
# wrk's thread count is FIXED rather than `-t$conc`. Every harness in this
# repository used `-t$c`, which makes concurrency the CLIENT's thread count too:
# `diag-slots.sh` measured that as a p99 artifact once concurrency exceeds the
# server's worker count, and at c=64 it would put 64 busy client threads on 12
# cores. Holding it constant keeps the client's own cost constant across every arm
# and every concurrency level, which is what a cross-arm comparison needs.
THREADS="${THREADS:-12}"
ENDPOINT="${ENDPOINT:-/items}"
WARMUP="${WARMUP:-2s}"

PORT_BASE="${PORT_BASE:-18500}"
PORT_W=$((PORT_BASE + 0))
PORT_T=$((PORT_BASE + 1))
PORT_R=$((PORT_BASE + 3))
PORT_Z=$((PORT_BASE + 4))
PORT_F=$((PORT_BASE + 5))

CFG="$RUNDIR/cfg"
LOG="$RUNDIR/log"
SOCK="$RUNDIR/sock"
NGX="$RUNDIR/nginx"
RESULTS="$RUNDIR/matrix.tsv"
MEMFILE="$RUNDIR/memory.tsv"
META="$RUNDIR/meta.txt"

fail() { echo "FATAL: $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "no volucer binary at $BIN (set BIN)"
[ -f "$ROOT/composer.json" ] || fail "no checkout at $ROOT (set ROOT)"
[ -d "$ROOT/vendor" ] || fail "$ROOT/vendor is missing - run: composer install"
[ -f "$ROOT/data/bench.sqlite" ] || fail "$ROOT/data/bench.sqlite is missing - run: php seed.php"
[ -n "$PHP" ] || fail "no php on PATH"
[ -n "$PHP_CGI" ] || fail "no php-cgi on PATH"
[ -n "$PHP_FPM" ] || fail "no php-fpm on PATH"
[ -n "$NGINX" ] || fail "no nginx on PATH"
command -v wrk >/dev/null 2>&1 || fail "no wrk on PATH"

mkdir -p "$CFG" "$LOG" "$SOCK" "$NGX"
mkdir -p "$NGX/tmp/client" "$NGX/tmp/proxy" "$NGX/tmp/fastcgi" "$NGX/tmp/uwsgi" "$NGX/tmp/scgi"
chmod 0755 "$SOCK"

# ---------------------------------------------------------------------------
# The ini wrappers. One per (SAPI, mode), so an arm's mode is a file name rather
# than a `-d` list assembled at the call site and easy to get wrong in one arm.
#
#   opcache.enable_cli   what the CLI SAPI (both warm arms) reads
#   opcache.enable       what the CGI/FPM SAPI (cold arms, FPM pool) reads
#
# `validate_timestamps = 0` belongs to the ON mode only: with opcache off there is
# nothing to validate, and setting it would imply the setting mattered.
# ---------------------------------------------------------------------------
write_wrappers() {
    local mode cli_flag cgi_flag
    for mode in ${OPCACHE_MODES//,/ }; do
        if [ "$mode" = "on" ]; then
            cli_flag="-d opcache.enable_cli=1 -d opcache.validate_timestamps=0"
            cgi_flag="-d opcache.enable=1 -d opcache.validate_timestamps=0"
        else
            cli_flag="-d opcache.enable_cli=0 -d opcache.enable=0"
            cgi_flag="-d opcache.enable=0"
        fi
        printf '#!/bin/sh\nexec %s %s -d memory_limit=512M -d date.timezone=UTC -d display_errors=0 "$@"\n' \
            "$PHP" "$cli_flag" > "$CFG/php-worker-$mode"
        printf '#!/bin/sh\nexec %s %s -d memory_limit=512M -d date.timezone=UTC -d display_errors=0 "$@"\n' \
            "$PHP_CGI" "$cgi_flag" > "$CFG/php-cgi-$mode"
        chmod +x "$CFG/php-worker-$mode" "$CFG/php-cgi-$mode"
    done
}

# Prove the wrapper's mode from the outside, once, and refuse to run a matrix
# whose "off" is not off. The arms that cannot be probed offline (frankenphp, fpm)
# are proved from inside their own process instead - see assert_mode_live.
verify_wrapper_modes() {
    local mode want got
    # php-cgi has no -r (its argument parser rejects it), so the CGI wrapper is
    # asked through a file and the CLI wrapper inline.
    printf '<?php echo @opcache_get_status(false) ? 1 : 0;\n' > "$CFG/ocprobe.php"
    for mode in ${OPCACHE_MODES//,/ }; do
        want=$([ "$mode" = "on" ] && echo 1 || echo 0)
        got="$("$CFG/php-worker-$mode" -r 'echo @opcache_get_status(false) ? 1 : 0;' 2>/dev/null)"
        [ "$got" = "$want" ] ||
            fail "worker wrapper '$mode' reports opcache active=$got, expected $want"
        got="$("$CFG/php-cgi-$mode" "$CFG/ocprobe.php" 2>/dev/null | tr -dc '01')"
        [ "$got" = "$want" ] ||
            fail "cgi wrapper '$mode' reports opcache active=$got, expected $want"
        echo "  opcache $mode: cli wrapper active=$want, cgi wrapper active=$want" | tee -a "$META"
    done
}

# ---------------------------------------------------------------------------
# Process-tree accounting.
#
# Every server is a plain background job, so `$!` is the server itself and every
# PHP process it spawns descends from it. Selecting by PPID descent is what makes
# the arm's footprint its own: `ps` also lists the host's php-fpm pools and nginx
# workers, and counting those would attribute someone else's memory to whatever
# arm happens to be running. `setsid` is deliberately not used - it forks when the
# caller is already a group leader, which makes `$!` the short-lived setsid rather
# than the server, and leaves the arm untrackable.
# ---------------------------------------------------------------------------
tree_pids() {
    [ "$#" -gt 0 ] || return 0
    ps -eo pid=,ppid= 2>/dev/null | awk -v roots="$*" '
        { pid[NR] = $1; ppid[NR] = $2; n = NR }
        END {
            k = split(roots, r, " ")
            for (j = 1; j <= k; j++) if (r[j] != "") sel[r[j]] = 1
            changed = 1
            while (changed) {
                changed = 0
                for (i = 1; i <= n; i++) {
                    if (sel[pid[i]] || pid[i] == "") continue
                    if (sel[ppid[i]]) { sel[pid[i]] = 1; changed = 1 }
                }
            }
            for (i = 1; i <= n; i++) if (sel[pid[i]]) print pid[i]
        }'
}

# Summed PSS and summed RSS over the tree, plus the process count. PSS needs
# smaps_rollup (Linux 4.14+); RSS comes from /proc/PID/status.
mem_sample() {
    local pids pss=0 rss=0 n=0 p s r
    pids="$(tree_pids "$@")"
    for p in $pids; do
        n=$((n + 1))
        s="$(awk '/^Pss:/{print $2; exit}' "/proc/$p/smaps_rollup" 2>/dev/null)"
        r="$(awk '/^VmRSS:/{print $2; exit}' "/proc/$p/status" 2>/dev/null)"
        pss=$((pss + ${s:-0}))
        rss=$((rss + ${r:-0}))
    done
    echo "$pss $rss $n"
}

record_mem() { # arm workers mode phase conc
    local arm="$1" n="$2" mode="$3" phase="$4" conc="$5"
    local pss rss pids
    read -r pss rss pids <<< "$(mem_sample "${ROOTS[@]}")"
    printf '%s\t%s\t%s\t%s\t%s\t%.1f\t%.1f\t%s\n' \
        "$arm" "$n" "$mode" "$phase" "${conc:-0}" \
        "$(awk -v k="${pss:-0}" 'BEGIN{printf "%.1f", k/1024}')" \
        "$(awk -v k="${rss:-0}" 'BEGIN{printf "%.1f", k/1024}')" \
        "${pids:-0}" >> "$MEMFILE"
}

# ---------------------------------------------------------------------------
# Start / stop.
# ---------------------------------------------------------------------------
ROOTS=()

start_bg() { # logfile, then the command
    local log="$1"; shift
    "$@" >>"$log" 2>&1 &
    ROOTS+=("$!")
}

# Readiness is a 200 on the measured endpoint, not "the port answers": both
# php-cgi and nginx can accept a connection before the application is reachable,
# and a 502 arriving mid-cell would be recorded as a throughput number.
wait_ready() { # port
    local code
    for _ in $(seq 1 240); do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
            "http://127.0.0.1:$1$ENDPOINT" 2>/dev/null)"
        [ "$code" = "200" ] && return 0
        sleep 0.25
    done
    return 1
}

# A 200 is not evidence the right page was served: an nginx `try_files` mistake in
# this repository's history served the front controller's SOURCE with a happy 200.
sanity_page() { # port
    local body
    body="$(curl -sS --max-time 20 "http://127.0.0.1:$1$ENDPOINT" 2>/dev/null)"
    case "$body" in
        *"Benchmark Item"*) return 0 ;;
        "") echo "  sanity FAILED: empty body" >&2; return 1 ;;
    esac
    case "$body" in
        *"<?php"*) echo "  sanity FAILED: got PHP SOURCE (a file server served the script)" >&2 ;;
        *) echo "  sanity FAILED: 200 but no 'Benchmark Item' (${#body} bytes)" >&2 ;;
    esac
    echo "  body: $(echo "$body" | head -c 200)" >&2
    return 1
}

stop_arm() {
    local ids p i alive
    [ "${#ROOTS[@]}" -gt 0 ] || return 0
    # Collect the tree BEFORE signalling: a child re-parented to init after its
    # parent dies no longer has a PPID link back to this arm, so a tree walked
    # afterwards would miss exactly the processes that leaked.
    ids="$(tree_pids "${ROOTS[@]}")"
    for p in $ids; do kill -TERM "$p" 2>/dev/null; done
    for i in $(seq 1 60); do
        alive=0
        for p in $ids; do kill -0 "$p" 2>/dev/null && alive=1; done
        [ "$alive" = "0" ] && break
        sleep 0.25
    done
    # A pool that ignores SIGTERM must not survive into the next cell: a leaked
    # php-cgi holds a port and competes for the cores under test (hazard 28).
    for p in $ids; do kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null; done
    sleep 0.4
    ids="$(tree_pids "${ROOTS[@]}")"
    if [ -n "${ids// /}" ]; then
        echo "  LEAK: $(echo $ids | wc -w) process(es) survived SIGKILL: $ids" | tee -a "$META" >&2
    fi
    ROOTS=()
}

# ---------------------------------------------------------------------------
# Config generation. Every parameter of the matrix is a placeholder here, and the
# reason for each setting sits with the value.
# ---------------------------------------------------------------------------
cfg_volucer_worker() { # file port workers mode
    cat > "$1" <<EOF
# volucer + resident worker: warm model, pipe transport.
default_backend = "app"

[server]
http = "127.0.0.1:$2"
document_root = "$ROOT/public"

# Off, so this arm consults no document root: every other arm here runs PHP for
# every request, including one for a file that exists.
[server.static_files]
enabled = false

[backends.app]
kind = "worker"
command = "$CFG/php-worker-$4 $ROOT/worker.php"
workers = $3
working_dir = "$ROOT"
max_requests = 0
EOF
}

cfg_volucer_cgi() { # file port workers mode
    cat > "$1" <<EOF
# volucer + spawn_cgi: the cold CGI SAPI reset php-fpm performs, in a pool volucer
# supervises, over the unix-socket transport.
default_backend = "cgi"

[server]
http = "127.0.0.1:$2"
document_root = "$ROOT/public"

[server.static_files]
enabled = false

[backends.cgi]
kind = "spawn_cgi"
binary = "$CFG/php-cgi-$4"
workers = $3
socket = "unix:$SOCK/cgi"
max_requests = 0
EOF
}

cfg_rr() { # file port workers mode
    cat > "$1" <<EOF
version: "3"

server:
  command: "$CFG/php-worker-$4 $ROOT/roadrunner-worker.php"
  relay: pipes

http:
  address: "127.0.0.1:$2"
  pool:
    num_workers: $3
    max_jobs: 0

logs:
  mode: production
  level: warn
EOF
}

cfg_franken() { # file port workers mode
    local oc; oc=$([ "$4" = "on" ] && echo 1 || echo 0)
    cat > "$1" <<EOF
{
	admin off

	frankenphp {
		num_threads 1
		max_requests 0

		php_ini memory_limit 512M
		php_ini opcache.enable $oc
		php_ini opcache.validate_timestamps 0
		php_ini display_errors Off
		php_ini date.timezone UTC
	}
}

http://127.0.0.1:$2 {
	root * $ROOT/public

	# No encode, no file_server: the other arms run PHP for every request.
	php_server {
		worker {
			file $ROOT/frankenphp-worker.php
			num $3
			# Without \`match\`, php_server serves the worker only for .php paths and
			# every other path silently takes the COLD handler - a correct 200 from
			# a server wearing the warm arm's name.
			match /*
		}
	}
}
EOF
}

cfg_fpm() { # file workers mode socket
    # opcache is a zend_extension whose enable flag is read at STARTUP. Measured on
    # this host, `php_admin_flag[opcache.enable] = 0` in the pool sets ini_get() to
    # '0' while opcache stays ACTIVE (it is applied after the extension has already
    # decided), so the pool cannot express the OFF mode. The mode is therefore
    # passed to the php-fpm master as `-d`, which the children inherit — verified
    # through a request, per cell, by assert_mode_live.
    cat > "$1" <<EOF
; php-fpm started directly (-y -F): no systemd service, no pool.d, no sudo, so the
; host's own pools are never restarted by this matrix.
[global]
daemonize = no
error_log = $LOG/fpm-error.log

[bench]
listen = $4
pm = static
pm.max_children = $2
pm.max_requests = 0

catch_workers_output = yes
php_admin_value[error_log] = $LOG/fpm-worker-error.log
php_admin_flag[log_errors] = on

php_admin_value[memory_limit] = 512M
php_admin_value[date.timezone] = UTC
EOF
}

cfg_nginx() { # file port socket
    cat > "$1" <<EOF
# A private nginx instance (-p/-c), not the host's: this matrix restarts the FPM
# arm eight times and must not reload a server that is serving something else.
daemon off;
worker_processes 4;
error_log $NGX/error.log warn;
pid $NGX/nginx.pid;

events { worker_connections 4096; }

http {
    access_log off;

    client_body_temp_path $NGX/tmp/client;
    proxy_temp_path       $NGX/tmp/proxy;
    fastcgi_temp_path     $NGX/tmp/fastcgi;
    uwsgi_temp_path       $NGX/tmp/uwsgi;
    scgi_temp_path        $NGX/tmp/scgi;

    fastcgi_read_timeout 30s;
    fastcgi_send_timeout 30s;

    server {
        listen 127.0.0.1:$2;
        server_name bench.local;
        root $ROOT/public;

        # Everything to the front controller, including a path that names a file:
        # the other arms route everything through the application too.
        location / {
            # An absolute path: with \`-p \$NGX\` the prefix is the run directory, so a
            # bare \`include fastcgi_params\` would look inside it and fail.
            include /etc/nginx/fastcgi_params;
            fastcgi_pass unix:$3;
            fastcgi_param SCRIPT_FILENAME $ROOT/public/index.php;
            fastcgi_param REQUEST_URI \$request_uri;
            fastcgi_param DOCUMENT_ROOT $ROOT/public;
        }

        # Diagnostic only: the pool's EFFECTIVE ini, read by a request rather than
        # trusted from the file. \`php_admin_flag[opcache.enable]\` is the value this
        # matrix claims to vary, so it is proved per cell.
        location = /.bench-ini-probe.php {
            include /etc/nginx/fastcgi_params;
            fastcgi_pass unix:$3;
            fastcgi_param SCRIPT_FILENAME $ROOT/public/.bench-ini-probe.php;
        }
    }
}
EOF
}

# ---------------------------------------------------------------------------
# Per-arm start. Each records the pids it started in ROOTS.
# ---------------------------------------------------------------------------
start_arm() { # arm workers mode
    local arm="$1" n="$2" mode="$3"
    ROOTS=()
    case "$arm" in
        volucer-worker)
            cfg_volucer_worker "$CFG/$arm-$n-$mode.toml" "$PORT_W" "$n" "$mode"
            start_bg "$LOG/$arm-$n-$mode.log" "$BIN" serve -c "$CFG/$arm-$n-$mode.toml"
            ;;
        volucer-fastcgi)
            cfg_volucer_cgi "$CFG/$arm-$n-$mode.toml" "$PORT_T" "$n" "$mode"
            start_bg "$LOG/$arm-$n-$mode.log" "$BIN" serve -c "$CFG/$arm-$n-$mode.toml"
            ;;
        rr)
            cfg_rr "$CFG/$arm-$n-$mode.yaml" "$PORT_R" "$n" "$mode"
            # RoadRunner resolves the worker command relative to its CWD.
            ( cd "$ROOT" && exec "$RR" serve -c "$CFG/$arm-$n-$mode.yaml" ) \
                >>"$LOG/$arm-$n-$mode.log" 2>&1 &
            ROOTS+=("$!")
            ;;
        frankenphp)
            cfg_franken "$CFG/$arm-$n-$mode.caddyfile" "$PORT_Z" "$n" "$mode"
            start_bg "$LOG/$arm-$n-$mode.log" "$FP" run \
                --config "$CFG/$arm-$n-$mode.caddyfile" --adapter caddyfile
            ;;
        fpm)
            rm -f "$SOCK/fpm.sock"
            cfg_fpm "$CFG/$arm-$n-$mode.conf" "$n" "$mode" "$SOCK/fpm.sock"
            cfg_nginx "$CFG/nginx-$n-$mode.conf" "$PORT_F" "$SOCK/fpm.sock"
            # See cfg_fpm: the opcache mode has to reach the master, not the pool.
            local oc; oc=$([ "$mode" = "on" ] && echo 1 || echo 0)
            start_bg "$LOG/$arm-$n-$mode-fpm.log" "$PHP_FPM" -y "$CFG/$arm-$n-$mode.conf" -F \
                -d opcache.enable="$oc" -d opcache.validate_timestamps=0
            # nginx may start before the socket exists; it fails per request until
            # then, and wait_ready below is what proves the pair works.
            start_bg "$LOG/$arm-$n-$mode-nginx.log" "$NGINX" -p "$NGX" -c "$CFG/nginx-$n-$mode.conf"
            ;;
        *) fail "unknown arm '$arm'" ;;
    esac
}

port_of() {
    case "$1" in
        volucer-worker)  echo "$PORT_W" ;;
        volucer-fastcgi) echo "$PORT_T" ;;
        rr)              echo "$PORT_R" ;;
        frankenphp)      echo "$PORT_Z" ;;
        fpm)             echo "$PORT_F" ;;
    esac
}

# ---------------------------------------------------------------------------
# Prove the opcache mode INSIDE the running server.
#
# This is the check that keeps the matrix honest: `opcache.enable` is the
# independent variable, and every mechanism that sets it (the Caddyfile's
# `php_ini`, the pool's `php_admin_flag`, a wrapper's `-d`) can be silently
# misapplied while the arm still serves a correct 200. The warm arms are proved
# offline by verify_wrapper_modes; these two are proved live.
# ---------------------------------------------------------------------------
assert_mode_live() { # arm workers mode
    local arm="$1" n="$2" mode="$3" want active log
    want=$([ "$mode" = "on" ] && echo 1 || echo 0)
    case "$arm" in
        frankenphp)
            log="$LOG/$arm-$n-$mode.log"
            active="$(grep -oE 'opcache=(true|false)' "$log" 2>/dev/null | head -1 | cut -d= -f2)"
            if [ -z "$active" ]; then
                echo "  mode check [$arm/$mode]: FAILED - the worker logged no ini line" |
                    tee -a "$META" >&2
                return 1
            fi
            if [ "$active" != "$([ "$want" = "1" ] && echo true || echo false)" ]; then
                echo "  mode check [$arm/$mode]: FAILED - the worker reports opcache=$active" |
                    tee -a "$META" >&2
                return 1
            fi
            ;;
        fpm)
            local body
            body="$(curl -sS --max-time 10 "http://127.0.0.1:$PORT_F/.bench-ini-probe.php" 2>/dev/null)"
            case "$body" in
                *"active=1"*) active=1 ;;
                *"active=0"*) active=0 ;;
                *)
                    echo "  mode check [$arm/$mode]: FAILED - the probe returned '$body'" |
                        tee -a "$META" >&2
                    return 1
                    ;;
            esac
            if [ "$active" != "$want" ]; then
                echo "  mode check [$arm/$mode]: FAILED - the pool reports active=$active" |
                    tee -a "$META" >&2
                return 1
            fi
            ;;
        *) return 0 ;;   # proved offline by verify_wrapper_modes
    esac
}

# ---------------------------------------------------------------------------
# One cell: wrk for DUR at a fixed concurrency, then the memory sample.
# ---------------------------------------------------------------------------
run_cell() { # arm workers mode conc round
    local arm="$1" n="$2" mode="$3" conc="$4" round="$5"
    local port; port="$(port_of "$arm")"
    local out="$LOG/wrk-$arm-$n-$mode-c$conc-r$round.txt"
    local rps p50 p99 p999 errs

    wrk -t"$THREADS" -c"$conc" -d"$DUR" --latency "http://127.0.0.1:$port$ENDPOINT" \
        > "$out" 2>&1

    rps="$(awk '/^Requests\/sec:/{print $2; exit}' "$out")"
    p50="$(awk '/^[[:space:]]+50%/{print $2; exit}' "$out")"
    p99="$(awk '/^[[:space:]]+99%/{print $2; exit}' "$out")"
    # A bounded pool converts a latency tail into a throughput number by shedding,
    # which looks exactly like the fix working. Record it rather than assume not.
    errs="$(grep -cE 'Non-2xx or 3xx responses|Socket errors' "$out" 2>/dev/null)"

    if [ -z "$rps" ] || [ -z "$p50" ] || [ -z "$p99" ]; then
        printf '%s\t%s\t%s\t%s\t%s\tFAIL\t?\t?\t%s\n' \
            "$arm" "$n" "$mode" "$conc" "$round" "$errs" >> "$RESULTS"
        printf '    %-15s w=%-2s %-3s c=%-3s r=%s  FAILED (incomplete wrk output)\n' \
            "$arm" "$n" "$mode" "$conc" "$round"
        return 1
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$arm" "$n" "$mode" "$conc" "$round" "$rps" "$p50" "$p99" "$errs" >> "$RESULTS"
    printf '    %-15s w=%-2s %-3s c=%-3s r=%s  %9s rps  p50 %8s  p99 %8s\n' \
        "$arm" "$n" "$mode" "$conc" "$round" "$rps" "$p50" "$p99"
}

# ---------------------------------------------------------------------------
# Header + preflight
# ---------------------------------------------------------------------------
: > "$RESULTS"
: > "$MEMFILE"
: > "$META"

{
    echo "=== worker x opcache x concurrency matrix ==="
    echo "  host:        $(nproc) cores, $(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo) MB"
    echo "  kernel:      $(uname -sr)"
    echo "  php:         $($PHP -v | head -1)"
    echo "  php-cgi:     $($PHP_CGI -v | head -1)"
    echo "  php-fpm:     $($PHP_FPM -v | head -1)"
    echo "  nginx:       $($NGINX -v 2>&1 | head -1)"
    echo "  volucer:     $($BIN version 2>/dev/null | head -1)"
    echo "  roadrunner:  $($RR --version 2>/dev/null | head -1)"
    echo "  frankenphp:  $($FP version 2>/dev/null | head -1)"
    echo "  app:         $ROOT"
    echo "  app ref:     $(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null || echo '(no git)')"
    echo "  arms:        $ARMS"
    echo "  workers:     $WORKERS_LIST"
    echo "  opcache:     $OPCACHE_MODES"
    echo "  endpoint:    $ENDPOINT"
    echo "  concurrency: $CONC   wrk threads: $THREADS   duration: $DUR   rounds: $ROUNDS"
} | tee "$META"

write_wrappers
verify_wrapper_modes

# opcache.file_update_protection defaults to 2 seconds and refuses to cache a file
# whose mtime is newer than that. A checkout touched immediately before the run
# would therefore miss the opcache on EVERY request by design - indistinguishable
# from opcache not surviving between requests, which is the ON mode's whole point.
newest="$(find "$ROOT" -name '*.php' -newermt '-3 seconds' -print -quit 2>/dev/null)"
if [ -n "$newest" ]; then
    echo "  a .php file was modified in the last 3s ($newest); waiting 3s"
    sleep 3
fi

# The FPM probe file. It lives only for the duration of the run and is removed by
# the trap; `public/` is otherwise untouched.
cat > "$ROOT/public/.bench-ini-probe.php" <<'PROBE'
<?php
header('Content-Type: text/plain');
$st = @opcache_get_status(false);
printf("opcache_enable=%s active=%d validate=%s memory=%s\n",
    ini_get('opcache.enable'), $st ? 1 : 0,
    ini_get('opcache.validate_timestamps'), ini_get('memory_limit'));
PROBE

cleanup_probe() { rm -f "$ROOT/public/.bench-ini-probe.php"; }
trap 'stop_arm; cleanup_probe' EXIT

printf 'arm\tworkers\topcache\tconc\tround\trps\tp50\tp99\terrors\n' >> "$RESULTS"
printf 'arm\tworkers\topcache\tphase\tconc\tpss_mb\trss_mb\tpids\n' >> "$MEMFILE"

# ---------------------------------------------------------------------------
# The grid.
# ---------------------------------------------------------------------------
for arm in ${ARMS//,/ }; do
    echo
    echo "=============================================================="
    echo " ARM $arm"
    echo "=============================================================="
    for n in ${WORKERS_LIST//,/ }; do
        for mode in ${OPCACHE_MODES//,/ }; do
            echo "--------------------------------------------------------------"
            echo " $arm  workers=$n  opcache=$mode"
            echo "--------------------------------------------------------------"

            start_arm "$arm" "$n" "$mode"

            if ! wait_ready "$(port_of "$arm")"; then
                echo "  NOT MEASURED: never answered 200 on $(port_of "$arm")$ENDPOINT"
                tail -6 "$LOG/$arm-$n-$mode.log" 2>/dev/null | sed 's/^/    /'
                echo "SKIP $arm w=$n $mode: not ready" >> "$META"
                stop_arm
                continue
            fi
            if ! sanity_page "$(port_of "$arm")"; then
                echo "  NOT MEASURED: the page did not render"
                echo "SKIP $arm w=$n $mode: bad page" >> "$META"
                stop_arm
                continue
            fi
            if ! assert_mode_live "$arm" "$n" "$mode"; then
                echo "  NOT MEASURED: the opcache mode could not be proved"
                stop_arm
                continue
            fi

            # Boot footprint: what this configuration costs before it serves
            # anything. That is the number a host is sized from.
            record_mem "$arm" "$n" "$mode" boot 0

            # First touch: compiles every file under the ON modes, wakes every
            # worker under the cold ones. Not part of any measurement.
            wrk -t"$THREADS" -c"$THREADS" -d"$WARMUP" \
                "http://127.0.0.1:$(port_of "$arm")$ENDPOINT" >/dev/null 2>&1

            for round in $(seq 1 "$ROUNDS"); do
                for conc in ${CONC//,/ }; do
                    run_cell "$arm" "$n" "$mode" "$conc" "$round"
                done
                # After the hardest cell of the round, not between cells: a sample
                # taken mid-round would describe a pool that is still warming.
                record_mem "$arm" "$n" "$mode" post \
                    "$(echo "${CONC//,/ }" | awk '{print $NF}')"
            done

            stop_arm
            echo "  done: $arm workers=$n opcache=$mode"
        done
    done
done

stop_arm
cleanup_probe

echo
echo "=============================================================="
echo " results"
echo "=============================================================="
echo "  raw:    $RESULTS"
echo "  memory: $MEMFILE"
echo "  meta:   $META"
strays="$(ps -eo pid=,args= | awk '/php-cgi/ && $0 !~ /awk/ { n++ } END { print n+0 }')"
echo "  stray php-cgi processes after teardown: $strays"
echo
echo "  report: python3 scripts/matrix-report.py $RESULTS $MEMFILE"
