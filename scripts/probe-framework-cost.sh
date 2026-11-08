#!/usr/bin/env bash
# Why is framework boot expensive, and what would change it?
#
# Runs the whole investigation in order and prints one report. Each probe answers
# a question the previous one raised, and every number here is measured on this
# host rather than inferred from a throughput ratio.
#
# The short version, so the report can be read against a claim:
#
#   `bare-echo.tsv` said removing the framework lifts php-fpm from ~27,900 to
#   ~104,300 rps. That is a ratio. As CPU it is 427 us vs 71 us per request on 12
#   cores -- 356 us of framework cost, which is 5x the ~70 us a warm worker needs
#   for the same dispatch.
#
# Usage: bash scripts/probe-framework-cost.sh
#        SKIP_PERF=1 bash scripts/probe-framework-cost.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

PHP_INI_SCAN_DIR="${PHP_INI_SCAN_DIR:-/home/competition/jit-on}"
export PHP_INI_SCAN_DIR

PHPBIN="${PHP:-php}"

hdr() { printf '\n\n=== %s ===\n\n' "$*"; }

hdr "1. Boot cost, and the share taken by the 100 filler routes"
"$PHPBIN" scripts/probe-boot-cost.php --routes

hdr "2. Where a boot goes, phase by phase (in-process)"
"$PHPBIN" scripts/probe-boot-cost.php

hdr "3. Cost of registering one route, and the deferred bucket sort"
"$PHPBIN" scripts/probe-route-cost.php

hdr "4. Framework cost on the wire, measured as CPU per request"
bash scripts/probe-boot-profile.sh

hdr "5. The same, with the filler routes removed"
PHASE=1 FILLERS=0 bash scripts/probe-boot-profile.sh | grep -E 'rps|framework cost' || true
hdr "6. Per-request phase attribution inside a real FPM child"
DUR=2s bash scripts/probe-phases.sh

hdr "7. Does the static memo survive between requests in FPM?"
bash scripts/probe-static.sh

hdr "8. Why a cold /items costs three times a warm one"
"$PHPBIN" scripts/probe-cold-dispatch.php

hdr "9. The connection is the surprise: which PRAGMA costs 60 us"
"$PHPBIN" scripts/probe-db-connect.php
"$PHPBIN" scripts/probe-db-first-statement.php

hdr "10. Would a compiled route table help? (no -- measured)"
"$PHPBIN" scripts/probe-route-cache.php

printf '\n\nDone. Raw artifacts: /tmp/{boot-profile,phases,static-probe}\n'
