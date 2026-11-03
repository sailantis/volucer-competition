#!/usr/bin/env bash
# The authoritative allocator A/B: same commit, same config, only the allocator differs.
#
# The earlier "compiled jemalloc is slower" result was invalid — the tree it was built
# from was at 85d1727, i.e. *before* the async hand-off, so it compared two different
# request paths. These two binaries are the same commit built twice.
set -uo pipefail
ROOT=/home/competition/volucer-competition
A=/home/competition/hello-bench/bin/volucer-async-glibc
B=/home/competition/hello-bench/bin/volucer-async-jemalloc
LIB=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
SECS=${SECS:-16}
ROUNDS=${ROUNDS:-3}

one() { # tag, binary, env
    env $3 bash "$ROOT/scripts/attach-probe.sh" "$2" 12 100 "$SECS" "$1" 2>&1 \
        | awk -v t="$1" '/^Requests\/sec:/{r=$2} /^front-end/{f=$2; u=$4} END{printf "%-14s rps=%-10s fe=%s cores  %s us/req\n", t, r, f, u}'
}

for r in $(seq 1 "$ROUNDS"); do
    if [ $((r % 2)) -eq 1 ]; then
        one "r$r-glibc"    "$A" ""
        one "r$r-jemalloc" "$B" ""
        one "r$r-preload"  "$A" "LD_PRELOAD=$LIB"
    else
        one "r$r-preload"  "$A" "LD_PRELOAD=$LIB"
        one "r$r-jemalloc" "$B" ""
        one "r$r-glibc"    "$A" ""
    fi
done
