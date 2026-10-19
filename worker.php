<?php

declare(strict_types=1);

/**
 * The WARM arm's entry point: what volucer's `worker` backend runs.
 *
 * The counterpart of `public/index.php`, and the contrast is the experiment. The
 * same `BenchApp` and the same page, but `bootstrap()` runs ONCE here, before the
 * loop, and every request reuses the container it built. That single line moving
 * out of the request is the whole difference between the warm and cold arms.
 *
 * `run()` owns the framing: `Request` already carries the method and URI, and the
 * SDK rebinds PHP's own output so an `echo` inside application code cannot
 * corrupt the protocol channel (see the SDK's README).
 */

require __DIR__ . '/vendor/autoload.php';
require __DIR__ . '/BenchApp.php';

$dbPath = __DIR__ . '/data/bench.sqlite';
if (!file_exists($dbPath)) {
    fwrite(STDERR, "Database not found. Run: php seed.php\n");
    exit(1);
}

$app = new BenchApp($dbPath);
// The boot the cold arms pay per request.
$app->bootstrap();

/*
 * volucer can reach a worker two ways, and this file drives both so the warm arm
 * can be measured on either.
 *
 * The default is the worker's own stdin/stdout, which is what this file has always
 * used and what the server assumes when `VOLUCER_WORKER_SOCKET` is absent. The
 * alternative is a loopback socket, and it exists for one measured reason: on Windows,
 * PHP's stream layer takes ~8 ms median to return from a blocking read on a *pipe* while
 * the same read on a *socket* returns in ~0.09 ms. A Rust process reading the identical
 * pipe returns in 0.010 ms, so the cost is PHP-on-Windows rather than the pipe itself.
 *
 * `Worker::connect()` is the whole decision — the protocol does not know which transport
 * it is on, so nothing else in this file changes.
 */
// **Supervisor mode**, which is the shape the `attach` backend exists for: one boot, then
// accept-and-fork. Each child serves one connection from the heap it inherited, so the
// interpreter and the OPcache segment are shared copy-on-write instead of mapped once per
// worker — the measurement `scripts/fork-demo.php` makes, and the reason volucer grew a backend
// that dials a relay instead of spawning a process.
//
//     php worker.php --prefork                      # the relay from VOLUCER_RELAY_SOCKET
//     php worker.php --prefork unix:/run/app/workers.sock
//
// The argument is optional. `relay` in `volucer.toml` names the same address, so a deployment can
// write it once in the unit file and have both sides read it — see the SDK README's
// "the address can be written once".
// The loop itself is the SDK's, in `Volucer\Supervisor`. It lives there rather than in this file
// because it is not application code: every application that wants the fork model needs the same
// decisions — accept in the master so the assignment stays exact, reap from the accept loop rather
// than from a `SIGCHLD` handler, drop the master's copy of the connection, `exit` rather than a
// return from the child — and a supervisor copied into each application gets them subtly
// differently. This file now supplies only what is genuinely its own: the boot to inherit, and the
// handler.
//
// **The application is booted before the fork, and the SDK is loaded before it too**, and both
// are load-bearing. A class the master has not loaded is one each child compiles for itself,
// which would undo half the saving; and a child that fatals in `require` after the master has
// already said "listening" shows up as a connection reset on the pool's first request rather
// than as the error it is. `Supervisor::serve()` warms the SDK's own classes for the same reason.
if (($argv[1] ?? '') === '--prefork') {
    // `null` when the argument is absent, which is where `VOLUCER_RELAY_SOCKET` is read. The
    // harnesses still pass it explicitly, because a benchmark's two arms must be told apart by
    // their own configuration rather than by a variable in the operator's shell.
    $relay = ($argv[2] ?? '') === '' ? null : $argv[2];

    // The SDK is pinned to a commit in `composer.json`, so a checkout that was installed before the
    // supervisor existed has a `Volucer\Worker` and no `Volucer\Supervisor`. Saying so is worth the
    // four lines: the alternative is a "class not found" inside a `require`, which reads like a typo.
    if (!class_exists(Volucer\Supervisor::class)) {
        fwrite(
            STDERR,
            "prefork: this volucer-worker build has no Volucer\\Supervisor; raise the "
            . "sailantis/volucer-worker pin in composer.json and run `composer update`\n",
        );
        exit(1);
    }

    Volucer\Supervisor::serve($relay, static function (Volucer\Request $request) use ($app): Volucer\Response {
        $result = $app->dispatch($request->method, $request->uri);
        // Drop this request's scope, or the next one inherits it. In a supervisor this matters
        // more than in a reused process, because the next request may be served by a *different*
        // child that inherited none of it.
        $app->cleanup();

        return new Volucer\Response(
            $result->status,
            [['Content-Type', 'text/html; charset=utf-8']],
            $result->body,
        );
    });

    exit(0);
}

$worker = Volucer\Worker::connect();

$worker->run(static function (Volucer\Request $request) use ($app): Volucer\Response {
    $result = $app->dispatch($request->method, $request->uri);
    // Drop this request's scope, or the next one inherits it.
    $app->cleanup();

    return new Volucer\Response(
        $result->status,
        [['Content-Type', 'text/html; charset=utf-8']],
        $result->body,
    );
});
