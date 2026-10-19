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
//     php worker.php --prefork unix:/run/app/workers.sock
//
// **The application is booted before the fork and the SDK is loaded before it too**, and both
// are load-bearing. A class the master has not loaded is one each child compiles for itself,
// which would undo half the saving; and a child that fatals in `require` after the master has
// already said "listening" shows up as a connection reset on the pool's first request rather
// than as the error it is.
if (($argv[1] ?? '') === '--prefork') {
    $relay = $argv[2] ?? '';
    if ($relay === '') {
        fwrite(STDERR, "usage: php worker.php --prefork <unix:/path/to.sock>\n");
        exit(2);
    }

    // Force the load now, so every child inherits it rather than lazily compiling its own.
    class_exists(Volucer\Worker::class);
    class_exists(Volucer\Request::class);
    class_exists(Volucer\Response::class);

    // `unix:` is volucer's convention, not PHP's: `stream_socket_server` takes the bare path.
    $path = str_starts_with($relay, 'unix:') ? substr($relay, 5) : $relay;
    @unlink($path);
    $listener = stream_socket_server('unix://' . $path, $errno, $errstr);
    if ($listener === false) {
        fwrite(STDERR, "prefork: cannot listen on {$path}: {$errstr} ({$errno})\n");
        exit(1);
    }

    // Readiness is announced only once the listener exists, so `volucer serve` can start
    // immediately afterwards without racing the socket.
    fwrite(STDOUT, "listening\n");
    fflush(STDOUT);

    // **Reaping is not optional here, and it is not the operating system's job.** A child that
    // exits stays a zombie until its parent waits for it, and a supervisor that only accepts
    // and forks grows one per connection — measured at exactly 10 zombies for 10 connections,
    // which for a pool that recycles is a process table that fills up over a day. `SIGCHLD`
    // with a `WNOHANG` loop is the standard answer: the handler must not block, because it runs
    // between any two instructions of the accept loop.
    pcntl_async_signals(true);
    pcntl_signal(SIGCHLD, static function (): void {
        while (pcntl_waitpid(-1, $status, WNOHANG) > 0) {
            // Reap everything that has exited. php-fpm's answer for the same problem.
        }
    });

    // Accept in the master, fork per connection. The ordering is what keeps the assignment
    // exact: the kernel wakes one waiter per connection and does not do it fairly, so N children
    // sharing the listener can leave one holding two connections and another none — which for
    // volucer would mean a slot whose connection nobody is reading.
    while (true) {
        $connection = @stream_socket_accept($listener, -1);
        if ($connection === false) {
            // A signal interrupted the accept, which is expected once per exiting child. The
            // signal handler has already reaped it; this loop just goes back to waiting.
            continue;
        }

        $pid = pcntl_fork();
        if ($pid === -1) {
            // Out of processes. Dropping the connection is the honest answer: volucer sees a
            // closed socket on that slot and replaces it on the next request, where pretending
            // to have forked would leave a slot waiting for an answer that never comes.
            fclose($connection);

            continue;
        }

        if ($pid !== 0) {
            // The master must drop its copy, or the socket never reaches end-of-file when the
            // child exits and one fd leaks per connection.
            fclose($connection);

            continue;
        }

        fclose($listener);

        // `create()`, not `connect()`: the connection is already open and is handed over. The
        // child inherited the booted `$app` by copy-on-write, which is the whole point.
        Volucer\Worker::create($connection, $connection)->run(
            static function (Volucer\Request $request) use ($app): Volucer\Response {
                $result = $app->dispatch($request->method, $request->uri);
                $app->cleanup();

                return new Volucer\Response(
                    $result->status,
                    [['Content-Type', 'text/html; charset=utf-8']],
                    $result->body,
                );
            },
        );

        exit(0);
    }
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
