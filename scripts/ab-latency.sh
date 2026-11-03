#!/usr/bin/env bash
# Rotated A/B: the shipped pre-async binary against the async attach exchange, at matched
# concurrency. Answers whether the change reduced CPU, latency, or both.
set -uo pipefail
cd ~/volucer-competition || exit 1
A=~/hello-bench/bin/volucer-async
B=~/hello-bench/bin/volucer-async-attach
echo "A=$(sha256sum $A | cut -c1-12)  B=$(sha256sum $B | cut -c1-12)"
run() {
  local bin=$1 conc=$2 tag=$3
  ./scripts/attach-probe.sh "$bin" 12 "$conc" 12 "$tag" 2>&1 \
    | awk -v t="[$(basename $bin) c=$conc]" '
        /^Requests\/sec:/ { rps=$2 }
        /^requests in / { req=$1 }
        /^ Latency/ { }
        /50%/ && !p50 { p50=$2 }
        /^front-end/ { fe=$2; feus=$4 }
        /^php / { ph=$2 }
        /^slots:/ { slots=$0 }
        END { printf "%-34s %9.0f rps  p50 %-8s fe %s cores %s us/req  php %s\n", t, rps, p50, fe, feus, ph }
      '
}
for round in 1 2; do
  echo "--- round $round"
  if [ $round -eq 1 ]; then
    for c in 1 100; do run "$A" "$c" "ab-a-$c-r$round"; run "$B" "$c" "ab-b-$c-r$round"; done
  else
    for c in 100 1; do run "$B" "$c" "ab-b-$c-r$round"; run "$A" "$c" "ab-a-$c-r$round"; done
  fi
done