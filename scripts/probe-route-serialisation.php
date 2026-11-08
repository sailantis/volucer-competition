<?php

declare(strict_types=1);

/**
 * What in a Router's state actually fails to go through a route cache?
 *
 * The question that prompted this: "how would a route cache handle closures?"
 * The answer is more interesting than expected, and it is not about handlers.
 *
 * `Router::add()` is typed `string|array|null $handler`, so a closure can never be
 * a handler -- the type union refuses it before any caching question arises. But
 * the *router* does hold closures: the constructor seeds `$this->types` with
 * `int`/`alpha`/`alnum`/`uuid`/`*` as closures, and `Router::type()` lets an
 * application register more. Those closures live in the same object whose state a
 * cache would have to persist, and `var_export` cannot represent a closure at all:
 * it emits `\Closure::__set_state(array())`, which fatals on inclusion.
 *
 * That is the real constraint, and it is the reason the cached table must be
 * *filtered* rather than dumped wholesale. This probe finds exactly which
 * properties block a cache, and checks that the ones that do are reconstructible.
 *
 * Usage: php scripts/probe-route-serialisation.php
 */

$root = dirname(__DIR__);
require $root . '/vendor/autoload.php';

/** Reflectively read every property a Router carries. */
function routerState(\Azera\Core\Router $router): array
{
    $state = [];
    $ref = new ReflectionClass($router);
    for ($c = $ref; $c !== false; $c = $c->getParentClass()) {
        foreach ($c->getProperties() as $p) {
            if ($p->getDeclaringClass()->getName() !== $c->getName()) {
                continue;
            }
            if ($p->isStatic()) {
                continue;
            }
            $p->setAccessible(true);
            if (!$p->isInitialized($router)) {
                $state[$p->getName()] = '(uninitialised)';
                continue;
            }
            $state[$p->getName()] = $p->getValue($router);
        }
    }
    return $state;
}

/** Does this value survive var_export -> require -> compare? */
function exportable(mixed $value): array
{
    if ($value instanceof Closure) {
        return [false, 'Closure'];
    }
    if (is_object($value)) {
        return [false, 'object ' . $value::class];
    }
    if (is_array($value)) {
        foreach ($value as $k => $v) {
            [$ok, $why] = exportable($v);
            if (!$ok) {
                return [false, "array[$k] -> $why"];
            }
        }
    }
    if (is_resource($value)) {
        return [false, 'resource'];
    }
    return [true, ''];
}

\App\Azera\Bootstrap::forget();
$router = \App\Azera\Bootstrap::boot($root . '/data/bench.sqlite')->router();
$state = routerState($router);

echo "Router state, property by property\n";
echo str_repeat('-', 68), "\n";
$blocked = [];
$clean = [];
foreach ($state as $name => $value) {
    [$ok, $why] = exportable($value);
    $type = is_array($value) ? 'array(' . count($value) . ')' : get_debug_type($value);
    printf("  %-22s %-16s %s\n", $name, $type, $ok ? 'exportable' : "BLOCKS: $why");
    if ($ok) {
        $clean[] = $name;
    } else {
        $blocked[] = $name;
    }
}

echo "\n";
if ($blocked === []) {
    echo "Nothing blocks a cache.\n";
} else {
    printf("%d of %d properties block a cache: %s\n", count($blocked), count($state), implode(', ', $blocked));
}

// --- What is actually inside $types, and can it be rebuilt? ---
echo "\n\$types — the closures that block a naive dump\n";
echo str_repeat('-', 68), "\n";
$types = $state['types'] ?? [];
foreach ($types as $name => $validator) {
    printf(
        "  %-8s %s\n",
        $name,
        $validator instanceof Closure ? 'Closure' : get_debug_type($validator),
    );
}

echo "\n";
echo "These are the built-in validators. They are created by the constructor with a\n";
echo "fixed set of names, so a cached table can leave them out entirely and let the\n";
echo "constructor re-create them -- they are code, not data. An application that\n";
echo "calls Router::type('name', $fn) registers a closure that is equally code, and\n";
echo "equally reconstructible by re-running that call.\n";

// --- Prove the filtered subset round-trips and still routes ---
echo "\nFiltered cache: export everything except the closure-bearing properties\n";
echo str_repeat('-', 68), "\n";

$ref = new ReflectionClass(\Azera\Core\Router::class);
$persist = [];
foreach ($state as $name => $value) {
    if ($name === 'types' || $name === '(uninitialised)') {
        continue;
    }
    if (exportable($value)[0]) {
        $persist[$name] = $value;
    }
}

$tmp = sys_get_temp_dir() . '/filtered-routes.php';
// Written by one process and required by another in `probe-route-encodings.php`;
// here it is written and required in this process, which is fine because this
// probe only asks whether the SHAPE round-trips, not how fast it loads.
file_put_contents($tmp, '<?php return ' . var_export($persist, true) . ';');

$loaded = require $tmp;
$fresh = new \Azera\Core\Router();          // constructor re-seeds $types
foreach ($loaded as $name => $value) {
    $p = $ref->getProperty($name);
    $p->setAccessible(true);
    $p->setValue($fresh, $value);
}

printf("  persisted %d properties: %s\n", count($persist), implode(', ', array_keys($persist)));

$probe = [
    ['/echo', 'GET'],
    ['/', 'GET'],
    ['/items', 'GET'],
    ['/items/7', 'GET'],            // int param -> needs the int validator
    ['/api/items', 'GET'],
    ['/items-qb', 'GET'],
    ['/blog/hello-world', 'GET'],   // static filler
    ['/api/v1/Page/show', 'GET'],
    ['/no-such-route', 'GET'],
];
$diffs = 0;
foreach ($probe as [$uri, $m]) {
    $a = $router->match($uri, $m);
    $b = $fresh->match($uri, $m);
    if ($a != $b) {
        $diffs++;
        printf("  MISMATCH %s\n    source: %s\n    cached: %s\n", $uri, json_encode($a), json_encode($b));
    }
}
echo $diffs === 0
    ? sprintf("\n  OK: all %d routes match, including the typed one -- the constructor\n"
        . "  re-created the validators the cache deliberately did not store.\n", count($probe))
    : "\n  FAILED\n";

// --- And the custom-type case: does it survive? ---
echo "\nWhat happens if an app registers a custom type?\n";
echo str_repeat('-', 68), "\n";
$custom = new \Azera\Core\Router();
$custom->type('slug', static fn($v) => preg_match('/^[a-z0-9-]+$/', $v) === 1);
$custom->get('/blog/{slug:slug}', 'Blog::view');
$customState = routerState($custom);
[$ok, $why] = exportable($customState['types']);
printf("  \$types after type('slug', fn) -> %s\n", $ok ? 'exportable' : "BLOCKS: $why");
echo "\n  So a custom validator must be re-registered by the app on every request, exactly\n";
echo "  as the built-ins are re-created by the constructor. It is code. The cache can\n";
echo "  store which type NAMES exist, but the closure itself has to come from the app.\n";

@unlink($tmp);
