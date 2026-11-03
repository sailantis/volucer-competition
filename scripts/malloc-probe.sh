#!/bin/sh
# Does `MALLOC_ARENA_MAX` help? A/B on the attach arm only.
#
# The front-end's own CPU is the thing under test: the earlier profile put ~7% of a
# hello-world request in glibc `malloc`/`free`, and glibc's per-thread arenas are a
# known source of contention on many-threaded servers. `MALLOC_ARENA_MAX` caps them.
#
# Alternating rounds rather than a blocked sweep: the question is a ratio between two
# configurations on one host, and a host that drifts would otherwise charge the drift
# to whichever arm ran last. Same reason `hello-bench.sh` rotates.
set -eu

ROOT="$HOME/volucer-competition"
BIN="${BIN:-$HOME/hello-bench/bin/volucer-fixed3}"
RUNDIR="$HOME/malloc-probe"
PORT=22700
DUR=8
CONC=32
WORKERS=12
ROUNDS="${ROUNDS:-4}"

rm -rf "$RUNDIR"; mkdir -p "$RUNDIR"

cpu_tree() { # marker...
    for d in /proc/[0-9]*; do
        [ -r "$d/stat" ] && [ -r "$d/cmdline" ] || continue
        line=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null) || continue
        [ -n "$line" ] || continue
        m=0
        for want in "$@"; do case "$line" in *"$want"*) m=1; break ;; esac; done
        [ "$m" = "1" ] || continue
        awk '{printf "%.2f\n", ($13 + $14 + $15 + $16) / 100.0}' "$d/stat" 2>/dev/null
    done | awk '{s += $1} END {printf "%.2f", s + 0}'
}

kill_markers() {
    for sig in TERM KILL; do
        for d in /proc/[0-9]*; do
            [ -r "$d/cmdline" ] || continue
            line=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null) || continue
            [ -n "$line" ] || continue
            m=0
            for want in "$@"; do case "$line" in *"$want"*) m=1; break ;; esac; done
            [ "$m" = "1" ] || continue
            kill -"$sig" "${d#/proc/}" 2>/dev/null || true
        done
        if [ "$sig" = TERM ]; then sleep 2; fi
    done
}

# One cell. `$1` is the label, `$2` is the MALLOC_ARENA_MAX value ("" for unset).
cell() {
    label="$1"; arena="$2"
    rm -f "$RUNDIR"/relay*
    sed -e "s#{{PORT}}#$PORT#g" -e "s#{{WORKERS}}#$WORKERS#g" -e "s#{{SOCKET_DIR}}#$RUNDIR#g" \
        "$ROOT/conf/hello-attach.toml.template" >"$RUNDIR/attach.toml"
    php -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \
        "$ROOT/apps/hello/supervisor.php" "unix:$RUNDIR/relay" >"$RUNDIR/sup.log" 2>&1 &
    for _ in $(seq 1 40); do [ -S "$RUNDIR/relay" ] && break; sleep 0.25; done
    if [ -n "$arena" ]; then
        MALLOC_ARENA_MAX="$arena" "$BIN" serve -c "$RUNDIR/attach.toml" >"$RUNDIR/$label.log" 2>&1 &
    else
        "$BIN" serve -c "$RUNDIR/attach.toml" >"$RUNDIR/$label.log" 2>&1 &
    fi
    for _ in $(seq 1 120); do curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/" && break; sleep 0.25; done

    # Warm, so the sample window is not measuring a cold pool.
    wrk -t"$CONC" -c"$CONC" -d3s "http://127.0.0.1:$PORT/" >/dev/null 2>&1

    before=$(cpu_tree "$RUNDIR/attach.toml")
    wrk -t"$CONC" -c"$CONC" -d"${DUR}s" --latency "http://127.0.0.1:$PORT/" >"$RUNDIR/wrk-$label.txt" 2>&1 &
    wrkpid=$!
    sleep $((DUR - 2))
    after=$(cpu_tree "$RUNDIR/attach.toml")
    wait "$wrkpid" 2>/dev/null || true

    rps=$(awk '/Requests\/sec/ {print $2}' "$RUNDIR/wrk-$label.txt")
    p50=$(awk '$1 == "50%" {print $2}' "$RUNDIR/wrk-$label.txt")
    cores=$(awk -v a="$before" -v b="$after" -v w="$((DUR - 2))" 'BEGIN{printf "%.2f", (b-a)/w}')
    echo "$label $rps $cores $p50"
    kill_markers "$RUNDIR/attach.toml" supervisor.php
}

: >"$RUNDIR/rows.tsv"
for round in $(seq 1 "$ROUNDS"); do
    # Alternating order, so neither configuration always runs on the warmer host.
    if [ $((round % 2)) -eq 1 ]; then
        cell "default-r$round" "" >>"$RUNDIR/rows.tsv"
        cell "arena2-r$round" "2" >>"$RUNDIR/rows.tsv"
        cell "arena8-r$round" "8" >>"$RUNDIR/rows.tsv"
    else
        cell "arena8-r$round" "8" >>"$RUNDIR/rows.tsv"
        cell "arena2-r$round" "2" >>"$RUNDIR/rows.tsv"
        cell "default-r$round" "" >>"$RUNDIR/rows.tsv"
    fi
done

echo
echo "=== MALLOC_ARENA_MAX on the attach arm, c$CONC, ${DUR}s ==="
awk '{split($1, a, "-r"); cfg = a[1]; n[cfg]++; r[cfg] += $2; c[cfg] += $3}
     END {
        for (k in n) printf "  %-10s median-ish rps %8.0f   front-end cores %.2f   (%d rounds)\n", k, r[k]/n[k], c[k]/n[k], n[k]
     }' "$RUNDIR/rows.tsv" | sort
echo
echo "raw:"
cat "$RUNDIR/rows.tsv"
