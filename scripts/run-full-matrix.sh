#!/bin/bash
# The published matrix: 8/16/32 workers, four endpoints, three rounds.
#
# Arms: the warm shapes (attach, tcp), the two cold ones (fastcgi, prefork), the
# decomposition (external), and the three other servers. volucer-worker and
# volucer-unix are left out deliberately -- attach and tcp already answer "warm"
# and "transport", and every arm costs about 20 minutes.
#
# prefork is pinned to w=1 because its `workers` counts LISTENING SOCKETS: the
# process count is its `children`, so w=1 ch=8 is 9 PHP processes and is the only
# shape comparable with w=8 on the one-process-per-slot arms.
cd "$HOME/volucer-competition" || exit 1

rm -rf "$HOME/matrix-8-16-32"

ARMS=volucer-attach,volucer-tcp,volucer-fastcgi,volucer-prefork,volucer-external,rr,frankenphp,fpm \
ENDPOINTS="/echo,/,/api/items,/items" \
WORKERS_LIST=8,16,32 \
ARM_WORKERS="volucer-prefork=1" \
CHILDREN_LIST="8,16,32" \
CONC=32,64,96 \
OPCACHE_MODES=on \
ORDER=interleaved \
ROUNDS=3 \
DUR=10s WARMUP=2s THREADS=12 \
INI_SCAN_DIR="$HOME/jit-on" \
RUNDIR="$HOME/matrix-8-16-32" \
bash scripts/matrix.sh > "$HOME/matrix-8-16-32.log" 2>&1

echo "EXIT=$?"
echo "rows: $(grep -c '' "$HOME/matrix-8-16-32/matrix.tsv" 2>/dev/null)"
