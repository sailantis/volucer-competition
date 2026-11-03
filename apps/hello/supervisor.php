<?php

declare(strict_types=1);

/**
 * HELLO ARM — volucer `attach`: boot once, then accept-and-fork.
 *
 * The server starts no PHP in this mode. It dials the relay this process listens on,
 * once per pool slot, and each accepted connection is served by a child forked from
 * the heap the master built. The interpreter, the loaded classes and the OPcache
 * segment therefore exist **once** for the whole pool rather than once per worker —
 * that is the property `attach` exists for, and the reason a hello page is a fair
 * place to measure it: there is no framework boot left to amortise, so the arm is
 * priced on its transport and its process model alone.
 *
 *     php apps/hello/supervisor.php                      # relay from VOLUCER_RELAY_SOCKET
 *     php apps/hello/supervisor.php unix:/run/relay.sock  # explicit
 *
 * The relay address is the one fact the server's `relay` and this process both have
 * to know. `Supervisor::relay()` reads `VOLUCER_RELAY_SOCKET` when no argument is
 * given, which is the form a deployment should use: the address is written once.
 * A benchmark passes it explicitly anyway, because the arms must be told apart by
 * their own configuration and not by a variable in the operator's shell.
 *
 * **Order matters.** The application boots before `Supervisor::serve()`, so the fork
 * happens after the boot and every child inherits it. Nothing that holds an open
 * connection may be built here: each child would inherit the handle and they would
 * take turns reading from it. This page opens none — but a real application that adds
 * a database should open it lazily, in the handler, for exactly that reason.
 */

require __DIR__ . '/../../vendor/autoload.php';
require __DIR__ . '/HelloApp.php';
require __DIR__ . '/HelloResult.php';
require __DIR__ . '/serve.php';

$relay = ($argv[1] ?? '') === '' ? null : (string) $argv[1];

if (!class_exists(Volucer\Supervisor::class)) {
    fwrite(
        STDERR,
        "hello: this volucer-worker build has no Volucer\\Supervisor; raise the "
            . "sailantis/volucer-worker pin and run `composer update`\n",
    );
    exit(1);
}

$app = new App\Hello\HelloApp();

// The boot every child inherits. Moving this inside the handler would turn the arm
// into a per-connection boot and make it a different measurement.
$app->bootstrap();

Volucer\Supervisor::serve(
    $relay,
    static fn (Volucer\Request $request): Volucer\Response => hello_serve($app, $request),
);
