<?php

declare(strict_types=1);

/*
 * Is the page byte-identical whether it is hydrated through the ORM or built
 * from stdClass rows? A faster variant that renders different HTML is not a
 * faster variant, it is a different benchmark.
 *
 * Compares the four rendering-relevant hydration sources for the same page and
 * the same template, and also compares against what the template accesses.
 *
 * Usage: php scripts/items-equivalence.php
 */

require __DIR__ . '/../vendor/autoload.php';
require __DIR__ . '/../BenchApp.php';

use App\Azera\Models\Item;
use Azera\AppContext;

$app = new BenchApp(__DIR__ . '/../data/bench.sqlite');
$app->bootstrap();
$view = AppContext::instance()->view();

function page(object $paginator, array $items, $view): string
{
    return $view->render('items.list', [
        'baseUrl'    => '/items',
        'items'      => $items,
        'pagination' => [
            'currentPage'  => $paginator->currentPage(),
            'lastPage'     => $paginator->lastPage(),
            'previousPage' => $paginator->previousPage(),
            'nextPage'     => $paginator->nextPage(),
            'totalItems'   => $paginator->totalItems(),
            'firstItem'    => $paginator->firstItem(),
            'lastItem'     => $paginator->lastItem(),
            'hasPrevious'  => $paginator->hasPrevious(),
            'hasNext'      => $paginator->hasNext(),
        ],
    ]);
}

$out = [];

$p = Item::query()->paginate(1, 20);
$out['entities (ORM)']  = page($p, $p->entities(), $view);
AppContext::instance()->clearRequestScope();

$p = Item::query()->paginate(1, 20);
$out['objects (stdClass)'] = page($p, $p->objects(), $view);
AppContext::instance()->clearRequestScope();

// `assoc()` is deliberately not compared: it yields arrays, and the template
// reads `{{ item.id }}` (property access), so it cannot render this page at all.
// The failure is asserted rather than assumed.
$p = Item::query()->paginate(1, 20);
try {
    page($p, $p->assoc(), $view);
    printf("assoc: UNEXPECTEDLY rendered — the template must be reading properties\n");
} catch (\Throwable $e) {
    printf("assoc: cannot render this page (%s) — not a candidate\n", substr($e->getMessage(), 0, 60));
}
AppContext::instance()->clearRequestScope();

printf("\npage sizes / hashes:\n");
foreach ($out as $label => $html) {
    printf("  %-22s %5d bytes  md5 %s\n", $label, strlen($html), md5($html));
}

$reference = $out['entities (ORM)'];
printf("\n");
foreach ($out as $label => $html) {
    printf("  %-22s %s\n", $label, $html === $reference ? 'IDENTICAL' : 'DIFFERS');
}

// Show the first difference, so a mismatch is actionable rather than a verdict.
foreach ($out as $label => $html) {
    if ($html === $reference) {
        continue;
    }
    $len = min(strlen($html), strlen($reference));
    for ($i = 0; $i < $len; $i++) {
        if ($html[$i] !== $reference[$i]) {
            printf("\n  first difference in %s at byte %d:\n    ORM:     %s\n    variant: %s\n",
                $label, $i,
                json_encode(substr($reference, max(0, $i - 30), 70)),
                json_encode(substr($html, max(0, $i - 30), 70)));
            break;
        }
    }
}
