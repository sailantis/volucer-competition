<?php

declare(strict_types=1);

/**
 * Can an object get into the route table today?
 *
 * The proposal is that routes and route middleware should never accept objects,
 * which would make the export-time check unnecessary rather than merely defensive.
 * That is only true if it holds for every entry point, so this tries to smuggle an
 * object in through each one and reports which succeed.
 *
 * Two things are being established:
 *
 *   1. Does the current type system already prevent it? (`pushGroupValues` is typed
 *      `string|array`, but an `array` of objects passes that check and then gets
 *      appended element by element with no element-type check.)
 *   2. Where it does NOT, what is the smallest change that closes it -- and does
 *      closing it break any existing usage?
 *
 * Usage: php scripts/probe-route-objects.php
 */

$root = dirname(__DIR__);
require $root . '/vendor/autoload.php';

/** @return string 'accepted' or 'rejected: <reason>' */
function attempt(callable $fn): string
{
    try {
        $fn();
        return 'accepted';
    } catch (TypeError $e) {
        return 'TypeError: ' . preg_replace('/, called in .*$/s', '', $e->getMessage());
    } catch (Throwable $e) {
        return $e::class . ': ' . $e->getMessage();
    }
}

$obj = new stdClass();
$closure = static fn() => 1;
$mw = new class { public function handle(): void {} };

/**
 * Walk a value and list any leaf that a route cache could not persist.
 *
 * This is the honest test: not "did the call throw" but "is anything non-data now
 * in the table". A string middleware is fine; an object middleware is not, and only
 * inspecting the stored value distinguishes them.
 */
function codeIn(mixed $v, string $path = ''): array
{
    if (is_object($v)) {
        return [$path === '' ? '(root)' : $path . ' = ' . get_debug_type($v)];
    }
    $found = [];
    if (is_array($v)) {
        foreach ($v as $k => $item) {
            $found = array_merge($found, codeIn($item, $path === '' ? (string) $k : $path . '.' . $k));
        }
    }
    return $found;
}

$cases = [
    // --- handler: the obvious place ---
    'handler = closure' => static fn(\Azera\Core\Router $r) => $r->get('/a', $closure),
    'handler = object' => static fn(\Azera\Core\Router $r) => $r->get('/a', $obj),
    'add(handler = object)' => static fn(\Azera\Core\Router $r) => $r->add('GET', '/a', $obj),

    // --- middleware: strings are the documented and legitimate form ---
    'middleware = string' => static fn(\Azera\Core\Router $r) => $r->middleware('auth')->get('/a', 'A::b'),
    'middleware = array of strings' => static fn(\Azera\Core\Router $r) => $r->middleware(['auth', 'csrf'])->get('/a', 'A::b'),

    // --- middleware: the actual question ---
    'middleware = array of objects' => static fn(\Azera\Core\Router $r) => $r->middleware([$mw])->get('/a', 'A::b'),
    'middleware = array of closures' => static fn(\Azera\Core\Router $r) => $r->middleware([$closure])->get('/a', 'A::b'),
    'middleware = array mixing' => static fn(\Azera\Core\Router $r) => $r->middleware(['auth', $mw])->get('/a', 'A::b'),

    // --- handler array form: keys are strings, values could be anything ---
    'handler array with object value' => static fn(\Azera\Core\Router $r) => $r->get('/a', ['controller' => $obj]),
    'handler array with closure value' => static fn(\Azera\Core\Router $r) => $r->get('/a', ['action' => $closure]),
];

echo "Is anything non-data in the route table after each call?\n";
echo str_repeat('=', 74), "\n";
$leaks = [];
foreach ($cases as $label => $fn) {
    $r = new \Azera\Core\Router();
    $err = null;
    try {
        $fn($r);
    } catch (Throwable $e) {
        $err = $e::class;
    }

    if ($err !== null) {
        printf("  %-32s rejected (%s)\n", $label, $err);
        continue;
    }

    // Inspect what the table actually holds, across every property that a cache
    // would persist.
    $bad = [];
    $ref = new ReflectionClass($r);
    foreach (['static', 'groups', 'namedRoutes', 'middlewareGroupStack'] as $prop) {
        $p = $ref->getProperty($prop);
        $p->setAccessible(true);
        foreach (codeIn($p->getValue($r), $prop) as $path) {
            $bad[] = $path;
        }
    }

    if ($bad === []) {
        printf("  %-32s ok, table is data only\n", $label);
    } else {
        printf("  %-32s LEAK: %s\n", $label, implode('; ', $bad));
        $leaks[] = $label;
    }
}

echo "\n";
if ($leaks === []) {
    echo "Every entry point leaves the table as data. An export check would be redundant.\n";
} else {
    printf("%d entry point(s) can put code in the table:\n", count($leaks));
    foreach ($leaks as $l) {
        echo "  - {$l}\n";
    }
}

// ---------------------------------------------------------------------------
// If an object DOES get in, what does it do to the table?
// ---------------------------------------------------------------------------

echo "\nWhat an object in the middleware stack does to the table\n";
echo str_repeat('-', 74), "\n";
$r = new \Azera\Core\Router();
try {
    $r->middleware([$mw]);
    $r->get('/a', 'A::b');
    $ref = new ReflectionProperty(\Azera\Core\Router::class, 'static');
    $ref->setAccessible(true);
    $table = $ref->getValue($r);
    printf("  table holds: %s\n", implode(', ', array_map('get_debug_type', $table['GET']['/a']['groups'] ?? [])));
    printf("  var_export:  %s\n", str_contains(var_export($table, true), '__set_state')
        ? 'would emit __set_state() and fatal on include'
        : 'fine');
    printf("  serialize:   %s\n", attempt(static fn() => serialize($table)));
} catch (Throwable $e) {
    printf("  rejected: %s\n", $e->getMessage());
}
