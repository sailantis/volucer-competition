#!/bin/bash
# What does replacing a worker cost?
#
# Every number in this repository was measured with `max_requests = 0`, so nothing here
# has ever charged an arm for recycling. That is the gap this fills, and it decides a real
# operational question: if replacing a worker is cheap, an application that leaks can be
# bounded aggressively instead of tolerated, and "recycle every 500 requests" stops being a
# compromise.
#
# The three warm arms recycle in three different ways, which is the actual subject:
#
#   P  worker   `exec` a fresh PHP process. Pays interpreter start, autoload, the framework
#               boot, and its own OPcache segment - the thing `fork` exists to avoid.
#   A  attach   close the connection and dial the relay again. The supervisor forks a
#               replacement from its booted master, so the cost is a fork() and a handshake.
#   F  fpm      php-fpm reaps the child and `fork`s a new one from its master. The reference
#               implementation of cheap recycling, and the standard the other two should be
#               held to.
#
# Two arms, because a throughput number alone cannot separate "the replacement cost
# throughput" from "the replacement cost the pool a slot for a moment":
#
#   1. isolation  w=1, c=1, max_requests=1: EVERY request pays a full replacement. The
#                 result is the replacement cost as a number - requests per second becomes
#                 the reciprocal of "fork/exec + handshake (+ boot)". This is the measurement
#                 that answers the question.
#   2. sweep      w=16, c=64, a range of max_requests: what it costs under real load, where
#                 a replacement happens in one slot while fifteen others serve. This is the
#                 number an operator would use to pick a threshold.
#
# The isolated arm is deliberately reported as "requests/sec" and "ms per replacement"
# rather than as a latency percentile: at c=1 every request IS a replacement, so the two
# are the same number and the honest label is the one that says so.
#
# Usage:
#   bash scripts/recycle-cost.sh              # both arms, all three servers
#   ARMS=P,A bash scripts/recycle-cost.sh     # just volucer worker vs attach
#   SKIP_FPM=1 bash scripts/recycle-cost.sh   # no sudo, no php-fpm
#
# Environment:
#   BIN        volucer release binary      [$HOME/volucer-bench/target/release/volucer]
#   ROOT       competition checkout        [the parent of this script]
#   PHP        CLI interpreter             [php8.5, else php]
#   ARMS       which warm arms to run      [P,A,F]
#   SWEEP      max_requests values         [0,100,500,2000]
#   WORKERS    workers for the sweep       [16]
#   CONC       concurrency for the sweep   [64]
#   THREADS    wrk threads, fixed          [12]
#   DUR        wrk duration per cell       [5s]
#   WARMUP     unmeasured load per cell    [2s]
#   ROUNDS     repeats per cell            [3]
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(dirname "$SCRIPT_DIR")}"
BIN="${BIN:-$HOME/volucer-bench/target/release/volucer}"
PHP="${PHP:-$(command -v php8.5 || command -v php)}"
ARMS="${ARMS:-P,A,F}"
SWEEP="${SWEEP:-0,100,500,2000}"
WORKERS="${WORKERS:-16}"
CONC="${CONC:-64}"
THREADS="${THREADS:-12}"
DUR="${DUR:-5s}"
WARMUP="${WARMUP:-2s}"
ROUNDS="${ROUNDS:-3}"
SKIP_FPM="${SKIP_FPM:-0}"
ENDPOINT="${ENDPOINT:-/items}"
D="$(mktemp -d /tmp/recycle-cost.XXXXXX)"

PORTS_P=19050
PORTS_A=19052
PORTS_F=19054

RESULTS="$D/results.tsv"
printf 'arm\tphase\tmax_requests\tworkers\tconc\tround\trps\tp50\tp99\terrors\n' > "$RESULTS"

fail() { echo "FATAL: $*" >&2; exit 1; }

