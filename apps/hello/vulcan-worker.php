<?php

declare(strict_types=1);

/**
 * A minimal worker that advertises `answers_ping` and reads a read deadline as end-of-file.
 *
 * It exists to measure the **server-side** keepalive, which neither shipped SDK can demonstrate:
 *
 * - The current SDK asks whether an empty read was a timeout (`readTimedOut()`, `feof()`), so a
 *   deadline on an idle read is waited out. A pool with no keepalive loses nothing, so there is
 *   nothing for the keepalive to rescue.
 * - The older SDK *does* read a deadline as a close, but does not advertise `answers_ping`, so the
 *   server correctly refuses to ping it. That refusal is the safety property, not a gap.
 *
 * So this is the third case and the one the feature exists for: a worker that has told the server it
 * may be pinged and has not fixed its own read loop.
 *
 * **Written against the wire format rather than subclassed from the SDK**, because every method the
 * loop needs there is private. The format is small — a 16-byte little-endian header and a JSON
 * payload — and reusing the SDK's `Header`, `Frame` and `MessageType` keeps the bytes honest without
 * reaching into anything private.
 *
 * Run with `php -d default_socket_timeout=N vulcan-worker.php`. It uses whichever transport the
 * server named in `VOLUCER_WORKER_SOCKET`, and stdio if it named none, so it works under `attach`
 * and under `worker` alike.
 */

require __DIR__ . '/../../vendor/autoload.php';

use Volucer\Frame;
use Volucer\Header;
use Volucer\MessageType;
use Volucer\Worker;

/**
 * Open the transport the server asked for, the way a real worker does.
 *
 * Returns one handle because the protocol is half-duplex per exchange: a request is written and its
 * answer read before the next one, so a reader and a writer that are the same descriptor never
 * interleave.
 *
 * `VOLUCER_WORKER_SOCKET` carries either form, and the prefix decides which — the same convention
 * the server's configuration uses. Building the URL here rather than passing the raw value is what
 * the SDK does too: `unix:/path` is not a `stream_socket_client` address, and handing it over
 * produces a `getaddrinfo` failure that reads as a DNS problem.
 */
function vulcan_open()
{
    $address = getenv('VOLUCER_WORKER_SOCKET');

    if ($address === false || trim($address) === '') {
        return STDIN;
    }

    $address = trim($address);
    // The prefix is spelled here rather than taken from the SDK, because the vendored copy in this
    // repository predates the constant and a fixture that depends on the SDK's internals would stop
    // working the moment the vendored copy moved.
    $url = str_starts_with($address, 'unix:')
        ? 'unix://' . substr($address, strlen('unix:'))
        : 'tcp://' . $address;

    $stream = @stream_socket_client($url, $errno, $errstr, 5.0);
    if ($stream === false) {
        fwrite(STDERR, "[vulcan] could not connect to $url: $errstr\n");
        exit(1);
    }

    return $stream;
}

/** Read one header, or `null` when the stream produced nothing at all. */
function vulcan_read($in): ?Header
{
    $bytes = stream_get_contents($in, Header::HEADER_LEN);

    if ($bytes === false || $bytes === '') {
        // **The defect, in one line.** `null` means "the read produced nothing", which is equally
        // true of a peer that closed and of a read that merely ran out of time. The fix is to ask
        // `feof()`; this does not, so an idle deadline ends the worker.
        return null;
    }

    return Header::decode($bytes);
}

/** Read a frame's payload, up to the length its header declares. */
function vulcan_payload($in, Header $header): string
{
    $need = $header->payloadLen;
    $buffer = '';

    while (strlen($buffer) < $need) {
        $piece = fread($in, $need - strlen($buffer));
        if ($piece === false || $piece === '') {
            break;
        }
        $buffer .= $piece;
    }

    return $buffer;
}

function vulcan_write($out, Frame $frame): void
{
    fwrite($out, $frame->encode());
    fflush($out);
}

$in = $out = vulcan_open();

// HELLO, then HELLO_ACK. `answers_ping` is the whole point of the fixture, so the claim and the
// behaviour are deliberately in tension: the server is told it may ping, and this reads the ping's
// absence of traffic as a close.
$hello = vulcan_read($in);
if ($hello === null || $hello->messageType !== MessageType::HELLO) {
    fwrite(STDERR, "[vulcan] expected a HELLO to begin the handshake\n");
    exit(1);
}
vulcan_payload($in, $hello);

vulcan_write($out, new Frame(MessageType::HELLO_ACK, Worker::UNSOLICITED, json_encode([
    'protocol_version' => Header::PROTOCOL_VERSION,
    'php_version' => PHP_VERSION,
    'sapi' => PHP_SAPI,
    'pid' => (int) getmypid(),
    'runtime' => 'vulcan-fixture',
    'no_checksum' => false,
    // **The claim.** With this set the server will keep this worker alive.
    'answers_ping' => true,
    // Not advertised: this fixture does not implement streamed request bodies.
    'stream_request_body' => false,
], JSON_THROW_ON_ERROR)));

while (true) {
    $header = vulcan_read($in);

    if ($header === null) {
        fwrite(STDERR, "[vulcan] nothing to read; treating it as a close and exiting\n");
        return;
    }

    $payload = vulcan_payload($in, $header);

    switch ($header->messageType) {
        case MessageType::REQUEST:
            // The smallest legal answer: a constant body. The page is irrelevant, the pool's
            // liveness is the measurement.
            $body = '{"hello":"world"}';
            vulcan_write($out, new Frame(
                MessageType::RESPONSE,
                $header->requestId,
                json_encode([
                    'status' => 200,
                    'headers' => [['content-type', 'application/json']],
                    'body_len' => strlen($body),
                ], JSON_THROW_ON_ERROR),
            ));
            vulcan_write($out, new Frame(
                MessageType::BODY,
                $header->requestId,
                $body,
                Header::FLAG_LAST,
            ));
            vulcan_write($out, new Frame(
                MessageType::END,
                $header->requestId,
                json_encode([
                    'app_status' => 0,
                    'peak_memory_bytes' => memory_get_peak_usage(true),
                    'duration_us' => 0,
                    'keep_alive' => true,
                ], JSON_THROW_ON_ERROR),
            ));
            break;

        case MessageType::PING:
            // Answered, and that is why the server keeps pinging: the pool acts on the *answer*,
            // not on the absence of traffic.
            vulcan_write($out, new Frame(MessageType::PONG, Worker::UNSOLICITED));
            break;

        case MessageType::CONTROL:
        case MessageType::LOG:
        case MessageType::METRIC:
        case MessageType::EVENT:
            break;

        default:
            fwrite(STDERR, "[vulcan] refusing a " . $header->typeName() . "\n");
            exit(1);
    }
}
