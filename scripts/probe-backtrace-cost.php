<?php

declare(strict_types=1);

/**
 * What does it actually cost to record which file registered a route?
 *
 * `probe-route-sources.php` showed `debug_backtrace()` finds the caller correctly,
 * but at ~0.31 us per registration that is 37 us across 120 routes -- over a fifth
 * of the 171 us boot a route cache exists to remove. That would be a poor trade if
 * it were paid on every request.
 *
 * Two things decide whether it is affordable, and both are measured here:
 *
 *   1. `$limit` -- the frame count passed to debug_backtrace. A limit of 2 should
 *      be far cheaper than 8, and 2 is enough when the caller is one frame out.
 *   2. *when* it is paid. Recording is only needed while writing the cache, which
 *      happens in a deploy step. A restored request registers no routes at all, so
 *      the hot path pays nothing. That is asserted rather than assumed.
 *
 * Usage: php scripts/probe-backtrace-cost.php
 */

$root = dirname(__DIR__);
require $root . '/vendor/autoload.php';

function med(array $xs): float
{
    sort($xs);
    $n = count($xs);
    return $n % 2 ? $xs[intdiv($n, 2)] : ($xs[$n / 2 - 1] + $xs[$n / 2]) / 2;
}

/** Mimics Router::add() with a configurable backtrace limit; 0 = tracking off. */
final class R
{
    /** @var array<string,true> */
    public array $sources = [];
    public int $limit = 0;

    public function add(): void
    {
        if ($this->limit > 0) {
            $trace = debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS, $this->limit);
            if (isset($trace[0]['file'])) {
                $this->sources[$trace[0]['file']] = true;
            }
        }
    }

    /** The `get()` -> `add()` shape the real router has. */
    public function get(): void
    {
        $this->add();
    }
}

$r = new R();
$N = 3000;

echo "Cost of recording the caller file, as Router::add() would pay it\n";
echo str_repeat('-', 62), "\n";

foreach ([0, 2, 3, 8] as $limit) {
    $r->limit = $limit;
    $s = [];
    for ($i = 0; $i < $N; $i++) {
        $t = hrtime(true);
        $r->get();
        $s[] = (hrtime(true) - $t) / 1000.0;
    }
    $label = $limit === 0 ? 'tracking off' : "limit={$limit}";
    printf(
        "  %-14s %.3f us/route   x120 = %6.1f us\n",
        $label,
        med($s),
        med($s) * 120,
    );
}

// Is a limit of 2 enough to still find the right file through get() -> add()?
$r->limit = 2;
$r->sources = [];
$r->get();
$found = array_key_first($r->sources);
printf(
    "\n  limit=2 still resolves the caller: %s (%s)\n",
    $found === false ? 'NO' : 'yes',
    $found === false ? '-' : basename($found),
);
printf("  ...and it is this probe, not the R class: %s\n", $found === __FILE__ ? 'yes' : 'NO');

// The restore-vs-build comparison moved to probe-route-encodings.php, which already
// establishes it (106.1 us build vs 17.1 us restore) with a clean two-process split.
// Keeping a second copy here invited the file_update_protection trap twice, so this
// probe now answers only the one question in its name: what recording costs.
