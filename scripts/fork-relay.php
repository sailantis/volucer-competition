<?php

declare(strict_types=1);

/**
 * The recommended fork design, at load: one master, N forked children, one inherited
 * AF_UNIX listener.
 *
 * This is option 1 from the README, reduced to the smallest thing that can be
 * benchmarked. It answers the two questions the attach-mode experiments could not:
 *
 *   1. Given the right channel, does a forked child actually keep the warm worker's
 *      speed? The children inherit the master's booted container *and* the listening
 *      socket, so there is no per-worker boot and no handover.
 *   2. What does the fork family cost while it serves, not while it waits? Every
 *      earlier memory number sampled an idle pool; this one serves continuously while
 *      the parent samples.
 *
 * The mechanism, which was verified separately before this was written: `fork()`
 * copies the file descriptor table, so a child inherits the listening socket itself.
 * N children may therefore each call `accept()` on one listener — no fd passing, no
 * SCM_RIGHTS, no SO_REUSEPORT. What they do *not* get is fairness: a child that loops
 * straight back into `accept()` tends to win repeatedly (measured: 3 of 4 children
 * served 40 connections). That does not break the design, but it means `accept()` alone
 * is not a load balancer, which is why the parent here reports the per-child share.
 *
 * It speaks plain HTTP/1.1 rather than volucer's protocol, deliberately: the point is
 * to measure the fork family and the listener, not to reimplement volucer. A real
 * implementation would put volucer's framed protocol on this socket and the server
 * would connect to it instead of spawning — which is the missing `attach` mode.
 *
 * Usage:
 *   php scripts/fork-relay.php
 *   CHILDREN=8 SOCKET=/tmp/relay.sock php scripts/fork-relay.php
 *   # then: wrk -t12 -c64 -d5s --latency --unix-socket /tmp/relay.sock http://localhost/items
 *
 * Environment:
 *   CHILDREN   children to fork                 [4]
 *   SOCKET     unix socket path                 [/tmp/volucer-relay.sock]
 *   REQUESTS   requests per child before exit   [0 = run until signalled]
 *   STATS      seconds between footprint lines  [2]
 *
 * Requires ext-pcntl, and Linux /proc for the footprint.
 */

if (!function_exists('pcntl_fork')) {
    fwrite(STDERR, "FATAL: ext-pcntl is not available.\n");
    exit(1);
}

$root = dirname(__DIR__);
$children = (int) (getenv('CHILDREN') ?: 4);
$socketPath = getenv('SOCKET') ?: '/tmp/volucer-relay.sock';
$maxRequests = (int) (getenv('REQUESTS') ?: 0);
$statsEvery = (int) (getenv('STATS') ?: 2);
$dbPath = $root . '/data/bench.sqlite';

if (!is_file($dbPath)) {
    fwrite(STDERR, "FATAL: $dbPath is missing - run: php seed.php\n");
    exit(1);
}

require $root . '/vendor/autoload.php';
require $root . '/BenchApp.php';

/** Summed PSS and process count under a root pid, by PPID descent. */
function footprint(int $rootPid): array
{
    $pids = [$rootPid];
    $all = [];
    foreach ((array) @scandir('/proc') as $entry) {
        if (!ctype_digit((string) $entry)) {
            continue;
        }
        $status = @file_get_contents("/proc/$entry/status");
        if ($status === false) {
            continue;
        }
        if (preg_match('/^PPid:\s+(\d+)/m', $status, $m) === 1) {
            $all[$entry] = (int) $m[1];
        }
    }
    $changed = true;
    while ($changed) {
        $changed = false;
        foreach ($all as $pid => $ppid) {
            if (!in_array($pid, $pids, true) && in_array($ppid, $pids, true)) {
                $pids[] = $pid;
                $changed = true;
            }
        }
    }
    $pss = 0;
    foreach ($pids as $pid) {
        $raw = @file_get_contents("/proc/$pid/smaps_rollup");
        if ($raw !== false && preg_match('/^Pss:\s+(\d+) kB/m', $raw, $m) === 1) {
            $pss += (int) $m[1];
        }
    }
    return [round($pss / 1024, 1), count($pids)];
}

// ---------------------------------------------------------------------------
// The boot the children inherit. This is the whole saving: it happens once.
// ---------------------------------------------------------------------------
$t0 = microtime(true);
$app = new BenchApp($dbPath);
$app->bootstrap();
$bootMs = (microtime(true) - $t0) * 1000;

// Warm the code paths before forking so the first request in a child is not paying
// for a lazy class load the master could have done once.
$warm = $app->dispatch('GET', '/items');
$app->cleanup();
if ($warm->status !== 200) {
    fwrite(STDERR, "FATAL: /items returned {$warm->status} before forking\n");
    exit(1);
}

// Bind AFTER the boot: a listener is a resource the children inherit, and the boot is
// what has to be shared, so there is no reason to hold the socket during it.
@unlink($socketPath);
$listener = stream_socket_server(
    'unix://' . $socketPath,
    $errno,
    $errstr,
    STREAM_SERVER_BIND | STREAM_SERVER_LISTEN
);
if ($listener === false) {
    fwrite(STDERR, "FATAL: cannot bind $socketPath ($errstr)\n");
    exit(1);
}
chmod($socketPath, 0660);

