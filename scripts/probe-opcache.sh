#!/usr/bin/env bash
# Is OPcache actually active, and actually *shared*, in each prefork pool?
#
# This has to be answered before any `cgi_prefork` vs `external_fpm` number is quoted, because
# the two arms differ by 45 MB of PSS at equal child count (27 MB vs 72 MB for 96 children
# each). A sharing failure and a slower interpreter look identical in a throughput table, and
# only one of them is a statement about php-fpm.
#
# Asks the question through the **real arms**, so the answer comes from the process that
# actually serves the benchmark rather than from a side-car started differently.
set -eu

SECS=${1:-12}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROBE="$ROOT/apps/hello/public/sapi-probe.php"
REPORT=${REPORT:-/tmp/sapi-probe.txt}
rm -f "$REPORT"

if [ ! -f "$PROBE" ]; then
    echo "=== FATAL: $PROBE is missing; it is the question being asked" >&2
    exit 2
fi

( cd "$ROOT" && ARMS_FILTER="cgi_prefork external_fpm" \
    bash scripts/arms.sh "$SECS" 1 1 >/tmp/occheck-arms.log 2>&1 & )
sleep $(( SECS * 2 + 8 ))

# One request per arm at concurrency 1 while the pool is still up. The route names a real file
# with a script extension, so it is resolved on disk and executed by the SAPI directly rather
# than through the front controller -- which is the thing being inspected.
for port in 22957 22956; do
    case $port in
        22957) arm=cgi_prefork ;;
        22956) arm=external_fpm ;;
    esac
    body=$(curl -s --max-time 5 "http://127.0.0.1:$port/sapi-probe.php" || echo "<no answer>")
    echo "=== $arm (port $port): $body"
done

echo "=== what the interpreters reported"
if [ -f "$REPORT" ]; then
    python3 - "$REPORT" <<'PY'
import json, sys
seen = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        continue
    seen.setdefault(d.get("sapi"), d)
for sapi, d in seen.items():
    print(f"--- sapi={sapi} pid={d.get('pid')}")
    for k, v in d.items():
        if k in ("sapi", "pid"):
            continue
        print(f"    {k:15} {v}")
PY
else
    echo "   no report at $REPORT (the arms may have been reaped before the request landed)"
fi
