<?php

declare(strict_types=1);

/**
 * What the two PHP arms share: one response from one request, and the header
 * conversion both of them need.
 *
 * A plain function rather than a class, because it has no state and there is nothing
 * to inject. `supervisor.php` and `worker.php` both call it, so the arm-to-arm
 * comparison cannot drift on the one line that turns the application's answer into
 * the protocol's.
 */

/**
 * Dispatch one volucer request against a booted application.
 *
 * The URI is reduced to its path: this page takes no query, and passing one through
 * would add work the Fastify arm does not do.
 */
function hello_serve(App\Hello\HelloApp $app, Volucer\Request $request): Volucer\Response
{
    $path = (string) parse_url($request->uri, PHP_URL_PATH);
    $result = $app->dispatch($request->method, $path === '' ? '/' : $path);

    // Drop this request's scope before the next one is read. In a supervisor it
    // matters more than in a reused process: the next request may arrive on a
    // *different* child, which inherited none of this state.
    $app->cleanup();

    return new Volucer\Response($result->status, hello_header_pairs($result->headers), $result->body);
}

/**
 * Azera's header map as the SDK's ordered list of pairs.
 *
 * Azera holds one value per name; the wire format carries an ordered list with case
 * preserved, so the map is simply unrolled.
 *
 * @param array<string, string> $headers
 * @return list<array{0: string, 1: string}>
 */
function hello_header_pairs(array $headers): array
{
    $pairs = [];
    foreach ($headers as $name => $value) {
        $pairs[] = [(string) $name, (string) $value];
    }

    return $pairs;
}