$master = getmypid();
printf("master pid=%d, boot %.1f ms, listening on %s\n", $master, $bootMs, $socketPath);
printf("forking %d children; each inherits the container AND this listener\n", $children);

fflush(STDOUT);
$pids = [];
for ($i = 0; $i < $children; $i++) {
    $pid = pcntl_fork();
    if ($pid === -1) {
        fwrite(STDERR, "FATAL: fork() failed after $i children\n");
        break;
    }
    if ($pid > 0) {
        $pids[] = $pid;
        continue;
    }

    // ---- child ------------------------------------------------------------
    // No boot: this process already has the master's container, its autoloaded
    // classes and its opcache. What it does not have is any state from the master's
    // one warm request, which `cleanup()` already dropped.
    $served = 0;
    while ($maxRequests === 0 || $served < $maxRequests) {
        // Suppress the warning `accept()` emits when the parent closes the listener
        // on the way out: at that point the child's job is to exit quietly.
        $conn = @stream_socket_accept($listener, 5);
        if ($conn === false) {
            if (@feof($listener) || $maxRequests === 0) {
                // A timeout is not a shutdown; a closed listener is.
                continue;
            }
            break;
        }
        $served++;

        $requestLine = fgets($conn);
        if ($requestLine === false) {
            fclose($conn);
            continue;
        }
        // Drain the headers; this relay does not use them.
        while (($line = fgets($conn)) !== false && trim($line) !== '') {
            // header
        }

        $uri = '/items';
        if (preg_match('#^[A-Z]+\s+(\S+)#', (string) $requestLine, $m) === 1) {
            $uri = $m[1];
        }

        $result = $app->dispatch('GET', $uri);
        $app->cleanup();

        // Written as one buffer: two small writes would give this socket the same
        // Nagle/delayed-ACK stall the TCP transport has (measured at 39 ms/request).
        $body = $result->body;
        fwrite($conn, "HTTP/1.1 {$result->status} OK\r\n"
            . "Content-Type: text/html; charset=utf-8\r\n"
            . 'Content-Length: ' . strlen($body) . "\r\n"
            . "Connection: keep-alive\r\n\r\n"
            . $body);
        fflush($conn);
        fclose($conn);
    }
    exit(0);
}

// ---------------------------------------------------------------------------
// The parent stays resident only to report and to reap. It serves nothing.
// ---------------------------------------------------------------------------
$stop = false;
pcntl_async_signals(true);
$onStop = static function (int $sig) use (&$stop): void {
    $stop = true;
    if (function_exists('posix_kill')) {
        // Children block in `accept()`; closing the listener is what wakes them.
        // A signal would interrupt the syscall but leave the socket open.
    }
};
pcntl_signal(SIGTERM, $onStop);
pcntl_signal(SIGINT, $onStop);

$peak = 0.0;
$ticks = 0;
while (!$stop) {
    $pid = pcntl_wait($status, WNOHANG);
    if ($pid > 0) {
        // A child exited. Replace it: the replacement costs a fork, not a boot.
        $pids = array_values(array_diff($pids, [$pid]));
        $new = pcntl_fork();
        if ($new === 0) {
            $served = 0;
            while ($maxRequests === 0 || $served < $maxRequests) {
                $conn = @stream_socket_accept($listener, 5);
                if ($conn === false) {
                    continue;
                }
                $served++;
                $requestLine = fgets($conn);
                while (($line = fgets($conn)) !== false && trim($line) !== '') {
                }
                $uri = '/items';
                if (preg_match('#^[A-Z]+\s+(\S+)#', (string) $requestLine, $m) === 1) {
                    $uri = $m[1];
                }
                $result = $app->dispatch('GET', $uri);
                $app->cleanup();
                $body = $result->body;
                fwrite($conn, "HTTP/1.1 {$result->status} OK\r\n"
                    . "Content-Type: text/html; charset=utf-8\r\n"
                    . 'Content-Length: ' . strlen($body) . "\r\n"
                    . "Connection: keep-alive\r\n\r\n"
                    . $body);
                fflush($conn);
                fclose($conn);
            }
            exit(0);
        }
        if ($new > 0) {
            $pids[] = $new;
        }
        continue;
    }
    usleep(200000);
    if (++$ticks % max(1, (int) ($statsEvery / 0.2)) === 0) {
        [$pss, $n] = footprint($master);
        $peak = max($peak, $pss);
        printf("  footprint now %7.1f MB across %d processes (peak %.1f)\n", $pss, $n, $peak);
        fflush(STDOUT);
    }
}

fclose($listener);
foreach ($pids as $pid) {
    posix_kill($pid, SIGTERM);
}
foreach ($pids as $pid) {
    pcntl_waitpid($pid, $timeoutStatus, WNOHANG);
}
@unlink($socketPath);
printf("master exiting; peak footprint %.1f MB\n", $peak);
