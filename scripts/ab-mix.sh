#!/usr/bin/env bash
# Both binaries resident; per-request syscall mix for each, alternating.
#
#   ab-mix.sh <binA> <binB> [secs] [conc] [rounds] [workers] [arm]
set -uo pipefail
A=${1:?}; B=${2:?}
SECS=${3:-10}; CONC=${4:-100}; ROUNDS=${5:-2}; WORKERS=${6:-48}; ARM=${7:-cgi}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=${OUT:-$HOME/ab-mix}; rm -rf "$OUT"; mkdir -p "$OUT"
PYTHON_BIN=$(command -v python3)
WRAP="$OUT/php-cgi-bench"
cat > "$WRAP" <<W
#!/bin/sh
exec $(command -v php-cgi) -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \\
    -d opcache.jit=off -d xdebug.mode=off -d memory_limit=512M "\$@"
W
chmod +x "$WRAP"
A_PORT=23030; B_PORT=23031
cleanup(){ kill -TERM $VOL_A $VOL_B 2>/dev/null; sleep 1.5; kill -9 $VOL_A $VOL_B 2>/dev/null
           pkill -f "$OUT/" 2>/dev/null; }
trap cleanup EXIT INT TERM
start(){ local bin=$1 port=$2 dir=$3; mkdir -p "$dir"
  case "$ARM" in
    dummy) tpl=hello-cgi-dummy.toml.template ;;
    cgi)   tpl=hello-cgi.toml.template ;;
  esac
  sed -e "s|{{PORT}}|$port|g" -e "s|{{ROOT}}|$ROOT|g" -e "s|{{WORKERS}}|$WORKERS|g" \
      -e "s|{{SOCKET_DIR}}|$dir|g" -e "s|{{PYTHON}}|$PYTHON_BIN|g" \
      -e "s|{{PHP_CGI}}|$WRAP|g" "$ROOT/conf/$tpl" > "$dir/cfg.toml"
  "$bin" serve -c "$dir/cfg.toml" >"$dir/volucer.log" 2>&1 & echo $!; }
echo "=== A: $A"; echo "=== B: $B"; echo "=== arm=$ARM workers=$WORKERS c=$CONC ${SECS}s"
VOL_A=$(start "$A" "$A_PORT" "$OUT/a"); VOL_B=$(start "$B" "$B_PORT" "$OUT/b")
for p in $A_PORT $B_PORT; do for _ in $(seq 1 900); do curl -sf -o /dev/null "http://127.0.0.1:$p/" && break; sleep 0.05; done; done
for p in $A_PORT $B_PORT; do b=$(curl -s --max-time 5 "http://127.0.0.1:$p/"); echo "  $p -> $b"
  printf '%s' "$b" | grep -q '"hello"' || { echo REFUSING; exit 1; }; done
echo "=== warm-up (discarded)"
wrk -t"$(nproc)" -c"$CONC" -d"${SECS}s" "http://127.0.0.1:$A_PORT/" >/dev/null 2>&1
wrk -t"$(nproc)" -c"$CONC" -d"${SECS}s" "http://127.0.0.1:$B_PORT/" >/dev/null 2>&1
run(){ local tag=$1 port=$2 pid=$3 r=$4
  echo "--- $tag r$r"
  CONC=$CONC SECS=$SECS OUT="$OUT/$tag-r$r" bash "$ROOT/scripts/mix.sh" "$pid" "$port" "$SECS" 2>&1 | sed 's/^/   /'
  cp "$OUT/$tag-r$r/perf-mix.txt" "$OUT/$tag-r$r.txt" 2>/dev/null || true; }
for r in $(seq 1 "$ROUNDS"); do
  if [ $(( r % 2 )) -eq 1 ]; then run A "$A_PORT" "$VOL_A" "$r"; run B "$B_PORT" "$VOL_B" "$r"
  else run B "$B_PORT" "$VOL_B" "$r"; run A "$A_PORT" "$VOL_A" "$r"; fi
done
cleanup
