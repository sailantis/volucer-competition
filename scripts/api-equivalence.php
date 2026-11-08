<?php

declare(strict_types=1);

/*
 * Does /api/items produce the same JSON from entities() as from select()?
 *
 * The benchmark's ApiController::indexAction() hydrates through the ORM, then
 * immediately flattens the entities back into arrays for json_encode(). The
 * identity map has nothing to contribute there: one LIMIT 20 over a unique PK
 * cannot repeat a row, so every findById() is a miss.
 *
 * Usage: php scripts/api-equivalence.php
 */

require __DIR__ . '/../vendor/autoload.php';
require __DIR__ . '/../BenchApp.php';

use App\Azera\Models\Item;
use Azera\AppContext;

$app = new BenchApp(__DIR__ . '/../data/bench.sqlite');
$app->bootstrap();

$viaEntities = json_encode(Item::query()->orderBy('id', 'asc')->limit(20)->entities());
AppContext::instance()->clearRequestScope();

// select() yields a ResultSet, which the controller flattens with toArray(), so
// the comparable call is the same flattening.
$viaSelect = json_encode(Item::query()->orderBy('id', 'asc')->limit(20)->select()->toArray());
AppContext::instance()->clearRequestScope();

printf("entities(): %5d bytes  md5 %s\n", strlen($viaEntities), md5($viaEntities));
printf("select():   %5d bytes  md5 %s\n", strlen($viaSelect), md5($viaSelect));
printf("identical JSON: %s\n", $viaEntities === $viaSelect ? 'YES' : 'NO');

if ($viaEntities !== $viaSelect) {
    $len = min(strlen($viaEntities), strlen($viaSelect));
    for ($i = 0; $i < $len; $i++) {
        if ($viaEntities[$i] !== $viaSelect[$i]) {
            printf("\nfirst difference at byte %d:\n  entities: %s\n  select:   %s\n", $i,
                substr($viaEntities, max(0, $i - 40), 90),
                substr($viaSelect, max(0, $i - 40), 90));
            break;
        }
    }
}
