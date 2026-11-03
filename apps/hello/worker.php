<?php

declare(strict_types=1);

/**
 * HELLO ARM — volucer `worker`: boot once, then serve one connection per worker.
 *
 * The control for `supervisor.php`, and the reason both files exist: they run the
 * same application with the same boot, and differ only in who owns the fork. Here the
 * server starts one process per slot with `exec`, so each has its own interpreter and
 * its own OPcache segment; there it dials a relay and the supervisor forks from one
 * shared heap. Comparing the two prices the memory model rather than the page.
 *
 *     php apps/hello/worker.php
 *
 * `Worker::connect()` rather than `create()` is the whole transport decision: when the
 * server asked for the socket transport, the protocol arrives over a loopback socket,
 * and `create()` would sit reading stdin for input that is no longer there.
 */

require __DIR__ . '/../../vendor/autoload.php';
require __DIR__ . '/HelloApp.php';
require __DIR__ . '/HelloResult.php';
require __DIR__ . '/serve.php';

$app = new App\Hello\HelloApp();

// Booted before the loop: the container is built once and reused for every request
// this worker answers.
$app->bootstrap();

Volucer\Worker::connect()->run(
    static fn (Volucer\Request $request): Volucer\Response => hello_serve($app, $request),
);
