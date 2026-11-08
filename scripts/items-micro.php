<?php

declare(strict_types=1);

// Measure /items and one render with whatever is currently in vendor/.
// Run with REVAL=<seconds> to exercise the revalidate window (needs the patched
// clarity-engine); omit it on the unpatched baseline.
// Usage: php scripts/micro.php [iterations]

require __DIR__ . '/../vendor/autoload.php';
require __DIR__ . '/../BenchApp.php';

use Azera\AppContext;

$n   = (int) ($argv[1] ?? 20000);
$rev = getenv('REVAL');

$app = new BenchApp(__DIR__ . '/../data/bench.sqlite');
$app->bootstrap();
$ctx  = AppContext::instance();
$view = $ctx->view();

if ($rev !== false && method_exists($view, 'setRevalidateFreq')) {
    $view->setRevalidateFreq((int) $rev);
}

function t(string $label, int $n, callable $fn, bool $reset = false): float
{
    for ($i = 0; $i < min(300, $n); $i++) {
        $fn();
        if ($reset) {
            AppContext::instance()->clearRequestScope();
        }
    }
    $t0 = hrtime(true);
    for ($i = 0; $i < $n; $i++) {
        $fn();
        if ($reset) {
            AppContext::instance()->clearRequestScope();
        }
    }
    $us = (hrtime(true) - $t0) / 1000 / $n;
    printf("%-46s %8.3f us\n", $label, $us);
    return $us;
}

$prop = fn(string $p) => (function () use ($p) {
    $r = new ReflectionProperty($this, $p);
    $r->setAccessible(true);
    return $r->getValue($this);
})->call($view);

$hasReval = method_exists($view, 'getRevalidateFreq');
printf("clarity: revalidateFreq %s\n", $hasReval ? 'PRESENT (' . $view->getRevalidateFreq() . ')' : 'absent');

$items = App\Azera\Models\Item::query()->limit(20)->select();
$vars = [
    'baseUrl' => '/items', 'items' => $items, 'title' => 'Items',
    'locale' => 'en_US', 'platform' => 'desktop',
    'pagination' => array_fill_keys(
        ['currentPage','lastPage','previousPage','nextPage','totalItems',
         'firstItem','lastItem','hasPrevious','hasNext'], 1),
];

echo "\n";
t('Policy::digest()', $n, fn() => $view->getPolicy()->digest());

$cache  = $prop('cache');
$loader = (new ReflectionMethod($view, 'getLoader'))->invoke($view);
t('isFresh(partials/header)  [1 dep]', $n,
    fn() => $cache->isFresh('partials/header', static fn(string $x) => $loader->load($x)?->revision));
t('isFresh(items.list)  [3 deps]', $n,
    fn() => $cache->isFresh('items.list', static fn(string $x) => $loader->load($x)?->revision));

printf("\n");
t('view->render(items.list)', $n, fn() => $view->render('items.list', $vars));
t('dispatch(/api/items)', $n, fn() => $app->dispatch('GET', '/api/items'), true);
t('dispatch(/items)', $n, fn() => $app->dispatch('GET', '/items'), true);

$app->cleanup();
