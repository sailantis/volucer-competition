#!/bin/bash
# Which interpreter is FrankenPHP actually running for this checkout?
#
# The matrix's FrankenPHP arm runs the release binary's embedded PHP, while every
# other arm runs the distro's. If those are the same minor version, the cross-arm
# comparison is matched on the interpreter and the confound the previous run had
# to caveat is gone. This asks the running server rather than the binary's
# version banner, because the banner is not what executes the application.
#
# It also reports whether the internal `psr` extension is loaded: PHP 8.5 ships
# `Psr\Log\LoggerInterface` as a native, UNTYPED interface, and this repository's
# bench app implements the composer version with typed signatures. Where the
# native one wins, the app dies on a fatal declaration error - which is a
# property of the arm, not of the server, and has to be known before measuring.
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(dirname "$SCRIPT_DIR")}"
FP="${FP:-$HOME/bin/frankenphp}"
PORT="${PORT:-23999}"
D="$(mktemp -d)"

fail() { echo "FATAL: $*" >&2; rm -rf "$D"; exit 1; }

[ -x "$FP" ] || fail "no frankenphp at $FP (set FP)"

cat > "$D/php.php" <<'PHP'
<?php
printf("PHP %s  psr=%s  xdebug=%s  opcache=%s  jit=%s\n",
    PHP_VERSION,
    extension_loaded('psr') ? 'YES' : 'no',
    extension_loaded('xdebug') ? 'YES' : 'no',
    function_exists('opcache_get_status')
        ? (@opcache_get_status(false) ? 'enabled' : 'disabled')
        : 'absent',
    ini_get('opcache.jit'));
if (extension_loaded('psr')) {
    $r = new ReflectionClass('Psr\Log\LoggerInterface');
    $m = $r->getMethod('emergency');
    printf("Psr\\Log\\LoggerInterface: %s, emergency() first parameter typed: %s\n",
        $r->getFileName() ?: '<internal>',
        $m->getParameters()[0]->hasType() ? 'yes' : 'no');
}
PHP

# Each directive and each block on its own line: Caddy's adapter rejects a block
# whose first directive shares the opening line ("Unexpected next token after '{'
# on same line"), and the server then exits before it ever listens.
cat > "$D/Caddyfile" <<CADDY
{
	admin off

	frankenphp {
		num_threads 1
	}
}

http://127.0.0.1:$PORT {
	root * $ROOT/public

	php_server
}
CADDY

cleanup() { [ -n "${FPID:-}" ] && kill "$FPID" 2>/dev/null; rm -rf "$D"; }
trap cleanup EXIT

cp "$D/php.php" "$ROOT/public/.fp-php-probe.php"
cleanup_probe() { rm -f "$ROOT/public/.fp-php-probe.php"; }

"$FP" run --config "$D/Caddyfile" --adapter caddyfile > "$D/fp.log" 2>&1 &
FPID=$!

for _ in $(seq 1 80); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
        "http://127.0.0.1:$PORT/.fp-php-probe.php")" = "200" ] && break
    sleep 0.25
done

echo "--- FrankenPHP, as this checkout runs it ---"
curl -sS --max-time 10 "http://127.0.0.1:$PORT/.fp-php-probe.php"
echo
echo "--- every other arm, for comparison ---"
for v in php8.3 php8.5; do
    command -v "$v" >/dev/null 2>&1 || continue
    printf '%-8s ' "$v"
    "$v" "$D/php.php"
done
cleanup_probe
