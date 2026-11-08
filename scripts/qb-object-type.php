<?php

declare(strict_types=1);

// What does /items-qb actually hand the template?
require __DIR__ . '/../vendor/autoload.php';
require __DIR__ . '/../BenchApp.php';

use Azera\AppContext;
use Azera\Db\Query;

$app = new BenchApp(__DIR__ . '/../data/bench.sqlite');
$app->bootstrap();

$p = Query::raw()->table('items')->paginate(1, 20);
$items = $p->objects();

$first = $items[0];
printf("/items      -> %s\n", get_class(App\Azera\Models\Item::query()->limit(1)->entities()[0]));
AppContext::instance()->clearRequestScope();
printf("/items-qb   -> %s\n", get_class($first));
printf("            -> has save()?  %s\n", method_exists($first, 'save') ? 'yes' : 'no');
printf("            -> is a Model?  %s\n", $first instanceof \Azera\Orm\Model ? 'yes' : 'no');
printf("            -> heap nodes after the read: %d\n", AppContext::instance()->heap()->count());
printf("            -> properties: %s\n", implode(', ', array_keys((array) $first)));
printf("            -> values: %s\n", json_encode($first));
