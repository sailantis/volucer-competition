<?php

declare(strict_types=1);

/**
 * Is the 61 us the PRAGMA's cost, or the cost of being the first statement?
 *
 * `probe-db-connect.php` reports 61 us for `PRAGMA journal_mode = WAL` on a fresh
 * connection, and 61.5 us for `PRAGMA synchronous = NORMAL`, which is not even in
 * the app's wiring. Two unrelated PRAGMAs costing the same amount to the tenth of
 * a microsecond is suspicious: it points at something a fresh SQLite connection
 * does on its *first* statement rather than at either statement's semantics.
 *
 * If that is right, the app is not paying 61 us for WAL -- it is paying 61 us for
 * touching the database at all, which the app has to do anyway, and the fix
 * (dropping the PRAGMA) would save nothing.
 *
 * Usage: php scripts/probe-db-first-statement.php
 */

$root = dirname(__DIR__);
require $root . '/vendor/autoload.php';
$db = $root . '/data/bench.sqlite';

function med(array $x): float
{
    sort($x);
    $n = count($x);
    return $n % 2 ? $x[intdiv($n, 2)] : ($x[$n / 2 - 1] + $x[$n / 2]) / 2;
}

function timed(callable $f, int $n = 100): float
{
    $s = [];
    for ($i = 0; $i < $n; $i++) {
        $t = hrtime(true);
        $f();
        $s[] = (hrtime(true) - $t) / 1000.0;
    }
    return med($s);
}

$mode = (new PDO('sqlite:' . $db))->query('PRAGMA journal_mode')->fetchColumn();
echo "database journal_mode: {$mode}\n\n";

printf("%-52s %8s\n", 'first statement on a fresh connection', 'median');
echo str_repeat('-', 61), "\n";

foreach ([
    'new PDO only, no statement' => static fn() => new PDO('sqlite:' . $db),
    'SELECT 1' => static function () use ($db) {
        (new PDO('sqlite:' . $db))->query('SELECT 1');
    },
    'PRAGMA busy_timeout = 5000' => static function () use ($db) {
        (new PDO('sqlite:' . $db))->query('PRAGMA busy_timeout = 5000');
    },
    'PRAGMA synchronous = NORMAL' => static function () use ($db) {
        (new PDO('sqlite:' . $db))->query('PRAGMA synchronous = NORMAL');
    },
    'PRAGMA journal_mode = WAL (already wal)' => static function () use ($db) {
        (new PDO('sqlite:' . $db))->query('PRAGMA journal_mode = WAL');
    },
    'PRAGMA cache_size = -2000' => static function () use ($db) {
        (new PDO('sqlite:' . $db))->query('PRAGMA cache_size = -2000');
    },
] as $label => $f) {
    printf("%-52s %6.1f us\n", $label, timed($f));
}

echo "\n  statements on an already-warm connection (2nd statement):\n";
foreach ([
    'PRAGMA journal_mode = WAL',
    'SELECT 1',
    'PRAGMA busy_timeout = 5000',
] as $sql) {
    $s = [];
    for ($i = 0; $i < 100; $i++) {
        $d = new PDO('sqlite:' . $db);
        $d->query('PRAGMA busy_timeout = 5000');   // pay the first-statement cost
        $t = hrtime(true);
        $d->query($sql);
        $s[] = (hrtime(true) - $t) / 1000.0;
    }
    printf("    %-46s %6.1f us\n", $sql, med($s));
}

echo "\n  whole wiring, as Bootstrap does it:\n";
printf("    %-46s %6.1f us\n", 'PDO + busy_timeout + WAL + stmt cache', timed(static function () use ($db) {
    $d = new \Azera\Db\Database('sqlite:' . $db);
    $d->query('PRAGMA journal_mode = WAL');
    $d->query('PRAGMA busy_timeout = 5000');
    $d->useStatementCache(true);
}));
printf("    %-46s %6.1f us\n", 'PDO + busy_timeout + stmt cache (no WAL)', timed(static function () use ($db) {
    $d = new \Azera\Db\Database('sqlite:' . $db);
    $d->query('PRAGMA busy_timeout = 5000');
    $d->useStatementCache(true);
}));
