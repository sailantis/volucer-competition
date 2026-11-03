<?php

declare(strict_types=1);

/**
 * HELLO ARM — the COLD entry point: what `spawn_cgi` (and `php-fpm`) run.
 *
 * This file exists so the hello page can be measured under the cold model at all.
 * Every other hello arm boots the application once and reuses it; `spawn_cgi` gets a
 * full CGI SAPI reset per request, so a cold arm is only honest if the boot happens
 * *inside* the request. Sharing `supervisor.php`'s resident loop here would quietly
 * make the cold arm warm and erase the thing being measured.
 *
 * That is a real trade and it is stated rather than hidden: the numbers from this
 * file include a framework boot per request, so a comparison against `upstream`
 * prices **two** differences at once — the cold model and the blocking transport.
 * The warm arms (`attach`, `worker`) are what separate them: they hold the page and
 * the model equal and change only the transport.
 *
 *     GET /  ->  {"hello":"world"}
 *
 * The response conversion is the same three lines `serve.php` does for the resident
 * arms, written against PHP's CGI protocol instead of volucer's, because a CGI child
 * talks to its SAPI and not to us.
 */

// `public/` is three levels down: the app, the checkout root and the vendor tree are
// above it. Azera's classes come from the autoloader, so the cold arm can never
// disagree with the warm ones about which code it runs.
$root = dirname(__DIR__, 3);
require $root . '/vendor/autoload.php';
require dirname(__DIR__) . '/HelloApp.php';

$app = new App\Hello\HelloApp();
// Inside the request, which is the whole point of this file.
$app->bootstrap();

// The page takes no query, so only the path is used — the same reduction `serve.php`
// makes, for the same reason: passing a query through would add work the Fastify arm
// does not do.
$uri = (string) ($_SERVER['REQUEST_URI'] ?? '/');
$path = parse_url($uri, PHP_URL_PATH);
if (!is_string($path) || $path === '') {
    $path = '/';
}

$result = $app->dispatch((string) ($_SERVER['REQUEST_METHOD'] ?? 'GET'), $path);

http_response_code($result->status);
foreach ($result->headers as $name => $value) {
    header($name . ': ' . $value);
}
echo $result->body;
