<?php

declare(strict_types=1);

/**
 * Would `fork()` make a resident worker cheaper? — the experiment, not the argument.
 *
 * The matrix says a warm worker costs ~16 MB of PSS, and that this cost is per
 * worker, because volucer starts each one as a separate `exec` of the PHP binary:
 * every child pays its own interpreter, its own copy of the booted container, and
 * its own opcache mapping. The obvious alternative is to boot once and `fork()`
 * the children, which is the model php-fpm uses — and php-fpm's footprint in the
 * same matrix is 1.2 MB per worker, not 16.
 *
 * So this compares the two process models directly, on this host, on this
 * application, in the same run:
 *
 *   exec   N children, each a fresh PHP process that boots the app itself.
 *          This is what volucer's `worker` backend does today.
 *   fork   one booted parent that forks N children, which inherit its container,
 *          its opcache mapping and its already-open SQLite handle.
 *
 * Three things are measured, because they fail independently:
 *
 *  1. Footprint — summed PSS, and summed PRIVATE memory. PSS alone can flatter a
 *     fork family because pages every child shares are charged once; the private
 *     column is what the machine cannot reclaim by sharing.
 *  2. Correctness — every child serves the same page and the body's md5 must
 *     match the parent's. A forked child inherits an open SQLite handle, and 16
 *     processes sharing one connection's file state is exactly the kind of thing
 *     that works until it silently does not.
 *  3. Whether it is still WARM — a fork inherits the opcache shared segment
 *     because it is mapped before the fork, so compiled scripts should survive.
 *     If a "fork" quietly lost the cache it would have thrown away the thing that
 *     makes a resident worker fast, whatever its memory looked like.
 *
 * Usage:
 *   php scripts/fork-demo.php
 *   CHILDREN=24 REQUESTS=50 php scripts/fork-demo.php
 *   PHP=/usr/bin/php8.5 INI_SCAN_DIR=$HOME/php85-clean/conf.d \
 *       php scripts/fork-demo.php
 *
 * Environment:
 *   CHILDREN      children per model                 [16]
 *   REQUESTS      requests each child serves         [50]
 *   PHP           interpreter for the exec'd model   [PHP_BINARY]
 *   INI_SCAN_DIR  PHP_INI_SCAN_DIR for both models   [unset]
 *   OPCACHE       `on` or `off` for the exec'd side  [on]
 *                 Forked children inherit the parent's opcache whatever this says
 *                 and cannot be given a different one, so turning it off here is
 *                 how the fork family's cost is split into "opcache" and "not
 *                 opcache" - see the README.
 *
 * Requires ext-pcntl, and Linux /proc for the readings.
 */

if (!function_exists('pcntl_fork')) {
    fwrite(STDERR, "FATAL: ext-pcntl is not available; cannot test fork().\n");
    exit(1);
}

$root = dirname(__DIR__);
$children = (int) (getenv('CHILDREN') ?: 16);
$requests = (int) (getenv('REQUESTS') ?: 50);
$phpBin = getenv('PHP') ?: PHP_BINARY;
$iniScan = getenv('INI_SCAN_DIR') ?: '';
$dbPath = $root . '/data/bench.sqlite';

if (!is_file($dbPath)) {
    fwrite(STDERR, "FATAL: $dbPath is missing - run: php seed.php\n");
    exit(1);
}

/**
 * Pss and the private part of the resident set, in MB, in one read.
 *
 * PSS splits a shared page across the processes that map it, which is the only
 * way to compare one process against sixteen that share most of their pages.
 * `Private_*` is the part no other process maps: the number that does not change
 * when you change how the total is divided up.
 */
function smaps(int $pid): array
{
    $raw = @file_get_contents("/proc/$pid/smaps_rollup");
    if ($raw === false) {
        return [-1.0, -1.0];
    }
    $pss = preg_match('/^Pss:\s+(\d+) kB/m', $raw, $m) === 1 ? (int) $m[1] : 0;
    $priv = 0;
    if (preg_match('/^Private_Clean:\s+(\d+) kB/m', $raw, $m) === 1) {
        $priv += (int) $m[1];
    }
    if (preg_match('/^Private_Dirty:\s+(\d+) kB/m', $raw, $m) === 1) {
        $priv += (int) $m[1];
    }
    return [round($pss / 1024, 1), round($priv / 1024, 1)];
}

function fmt(float $v): string
{
    return sprintf('%8.1f', $v);
}

