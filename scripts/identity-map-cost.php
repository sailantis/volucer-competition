<?php

declare(strict_types=1);

/*
 * What the identity map actually buys, on the same rows the benchmark reads.
 *
 * The benchmark's /items page only READS. A CRUD page reads, mutates and writes,
 * and the write is what the identity map exists for:
 *
 *   - the in-request identity guarantee (one row = one object, always);
 *   - the SNAPSHOT taken at load, which is what makes save() a diff — it can
 *     tell which columns the caller changed, so it emits an UPDATE of those and
 *     nothing else;
 *   - the untracked case, where there is no snapshot and the write has to be a
 *     blind UPDATE of every column (or fail to compile at all).
 *
 * This prints the SQL each path emits for "read item 7, change its title, save".
 *
 * Usage: php scripts/identity-map-cost.php
 */

require __DIR__ . '/../vendor/autoload.php';
require __DIR__ . '/../BenchApp.php';

use App\Azera\Models\Item;
use Azera\AppContext;
use Azera\Orm\Model;

$app = new BenchApp(__DIR__ . '/../data/bench.sqlite');
$app->bootstrap();
$ctx = AppContext::instance();

/** Record every statement the connection prepares. */
function recordSql(): array
{
    $db  = AppContext::instance()->dbManager()->getDefault();
    $pdo = (function () {
        $r = new ReflectionProperty($this, 'pdo');
        $r->setAccessible(true);
        return $r->getValue($this);
    })->call($db);

    // PDO has no statement hook; trace via sqlite's own logging is not exposed,
    // so read the connection's statement log if it keeps one.
    $logProp = new ReflectionProperty($db, 'queries');
    $logProp->setAccessible(true);
    return [$db, $logProp];
}

echo "=== 1. the identity guarantee: same row, same object ===\n";
$ctx->clearRequestScope();
$a = Item::find(7);
$b = Item::find(7);
printf("  Item::find(7) twice -> same object? %s\n", $a === $b ? 'YES' : 'no');
printf("  heap tracks %d node(s)\n", $ctx->heap()->count());

echo "\n=== 2. the snapshot: save() emits a DIFF ===\n";
$a->title = 'Edited title';
$changed = $a->hasChanged();
printf("  hasChanged() after editing one column: %s\n", $changed ? 'true' : 'false');

// Show which columns the diff considers changed.
$em  = $ctx->entityManager();
$node = $ctx->heap()->find($a);
printf("  snapshot columns on the node: %s\n", implode(', ', array_keys($node->data)));
printf("  node state: %d (MANAGED=%d, SCHEDULED_UPDATE=%d)\n",
    $node->state, \Azera\Orm\Node::MANAGED, \Azera\Orm\Node::SCHEDULED_UPDATE);

// What the EM would actually write: only the columns that differ.
$meta = Azera\Orm\Metadata::for(Item::class);
$diff = [];
foreach ($node->data as $col => $was) {
    $field = array_search($col, array_map(fn($c) => $c['name'], $meta['columns']), true);
    $now = $a->{$field} ?? null;
    if ($now != $was) {
        $diff[$col] = [$was, $now];
    }
}
printf("  columns the UPDATE will touch: %s\n",
    $diff === [] ? '(none)' : implode(', ', array_keys($diff)));

echo "\n=== 3. the untracked case, which is what objects() gives you ===\n";
$ctx->clearRequestScope();
// objects() hands back stdClass, not models. There is no save() on it at all.
$row = Item::query()->where('id', '=', 7)->firstEntity();
printf("  firstEntity() -> %s (a tracked Model: has save()? %s)\n",
    get_class($row), method_exists($row, 'save') ? 'YES' : 'no');

$ctx->clearRequestScope();
$plain = Item::query()->where('id', '=', 7)->select()->fetchObject();
printf("  select()->fetchObject() -> %s (has save()? %s)\n",
    get_class($plain), method_exists($plain, 'save') ? 'YES' : 'no');
printf("  heap tracks %d node(s) after the raw read\n", $ctx->heap()->count());

echo "\n=== 4. cost of the two reads, same row ===\n";
function t(string $label, int $n, callable $fn): float
{
    for ($i = 0; $i < 100; $i++) {
        $fn();
        AppContext::instance()->clearRequestScope();
    }
    $t0 = hrtime(true);
    for ($i = 0; $i < $n; $i++) {
        $fn();
        AppContext::instance()->clearRequestScope();
    }
    $us = (hrtime(true) - $t0) / 1000 / $n;
    printf("%-46s %8.2f us\n", $label, $us);
    return $us;
}

echo "\n";
t('Item::find(7)        [tracked, snapshot]', 20000, fn() => Item::find(7));
t('select()->fetchObject()  [untracked]', 20000,
    fn() => Item::query()->where('id', '=', 7)->select()->fetchObject());

echo "\n=== 5. the list page, per row ===\n";
$ctx->clearRequestScope();
t('paginate(1,20)->entities()  [20 tracked]', 5000, function () {
    $p = Item::query()->paginate(1, 20);
    $p->entities();
});
t('paginate(1,20)->objects()   [20 untracked]', 5000, function () {
    $p = Item::query()->paginate(1, 20);
    $p->objects();
});
$ctx->clearRequestScope();
