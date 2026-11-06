#!/usr/bin/env bash
# A/B the `spawn_cgi` branch across two builds, interleaved so neither binary gets the
# quiet half of the host.
#
# The order is ABBA per block, not AAAA then BBBB: every figure in this record that had to
# be discarded was discarded because the two arms were measured at different times on a
# host whose load was not the same. Alternating cannot fix a host that drifts, but it makes
# the drift land on both arms equally instead of entirely on one.
#
#   ab-branch.sh <binA> <binB> [secs] [conc] [rounds-per-block] [rounds]
#
# Each invocation of `arms.sh` pays its own warm-up pass, which is what makes the cells
# comparable -- Phase 20's 7% artefact was one script warming and another not.
set -uo pipefail
A=${1:?first binary}
B=${2:?second binary}
SECS=${3:-14}
CONC=${4:-100}
BLOCK=${5:-1}
ROUNDS=${6:-2}
OUT=${OUT:-$HOME/ab-branch}
mkdir -p "$OUT"
: > "$OUT/all.txt"

for r in $(seq 1 "$ROUNDS"); do
    # ABBA on odd rounds, BAAB on even, so neither binary is always first or always second.
    if [ $(( r % 2 )) -eq 1 ]; then order="A B B A"; else order="B A A B"; fi
    for slot in $order; do
        [ "$slot" = A ] && bin=$A tag=$(basename "$A") || { bin=$B; tag=$(basename "$B"); }
        echo "### round $r slot $slot -> $tag  $(date +%H:%M:%S)" | tee -a "$OUT/all.txt"
        echo "### load $(awk '{print $1}' /proc/loadavg)" >> "$OUT/all.txt"
        cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
        BIN=$bin ARMS_FILTER="${ARMS_FILTER:-cgi cgi_dummy attach}" WORKERS=${WORKERS:-96} \
            bash scripts/arms.sh "$SECS" "$CONC" "$BLOCK" 2>&1 \
            | grep -E '^  (cgi|cgi_dummy|attach)-r' \
            | sed -e "s/^/[$tag r$r] /" | tee -a "$OUT/all.txt"
    done
done
echo "=== wrote $OUT/all.txt"
