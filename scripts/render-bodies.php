<?php

declare(strict_types=1);

// Render the benchmark's pages and write each as "<status>\n<body>", so two
// dependency versions can be compared byte for byte.

require __DIR__ . '/../vendor/autoload.php';
require __DIR__ . '/../BenchApp.php';

$out = $argv[1] ?? sys_get_temp_dir() . '/bodies';
if (!is_dir($out)) {
    mkdir($out, 0777, true);
}

$app = new BenchApp(__DIR__ . '/../data/bench.sqlite');
$app->bootstrap();

foreach (['/', '/echo', '/api/items', '/api/items/7', '/items', '/items?page=2'] as $uri) {
    $r = $app->dispatch('GET', $uri);
    $name = preg_replace('/[^a-z0-9]+/i', '_', $uri);
    file_put_contents($out . '/' . $name . '.txt', $r->status . "\n" . $r->body);
    printf("%-20s %d %5d bytes\n", $uri, $r->status, strlen($r->body));
    $app->cleanup();
}
