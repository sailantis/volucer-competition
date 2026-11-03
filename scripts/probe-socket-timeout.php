<?php

declare(strict_types=1);

/**
 * Does a unix-socket read honour `default_socket_timeout`, and is a timeout distinguishable
 * from a closed peer?
 *
 * This matters because the worker SDK's `readHeader()` is:
 *
 *     $bytes = stream_get_contents($this->in, Header::HEADER_LEN);
 *     if ($bytes === false || $bytes === '') { return null; }   // "clean EOF: break"
 *
 * so if a timeout also produces `false`/`''`, a worker that idles for longer than the
 * timeout exits *silently*, believing the server closed the connection.
 *
 * The timeout is captured when the stream is **created**, not when it is read, so the
 * setting has to be in place before `stream_socket_accept()`. An earlier version of this
 * probe set it afterwards and therefore measured nothing: the stream kept the 60 s default
 * and the read simply waited for the peer to exit, which `stream_get_contents` reports as
 * end-of-file rather than as a timeout.
 *
 *     php scripts/probe-socket-timeout.php
 */
$timeout = (int) ($argv[1] ?? 2);
$peerLifetime = (int) ($argv[2] ?? 8);

$dir = sys_get_temp_dir() . '/volucer-timeout-probe';
@mkdir($dir);
$path = "$dir/s.sock";
@unlink($path);

$server = stream_socket_server("unix://$path", $errno, $errstr);
if ($server === false) {
    fwrite(STDERR, "bind failed: $errstr\n");
    exit(1);
}

// The **reading** side is the child, and it sets the timeout before it creates its stream:
// `default_socket_timeout` is captured when a stream is opened, so a value set afterwards
// is never consulted. (It also bounds `stream_socket_accept`, which is why the accepting
// side here keeps the default and is not the one under test.)
$pid = pcntl_fork();
if ($pid === 0) {
    ini_set('default_socket_timeout', (string) $timeout);

    $client = stream_socket_client("unix://$path", $errno, $errstr, 10.0);
    if ($client === false) {
        fwrite(STDERR, "connect failed: $errstr\n");
        exit(1);
    }

    $started = microtime(true);
    $bytes = stream_get_contents($client, 16);
    $elapsed = microtime(true) - $started;
    $meta = stream_get_meta_data($client);

    printf("timeout=%ds peer_lifetime=%ds\n", $timeout, $peerLifetime);
    printf("returned=%s elapsed=%.2fs timed_out=%s eof=%s\n",
        var_export($bytes, true),
        $elapsed,
        var_export($meta['timed_out'] ?? null, true),
        var_export($meta['eof'] ?? null, true),
    );
    printf("=> %s\n", ($elapsed < $peerLifetime - 0.5)
        ? 'TIMED OUT while the peer was still open (the SDK reads this as EOF and exits)'
        : 'read until the peer closed (a genuine EOF)');
    exit(0);
}

// The peer: accept, then stay silent for as long as the lifetime says.
$conn = stream_socket_accept($server, 10.0);
sleep($peerLifetime);
@fclose($conn);
pcntl_waitpid($pid, $status);
@unlink($path);
exit(0);

$client = stream_socket_accept($server, 10.0);
if ($client === false) {
    fwrite(STDERR, "accept failed\n");
    exit(1);
}

$started = microtime(true);
$bytes = stream_get_contents($client, 16);
$elapsed = microtime(true) - $started;
$meta = stream_get_meta_data($client);

printf("timeout=%ds peer_lifetime=%ds\n", $timeout, $peerLifetime);
printf("returned=%s elapsed=%.2fs timed_out=%s eof=%s\n",
    var_export($bytes, true),
    $elapsed,
    var_export($meta['timed_out'] ?? null, true),
    var_export($meta['eof'] ?? null, true),
);

// The question the SDK's `readHeader()` cannot ask: was this a timeout or a closed peer?
printf("=> %s\n", ($elapsed < $peerLifetime - 0.5)
    ? 'TIMED OUT before the peer went away (indistinguishable from EOF in the SDK)'
    : 'read until the peer closed (a genuine EOF)');

pcntl_waitpid($pid, $status);
@unlink($path);
