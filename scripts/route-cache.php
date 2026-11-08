<?php

declare(strict_types=1);

/**
 * A `route:cache` for Azera, as a deploy step.
 *
 * This exists to answer "how would a cache handle closures?" with code rather than
 * opinion. The short answer, measured by `probe-route-serialisation.php`:
 *
 *   * A closure can NEVER be a route handler. `Router::add()` is typed
 *     `string|array|null $handler`, so `$r->get('/x', fn() => 1)` is a TypeError
 *     before the cache is involved. There is nothing to persist and nothing to
 *     handle.
 *
 *   * The only closures in router state are the parameter validators in
 *     `Router::$types`. They block a naive `var_export` (which emits
 *     `\Closure::__set_state(array())` and fatals on include). But they are CODE,
 *     not data: five fixed built-ins seeded by the constructor, plus whatever the
 *     app registered with `Router::type()`. So the cache simply omits `$types` and
 *     lets the constructor re-create it -- which it does, because `new Router()`
 *     runs the constructor. Verified: a cached table missing `$types` still matches
 *     `/items/7`, whose `{id:int}` needs the `int` validator.
 *
 * That is the whole design, and it is why this is fifteen lines of filtering rather
 * than a serialisation format.
 *
 * What is deliberately NOT cached: `$resolvedOverrides` is a per-handler memo that
 * costs 0.41 us on its first use and is cheap to rebuild, so persisting it would
 * trade a correctness risk (a stale triple after a deploy) for ~nothing. The
 * filter below excludes it for that reason, not because it cannot be exported.
 *
 * Usage:
 *   php scripts/route-cache.php --write [--out=path]   # deploy step
 *   php scripts/route-cache.php --verify [--out=path] # CI check
 *
 * The bootstrap has to be the application's, because only the application knows its
 * route table. This script therefore boots through `App\Azera\Bootstrap`, which is
 * the same entry point every SAPI uses.
 */

$root = dirname(__DIR__);
require $root . '/vendor/autoload.php';
require $root . '/BenchApp.php';

$write = in_array('--write', $argv, true);
$verify = in_array('--verify', $argv, true);
$out = $root . '/data/cache/routes.php';
foreach ($argv as $a) {
    if (str_starts_with($a, '--out=')) {
        $out = substr($a, 6);
    }
}

if (!$write && !$verify) {
    fwrite(STDERR, "usage: route-cache.php --write|--verify [--out=path]\n");
    exit(2);
}

/**
 * Properties that must not be persisted because they hold code.
 *
 * `types` is the only one today. Keeping the list explicit rather than testing
 * each value for closures means a future property holding an object is a loud
 * failure at write time instead of a silent skip -- a cache that quietly drops
 * state is much worse than one that refuses to build.
 */
const NOT_DATA = ['types'];

/** Properties rebuilt cheaply per request, so persisting them buys nothing. */
const REBUILT = ['resolvedOverrides'];

/** Read every instance property the router carries, subclass-aware. */
function routerState(\Azera\Core\Router $router): array
{
    $state = [];
    for ($c = new ReflectionClass($router); $c !== false; $c = $c->getParentClass()) {
        foreach ($c->getProperties() as $p) {
            if ($p->isStatic() || $p->getDeclaringClass()->getName() !== $c->getName()) {
                continue;
            }
            $p->setAccessible(true);
            if ($p->isInitialized($router)) {
                $state[$p->getName()] = $p->getValue($router);
            }
        }
    }
    return $state;
}

// Boot the real application. The cache describes this app's table and no other.
\App\Azera\Bootstrap::forget();
$router = \App\Azera\Bootstrap::boot($root . '/data/bench.sqlite')->router();
$state = routerState($router);

$persist = [];
foreach ($state as $name => $value) {
    if (in_array($name, NOT_DATA, true) || in_array($name, REBUILT, true)) {
        continue;
    }
    if (containsCode($value)) {
        fwrite(
            STDERR,
            "refusing to cache: property `{$name}` holds executable code, and a route\n"
            . "cache must not guess at it. Add it to NOT_DATA if the constructor can\n"
            . "re-create it, or to REBUILT if it is cheap to recompute.\n",
        );
        exit(1);
    }
    $persist[$name] = $value;
}

function containsCode(mixed $v): bool
{
    if ($v instanceof Closure || is_object($v)) {
        return true;
    }
    if (is_array($v)) {
        foreach ($v as $item) {
            if (containsCode($item)) {
                return true;
            }
        }
    }
    return false;
}

// Which route patterns carry a custom (non-built-in) parameter type? Those are the
// ones whose validator an app has to re-register; the built-ins come back with the
// constructor. Reported so a stale cache cannot silently lose a constraint.
$builtin = ['int', 'alpha', 'alnum', 'uuid', '*'];
$customTypes = array_values(array_diff(array_keys($state['types'] ?? []), $builtin));

$header = sprintf(
    "<?php\n\n// Generated by scripts/route-cache.php. Do not edit.\n"
    . "// Routes: %d. Built with PHP %s.\n"
    . "// Omitted as code (re-created by the constructor): %s\n"
    . "// Omitted as cheap to rebuild: %s\n"
    . "// Custom parameter types the application must re-register: %s\n\n",
    countRoutes($persist),
    PHP_VERSION,
    implode(', ', NOT_DATA),
    implode(', ', REBUILT),
    $customTypes === [] ? '(none)' : implode(', ', $customTypes),
);

if ($write) {
    if (!is_dir(dirname($out))) {
        mkdir(dirname($out), 0777, true);
    }
    // Write atomically: a half-written route file picked up by a request during a
    // deploy is a fatal error, and `rename` on the same filesystem is atomic.
    $tmp = $out . '.tmp.' . getmypid();
    file_put_contents($tmp, $header . 'return ' . var_export($persist, true) . ";\n");
    rename($tmp, $out);
    printf(
        "wrote %s (%.1f KB, %d routes)\n",
        $out,
        filesize($out) / 1024,
        countRoutes($persist),
    );
    exit(0);
}

// --verify: does the file describe the table the code would build today?
if (!is_file($out)) {
    fwrite(STDERR, "no cache at {$out}; run --write\n");
    exit(1);
}
$cached = require $out;
$diffs = [];
foreach ($persist as $name => $value) {
    if (!array_key_exists($name, $cached)) {
        $diffs[] = "{$name}: missing from cache";
        continue;
    }
    if ($cached[$name] != $value) {
        $diffs[] = "{$name}: differs";
    }
}
foreach (array_keys($cached) as $name) {
    if (!array_key_exists($name, $persist)) {
        $diffs[] = "{$name}: stale, not in the current table";
    }
}

if ($diffs === []) {
    printf("cache is current: %d properties match, %d routes\n", count($persist), countRoutes($persist));
    exit(0);
}
fwrite(STDERR, "cache is STALE:\n  " . implode("\n  ", $diffs) . "\n");
exit(1);

function countRoutes(array $persist): int
{
    $n = 0;
    foreach ($persist['static'] ?? [] as $byPath) {
        $n += count($byPath);
    }
    foreach ($persist['groups'] ?? [] as $bucket) {
        foreach ($bucket as $list) {
            $n += count($list);
        }
    }
    return $n;
}