$tmp = sys_get_temp_dir() . '/fork-demo-' . getmypid();
@mkdir($tmp);
// Only the parent may clean up. A forked child inherits this shutdown hook, and
// the first version let each child delete the directory on the way out - which
// removed the very file its siblings were still writing, so the fork family
// reported zero successes while actually serving every request correctly.
$parentPid = getmypid();
register_shutdown_function(static function () use ($tmp, $parentPid): void {
    if (getmypid() !== $parentPid) {
        return;
    }
    @array_map('unlink', glob("$tmp/*") ?: []);
    @rmdir($tmp);
});

printf("php            %s\n", PHP_VERSION);
printf("children       %d, %d requests each\n", $children, $requests);
printf("ini scan       %s\n", $iniScan === '' ? '(host default)' : $iniScan);
printf("exec opcache   %s\n", $ocMode);
printf("exec model     %s\n\n", $phpBin);

// The ON mode of the matrix by default, so the exec'd side is measured in the
// same configuration the ~16 MB per worker figure came from. `OPCACHE=off` is the
// control that separates opcache's share from the interpreter's.
$ocMode = getenv('OPCACHE') ?: 'on';
$ocFlag = $ocMode === 'off' ? '0' : '1';
$childIni = ['-d', "opcache.enable_cli=$ocFlag", '-d', 'opcache.validate_timestamps=0',
             '-d', 'memory_limit=512M', '-d', 'date.timezone=UTC'];

// ---------------------------------------------------------------------------
// One boot in this process: it is the fork family's parent, and the reference
// both models must match.
// ---------------------------------------------------------------------------
require $root . '/vendor/autoload.php';
require $root . '/BenchApp.php';

$app = new BenchApp($dbPath);
$app->bootstrap();
$first = $app->dispatch('GET', '/items');
if ($first->status !== 200) {
    fwrite(STDERR, "FATAL: /items returned {$first->status}\n");
    exit(1);
}
$expectHash = md5($first->body);
$bodyFile = "$tmp/body.md5";
file_put_contents($bodyFile, $expectHash);

$oc = opcache_get_status(false);
$parentScripts = $oc === false ? 0 : ($oc['opcache_statistics']['num_cached_scripts'] ?? 0);

[$thisPss, $thisPrivate] = smaps(getmypid());
printf("booted in this process (the fork family's parent)\n");
printf("  pss %s MB   private %s MB\n", fmt($thisPss), fmt($thisPrivate));
printf("  opcache %s, %d scripts cached\n", $oc === false ? 'inactive' : 'active', $parentScripts);
printf("  /items %d bytes, md5 %s\n\n", strlen($first->body), $expectHash);

// ---------------------------------------------------------------------------
// Wave 1 — exec: N independent processes that each boot the application.
//
// The child is a generated file rather than a shared one so that it carries
// exactly this run's parameters; it serves REQUESTS requests, reports itself,
// then stays resident so the parent can sample that exact process.
// ---------------------------------------------------------------------------
$execResults = "$tmp/exec.tsv";
$script = "$tmp/exec-child.php";
// A template with tokens rather than sprintf: the child writes its own
// `sprintf("...%d...")` format strings, and a second layer of sprintf would
// consume them.
$childTemplate = <<<'PHP'
$root = {{ROOT}};
$requests = {{REQUESTS}};
$bodyFile = {{BODY}};
$out = {{OUT}};
require $root . '/vendor/autoload.php';
require $root . '/BenchApp.php';
$app = new BenchApp($root . '/data/bench.sqlite');
$app->bootstrap();
$expect = trim((string) file_get_contents($bodyFile));
$ok = 0; $fail = '';
for ($i = 0; $i < $requests; $i++) {
    $r = $app->dispatch('GET', '/items');
    $app->cleanup();
    if ($r->status === 200 && md5($r->body) === $expect) { $ok++; }
    elseif ($fail === '') { $fail = 'status=' . $r->status; }
}
$oc = opcache_get_status(false);
$raw = (string) @file_get_contents('/proc/self/smaps_rollup');
$pss = preg_match('/^Pss:\s+(\d+) kB/m', $raw, $m) ? (int) $m[1] : 0;
$priv = 0;
if (preg_match('/^Private_Clean:\s+(\d+) kB/m', $raw, $m)) { $priv += (int) $m[1]; }
if (preg_match('/^Private_Dirty:\s+(\d+) kB/m', $raw, $m)) { $priv += (int) $m[1]; }
file_put_contents($out, sprintf("exec\t%.1f\t%.1f\t%d\t%d\t%s\n",
    $pss / 1024, $priv / 1024, $ok,
    $oc === false ? 0 : ($oc['opcache_statistics']['num_cached_scripts'] ?? 0),
    $fail === '' ? 'ok' : $fail), FILE_APPEND | LOCK_EX);
