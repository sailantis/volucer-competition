#!/usr/bin/env bash
# Both binaries resident, alternating, with CPU and syscall counts per request.
#
# Throughput cannot resolve a small change on this host: the Windows side is busy and `wrk`
# reproduces to about ±20% between blocks. Task-clock per request and futexes per request
# are properties of the process, not of how fast the host happens to be, so they are the
# instrument for a change that is expected to move a few microseconds.
#
# Order is ABBA per round so neither binary is always measured first.
#
#   ab-counts.sh <binA> <binB> [secs] [conc] [rounds] [workers] [arm]
set -uo pipefail
A=${1:?first binary}
B=${2:?second binary}
SECS=${3:-12}
CONC=${4:-100}
ROUNDS=${5:-3}
WORKERS=${6:-24}
ARM=${7:-dummy}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=${OUT:-$HOME/ab-counts}
rm -rf "$OUT"; mkdir -p "$OUT"
PYTHON_BIN=$(command -v python3)
PHP_CGI_WRAPPER="$OUT/php-cgi-bench"
if [ -n "$(command -v php-cgi)" ]; then
cat > "$PHP_CGI_WRAPPER" <<WRAPPER
#!/bin/sh
exec $(command -v php-cgi) -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \\
    -d opcache.jit=off -d xdebug.mode=off -d memory_limit=512M "\$@"
WRAPPER
chmod +x "$PHP_CGI_WRAPPER"
fi

A_PORT=23020; B_PORT=23021
cleanup() {
    kill -TERM $VOL_A $VOL_B 2>/dev/null; sleep 1.5; kill -9 $VOL_A $VOL_B 2>/dev/null
    pkill -f "$OUT/" 2>/dev/null
}
trap cleanup EXIT INT TERM

start() {
    local bin=$1 port=$2 dir=$3
    mkdir -p "$dir"
    case "$ARM" in
        dummy) tpl=hello-cgi-dummy.toml.template ;;
        cgi)   tpl=hello-cgi.toml.template ;;
        *) echo "unknown arm $ARM" >&2; exit 2 ;;
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
echo "=== arm=$ARM workers=$WORKERS c=$CONC ${SECS}s x $ROUNDS"
VOL_A=$(start "$A" "$A_PORT" "$OUT/a")
VOL_B=$(start "$B" "$B_PORT" "$OUT/b")
for p in "$A_PORT" "$B_PORT"; do
    for _ in $(seq 1 900); do curl -sf -o /dev/null "http://127.0.0.1:$p/" && break; sleep 0.05; done
done
for p in "$A_PORT" "$B_PORT"; do
    body=$(curl -s --max-time 5 "http://127.0.0.1:$p/")
    printf '  port %s -> %s\n' "$p" "$body"
    printf '%s' "$body" | grep -q '"hello"' || { echo "REFUSING: an arm is not serving"; exit 1; }
done
echo "=== warm-up (discarded)"
wrk -t"$(nproc)" -c"$CONC" -d"${SECS}s" "http://127.0.0.1:$A_PORT/" >/dev/null 2>&1
wrk -t"$(nproc)" -c"$CONC" -d"${SECS}s" "http://127.0.0.1:$B_PORT/" >/dev/null 2>&1

tsv="$OUT/counts.tsv"; : > "$tsv"
one() {   # $1=tag $2=port $3=pid $4=round
    local tag=$1 port=$2 pid=$3 r=$4
    local d="$OUT/$tag-r$r"
    CONC=$CONC SECS=$SECS OUT="$d" bash "$ROOT/scripts/count-pair.sh" "$pid" "$port" "$SECS" > "$d.out" 2>&1
    local line
    line=$(python3 - "$d/../perf-count.txt" 2>/dev/null || true)
    printf '%s\t%s\t%s\n' "$r" "$tag" "$(tr '\n' ' ' < "$d.out")" >> "$tsv"
    printf '  %s r%-2s %s\n' "$tag" "$r" "$(tr '\n' ' ' < "$d.out")"
}

for r in $(seq 1 "$ROUNDS"); do
    echo "--- round $r"
    if [ $(( r % 2 )) -eq 1 ]; then order="A B B A"; else order="B A A B"; fi
    for s in $order; do
        if [ "$s" = A ]; then one A "$A_PORT" "$VOL_A" "$r"; else one B "$B_PORT" "$VOL_B" "$r"; fi
    done
done

python3 - "$tsv" <<'PY'
import sys, re, statistics as st
d = {}
for line in open(sys.argv[1]).read().splitlines():
    if not line.strip(): continue
    r, tag, rest = line.split('\t', 2)
    us = re.search(r'=\s*([\d.]+) us/req', rest)
    fx = re.search(r'futex\s+([\d.]+)/req', rest)
    rps = re.search(r'rps\s+([\d,]+)', rest)
    d.setdefault(tag, []).append((
        float(us.group(1)) if us else 0.0,
        float(fx.group(1)) if fx else 0.0,
        float(rps.group(1).replace(',', '')) if rps else 0.0))
for tag in ('A', 'B'):
    v = d.get(tag, [])
    if not v: continue
    us = st.median(x[0] for x in v); fx = st.median(x[1] for x in v)
    rp = st.median(x[2] for x in v)
    print(f"\n=== {tag}  median  {us:6.1f} us/req   {fx:5.2f} futex/req   {rp:9,.0f} rps  (n={len(v)})")
a, b = d.get('A', []), d.get('B', [])
if a and b:
    ua, ub = st.median(x[0] for x in a), st.median(x[0] for x in b)
    fa, fb = st.median(x[1] for x in a), st.median(x[1] for x in b)
    print(f"=== A vs B:  {(ua/ub-1)*100:+.1f}% us/req,  futex {fa-fb:+.2f}/req")
PY
cleanup
echo "=== wrote $OUT/counts.tsv"
