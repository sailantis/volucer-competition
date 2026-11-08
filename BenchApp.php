<?php

declare(strict_types=1);

/**
 * The application, shared by all five arms.
 *
 * Every arm must run the *same* application code or the comparison measures
 * nothing: the only differences between the arms are the server, the transport,
 * and whether the framework's bootstrap is paid once (a resident worker) or on
 * every request (a full CGI SAPI reset, as php-fpm does).
 *
 * `bootstrap()` is the expensive part and that is the entire point of the
 * experiment. `azera-competition` measured it at ~0.47 ms per request, against a
 * `GET /` that returns in ~0.255 ms warm — so a cold arm spends most of its time
 * rebuilding the container it is about to throw away.
 */

use App\Azera\Bootstrap;
use Azera\Http\Request;

/**
 * A status and a body, so "no route matched" is reported as a 404 on every arm
 * rather than as a 200 whose body happens to say so.
 */
final class BenchResult
{
    public function __construct(
        public readonly int $status,
        public readonly string $body,
    ) {
    }
}

final class BenchApp
{
    private ?\Azera\AppContext $ctx = null;

    /**
     * `$bare` answers "what does `/echo` actually consist of?" by removing the
     * framework from the measured path and nothing else.
     *
     * It exists to be used once, as a diagnostic, and not published as an arm.
     * The reason is fairness: a bare `volucer-attach` reuses a loaded worker while
     * a bare `php-fpm` cannot, so a bare warm-versus-cold comparison prices the
     * warm/cold model rather than the framework. Run it per arm at one
     * concurrency, compare bare against non-bare *within* one arm, and throw the
     * arm away.
     *
     * The flag is a constructor argument rather than a request parameter because
     * the warm arms build this object once, before their request loop: a
     * `?bare=1` would arrive long after `bootstrap()` had run. See the entry
     * points, which read `BENCH_BARE` from the environment for that reason.
     */
    public function __construct(
        private readonly string $dbPath,
        private readonly bool $bare = false,
    ) {
    }

    /**
     * Boot the framework once. Called before the request loop by the worker, and
     * once per request by the front controller.
     *
     * In `$bare` mode this does nothing at all — no container, no router, and no
     * `Bootstrap::boot()`. Skipping it is the entire point: the remaining work is
     * the server, the transport and the SAPI.
     */
    public function bootstrap(): void
    {
        if ($this->bare) {
            return;
        }

        $this->ctx = Bootstrap::boot($this->dbPath);
    }

    /**
     * Dispatch one request and return its status and body.
     *
     * The URI is path plus query, exactly as both servers present it, so the
     * router and the paginator see the same input on every arm.
     */
    public function dispatch(string $method, string $uri): BenchResult
    {
        if ($this->bare) {
            return $this->bareResponse($uri);
        }

        $ctx = $this->ctx ?? throw new RuntimeException('dispatch() before bootstrap()');

        // A synthetic $_SERVER rather than the real one: the arms differ in
        // whether PHP's CGI SAPI populates it, and letting that leak into the
        // application would make the cold arms do more work than the warm ones
        // for reasons that have nothing to do with the server.
        $server = [
            'REQUEST_URI' => $uri,
            'REQUEST_METHOD' => $method,
            'SERVER_PROTOCOL' => 'HTTP/1.1',
            'HTTP_HOST' => 'bench.local',
            'SCRIPT_NAME' => '/index.php',
        ];

        $request = new Request($server);
        $ctx->set(Request::class, $request);

        $route = $ctx->router()->match($request->path(), $request->method());
        if ($route === null) {
            return new BenchResult(404, '<h1>404 Not Found</h1>');
        }

        $response = $ctx->dispatcher()->dispatch($route);

        return new BenchResult($response->getStatus(), $response->getBody());
    }

    /**
     * The body a bare request returns, and the whole of the work it does.
     *
     * `/echo` answers `bench` through the framework; this answers the same bytes
     * without the router, so the two differ only by the framework. Any other path,
     * including `/items`, gets that same fixed body rather than a 404: the
     * diagnostic asks what the request costs, not what a page costs, and a 404
     * branch would introduce a comparison the framework arm does not have.
     */
    private function bareResponse(string $uri): BenchResult
    {
        return new BenchResult(200, 'bench');
    }

    /**
     * The resident-worker contract: drop this request's state before the next one.
     *
     * Only a resident worker needs this, and the reason is narrower than "state
     * accumulates". Measured, memory does not climb either way: `AppContext`
     * replaces its `Request` each dispatch and the identity map belongs to the
     * per-dispatch `EntityManager`, so 2,000 requests on one app hold at ~4 MB
     * whether or not this is called.
     *
     * What it buys is isolation, not reclamation. Without it, request N+1 can see
     * the `RequestScoped` service instances request N left behind, because the
     * container itself is reused for the life of the worker. That is a correctness
     * property of a long-lived process, and it is invisible until something
     * stores per-request state in a service.
     *
     * On a cold arm this is a no-op: `public/index.php` constructs a fresh
     * `BenchApp` and `AppContext` per request, so the previous request's container
     * is already garbage. Measured on real servers at c=96, calling it or not
     * moves `/items` by +0.8% and `/echo` by +1.3% on fpm, both inside the
     * round-to-round noise. It stays because it is free and because a `php-cgi`
     * child does serve several requests in sequence, which is easy to forget.
     */
    public function cleanup(): void
    {
        $this->ctx?->clearRequestScope();
    }
}
