<?php

declare(strict_types=1);

/**
 * Does the route cache's guard actually fire?
 *
 * `scripts/route-cache.php` claims it refuses to write a cache when a persisted
 * property holds a closure or an object, rather than silently dropping it. A guard
 * that has never been seen to fire is not a guard -- so this exercises it.
 *
 * It builds a variant of the cache script whose exclusion lists are empty, which is
 * exactly the situation a future framework version would create by adding a
 * code-bearing property, and asserts the write is refused with a message naming the
 * property.
 *
 * Usage: php scripts/test-route-cache-guard.php
 */

$root = dirname(__DIR__);
$source = $root . '/scripts/route-cache.php';

$variants = [    // Nothing excluded: `types` holds closures, so this MUST be refused.
    'no exclusions' => [
        'const NOT_DATA = [\'types\'];' => 'const NOT_DATA = [];',
        'const REBUILT = [\'resolvedOverrides\'];' => 'const REBUILT = [];',
    ],
    // Only `types` excluded, `resolvedOverrides` persisted: that one is exportable,
    // so the write must SUCCEED. This is the control that proves the guard is not
    // simply refusing everything.
    'types excluded only' => [
        'const REBUILT = [\'resolvedOverrides\'];' => 'const REBUILT = [];',
    ],
];

$tmp = sys_get_temp_dir() . '/route-cache-variant.php';
$out = sys_get_temp_dir() . '/route-cache-guard-test.php';
$failures = 0;

foreach ($variants as $label => $replacements) {
    $code = file_get_contents($source);
    foreach ($replacements as $from => $to) {
        if (!str_contains($code, $from)) {
            fwrite(STDERR, "FAIL: source does not contain {$from}\n");
            $failures++;
            continue 2;
        }
        $code = str_replace($from, $to, $code);
    }
    // The variant lives in /tmp, so `dirname(__DIR__)` inside it resolves to `/`.
    // Rewrite the root to the real one rather than moving the file, so the variant
    // is byte-identical to the real script apart from the two exclusion lists.
    $code = str_replace(
        '$root = dirname(__DIR__);',
        '$root = ' . var_export($root, true) . ';',
        $code,
    );
    // Point the variant at a scratch output path so the real cache is untouched.
    file_put_contents($tmp, $code);

    $cmd = sprintf(
        '%s -d opcache.enable_cli=1 %s --write --out=%s 2>&1',
        escapeshellarg(PHP_BINARY),
        escapeshellarg($tmp),
        escapeshellarg($out),
    );
    exec($cmd, $lines, $rc);
    $output = implode("\n", $lines);
    $lines = [];

    $shouldFail = $label === 'no exclusions';
    $didFail = $rc !== 0;
    $named = str_contains($output, 'types');

    $ok = $shouldFail ? ($didFail && $named) : !$didFail;
    printf(
        "%-22s exit=%-3d %s\n",
        $label,
        $rc,
        $ok ? 'ok' : 'FAIL',
    );
    if (!$ok) {
        $failures++;
        echo "  expected " . ($shouldFail ? 'refusal naming `types`' : 'success') . "\n";
        echo '  got: ' . str_replace("\n", "\n       ", trim($output)) . "\n";
    } elseif ($shouldFail) {
        echo '  refused: ' . str_replace("\n", ' ', trim($output)) . "\n";
    }
    @unlink($out);
}

@unlink($tmp);
echo $failures === 0 ? "\nGUARD OK\n" : "\nGUARD FAILED ({$failures})\n";
exit($failures === 0 ? 0 : 1);
