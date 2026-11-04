<?php

declare(strict_types=1);

/**
 * Can a worker tell "the server closed the connection" from "nobody spoke for a while"?
 *
 * `readHeader()` currently cannot: `stream_get_contents()` returns `''` for both, and the
 * SDK reads `''` as "the server is finished with me" and returns from `run()`. The
 * candidates are, cheapest first:
 *
 *   1. `feof()`                               — one call, and the obvious answer if it works
 *   2. `stream_get_meta_data()['timed_out']`  — one call, describes the last read
 *   3. `stream_select()`                      — a syscall, but answers "is there something
 *                                               to read" *before* a read can block
 *   4. `default_socket_timeout = -1`          — no deadline; EOF becomes the only exit
 *
 * Each is measured against the same two situations, because a mechanism that reports EOF
 * merely because the peer is quiet *is* the bug rather than the fix:
 *
 *   QUIET   the peer holds the connection open and sends nothing past the deadline
 *   CLOSED  the peer closes while the reader is waiting
 *
 *     php scripts/probe-eof-vs-timeout.php [timeout-seconds] [quiet-seconds]
 *
 * Exit code 0 when at least one mechanism separates the two cases correctly.
 */
$timeout = (int) ($argv[1] ?? 2);
$quietFor = (int) ($argv[2] ?? 6);

$dir = sys_get_temp_dir() . '/volucer-eof-probe';
@mkdir($dir);
$path = "$dir/s.sock";
@unlink($path);

$server = stream_socket_server("unix://$path", $errno, $errstr);
if ($server === false) {
    fwrite(STDERR, "bind failed: $errstr\n");
    exit(1);
}

/**
 * One scenario: a forked peer behaves as `$peerSeconds` says, and a forked reader reports
 * what every mechanism saw.
 *
 * The reader is the child because `default_socket_timeout` is captured when a stream is
 * *created*; a value set after `stream_socket_client()` is never consulted, which is the
 * mistake that made an earlier version of this probe measure nothing at all.
 *
 * @param resource $server
 */
function scenario($server, string $label, string $path, int $timeout, int $peerSeconds): void
{
    $peer = pcntl_fork();

    if ($peer === 0) {
        $conn = stream_socket_accept($server, 10.0);
        if ($conn !== false) {
            sleep($peerSeconds);
            @fclose($conn);
        }
        exit(0);
    }

    $reader = pcntl_fork();

    if ($reader === 0) {
        ini_set('default_socket_timeout', (string) $timeout);

        $conn = stream_socket_client("unix://$path", $errno, $errstr, 10.0);
        if ($conn === false) {
            fwrite(STDERR, "connect failed: $errstr\n");
            exit(2);
        }

        // Exactly what `readHeader()` does today.
        $started = microtime(true);
        $bytes = stream_get_contents($conn, 16);
        $elapsed = microtime(true) - $started;

        $meta = stream_get_meta_data($conn);
        $timedOut = (bool) ($meta['timed_out'] ?? false);
        $eof = feof($conn);

        // A close is readable; a quiet socket is not. This is the question a
        // `stream_select` guard would ask *before* reading, and it is the same question.
        $read = [$conn];
        $write = null;
        $except = null;
        $ready = @stream_select($read, $write, $except, 0, 0);

        printf(
            "  %-6s read=%-4s %5.2fs  timed_out=%-5s feof=%-5s readable=%-4s\n",
            $label,
            var_export($bytes, true),
            $elapsed,
            var_export($timedOut, true),
            var_export($eof, true),
            var_export($ready, true),
        );
        exit(0);
    }

    pcntl_waitpid($peer, $status);
    pcntl_waitpid($reader, $status);
}

printf("timeout=%ds\n", $timeout);

// QUIET: the peer outlives the deadline and says nothing.
scenario($server, 'QUIET', $path, $timeout, $quietFor);

// CLOSED: the peer closes well inside the deadline.
scenario($server, 'CLOSED', $path, $timeout, 1);

@unlink($path);
fclose($server);

echo "\nUsable only if the two rows differ. A mechanism that reports EOF for QUIET\n";
echo "reproduces the bug it is meant to fix.\n";