cleanup() {
    [ -n "${VP:-}" ] && kill "$VP" 2>/dev/null
    [ -n "${SUP:-}" ] && kill -KILL "$SUP" 2>/dev/null
    pkill -KILL -f "$D" 2>/dev/null
    pkill -KILL -f "worker.php --prefork unix:$D" 2>/dev/null
    # The supervisor's children are forked by it, so a SIGKILL to the master leaves
    # the child serving the connection that was open when it died. `pkill -f "$D"` above
    # catches them because their command line carries the relay path.
    if [ "$fpm_installed" = "1" ]; then
        sudo rm -f /etc/php/*/fpm/pool.d/bench-recycle.conf 2>/dev/null
        sudo rm -f /etc/nginx/sites-enabled/bench-recycle.conf 2>/dev/null
        sudo systemctl restart "$FPM_SERVICE" 2>/dev/null
        sudo systemctl reload nginx 2>/dev/null
    fi
    rm -rf "$D"
}
trap cleanup EXIT

[ -x "$BIN" ] || fail "no volucer at $BIN (set BIN)"
[ -f "$ROOT/worker.php" ] || fail "no $ROOT/worker.php"
[ -f "$ROOT/data/bench.sqlite" ] || fail "$ROOT/data/bench.sqlite is missing - run: php seed.php"
command -v wrk >/dev/null 2>&1 || fail "no wrk on PATH"

# A php-cgi left behind by another script keeps a port bound and the next run then
# measures a server it never started.
pkill -KILL -f 'worker.php --prefork' 2>/dev/null
pkill -KILL -f 'volucer serve -c /tmp/recycle-cost' 2>/dev/null
sleep 0.3

# The wrappers, matching `matrix.sh`: opcache on for every arm here, because the
# question is about recycling and a cold interpreter would answer a different one.
# `validate_timestamps=0` is what every published warm number was measured with.
cat > "$D/php-worker" <<WRAPPER
#!/bin/sh
exec $PHP -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 -d memory_limit=512M -d date.timezone=UTC -d display_errors=0 "\$@"
WRAPPER
chmod +x "$D/php-worker"

FPM_SERVICE=""
fpm_installed=0
for unit in php8.3-fpm php8.5-fpm php-fpm; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${unit}\.service"; then
        FPM_SERVICE="$unit"
        break
    fi
done

wait_ready() {
    local url="$1" tries="${2:-240}"
    for _ in $(seq 1 "$tries"); do
        [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$url")" = "200" ] && return 0
        sleep 0.25
    done
    return 1
}

# One wrk run, reduced to the four numbers the table needs.
measure() { # port round
    local port="$1" round="$2" out="$D/wrk-$port-$round.txt"
    local rps p50 p99 errs

    wrk -t"$THREADS" -c"$CONC" -d"$DUR" --latency "http://127.0.0.1:$port$ENDPOINT" >"$out" 2>&1

    rps="$(awk '/^Requests\/sec:/{print $2; exit}' "$out")"
    p50="$(awk '/^[[:space:]]+50%/{print $2; exit}' "$out")"
    p99="$(awk '/^[[:space:]]+99%/{print $2; exit}' "$out")"
    # Recycling can convert a lost request into a 5xx, which looks like the server
    # working if only throughput is read.
    errs="$(grep -cE 'Non-2xx or 3xx responses|Socket errors' "$out" 2>/dev/null || true)"

    if [ -z "$rps" ]; then
        echo "FAIL ? ? ${errs:-0}"
        return 1
    fi
    echo "$rps $p50 $p99 ${errs:-0}"
}

# One connection, one worker, no warmup. Used for both isolated phases, because they
# differ only in `max_requests` and a second code path would be a second thing to get
# wrong.
measure_isolated() { # port round tag
    local port="$1" round="$2" tag="$3"
    # Two statements, not one. `local a=1 b=$a` marks every name local *before* it
    # assigns any of them, so `out="...$tag..."` in the same `local` reads an
    # as-yet-unset `tag` and dies with "tag: unbound variable" under `set -u`. That
    # is not hypothetical: it is how the first tagged version failed.
    local out="$D/iso-$tag-$port-$round.txt"
    local rps p50 errs
    wrk -t1 -c1 -d"$DUR" --latency "http://127.0.0.1:$port$ENDPOINT" >"$out" 2>&1
    rps="$(awk '/^Requests\/sec:/{print $2; exit}' "$out")"
    p50="$(awk '/^[[:space:]]+50%/{print $2; exit}' "$out")"
    errs="$(grep -cE 'Non-2xx or 3xx responses|Socket errors' "$out" 2>/dev/null || true)"
    if [ -z "$rps" ]; then
        echo "FAIL ? ${errs:-0}"
        return 1
    fi
    echo "$rps $p50 ${errs:-0}"
}

run_volucer_arm() { # arm port max_requests phase round
    local arm="$1" port="$2" max="$3" phase="$4" round="$5"
    local config="$D/$arm-$max-$phase.toml" rps p50 p99 errs

    cat > "$config" <<EOF
default_backend = "app"

[server]
http = "127.0.0.1:$port"
document_root = "$ROOT/public"

[server.static_files]
enabled = false

[backends.app]
kind = "worker"
command = "$D/php-worker $ROOT/worker.php"
workers = $([ "$phase" = "sweep" ] && echo "$WORKERS" || echo 1)
working_dir = "$ROOT"
max_requests = $max
EOF

    "$BIN" serve -c "$config" > "$D/$arm-$max-$round.log" 2>&1 &
    VP=$!
    if ! wait_ready "http://127.0.0.1:$port$ENDPOINT"; then
        echo "FAIL ? ? ?"
        sed 's/^/    /' "$D/$arm-$max-$round.log" | head -5
        kill -KILL "$VP" 2>/dev/null
        VP=""
        return 1
    fi

    if [ "$phase" = "sweep" ]; then
        wrk -t"$THREADS" -c"$CONC" -d"$WARMUP" "http://127.0.0.1:$port$ENDPOINT" >/dev/null 2>&1
        read -r rps p50 p99 errs <<<"$(measure "$port" "$round")"
    else
        # No warmup at either isolated phase, so the two differ only in max_requests.
        read -r rps p50 errs <<<"$(measure_isolated "$port" "$round" "$arm-$phase")"
        p99="?"
    fi

    kill "$VP" 2>/dev/null
    wait "$VP" 2>/dev/null
    VP=""

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$arm" "$phase" "$max" \
        "$([ "$phase" = "sweep" ] && echo "$WORKERS" || echo 1)" \
        "$([ "$phase" = "sweep" ] && echo "$CONC" || echo 1)" "$round" \
        "$rps" "$p50" "$p99" "$errs" >> "$RESULTS"
    echo "$rps $p50 $p99 $errs"
}

run_attach_arm() { # port max_requests phase round
    local port="$1" max="$2" phase="$3" round="$4"
    local n="$([ "$phase" = "sweep" ] && echo "$WORKERS" || echo 1)"
    local relay="$D/relay-$port.sock"
    local rps p50 p99 errs

    # A socket file left by a SIGKILLed supervisor is still `-S`, so a readiness check
    # that only tests for the file passes instantly against a listener that is gone —
    # and volucer then fails at startup with "Connection refused" on a path that exists.
    # That is exactly what happened on the first run: the isolation arm was killed, its
    # socket stayed, and every sweep round after it failed to start.
    rm -f "$relay"

    "$D/php-worker" "$ROOT/worker.php" --prefork "unix:$relay" > "$D/sup-$port-$round.out" 2>&1 &
    SUP=$!
    # The supervisor's own readiness line, on stderr, once the listener exists. Waiting for it
    # rather than for the socket path is what makes the `rm` above belt and braces rather than
    # load-bearing.
    for _ in $(seq 1 300); do
        kill -0 "$SUP" 2>/dev/null || break
        grep -q 'listening on' "$D/sup-$port-$round.out" 2>/dev/null && break
        sleep 0.1
    done
    if ! grep -q 'listening on' "$D/sup-$port-$round.out" 2>/dev/null; then
        echo "FAIL ? ? ?"
        sed 's/^/    /' "$D/sup-$port-$round.out" | head -5
        SUP=""
        return 1
    fi

    cat > "$D/attach-$port-$max.toml" <<EOF
default_backend = "app"

[server]
http = "127.0.0.1:$port"
document_root = "$ROOT/public"

[server.static_files]
enabled = false

[backends.app]
kind = "attach"
relay = "unix:$relay"
workers = $n
max_requests = $max
EOF

    "$BIN" serve -c "$D/attach-$port-$max.toml" > "$D/attach-$port-$max-$round.log" 2>&1 &
    VP=$!
    if ! wait_ready "http://127.0.0.1:$port$ENDPOINT"; then
        echo "FAIL ? ? ?"
        sed 's/^/    /' "$D/attach-$port-$max-$round.log" | head -5
        kill -KILL "$VP" 2>/dev/null; VP=""
        kill -KILL "$SUP" 2>/dev/null; SUP=""
        return 1
    fi

    if [ "$phase" = "sweep" ]; then
        wrk -t"$THREADS" -c"$CONC" -d"$WARMUP" "http://127.0.0.1:$port$ENDPOINT" >/dev/null 2>&1
        read -r rps p50 p99 errs <<<"$(measure "$port" "$round")"
    else
        read -r rps p50 errs <<<"$(measure_isolated "$port" "$round" "A-$phase")"
        p99="?"
    fi

    kill "$VP" 2>/dev/null; wait "$VP" 2>/dev/null; VP=""
    kill -KILL "$SUP" 2>/dev/null; wait "$SUP" 2>/dev/null; SUP=""

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "A" "$phase" "$max" "$n" \
        "$([ "$phase" = "sweep" ] && echo "$CONC" || echo 1)" "$round" \
        "$rps" "$p50" "$p99" "$errs" >> "$RESULTS"
    echo "$rps $p50 $p99 $errs"
}

# --- php-fpm, the reference ---------------------------------------------------
#
# Installed as a pool + an nginx vhost for the duration, then removed. This mirrors
# `bench.sh`, which is the harness the published FPM numbers came from; anything
# different here would make the reference a different server.
setup_fpm() {
    if [ "$SKIP_FPM" = "1" ]; then echo "  (SKIP_FPM=1)"; return 1; fi
    [ -n "$FPM_SERVICE" ] || { echo "  (no php-fpm installed)"; return 1; }
    command -v nginx >/dev/null 2>&1 || { echo "  (no nginx installed)"; return 1; }
    sudo -n true 2>/dev/null || { echo "  (no passwordless sudo)"; return 1; }

    local pool_dir
    case "$FPM_SERVICE" in
        php8.3-fpm) pool_dir=/etc/php/8.3 ;;
        php8.5-fpm) pool_dir=/etc/php/8.5 ;;
        *)          pool_dir=/etc/php/8.3 ;;
    esac
    FPM_POOL_DIR="$pool_dir/fpm/pool.d"
    [ -d "$FPM_POOL_DIR" ] || { echo "  (no $FPM_POOL_DIR)"; return 1; }
    FPM_BIN="$(command -v "php-fpm${pool_dir##*/}" || command -v php-fpm || true)"
    [ -n "$FPM_BIN" ] || { echo "  (no php-fpm binary for $pool_dir)"; return 1; }

    # xdebug loaded into the pool is worth 3.1x on this host, which is more than any
    # difference this script measures. Same treatment as bench.sh: remove the conf.d
    # file rather than setting `xdebug.mode = off`, which leaves it loaded and empty.
    XDEBUG_INI="$(ls "$pool_dir"/fpm/conf.d/*xdebug*.ini 2>/dev/null | head -1)"
    if [ -n "$XDEBUG_INI" ]; then
        sudo mv "$XDEBUG_INI" "$XDEBUG_INI.recycle-bench" 2>/dev/null &&
            echo "  disabled php-fpm xdebug: $XDEBUG_INI moved aside"
    fi

    sudo rm -f /etc/php/*/fpm/pool.d/bench-recycle.conf 2>/dev/null
    FPM_USER="$(id -un)"
    FPM_GROUP="$(id -gn)"
    fpm_installed=1
    return 0
}

write_fpm_pool() { # socket max_requests workers
    local socket="$1" max="$2" n="$3"
    # Not `/etc/php/*/...`: `/etc/php` is not readable by the unprivileged user, so the
    # glob never expands and `tee` is handed the literal pattern â€” which fails with
    # "No such file or directory" and looks like a missing php-fpm. `FPM_POOL_DIR` is
    # resolved once in `setup_fpm`, where the version is known.
    sudo tee "$FPM_POOL_DIR/bench-recycle.conf" >/dev/null <<EOF
[bench]
listen = $socket
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = static
pm.max_children = $n
pm.max_requests = $max
user = $FPM_USER
group = $FPM_GROUP
catch_workers_output = yes
php_admin_value[memory_limit] = 512M
php_admin_flag[opcache.enable] = 1
php_admin_value[opcache.validate_timestamps] = 0
php_admin_value[date.timezone] = UTC
EOF
}

run_fpm_arm() { # port max_requests phase round
    local port="$1" max="$2" phase="$3" round="$4"
    local n="$([ "$phase" = "sweep" ] && echo "$WORKERS" || echo 1)"
    local socket="/run/php-fpm-bench/recycle.sock"
    local rps p50 p99 errs

    write_fpm_pool "$socket" "$max" "$n" || { echo "FAIL ? ? ?"; return 1; }
    sudo rm -f "$socket" 2>/dev/null
    if ! sudo "$FPM_BIN" -t >/dev/null 2>&1; then
        echo "FAIL ? ? ?"; return 1
    fi
    sudo systemctl restart "$FPM_SERVICE" || { echo "FAIL ? ? ?"; return 1; }
    for _ in $(seq 1 60); do [ -S "$socket" ] && break; sleep 0.25; done

    cat > "$D/nginx-recycle.conf" <<EOF
server {
    listen 127.0.0.1:$port;
    server_name _;
    root $ROOT/public;
    index index.php;
    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }
    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:$socket;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF
    sudo cp "$D/nginx-recycle.conf" /etc/nginx/sites-enabled/bench-recycle.conf
    sudo nginx -t >/dev/null 2>&1 || { echo "FAIL ? ? ?"; return 1; }
    sudo systemctl reload nginx 2>/dev/null || sudo nginx -s reload 2>/dev/null
    if ! wait_ready "http://127.0.0.1:$port$ENDPOINT" 120; then
        echo "FAIL ? ? ?"; return 1
    fi

    if [ "$phase" = "sweep" ]; then
        wrk -t"$THREADS" -c"$CONC" -d"$WARMUP" "http://127.0.0.1:$port$ENDPOINT" >/dev/null 2>&1
        read -r rps p50 p99 errs <<<"$(measure "$port" "$round")"
    else
        read -r rps p50 errs <<<"$(measure_isolated "$port" "$round" "F-$phase")"
        p99="?"
    fi

    printf 'F\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$phase" "$max" "$n" \
        "$([ "$phase" = "sweep" ] && echo "$CONC" || echo 1)" "$round" \
        "$rps" "$p50" "$p99" "$errs" >> "$RESULTS"
    echo "$rps $p50 $p99 $errs"
}

# --- driver -------------------------------------------------------------------
median_of() { # arm phase max
    awk -F'\t' -v a="$1" -v p="$2" -v m="$3" '
        $1 == a && $2 == p && $3 == m && $7 != "FAIL" { v[NR] = $0 }
        END {
            # Sort by the rps field (7) and print the middle row, so the reported
            # numbers are one real run rather than an average of three.
            n = 0
            for (k in v) { n++; rows[n] = v[k] }
            for (i = 1; i < n; i++)
                for (j = i + 1; j <= n; j++) {
                    split(rows[i], x, "\t"); split(rows[j], y, "\t")
                    if (x[7] + 0 > y[7] + 0) { t = rows[i]; rows[i] = rows[j]; rows[j] = t }
                }
            if (n == 0) { print "FAIL\t?\t?"; exit }
            split(rows[int((n + 1) / 2)], z, "\t")
            print z[7] "\t" z[8] "\t" z[9]
        }
    ' "$RESULTS"
}

report() {
    echo
    echo "=== 1. the cost of one replacement ==="
    echo "    w=1, c=1. Baseline is max_requests=0: one worker answering one request at a time."
    echo "    Isolation is max_requests=1: every request destroys its worker first."
    echo "    The difference between the two per-request times is what a replacement costs -"
    echo "    and it is the number that decides whether recycling is cheap enough to be policy."
    echo
    printf '    %-4s %10s %10s %12s %9s %12s\n' \
        arm base_ms iso_ms repl_ms share_of_req "x base"
    for arm in P A F; do
        case ",$ARMS," in *",$arm,"*) ;; *) continue ;; esac
        [ "$arm" = "F" ] && [ "$fpm_ready" != "1" ] && continue
        read -r base_rps _ _ <<<"$(median_of "$arm" baseline 0)"
        read -r iso_rps _ _ <<<"$(median_of "$arm" isolation 1)"
        if [ "$base_rps" = "FAIL" ] || [ "$iso_rps" = "FAIL" ]; then
            printf '    %-4s %10s %10s %12s\n' "$arm" FAILED FAILED -
            continue
        fi
        # One `awk`, printed directly. A `read` over a heredoc containing a command
        # substitution reads the substitution's *unexpanded* text as the fields, which
        # is how the first version produced empty columns and a division by zero.
        awk -v a="$arm" -v b="$base_rps" -v i="$iso_rps" 'BEGIN {
            bm = 1000 / b; im = 1000 / i; d = im - bm;
            printf "    %-4s %10.2f %10.2f %12.2f %8.0f%% %11.1fx\n",
                   a, bm, im, d, (im > 0 ? d / im * 100 : 0), (bm > 0 ? im / bm : 0)
        }'
    done

    echo
    echo "=== 2. under load: ${WORKERS} workers, c=${CONC}, t=${THREADS} ==="
    echo "    A replacement in one slot while fifteen others serve. mr=0 is the control:"
    echo "    it must reproduce the published ${WORKERS}x${CONC} number or the harness differs."
    echo
    printf '    %-4s %8s %10s %10s %10s %8s\n' arm mr rps p50 p99 errs
    for arm in P A F; do
        case ",$ARMS," in *",$arm,"*) ;; *) continue ;; esac
        [ "$arm" = "F" ] && [ "$fpm_ready" != "1" ] && continue
        for max in ${SWEEP//,/ }; do
            read -r rps p50 p99 <<<"$(median_of "$arm" sweep "$max")"
            if [ "$rps" = "FAIL" ]; then
                printf '    %-4s %8s %10s\n' "$arm" "$max" FAILED
                continue
            fi
            errs="$(awk -F'\t' -v a="$arm" -v m="$max" '$1 == a && $2 == "sweep" && $3 == m { s += $10 } END { print s + 0 }' "$RESULTS")"
            printf '    %-4s %8s %10s %10s %10s %8s\n' "$arm" "$max" "$rps" "$p50" "$p99" "$errs"
        done
    done
}

echo "=== recycling cost: what replacing a worker costs, per server ==="
echo "    php: $("$PHP" -v | head -1)"
echo "    volucer: $BIN"
echo "    arms: $ARMS  sweep: mr=$SWEEP  workers=$WORKERS  c=$CONC  t=$THREADS  ${DUR}x${ROUNDS}"
echo

fpm_ready=0
if [ "$SKIP_FPM" != "1" ]; then
    echo "--- php-fpm ---"
    if setup_fpm; then
        fpm_ready=1
        sudo mkdir -p /run/php-fpm-bench
        sudo chmod 0777 /run/php-fpm-bench
        echo "  pool + vhost installed, service restartable"
    fi
    echo
fi

for arm in ${ARMS//,/ }; do
    case "$arm" in
        P|A|F) ;;
        *) fail "unknown arm '$arm' (P, A or F)" ;;
    esac
done

echo "--- arm 1: baseline (w=1, c=1, max_requests=0) ---"
echo "    One worker and one connection with NO recycling: the cost of a request on its own."
echo "    Subtracting this is what turns the isolation arm into the cost of a replacement."
for round in $(seq 1 "$ROUNDS"); do
    case ",$ARMS," in
        *,P,*) printf '  P  round %s: %s\n' "$round" "$(run_volucer_arm P "$PORTS_P" 0 baseline "$round")" ;;
    esac
    case ",$ARMS," in
        *,A,*) printf '  A  round %s: %s\n' "$round" "$(run_attach_arm "$PORTS_A" 0 baseline "$round")" ;;
    esac
    case ",$ARMS," in
        *,F,*) [ "$fpm_ready" = "1" ] &&
            printf '  F  round %s: %s\n' "$round" "$(run_fpm_arm "$PORTS_F" 0 baseline "$round")" ;;
    esac
done

echo
echo "--- arm 2: isolation (w=1, c=1, max_requests=1) ---"
for round in $(seq 1 "$ROUNDS"); do
    case ",$ARMS," in
        *,P,*) printf '  P  round %s: %s\n' "$round" "$(run_volucer_arm P "$PORTS_P" 1 isolation "$round")" ;;
    esac
    case ",$ARMS," in
        *,A,*) printf '  A  round %s: %s\n' "$round" "$(run_attach_arm "$PORTS_A" 1 isolation "$round")" ;;
    esac
    case ",$ARMS," in
        *,F,*) [ "$fpm_ready" = "1" ] &&
            printf '  F  round %s: %s\n' "$round" "$(run_fpm_arm "$PORTS_F" 1 isolation "$round")" ;;
    esac
done

echo
echo "--- arm 3: sweep (w=$WORKERS, c=$CONC, mr in $SWEEP) ---"
for max in ${SWEEP//,/ }; do
    for round in $(seq 1 "$ROUNDS"); do
        case ",$ARMS," in
            *,P,*) printf '  P  mr=%-5s round %s: %s\n' "$max" "$round" "$(run_volucer_arm P "$PORTS_P" "$max" sweep "$round")" ;;
        esac
        case ",$ARMS," in
            *,A,*) printf '  A  mr=%-5s round %s: %s\n' "$max" "$round" "$(run_attach_arm "$PORTS_A" "$max" sweep "$round")" ;;
        esac
        case ",$ARMS," in
            *,F,*) [ "$fpm_ready" = "1" ] &&
                printf '  F  mr=%-5s round %s: %s\n' "$max" "$round" "$(run_fpm_arm "$PORTS_F" "$max" sweep "$round")" ;;
        esac
    done
done

report

echo
echo "raw: $D/results.tsv (kept until this script exits; copy it if the run matters)"
