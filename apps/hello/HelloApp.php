<?php

declare(strict_types=1);

namespace App\Hello;

use Azera\AppContext;
use Azera\Http\Request;
use RuntimeException;

/**
 * The hello-world application, booted once and then dispatched per request.
 *
 * Deliberately the same shape as `BenchApp` — a `bootstrap()` that builds the
 * container, a `dispatch()` that turns one request into one response, and a
 * `cleanup()` the worker calls between requests — so the only thing this arm adds to
 * the comparison is the *page*, not a second way of wiring an application.
 *
 * What the page does not do is as deliberate as what it does. There is no database,
 * no template render, no middleware, and no service resolution beyond the router and
 * the dispatcher, because the Fastify arm does none of those either. `/items` in
 * `BenchApp` is the page that measures a framework's work; this one is the floor
 * beneath it, and it exists to be compared against a Node runtime on the same
 * request.
 *
 * The route table is registered once, at boot, and the router and dispatcher are
 * reused for every request. That is the whole premise of the warm model: the boot is
 * paid here and never again.
 */
final class HelloApp
{
    private ?AppContext $ctx = null;

    /**
     * Boot the application. Called before the fork, so every child inherits the
     * booted container instead of building one of its own.
     */
    public function bootstrap(): void
    {
        AppContext::setInstance(new AppContext());
        $ctx = AppContext::instance();

        // `HelloController` is outside composer's PSR-4 map (`App\Azera\`), so it is
        // loaded by path. A checkout that has not had `composer dump-autoload` run
        // since this directory appeared must still start: a class missing after the
        // supervisor has already announced "listening" shows up as a connection
        // reset on the pool's first request rather than as the error it is.
        require_once __DIR__ . '/HelloController.php';
        require_once __DIR__ . '/HelloResult.php';

        $ctx->router()->get('/', HelloController::class . '::indexAction');

        // The dispatcher resolves the controller name relative to this namespace, so
        // the route above names a class rather than a path.
        $ctx->dispatcher()->setBaseNamespace(__NAMESPACE__);

        $this->ctx = $ctx;
    }

    /**
     * Dispatch one request and return its status, headers and body.
     *
     * The URI is the path alone: this page takes no query, and letting one through
     * would only add work the Fastify arm does not do.
     */
    public function dispatch(string $method, string $uri): HelloResult
    {
        $ctx = $this->ctx ?? throw new RuntimeException('dispatch() before bootstrap()');

        // A synthetic `$_SERVER` rather than the real one. The arms differ in whether
        // PHP's CGI SAPI populated it at all, and letting that leak into the
        // comparison would charge one arm for a superglobal it never read.
        $request = new Request([
            'REQUEST_URI' => $uri,
            'REQUEST_METHOD' => $method,
            'SERVER_PROTOCOL' => 'HTTP/1.1',
            'HTTP_HOST' => 'bench.local',
            'SCRIPT_NAME' => '/index.php',
        ]);
        $ctx->set(Request::class, $request);

        $route = $ctx->router()->match($request->path(), $request->method());
        if ($route === null) {
            return new HelloResult(404, ['Content-Type' => 'text/plain; charset=utf-8'], 'Not Found');
        }

        $response = $ctx->dispatcher()->dispatch($route);

        return new HelloResult(
            $response->getStatus(),
            $response->getHeaders(),
            $response->getBody(),
        );
    }

    /**
     * The resident-worker contract: drop this request's state before the next one.
     *
     * A forked child serves its connection until the server closes it, so it answers
     * many requests. Without this the request-scoped heap survives into the next one,
     * which shows up as memory and latency climbing across a run rather than as an
     * error.
     */
    public function cleanup(): void
    {
        $this->ctx?->clearRequestScope();
    }
}
