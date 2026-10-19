#!/bin/bash
# Does an exec'd worker share OPcache with its siblings, or clone it?
#
# The claim under test is the one that decides whether fork() is optional or
# structural: on Linux, OPcache's shared memory can only be shared by `fork()`.
# A process started with `exec` cannot attach to a segment somebody else created,
# so N exec'd workers each map their OWN copy and each pays for it.
#
# If that is true, a pool's memory should grow with opcache ON and shrink with it
# OFF, by about one segment per worker — and the growth should be PRIVATE memory,
# not shared, because nothing is actually shared between processes that did not
# fork from a common ancestor.
#
# If it is false — if exec'd workers somehow share one segment — the on/off delta
# would be small and PSS would be charged once.
#
# The method is the difference between two otherwise-identical pools, so everything
# else (interpreter, boot, page, request count) cancels out. PSS alone cannot answer
# it: a shared segment is charged once, and that is exactly the ambiguity. So the
# `private` column is the answer, and PSS is reported beside it for corroboration.
#
# Usage:
#   bash scripts/diag-opcache-sharing.sh
#   CHILDREN=8 PHP=/usr/bin/php8.5 bash scripts/diag-opcache-sharing.sh
#
# Environment:
#   CHILDREN  processes in the pool        [4]
#   REQUESTS  requests each one serves     [20]
#   PHP       the interpreter              [PHP_BINARY of the running php]
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(dirname "$SCRIPT_DIR")}"
CHILDREN="${CHILDREN:-4}"
REQUESTS="${REQUESTS:-20}"
PHP="${PHP:-$(command -v php || true)}"
D="$(mktemp -d)"

fail() { echo "FATAL: $*" >&2; rm -rf "$D"; exit 1; }

[ -n "$PHP" ] || fail "no php on PATH"
[ -f "$ROOT/data/bench.sqlite" ] || fail "$ROOT/data/bench.sqlite is missing - run: php seed.php"

# A worker that boots the app, serves REQUESTS, then reports itself and waits to be
# sampled. The same shape the matrix's warm arm runs, minus the protocol channel.
cat > "$D/child.php" <<'PHP'
<?php
$root = getenv('DIAG_ROOT');
$requests = (int) getenv('DIAG_REQUESTS');
$out = getenv('DIAG_OUT');
require $root . '/vendor/autoload.php';
require $root . '/BenchApp.php';

$app = new BenchApp($root . '/data/bench.sqlite');
$app->bootstrap();
$expect = null;
for ($i = 0; $i < $requests; $i++) {
    $r = $app->dispatch('GET', '/items');
    $app->cleanup();
    $expect = md5($r->body);
}
$oc = @opcache_get_status(false);
$raw = (string) @file_get_contents('/proc/self/smaps_rollup');
$get = static function (string $key) use ($raw): int {
    return preg_match('/^' . $key . ':\s+(\d+) kB/m', $raw, $m) === 1 ? (int) $m[1] : 0;
};
file_put_contents((string) $out, sprintf(
    "%d\t%.1f\t%.1f\t%.1f\t%.1f\t%d\t%d\t%s\n",
    getmypid(),
    $get('Pss') / 1024,
    ($get('Private_Clean') + $get('Private_Dirty')) / 1024,
    ($get('Shared_Clean') + $get('Shared_Dirty')) / 1024,
    $get('Anonymous') / 1024,
    $oc === false ? 0 : (int) ($oc['opcache_statistics']['num_cached_scripts'] ?? 0),
    $oc === false ? 0 : (int) round(($oc['memory_usage']['used_memory'] ?? 0) / 1048576),
    $expect
), FILE_APPEND | LOCK_EX);
sleep(60);
PHP

run_pool() { # mode -> writes rows to $D/$mode.tsv
    local mode="$1" oc
    oc=$([ "$mode" = "on" ] && echo 1 || echo 0)
    : > "$D/$mode.tsv"
    local pids=()
    for _ in $(seq 1 "$CHILDREN"); do
        DIAG_ROOT="$ROOT" DIAG_REQUESTS="$REQUESTS" DIAG_OUT="$D/$mode.tsv" \
            "$PHP" -d "opcache.enable_cli=$oc" -d opcache.validate_timestamps=0 \
            -d memory_limit=512M -d date.timezone=UTC "$D/child.php" \
            >/dev/null 2>>"$D/err.log" &
        pids+=("$!")
    done
    # Wait for every child to have written its row (they then sleep), so all of them
    # are resident at the same time - which is the state being measured.
    for _ in $(seq 1 600); do
        [ "$(wc -l < "$D/$mode.tsv" 2>/dev/null || echo 0)" -ge "$CHILDREN" ] && break
        sleep 0.1
    done
    sleep 0.3
    for p in "${pids[@]}"; do kill -KILL "$p" 2>/dev/null; done
    wait 2>/dev/null
}

summarise() { # mode
    local mode="$1" n pss priv shr scr
    n=$(wc -l < "$D/$mode.tsv" 2>/dev/null || echo 0)
    if [ "$n" -eq 0 ]; then
        echo "$mode: no children reported. First error:"
        head -5 "$D/err.log" 2>/dev/null | sed 's/^/    /'
        return
    fi
    read -r pss priv shr scr <<< "$(awk -F'\t' '{p+=$2; v+=$3; s+=$4; c+=$6} END {printf "%.1f %.1f %.1f %d", p, v, s, c}' "$D/$mode.tsv")"
    printf '%-5s %-9s %-10s %-12s %-11s %-11s %-9s\n' "$mode" "$n" "$pss" "$priv" "$shr" \
        "$(awk -v p="$pss" -v n="$n" 'BEGIN{printf "%.1f", p/n}')" "$scr"
}

echo "php $("$PHP" -v | head -1)"
echo "children $CHILDREN, $REQUESTS requests each"
echo "opcache.memory_consumption $("$PHP" -r 'echo ini_get("opcache.memory_consumption");') MB"
echo
printf '%-5s %-9s %-10s %-12s %-11s %-11s %-9s\n' \
    mode children sum_pss_mb sum_private_mb sum_shared_mb per_child_pss opcache_scripts
run_pool on;  summarise on
run_pool off; summarise off

echo
echo "If opcache were SHARED between these exec'd workers, turning it off would"
echo "change little and the delta would sit in the shared column. If each worker"
echo "maps its OWN segment - which is what Linux allows for a process that did not"
echo "fork - the on/off delta is private memory, roughly one segment's resident"
echo "pages per worker."
rm -rf "$D"
