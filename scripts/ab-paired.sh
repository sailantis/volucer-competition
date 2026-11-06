#!/usr/bin/env bash
# A paired A/B of two volucer binaries, with BOTH servers resident.
#
# Why not two `arms.sh` runs: every `arms.sh` invocation pays a 96-slot startup and its own
# warm-up, so ~90 s of each block is drift rather than measurement, and the two binaries end
# up on different parts of a host whose load is not the same. Measured that way, the same
# binary against itself produced a spread wider than any effect worth reporting.
#
# Here both servers are started once, on separate ports, and `wrk` alternates between them.
# Neither restarts, so the pairing is tight: an arm always has a neighbour measured seconds
# away on the same host. The order is ABBA per round, so neither binary is always first.
#
# `attach` is included on purpose as a CONTROL: this branch touches the FastCGI pools and
# nothing on the worker-protocol path, so `attach` must come out flat. If it does not, the
# harness is biased and its other rows cannot be believed.
#
#   ab-paired.sh <binA> <binB> [secs] [conc] [rounds] [workers]
set -uo pipefail
A=${1:?first binary}
B=${2:?second binary}
SECS=${3:-12}
CONC=${4:-100}
ROUNDS=${5:-4}
WORKERS=${6:-24}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=${OUT:-$HOME/ab-paired}
rm -rf "$OUT"; mkdir -p "$OUT"
PHP_CGI_BIN=$(command -v php-cgi)
PYTHON_BIN=$(command -v python3)
WRK_T=$(nproc); [ "$WRK_T" -gt "$CONC" ] && WRK_T=$CONC

# ONE php-cgi wrapper for both arms, built once: two wrappers differing in a flag would be
# measuring a php.ini rather than the branch (hazard 28).
PHP_CGI_WRAPPER="$OUT/php-cgi-bench"
cat > "$PHP_CGI_WRAPPER" <<WRAPPER
#!/bin/sh
exec $PHP_CGI_BIN -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \\
    -d opcache.jit=off -d xdebug.mode=off -d memory_limit=512M "\$@"
WRAPPER
chmod +x "$PHP_CGI_WRAPPER"

A_PORT=23010; B_PORT=23011
cleanup() {
    kill -TERM $VOL_A $VOL_B 2>/dev/null
    sleep 1.5
    kill -9 $VOL_A $VOL_B 2>/dev/null
    # Anchored on this run's own directory, so it can only reach processes it started.
    pkill -f "$OUT/" 2>/dev/null
    pkill -f "fcgi-dummy.py unix:$OUT/" 2>/dev/null
}
trap cleanup EXIT INT TERM

start() {   # $1=tag $2=bin $3=port $4=dir
    local tag=$1 bin=$2 port=$3 dir=$4
    mkdir -p "$dir"
    case "${ARM:-dummy}" in
        dummy) tpl=hello-cgi-dummy.toml.template ;;
        # The arm the branch is actually about: `spawn_cgi` -> `php-cgi`, cold.
        cgi)   tpl=hello-cgi.toml.template ;;
        *)     echo "unknown ARM=${ARM}" >&2; exit 2 ;;
    esac
    sed -e "s|{{PORT}}|$port|g" -e "s|{{ROOT}}|$ROOT|g" \
        -e "s|{{WORKERS}}|$WORKERS|g" -e "s|{{SOCKET_DIR}}|$dir|g" \
        -e "s|{{PYTHON}}|$PYTHON_BIN|g" -e "s|{{PHP_CGI}}|$PHP_CGI_WRAPPER|g" \
        "$ROOT/conf/$tpl" > "$dir/cfg.toml"
    "$bin" serve -c "$dir/cfg.toml" >"$dir/volucer.log" 2>&1 &
    echo $!
}

echo "=== A: $A  ($("$A" --version 2>/dev/null))"
echo "=== B: $B  ($("$B" --version 2>/dev/null))"
echo "=== workers=$WORKERS c=$CONC ${SECS}s x $ROUNDS  wrk -t$WRK_T"
VOL_A=$(start ca "$A" "$A_PORT" "$OUT/a")
VOL_B=$(start cb "$B" "$B_PORT" "$OUT/b")

# A body guard before anything is timed, on both: a 502 is answered faster than a real
# request, so a dead arm wins a race it never ran.
for p in "$A_PORT" "$B_PORT"; do
    for _ in $(seq 1 900); do curl -sf -o /dev/null "http://127.0.0.1:$p/" && break; sleep 0.05; done
done
for p in "$A_PORT" "$B_PORT"; do
    body=$(curl -s --max-time 5 "http://127.0.0.1:$p/")
    printf '  port %s -> %s\n' "$p" "$body"
    printf '%s' "$body" | grep -q '"hello"' || {
        echo "REFUSING TO MEASURE: an arm is not serving the page"; exit 1; }
done

echo "=== warm-up (discarded)"
wrk -t"$WRK_T" -c"$CONC" -d"${SECS}s" "http://127.0.0.1:$A_PORT/" >/dev/null 2>&1
wrk -t"$WRK_T" -c"$CONC" -d"${SECS}s" "http://127.0.0.1:$B_PORT/" >/dev/null 2>&1

tsv="$OUT/paired.tsv"; : > "$tsv"
one() {   # $1=tag $2=port $3=round
    local f="$OUT/wrk-$1-r$3.txt"
    wrk -t"$WRK_T" -c"$CONC" -d"${SECS}s" --latency "http://127.0.0.1:$2/" >"$f" 2>&1
    local rps p50 bad
    rps=$(awk '/^Requests\/sec:/{print $2}' "$f")
    p50=$(awk '/^ +50%/{print $2}' "$f")
    bad=$(awk -F: '/Non-2xx/{gsub(/ /,"",$2); print $2+0}' "$f")
    printf '%s\t%s\t%s\t%s\t%s\n' "$3" "$1" "${rps:-0}" "${p50:-0}" "${bad:-0}" >> "$tsv"
    printf '  r%-2s %-2s %8.0f rps  p50 %-9s%s\n' "$3" "$1" "${rps:-0}" "${p50:-?}" \
        "$([ "${bad:-0}" -gt 0 ] && echo "  <<< NON-2xx ${bad}")"
}

for r in $(seq 1 "$ROUNDS"); do
    echo "--- round $r"
    if [ $(( r % 2 )) -eq 1 ]; then one A "$A_PORT" "$r"; one B "$B_PORT" "$r"
                                  one B "$B_PORT" "$r"; one A "$A_PORT" "$r"
    else                          one B "$B_PORT" "$r"; one A "$A_PORT" "$r"
                                  one A "$A_PORT" "$r"; one B "$B_PORT" "$r"; fi
done

python3 - "$tsv" <<'PY'
import sys, statistics as st
rows = [l.split('\t') for l in open(sys.argv[1]).read().splitlines() if l.strip()]
d = {}
for rnd, tag, rps, p50, bad in rows:
    d.setdefault(tag, []).append(float(rps))
a, b = d.get('A', []), d.get('B', [])
if a and b:
    ma, mb = st.median(a), st.median(b)
    print(f"\n=== A median {ma:,.0f} rps over {len(a)}  (min {min(a):,.0f} max {max(a):,.0f})")
    print(f"=== B median {mb:,.0f} rps over {len(b)}  (min {min(b):,.0f} max {max(b):,.0f})")
    print(f"=== A/B = {ma/mb:.3f}   ({(ma/mb-1)*100:+.1f}% for A)")
PY
cleanup
echo "=== wrote $OUT/paired.tsv"