sleep(60);
PHP;

file_put_contents($script, "<?php\n" . strtr($childTemplate, [
    '{{ROOT}}' => var_export($root, true),
    '{{REQUESTS}}' => (string) $requests,
    '{{BODY}}' => var_export($bodyFile, true),
    '{{OUT}}' => var_export($execResults, true),
]));

$env = $iniScan === '' ? null : ['PHP_INI_SCAN_DIR' => $iniScan];
$procs = [];
for ($i = 0; $i < $children; $i++) {
    $p = proc_open(
        array_merge([$phpBin], $childIni, [$script]),
        [1 => ['file', '/dev/null', 'w'], 2 => ['file', "$tmp/exec.err", 'a']],
        $pipes, $root, $env
    );
    if (!is_resource($p)) {
        fwrite(STDERR, "FATAL: could not start exec child $i\n");
        exit(1);
    }
    $procs[] = $p;
}

$deadline = microtime(true) + 60;
while (microtime(true) < $deadline) {
    if (is_file($execResults) && count(file($execResults)) >= $children) {
        break;
    }
    usleep(50000);
}
usleep(300000);

$execPss = 0.0;
$execPrivate = 0.0;
$execAlive = 0;
foreach ($procs as $p) {
    $st = proc_get_status($p);
    if (!$st['running']) {
        continue;
    }
    [$pss, $priv] = smaps((int) $st['pid']);
    if ($pss < 0) {
        continue;
    }
    $execPss += $pss;
    $execPrivate += $priv;
    $execAlive++;
}
foreach ($procs as $p) {
    $st = proc_get_status($p);
    if ($st['running']) {
        posix_kill((int) $st['pid'], SIGKILL);
    }
    proc_close($p);
}

$execRows = is_file($execResults) ? file($execResults, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) : [];
$execOk = 0;
$execCached = [];
foreach ($execRows as $row) {
    $c = explode("\t", $row);
    if (($c[5] ?? '') === 'ok') {
        $execOk++;
    }
    $execCached[] = (int) ($c[4] ?? 0);
}

printf("EXEC model - %d separate PHP processes, each with its own boot\n", $children);
printf("  processes sampled                %8d\n", $execAlive);
printf("  sum pss                         %s MB\n", fmt($execPss));
printf("  sum private                     %s MB\n", fmt($execPrivate));
printf("  per child pss                   %s MB\n", fmt($execAlive > 0 ? $execPss / $execAlive : 0));
printf("  children rendering the page     %8d / %d\n", $execOk, $children);
printf("  opcache scripts per child       %8d (min %d)\n\n",
    $execCached ? max($execCached) : 0, $execCached ? min($execCached) : 0);

// ---------------------------------------------------------------------------
// Wave 2 — fork: this booted parent forks N children.
// ---------------------------------------------------------------------------
fflush(STDOUT);
$forkResults = "$tmp/fork.tsv";
$pids = [];
for ($i = 0; $i < $children; $i++) {
    $pid = pcntl_fork();
    if ($pid === -1) {
        fwrite(STDERR, "FATAL: fork() failed after $i children\n");
        foreach ($pids as $p) {
            posix_kill($p, SIGKILL);
        }
        exit(1);
    }
    if ($pid > 0) {
        $pids[] = $pid;
        continue;
    }
    // ---- child: inherits the container, the opcache mapping and the open handle.
    $ok = 0;
    $fail = '';
    for ($r = 0; $r < $requests; $r++) {
        $res = $app->dispatch('GET', '/items');
        $app->cleanup();
        if ($res->status === 200 && md5($res->body) === $expectHash) {
            $ok++;
        } elseif ($fail === '') {
            $fail = 'status=' . $res->status . ' md5=' . md5($res->body);
        }
    }
    $oc = opcache_get_status(false);
    $raw = (string) @file_get_contents('/proc/self/smaps_rollup');
    $fPss = preg_match('/^Pss:\s+(\d+) kB/m', $raw, $m) ? (int) $m[1] : 0;
    $fPriv = 0;
    if (preg_match('/^Private_Clean:\s+(\d+) kB/m', $raw, $m)) { $fPriv += (int) $m[1]; }
    if (preg_match('/^Private_Dirty:\s+(\d+) kB/m', $raw, $m)) { $fPriv += (int) $m[1]; }
    file_put_contents($forkResults, sprintf("fork\t%.1f\t%.1f\t%d\t%d\t%s\n",
        $fPss / 1024, $fPriv / 1024, $ok,
        $oc === false ? 0 : ($oc['opcache_statistics']['num_cached_scripts'] ?? 0),
        $fail === '' ? 'ok' : $fail), FILE_APPEND | LOCK_EX);
    // `exit` rather than returning: the parent's state is not the child's to tear
    // down, and running the destructors here would close a handle 15 other
    // processes are still using.
    exit(0);
}

