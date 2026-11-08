<?php

declare(strict_types=1);

/**
 * What is a cold `DB connection actually doing for 164 us?
 *
 * `probe-cold-dispatch.php` attributes 163.6 us to the first statement on a cold
 * container, but `new PDO(...)` measured alone is 20.1 us and the three PRAGMAs
 * are ~1 us each. So ~140 us is unaccounted, and an unexplained term is exactly
 * what starts a wrong story. This splits it.
 *
 * Usage: php scripts/probe-db-connect.php
 */

$root = dirname(__DIR__);
require $root . '/vendor/autoload.php';

function med(array $xs): float
{
    sort($xs);
    $n = count($xs);
    return $n % 2 ? $xs[intdiv($n, 2)] : ($xs[$n / 2 - 1] + $xs[$n / 2]) / 2;
}

$db = $root . '/data/bench.sqlite';

for ($i = 0; $i < 100; $i++) {
    $t0 = hrtime(true);
    new PDO('sqlite:' . $db);
    $t['bare new PDO'][] = (hrtime(true) - $t0) / 1000.0;
}

for ($i = 0; $i < 100; $i++) {
    $t0 = hrtime(true);
    new \Azera\Db\Database('sqlite:' . $db);
    $t['new Azera\Database'][] = (hrtime(true) - $t0) / 1000.0;
}

for ($i = 0; $i < 100; $i++) {
    $t0 = hrtime(true);
    $d = new \Azera\Db\Database('sqlite:' . $db);
    $d->query('PRAGMA journal_mode = WAL');
    $d->query('PRAGMA busy_timeout = 5000');
    $d->useStatementCache(true);
    // as Bootstrap wires it
    $t['Database + PRAGMAs + cache'][] = (hrtime(true) - $t0) / 1000.0;
}

for ($i = 0; $i < 100; $i++) {
    $t0 = hrtime(true);
    $d = new \Azera\Db\Database('sqlite:' . $db);
    $d->query('PRAGMA journal_mode = WAL');
    $d->query('PRAGMA busy_timeout = 5000');
    $d->useStatementCache(true);
    $d->query('SELECT 1');
    $t['Database + PRAGMAs + first q'][] = (hrtime(true) - $t0) / 1000.0;
}

for ($i = 0; $i < 100; $i++) {
    $t0 = hrtime(true);
    $d = new \Azera\Db\Database('sqlite:' . $db);
    $d->useStatementCache(true);
    $d->query('SELECT 1');
    $t['Database + cache + first query'][] = (hrtime(true) - $t0) / 1000.0;
}

// The statement cache reuses prepared statements. The *first* statement in a
// process also pays for the sqlite3 driver's own initialisation, which is once
// per process and therefore warm-arm-only in practice.
for ($i = 0; $i < 100; $i++) {
    $t0 = hrtime(true);
    $d = new \Azera\Db\Database('sqlite:' . $db);
    $d->useStatementCache(true);
    $d->query('SELECT 1');
    $d->query('SELECT 1');
    $d->query('SELECT 1');
    $t['... plus 2 more queries'][] = (hrtime(true) - $t0) / 1000.0;
}

printf("%-32s %10s\n", 'operation', 'median');
echo str_repeat('-', 44), "\n";
foreach ($t as $k => $xs) {
    printf("%-32s %8.1f us\n", $k, med($xs));
}

// Which PRAGMA is the expensive one? `journal_mode = WAL` has to take a lock on
// the database file, and it is the only one of the three that can write.
//
// Only the *first* two are measured: `journal_mode = WAL` is persistent (it is
// stored in the file header), so measuring it repeatedly on an already-WAL file
// measures a no-op, and measuring a switch *away* from WAL would leave the
// benchmark's database in the wrong mode. `probe-db-connect.php` must never
// change the database it is measuring -- an earlier version did exactly that by
// timing `journal_mode = DELETE` and left WAL off.
echo "\n  each PRAGMA on a fresh connection:\n";
foreach (['busy_timeout = 5000', 'journal_mode = WAL'] as $p) {
    $s = [];
    for ($i = 0; $i < 100; $i++) {
        $d = new \Azera\Db\Database('sqlite:' . $db);
        $t0 = hrtime(true);
        $d->query('PRAGMA ' . $p);
        $s[] = (hrtime(true) - $t0) / 1000.0;
    }
    printf("    %-28s %8.1f us\n", $p, med($s));
}

// And the whole wiring again, to show the two together.
$s = [];
for ($i = 0; $i < 100; $i++) {
    $t0 = hrtime(true);
    $d = new \Azera\Db\Database('sqlite:' . $db);
    $d->query('PRAGMA busy_timeout = 5000');
    $d->useStatementCache(true);
    $s[] = (hrtime(true) - $t0) / 1000.0;
}
printf("\n  without journal_mode=WAL          %8.1f us\n", med($s));
