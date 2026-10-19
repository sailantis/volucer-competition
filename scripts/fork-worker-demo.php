<?php

declare(strict_types=1);

/**
 * Can a worker fork its own children and still be *volucer's* worker?
 *
 * The proposal this tests: start one PHP process, let it boot once, then have it
 * `fork()` the workers instead of making volucer spawn one process per worker.
 * The parent stays resident only to produce (and replace) children, and reports
 * the pids so the server can treat them like its own.
 *
 * That splits into four independent questions, and they do not all have the same
 * answer:
 *
 *   1. TRANSPORT — a forked child inherits the parent's stdin/stdout. On the pipe
 *      transport those are the worker protocol's own pipes, so a child that calls
 *      `Worker::connect()` after the fork reads the same channel the server
 *      opened. If that works, the server cannot tell a forked worker from an
 *      exec'd one.
 *   2. KILLING — the server kills `self.child`, which after a fork is the PARENT.
 *      Killing the parent leaves the children running. Whether an individual
 *      child can be killed by pid is the question.
 *   3. DETECTION — the pool asks `child.try_wait()` whether a worker died. That
 *      works for a child of volucer; it does NOT work for a grandchild, which
 *      only the parent can reap.
 *   4. TEARDOWN — a master that dies without killing its children orphans them.
 *
 * This script is the worker entry point for that experiment. Run it through
 * volucer (`workers = 1`) with the env vars below and watch what the four
 * questions do.
 *
 * Usage (through volucer, see scripts/fork-worker-demo.sh):
 *   VOLUCER_WORKER_FORK=1 VOLUCER_WORKER_CHILDREN=4 php scripts/fork-worker-demo.php
 *
 * Environment:
 *   VOLUCER_WORKER_FORK      1 to fork instead of serving here   [unset]
 *   VOLUCER_WORKER_CHILDREN  how many children to fork           [4]
 *   VOLUCER_WORKER_LOG       where to write the pid map          [stderr]
 *
 * Without `VOLUCER_WORKER_FORK` this is an ordinary single-process worker, so the
 * same file drives both sides of the comparison.
 */

require __DIR__ . '/../vendor/autoload.php';
require __DIR__ . '/../BenchApp.php';

$root = dirname(__DIR__);
$dbPath = $root . '/data/bench.sqlite';
if (!is_file($dbPath)) {
    fwrite(STDERR, "Database not found. Run: php seed.php\n");
    exit(1);
}

function logline(string $msg): void
{
    $dest = getenv('VOLUCER_WORKER_LOG') ?: 'php://stderr';
    // stderr is shared by every forked child, and a line written with one
    // `fwrite` of a pre-built string is what keeps them from interleaving.
    @file_put_contents($dest, $msg . "\n", FILE_APPEND);
}

$fork = getenv('VOLUCER_WORKER_FORK') === '1';
$children = (int) (getenv('VOLUCER_WORKER_CHILDREN') ?: 4);

// The boot every worker pays. Forked children inherit this container, which is
// the entire point: they do not boot again.
$app = new BenchApp($dbPath);
$app->bootstrap();

$serve = static function () use ($app): void {
    $worker = Volucer\Worker::connect();
    $worker->run(static function (Volucer\Request $request) use ($app): Volucer\Response {
        $result = $app->dispatch($request->method, $request->uri);
        $app->cleanup();

        return new Volucer\Response(
            $result->status,
            [['Content-Type', 'text/html; charset=utf-8']],
            $result->body,
        );
    });
};

if (!$fork || !function_exists('pcntl_fork')) {
    if ($fork) {
        logline('fork requested but ext-pcntl is unavailable; serving single-process');
    }
    $serve();
    exit(0);
}

// ---------------------------------------------------------------------------
// The forking worker.
//
// Deliberately NOT connecting before the fork: the protocol channel is the
// parent's stdin/stdout, and two processes reading one pipe would split the frame
// stream between them and corrupt it. The child connects; the parent never does.
// ---------------------------------------------------------------------------
$pids = [];
for ($i = 0; $i < $children; $i++) {
    $pid = pcntl_fork();
    if ($pid === -1) {
        logline("fork failed after $i children");
        break;
    }
    if ($pid === 0) {
        // ---- child -------------------------------------------------------
        // It inherits stdin/stdout, so this reads the channel the server opened
        // for the process it actually spawned.
        $serve();
        exit(0);
    }
    $pids[] = $pid;
}

logline(sprintf('master pid=%d forked %d children: %s',
    getmypid(), count($pids), implode(' ', $pids)));

// The parent must reap its own children: they are not volucer's, so volucer's
// `try_wait` cannot see them exit. Reaping here also means a child that dies is
// noticed by the master rather than becoming a zombie.
$stopping = false;
pcntl_async_signals(true);
$stop = static function (int $sig) use (&$stopping, $pids): void {
    $stopping = true;
    logline(sprintf('master received signal %d, forwarding SIGTERM to %d children',
        $sig, count($pids)));
    foreach ($pids as $p) {
        posix_kill($p, SIGTERM);
    }
};
pcntl_signal(SIGTERM, $stop);
pcntl_signal(SIGINT, $stop);

while (!$stopping) {
    // -1 waits for any child. `WNOHANG` would spin; this blocks until one exits,
    // which is exactly the "a child died, replace it" event the design needs.
    $pid = pcntl_wait($status);
    if ($pid === -1) {
        break;
    }
    if ($stopping) {
        break;
    }
    logline(sprintf('child %d exited (status %d); forking a replacement', $pid,
        pcntl_wifexited($status) ? pcntl_wexitstatus($status) : -1));
    // The replacement inherits the same booted container, which is why replacing
    // a worker costs a fork and not a framework boot.
    $new = pcntl_fork();
    if ($new === 0) {
        $serve();
        exit(0);
    }
    if ($new > 0) {
        $pids = array_values(array_diff($pids, [$pid]));
        $pids[] = $new;
        logline(sprintf('replacement pid=%d', $new));
    }
}

// A master that exits while its children are still alive orphans them: they are
// reparented to init, keep their inherited pipes, and go on serving requests that
// volucer no longer believes exist. Killing them here is the only thing that
// prevents it, and it is why this cannot be done without the parent's cooperation.
foreach ($pids as $p) {
    posix_kill($p, SIGKILL);
}
logline('master exiting after killing its children');
