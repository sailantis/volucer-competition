#!/usr/bin/env bash
# Which syscall are the *idle* children of each prefork pool blocked in, under load?
#
# `cgi_prefork` and `external_fpm` put the same number of PHP processes behind one listening
# socket, and the same page, so a difference between them cannot be the application. The one
# structural difference left is how a waiting child is told a connection arrived. A child
# parked in `accept`/`poll`/`futex` says which mechanism owns that, and the answer decides
# whether the gap is the supervision layer (php-fpm's accept discipline) or PHP's interpreter.
#
# Run with the arms already up, or pass a seconds argument to start them first.
set -eu

SECS_PROBE=${1:-0}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

if [ "$SECS_PROBE" -gt 0 ]; then
    ( cd "$ROOT" && ARMS_FILTER="cgi_prefork external_fpm" bash scripts/arms.sh "$SECS_PROBE" "${CONC:-100}" 1 \
        >/tmp/arms-wchan.log 2>&1 & )
    # Let the warm-up pass finish and the timed round begin: the sample has to land while the
    # pool is busy, because an idle pool reports the same wchan for both and proves nothing.
    sleep $(( SECS_PROBE + 6 ))
fi

sample() {
    local label=$1 pattern=$2 n=0
    echo "=== $label"
    while read -r pid; do
        n=$((n + 1))
        [ "$n" -gt 8 ] && { echo "   ..."; break; }
        printf "   pid %-7s wchan=%-16s state=%s\n" \
            "$pid" "$(cat "/proc/$pid/wchan" 2>/dev/null || echo '?')" \
            "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || echo '?')"
    done < <(pgrep -f "$2" 2>/dev/null || true)
    [ "$n" -eq 0 ] && echo "   (no processes matched)"
    return 0
}

# The master and the children are separate populations, and it is the *children* that accept.
sample "cgi_prefork children" 'php-cgi.*cgi-prefork/'
sample "php-fpm children"     'php-fpm: pool bench$'