foreach ($pids as $pid) {
    pcntl_waitpid($pid, $status);
}
$forkRows = is_file($forkResults) ? file($forkResults, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) : [];
$forkOk = 0;
$forkCached = [];
$forkBurstPss = 0.0;
$forkBurstPrivate = 0.0;
foreach ($forkRows as $row) {
    $c = explode("\t", $row);
    if (($c[5] ?? '') === 'ok') {
        $forkOk++;
    }
    $forkCached[] = (int) ($c[4] ?? 0);
    $forkBurstPss += (float) ($c[1] ?? 0);
    $forkBurstPrivate += (float) ($c[2] ?? 0);
}

// A second wave to sample, held LIVE while the parent reads them. The first wave
// has exited, so its Pss is gone. These children sit in a sleep: that is what a
// resident fork family costs while it waits, and a worker spends most of its life
// waiting - but an idle child is also the floor rather than the working figure, so
// the per-child peak after a burst is measured on the first wave above and both
// numbers are reported.
$pids = [];
for ($i = 0; $i < $children; $i++) {
    $pid = pcntl_fork();
    if ($pid === -1) {
        fwrite(STDERR, "FATAL: second-wave fork failed after $i children\n");
        exit(1);
    }
    if ($pid === 0) {
        sleep(60);
        exit(0);
    }
    $pids[] = $pid;
}
usleep(400000);

$forkPss = 0.0;
$forkPrivate = 0.0;
$forkAlive = 0;
foreach ($pids as $pid) {
    [$pss, $priv] = smaps($pid);
    if ($pss < 0) {
        continue;
    }
    $forkPss += $pss;
    $forkPrivate += $priv;
    $forkAlive++;
}
[$parentPss, $parentPrivate] = smaps(getmypid());
foreach ($pids as $pid) {
    posix_kill($pid, SIGKILL);
    pcntl_waitpid($pid, $status);
}

printf("FORK model - one boot, %d forked children\n", $children);
printf("  children sampled                %8d\n", $forkAlive);
printf("  sum pss (children)              %s MB\n", fmt($forkPss));
printf("  sum private (children)          %s MB\n", fmt($forkPrivate));
printf("  per child pss                   %s MB\n", fmt($forkAlive > 0 ? $forkPss / $forkAlive : 0));
printf("  parent pss, counted separately  %s MB\n", fmt($parentPss));
printf("  per child pss after its burst   %s MB\n",
    fmt($children > 0 ? $forkBurstPss / $children : 0));
printf("  per child private after burst   %s MB\n",
    fmt($children > 0 ? $forkBurstPrivate / $children : 0));
printf("  children rendering the page     %8d / %d\n", $forkOk, $children);
printf("  opcache scripts per child       %8d (min %d)\n\n",
    $forkCached ? max($forkCached) : 0, $forkCached ? min($forkCached) : 0);

// ---------------------------------------------------------------------------
// Verdict
// ---------------------------------------------------------------------------
$execTotal = $execPss;
$forkTotal = $forkPss + $parentPss;
$execPrivTotal = $execPrivate;
$forkPrivTotal = $forkPrivate + $parentPrivate;

printf("VERDICT at %d workers\n", $children);
printf("  total pss      exec %s MB   fork %s MB   %+.0f%%\n",
    fmt($execTotal), fmt($forkTotal),
    $execTotal > 0 ? (($forkTotal - $execTotal) / $execTotal) * 100 : 0);
printf("  total private  exec %s MB   fork %s MB   %+.0f%%\n",
    fmt($execPrivTotal), fmt($forkPrivTotal),
    $execPrivTotal > 0 ? (($forkPrivTotal - $execPrivTotal) / $execPrivTotal) * 100 : 0);
printf("  per worker     exec %s MB   fork %s MB\n",
    fmt($execAlive > 0 ? $execTotal / $execAlive : 0),
    fmt($forkAlive > 0 ? $forkTotal / $forkAlive : 0));
if ($forkCached && $execCached && min($forkCached) < max($execCached)) {
    printf("  NOTE: forked children cached fewer scripts (%d) than exec'd ones (%d)\n",
        min($forkCached), max($execCached));
}
