#!/bin/bash
# Interleaved A/B of the /items application cost through a real volucer worker.
#
# Every round measures every variant back to back, so drift in machine state hits
# all of them equally; the medians are the comparison. Assertions: the box is idle
# before each measurement, and every measurement returned 200.
#
#   bash scripts/items-ab.sh [uri] [conc] [rounds] [duration]
#   VARIANTS="real shipped objects best" bash scripts/items-ab.sh
#
# Variants, and the ONE thing each isolates (all serve the identical page — see
# scripts/items-equivalence.php):
#
#   real      the unmodified application, dispatched exactly as worker.php does.
#             The control: it separates "this harness is slow" from "the change
#             under test is slow".
#   shipped   the HTML action reproduced against the SHIPPED clarity-engine:
#             freshness re-checked against the filesystem on every render, policy
#             digest recomputed on every template load
#   objects   shipped clarity, but the page hydrated as stdClass — no ORM identity
#             map. Proven byte-identical to the ORM page.
#   best      objects + a 60 s revalidate window (needs the patched clarity-engine,
#             where setRevalidateFreq() exists; the worker exits loudly without it)
#   apibase   /api/items through entities(), as ApiController::indexAction does
#   apiselect /api/items through select()->toArray(), which is byte-identical JSON
#
# `real` and `shipped` should agree to within noise; if they do not, the harness
# is measuring itself.
set -u

ROOT="$HOME/volucer-competition"
BIN="$HOME/volucer-bench/target/release/volucer"
URI="${1:-/items}"
CONC="${2:-96}"
ROUNDS="${3:-5}"
DUR="${4:-10s}"
PORT=18490
RUN=/tmp/items-ab
VARIANTS="${VARIANTS:-real shipped objects best}"

rm -rf "$RUN"; mkdir -p "$RUN"

fail() { echo "FAIL: $*" >&2; exit 1; }

assert_idle() {
    local php vol
    php=$(pgrep -c -x php || true); php=${php:-0}
    vol=$(pgrep -c -x volucer || true); vol=${vol:-0}
    if [ "$php" != "0" ] || [ "$vol" != "0" ]; then
        fail "machine not idle before [$1]: php=$php volucer=$vol"
    fi
}

wait_ready() {
    for _ in $(seq 1 300); do
        curl -sf -o /dev/null -m 1 "http://127.0.0.1:$PORT/echo" && return 0
        sleep 0.1
    done
    return 1
}

start() { # variant
    cat > "$RUN/volucer-$1.toml" <<EOF
[server]
default_backend = "app"
http = "127.0.0.1:$PORT"
document_root = "$ROOT/public"
[server.static_files]
enabled = false
[backends.app]
kind = "worker"
command = "php $ROOT/scripts/items-ab-worker.php $1"
workers = 8
working_dir = "$ROOT"
max_requests = 0
EOF
    "$BIN" serve --config "$RUN/volucer-$1.toml" > "$RUN/server-$1.log" 2>&1 &
    echo $!
}

stop() {
    kill "$1" 2>/dev/null
    wait "$1" 2>/dev/null
    for _ in $(seq 1 50); do pgrep -x php >/dev/null || break; sleep 0.1; done
}

TSV="$RUN/ab.tsv"
printf "variant\tround\tconc\trps\tp50\tp99\terrors\n" > "$TSV"

echo "uri=$URI conc=$CONC rounds=$ROUNDS duration=$DUR"
echo "variants: $VARIANTS"
echo "volucer:  $("$BIN" --version 2>&1 | head -1)"
if grep -q revalidateFreq "$ROOT/vendor/sailantis/clarity-engine/src/Engine/Cache.php"; then
    echo "clarity:  patched (setRevalidateFreq available)"
else
    echo "clarity:  shipped 0.4.0 (no revalidate window)"
fi

for r in $(seq 1 "$ROUNDS"); do
    for v in $VARIANTS; do
        assert_idle "$v r$r"
        pid=$(start "$v")
        wait_ready "$pid" || { tail -5 "$RUN/server-$v.log" >&2; fail "server for $v never became ready"; }

        # The variant must serve the endpoint under test, not just /echo.
        code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$URI")
        [ "$code" = "200" ] || fail "$v returned $code on $URI"

        out=$(wrk -t12 -c"$CONC" -d"$DUR" --latency "http://127.0.0.1:$PORT$URI" 2>/dev/null)
        rps=$(awk '/Requests\/sec:/ {print $2}' <<< "$out")
        p50=$(awk '/^ +50%/ {print $2}' <<< "$out")
        p99=$(awk '/^ +99%/ {print $2}' <<< "$out")
        non2xx=$(awk '/Non-2xx/ {print $2}' <<< "$out")

        [ -n "$rps" ] || fail "$v produced no Requests/sec on $URI"

        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$v" "$r" "$CONC" "$rps" "$p50" "$p99" "${non2xx:-0}" >> "$TSV"
        printf "  r%-2s %-9s %10s rps  p50 %-9s p99 %s\n" "$r" "$v" "$rps" "$p50" "$p99"

        stop "$pid"
    done
done

echo
echo "=== medians ==="
awk -F'\t' 'NR>1 { n[$1]++; v[$1][n[$1]]=$4 }
END {
  for (k in n) {
    for (i=1;i<=n[k];i++) for (j=i+1;j<=n[k];j++) if (v[k][i]>v[k][j]) { t=v[k][i]; v[k][i]=v[k][j]; v[k][j]=t }
    m = (n[k]%2) ? v[k][(n[k]+1)/2] : (v[k][n[k]/2]+v[k][n[k]/2+1])/2
    printf "%-10s %10.2f\n", k, m
  }
}' "$TSV" | sort -k2 -nr

echo
echo "raw: $TSV"
