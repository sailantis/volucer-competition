<?php
/**
 * Azera benchmark bootstrap.
 *
 * Wires AppContext with SQLite, ClarityEngine views, and the 4 benchmark
 * routes.  Called by AzeraAdapter::bootstrap().
 */

namespace App\Azera;

use App\Azera\Controllers\BenchController;
use Azera\Aop\Cache as CacheAdvice;
use Azera\Aop\CacheInterceptor;
use Azera\Aop\Log as LogAdvice;
use Azera\Aop\LogInterceptor;
use Azera\Aop\Retry as RetryAdvice;
use Azera\Aop\RetryInterceptor;
use Azera\Aop\Transactional;
use Azera\Aop\TransactionalInterceptor;
use Azera\AppContext;
use Azera\Cache\ArrayCache;
use Azera\Core\Engines\ClarityEngine;
use Azera\Core\ViewEngine;
use Azera\Db\Database;
use Azera\Event\EventDispatcher;
use Azera\Queue\QueueInterface;
use Azera\Queue\SyncQueue;
use Psr\EventDispatcher\EventDispatcherInterface;
use Psr\Log\LoggerInterface;
use Psr\SimpleCache\CacheInterface;

class Bootstrap
{
    /**
     * Wiring memo, so a boot in a process that already has one can skip
     * rebuilding the container and the 120-entry route table.
     * Keyed by dbPath so separate contexts (different databases) never
     * share a table.
     *
     * This works in a long-lived CLI process and does NOT work under php-fpm.
     * With OPcache on, the class entry lives in shared memory, so PHP restores
     * mutable statics to their compile-time defaults at the start of every
     * request: measured with one fpm child and five sequential requests
     * (`scripts/probe-static.sh`), the same pid sees the same static reset
     * every time. So on fpm this is empty by the time it is read, and
     * `boot()` pays the full ~170 us per request.
     *
     * In a CLI worker (volucer's model) it does work: first boot ~6.9 ms once
     * the autoloader is warm, then 0.45-2.5 us per re-bootstrap.
     *
     * The "~0.38 ms of pure rebuild" this originally claimed to save was
     * measured under the CLI, where the memo hits. The rebuild is real, but it
     * is ~120 us, and on fpm the memo never avoids it. See
     * `docs/framework-cost.md`.
     *
     * @var array<string, AppContext>
     */
    private static array $wired = [];

    /**
     * How many filler routes to register. A property rather than a literal
     * because the count is a benchmark *input*, not a fact about the app:
     * `scripts/probe-boot-cost.php` varies it to separate per-route cost from
     * everything else the boot does. 100 is what every published run used.
     */
    public static int $fillerRoutes = 100;

    /**
     * Boot phase timings, filled in when {@see self::profile()} is called.
     *
     * `boot()` is one 2 ms block in the profile and every statement about why
     * it costs that is a guess until the block is split. This is a nullable
     * array checked once per section, so leaving it null costs nothing on the
     * hot path -- which matters, because `boot()` is measured.
     *
     * @var array<string, float>|null  phase name => microseconds
     */
    public static ?array $profile = null;
    private static int $profileAt = 0;

    /**
     * Close a boot phase and file its elapsed time under `$label`.
     *
     * Called at the *end* of each section so the label names the work that
     * just finished. A no-op unless {@see self::$profile} was initialised, and
     * a single null test when it was not, so `boot()` costs the same either way.
     */
    private static function mark(string $label): void
    {
        if (self::$profile === null) {
            return;
        }
        $now = hrtime(true);
        self::$profile[$label] = (self::$profile[$label] ?? 0.0) + ($now - self::$profileAt) / 1000.0;
        self::$profileAt = $now;
    }

    /**
     * Record phase timings for the next boot into {@see self::$profile}.
     * Returns the previous setting so a caller can restore it.
     */
    public static function profile(?array $initial = []): ?array
    {
        $old = self::$profile;
        self::$profile = $initial;
        self::$profileAt = hrtime(true);
        return $old;
    }

    /**
     * Forget the wiring memo — the next boot() rebuilds everything (fresh
     * AppContext, route table, services). verify.php/tests call this to get
     * true cold isolation; the benchmark's cold mode runs each app in its
     * own child process, where the memo is empty anyway.
     */
    public static function forget(): void
    {
        self::$wired = [];
        AppContext::reset();
    }

    public static function boot(string $dbPath): AppContext
    {
        self::mark('start');
        $ctx = self::$wired[$dbPath] ?? null;

        if ($ctx !== null) {
            // A re-bootstrap in a process that already has a wired context.
            // This branch is reachable from a CLI worker (volucer's model) and
            // is effectively dead under php-fpm, where the static above is reset
            // between requests -- see the note on self::$wired.
            // Request-scoped state was reset by clearRequestScope() after
            // the previous request (the RequestScoped contract) — nothing
            // to rebuild here beyond handing back the same context.
            AppContext::setInstance($ctx);
            return $ctx;
        }

        // Fresh singleton for cold-mode reproducibility
        AppContext::setInstance(new AppContext());
        $ctx = AppContext::instance();

        // Reset benchmark state for cold-mode reproducibility
        \App\Azera\Middleware\RequestContextMiddleware::reset();
        self::mark('AppContext');

        // --- Database (SQLite) ---
        // Use a factory so we can configure PRAGMAs right after connecting.
        $ctx->dbManager()->set('default', function () use ($dbPath) {
            $db = new Database('sqlite:' . $dbPath);
            // WAL mode + busy timeout so POST (write) iterations don't lock
            $db->query('PRAGMA journal_mode = WAL');
            $db->query('PRAGMA busy_timeout = 5000');
            // Reuse prepared statements between requests. The benchmark runs the same
            // handful of statements tens of thousands of times, so re-parsing the SQL
            // (`sqlite3_prepare_v2`) on every call is pure overhead: measured at
            // -17.7% dispatch CPU and +9.6% served throughput at c=96. Enabled here for
            // every SQLite arm rather than only volucer's, because it is a property of
            // the application, not of the server in front of it — leaving it off would
            // charge all six arms for the same avoidable work.
            $db->useStatementCache(true);
            return $db;
        });

        // Tell the Item model to use the default role
        //Item::setDefaultRole('default');
        self::mark('Database factory');

        // --- Views (Clarity) ---
        // Register a deferred factory on the container instead of calling
        // $ctx->view() at boot: boot never renders, so the Clarity class
        // stack must not be autoloaded here. The engine is built on the
        // first render (inside dispatch).
        $cacheDir = __DIR__ . '/../../data/cache';
        if (!is_dir($cacheDir)) {
            @mkdir($cacheDir, 0777, true);
        }
        $viewsPath = __DIR__ . '/Views';
        // Register the Clarity view engine lazily because not all requests need to render views.
        //
        // setRevalidateFreq(60) makes the template cache behave the way the OPcache
        // in this matrix already behaves. Every arm here runs OPcache with
        // `opcache.validate_timestamps=0` (see `write_wrappers()` in
        // scripts/matrix.sh), so PHP files are never re-stat()ed at runtime -- the
        // matrix deliberately does not pay for that check. Clarity's own freshness
        // check is not governed by that ini: it stats every dependency on every
        // render unless told otherwise, which made this app the one place in the
        // run still verifying its source files per request.
        //
        // 60 is the same window php-fpm's php.ini uses on this host
        // (`opcache.revalidate_freq = 60`), so code and templates now age on the
        // same schedule. That is the production posture the benchmark is meant to
        // describe: the deploy path clears both caches, and neither is checked per
        // request. Verified to be byte-identical output; it changes only how often
        // the filesystem is consulted.
        $ctx->set(ViewEngine::class, fn() =>
            (new ClarityEngine())
                ->setExtension('.clarity.html')
                ->setViewPath($viewsPath)
                ->setCachePath($cacheDir)
                ->setRevalidateFreq(60)
                ->setVars([
                    'locale'   => 'en_US',
                    'platform' => 'desktop',
                ]));
        self::mark('View engine');

        // --- Routes ---
        // The cached() declarations below are what turn the framework route cache on,
        // and the router writes the table itself on the first read after the sources
        // change -- no separate `routes:cache` call is needed. `BENCH_ROUTE_CACHE`
        // chooses *where* it lives; `BENCH_ROUTE_CACHE=off` opts out entirely, which is
        // the cold arm this benchmark measures against. `BENCH_ROUTE_WARM=1`
        // additionally forces a compile up front, which is what a deploy hook would do.
        //
        // Every registration below lives inside a cached() block, so the table is
        // entirely attributable to a file. A route registered outside one is refused by
        // the router, because a cache hit would change the winner wherever two routes
        // tie on specificity -- see RouterStateTest.
        $router     = $ctx->router();
        $routeCache = getenv('BENCH_ROUTE_CACHE');

        if ($routeCache === 'off') {
            $router->disableCache();
        } elseif ($routeCache !== false && $routeCache !== '') {
            $router->setCachePath($routeCache);
        }

        $router->cached(__FILE__, function (\Azera\Core\Router $router): void {
            // Benchmark endpoints (the ones we actually time).
            // Use the controller() group with a callback so the group stack
            // is automatically restored afterwards.
            $router->controller(BenchController::class, function (\Azera\Core\Router $r) {
                $r->get('/', '::indexAction');
                // The framework floor: routed, dispatched, both middlewares, no work after that.
                $r->get('/echo', '::echoAction');
                // ORM endpoints (model hydration)
                $r->get('/items', '::listAction');
                // GET /items with the identity map removed and nothing else changed:
                // the single-variable control for /items (see listFastAction).
                $r->get('/items-fast', '::listFastAction');
                $r->get('/items/{id:int}', '::showAction');
                $r->post('/items', '::createAction');

                // New ORM stack endpoints (Model facade over the EM pipeline)
                // Deactivated (2026-09-05) — the listOrmAction/showOrmAction/
                // createOrmAction actions stay in BenchController for the next
                // comparison run; re-enable these three routes to bring the
                // /items-orm paths back.
                // $r->get('/items-orm', '::listOrmAction');
                // $r->get('/items-orm/{id:int}', '::showOrmAction');
                // $r->post('/items-orm', '::createOrmAction');

                // Query Builder endpoints (no model hydration)
                $r->get('/items-qb', '::listQbAction');
                $r->get('/items-qb/{id:int}', '::showQbAction');
                $r->post('/items-qb', '::createQbAction');
            });

            // --- Fill routes ---
            // 100 dummy routes to simulate a real project's route table.
            // We never dispatch these — they exist only so the router has a
            // realistic number of entries to search through on every match.
            // Mix of static, parametric, grouped, and multi-method routes.
            self::registerFillerRoutes($router, self::$fillerRoutes);
        });
        self::mark('Bench routes, fillers');

        // --- Dispatcher + Global Middleware ---
        $dispatcher = $ctx->dispatcher();
        $dispatcher->setBaseNamespace('\App\Azera\Controllers');

        // Global middleware pipeline (runs on every dispatched request):
        //   1. SecurityHeadersMiddleware — sets common security headers
        //      on the response (X-Frame-Options, X-Content-Type-Options, etc.)
        //   2. RequestContextMiddleware — reads Accept-Language + User-Agent
        //      from request headers, picks a locale, stamps view vars
        // This mirrors typical real-app middleware stacks and adds realistic
        // per-request overhead that all full-stack frameworks pay.
        $dispatcher->addMiddleware(new \App\Azera\Middleware\SecurityHeadersMiddleware());
        $dispatcher->addMiddleware(new \App\Azera\Middleware\RequestContextMiddleware());
        self::mark('Dispatcher + middleware');

        // --- Enterprise Infrastructure (PSR-3/14/16 + AOP) ---
        self::registerEnterpriseServices($ctx);
        self::mark('Enterprise services');

        // --- FeatureService (autowired so AOP proxy is generated) ---
        // Registered as a class string (no factory) so AppContext::build()
        // generates the AOP proxy.  The constructor receives AppContext
        // which is already available as a registered service.
        $ctx->set(\App\Azera\Services\FeatureService::class);

        // --- RequestScoped demo service ---
        // Registered as a class string so AppContext::build() instantiates
        // it once; clearRequestScope() calls its resetState() hook.
        $ctx->set(\App\Azera\Services\RequestCounter::class);

        // --- Config ---
        // Register a Config instance with a small nested array so the
        // /features/config demo can read dot-notation keys.
        $ctx->set(\Azera\Config\Config::class, new \Azera\Config\Config([
            'app' => ['name' => 'azera-competition', 'env' => 'bench'],
            'db'  => ['dsn' => 'sqlite:data/bench.sqlite', 'driver' => 'sqlite'],
        ]));

        // --- Session middleware (needed for CSRF demo) ---
        // IMPORTANT: registered as a NAMED GROUP, NOT globally. In CLI
        // mode (verify.php / run.php) output is echoed before dispatch, so
        // session_start() fails ("headers already sent") and leaves
        // $_SESSION null, which crashes SessionMiddleware. Scoping it to
        // only the /features/security routes keeps the benchmark endpoints
        // free of session overhead (fair comparison with the other 5
        // frameworks) while preserving the CSRF demo over HTTP.
        $dispatcher->defineMiddlewareGroup('session', [
            new \Azera\Http\SessionMiddleware(),
        ]);

        // --- Feature Demo Routes ---
        // Endpoints that exercise the new enterprise features (AOP,
        // events, cache, logging, security).  These don't interfere
        // with benchmark routes. They are a second cached() unit, both because a
        // unit is the natural granularity for a source file and because a table must
        // be entirely attributable to cached() blocks -- see RouterStateTest.
        $router->cached(__FILE__, function (\Azera\Core\Router $router): void {
            $dispatcher = AppContext::instance()->dispatcher();
            $dispatcher->defineMiddlewareGroup('session', [
                new \Azera\Http\SessionMiddleware(),
            ]);

            $router->controller(\App\Azera\Controllers\FeatureController::class, function (\Azera\Core\Router $r) {
                $r->get('/features', '::indexAction');
                $r->get('/features/aop', '::aopAction');
                $r->get('/features/cache', '::cacheAction');
                $r->get('/features/log', '::logAction');
                $r->get('/features/retry', '::retryAction');
                $r->get('/features/db-events', '::dbEventsAction');
                $r->get('/features/validation', '::validationAction');
                $r->get('/features/config', '::configAction');
                $r->get('/features/request-scoped', '::requestScopedAction');
                $r->get('/features/pipeline', '::pipelineAction');
                $r->get('/features/events', '::eventsAction');
                $r->get('/features/rate-limit', '::rateLimitAction');

                // CSRF demo needs a real session — apply the 'session' group
                // only to these routes.
                $r->middleware('session', function () use ($r) {
                    $r->get('/features/security', '::securityAction');
                    $r->post('/features/security', '::securityPostAction');
                });
            });

            // --- REST API Routes ---
            // A dedicated JSON API category.  Every framework implements the
            // same /api/* endpoints so routing + controller + JSON
            // serialization overhead is compared apples-to-apples.
            $router->controller(\App\Azera\Controllers\ApiController::class, function (\Azera\Core\Router $r) {
                $r->get('/api/items', '::indexAction');
                // /api/items with the model replaced by the literal table: the
                // single-variable control for /api/items (see indexFastAction).
                $r->get('/api/items-fast', '::indexFastAction');
                $r->get('/api/items/{id:int}', '::showAction');
                $r->post('/api/items', '::createAction');
            });
        });

        // Memoize the wired context per dbPath so a later boot in the same
        // process can skip the rebuild. Only reachable from a CLI worker; under
        // php-fpm the static is reset before this line could ever be read.
        self::$wired[$dbPath] = $ctx;
        self::mark('Feature routes');

        // A deploy-hook equivalent: compile the table now instead of leaving it for the
        // first request. Only meaningful with the cache enabled, and only here, after
        // every cached() unit has been declared.
        if (getenv('BENCH_ROUTE_WARM') === '1' && $router->cachePath() !== null) {
            $router->compileCache();
            self::mark('Route cache warm');
        }

        return $ctx;
    }

    /**
     * Register enterprise infrastructure services (PSR-3 Logger, PSR-14
     * Event Dispatcher, PSR-16 Cache, Queue) and AOP interceptors.
     *
     * This wires the new framework subsystems into the benchmark app so
     * we can validate them on a real Azera app without touching the
     * production sailantis-homepage.
     */
    private static function registerEnterpriseServices(AppContext $ctx): void
    {
        // --- PSR-3 Logger ---
        // Register a single in-memory logger instance under BOTH its
        // concrete class and the PSR-3 interface, so the #[Log] AOP
        // interceptor (which resolves LoggerInterface) and the controller
        // (which injects MemoryLogger) share the same object.  Swap to
        // Monolog for real logs.
        $memoryLogger = new \App\Azera\Services\MemoryLogger();
        $ctx->set(\App\Azera\Services\MemoryLogger::class, $memoryLogger);
        $ctx->set(LoggerInterface::class, $memoryLogger);

        // --- PSR-14 Event Dispatcher ---
        $ctx->set(EventDispatcherInterface::class, function () {
            $dispatcher = new EventDispatcher();
            $dispatcher->listen(
                \App\Azera\Events\ItemCreated::class,
                \App\Azera\Events\Listener\ItemCreatedListener::class,
            );
            // Db event listeners — one handler per concrete event class.
            // EventDispatcher also resolves listeners for parent classes
            // and interfaces, so each registration covers its subtype.
            $dispatcher->listen(
                \Azera\Db\Event\QueryExecuted::class,
                \App\Azera\Events\Listener\DatabaseEventListener::class,
            );
            $dispatcher->listen(
                \Azera\Db\Event\StatementPrepared::class,
                \App\Azera\Events\Listener\DatabaseEventListener::class,
            );
            $dispatcher->listen(
                \Azera\Db\Event\TransactionStarted::class,
                \App\Azera\Events\Listener\DatabaseEventListener::class,
            );
            $dispatcher->listen(
                \Azera\Db\Event\TransactionCommitted::class,
                \App\Azera\Events\Listener\DatabaseEventListener::class,
            );
            return $dispatcher;
        });

        // --- PSR-16 Cache ---
        $ctx->set(CacheInterface::class, fn() => new ArrayCache());

        // --- Queue ---
        $ctx->set(QueueInterface::class, fn() => new SyncQueue());

        // --- Demo services (autowired) ---
        $ctx->set(\App\Azera\Services\DbEventLog::class);
        $ctx->set(\App\Azera\Services\OrmDemoService::class);

        // --- AOP Interceptors ---
        // Enable proxy generation for #[Advised] classes.
        // AOP cache dir for file-based proxy generation.
        $ctx->setAopCacheDir(__DIR__ . '/../../data/aop');

        // Interceptors as FACTORIES: built once, on the first advised-class
        // construction (proxy build), not at boot. The eager versions pulled
        // ArrayCache + DatabaseManager + NullLogger + all four interceptor
        // classes into the cold-boot path; AOP requests resolve them on
        // first use instead.
        $ctx->registerInterceptor(
            Transactional::class,
            fn() => new TransactionalInterceptor($ctx->dbManager()),
        );
        $ctx->registerInterceptor(
            CacheAdvice::class,
            fn() => new CacheInterceptor($ctx->cache()),
        );
        $ctx->registerInterceptor(
            LogAdvice::class,
            fn() => new LogInterceptor($ctx->logger()),
        );
        $ctx->registerInterceptor(
            RetryAdvice::class,
            fn() => new RetryInterceptor($ctx->logger()),
        );
    }

    /**
     * Register N dummy routes that simulate a larger application.
     *
     * The routes are deliberately varied:
     *   - Static routes (/about, /contact, /api/v1/users, ...)
     *   - Parametric routes (/users/{id}, /blog/{slug}, /api/v1/users/{id}/posts/{postId}, ...)
     *   - Grouped routes (prefix + namespace + controller)
     *   - Multi-method routes (GET + POST on the same path)
     *
     * All handlers point to BenchController::indexAction so no extra
     * controller classes are needed; we never actually dispatch them.
     */
    private static function registerFillerRoutes(\Azera\Core\Router $router, int $count): void
    {
        $controllers = ['User', 'Post', 'Comment', 'Category', 'Tag', 'Order', 'Product', 'Page', 'Setting', 'Search'];
        $actions     = ['index', 'show', 'create', 'update', 'delete', 'edit', 'list', 'search'];
        $sections    = ['admin', 'api', 'api/v1', 'api/v2', 'dashboard', 'panel', 'manage'];
        $slugPool    = ['hello-world', 'getting-started', 'first-post', 'welcome', 'about-us', 'faq', 'docs', 'changelog'];

        $registered = 0;
        $i          = 0;

        while ($registered < $count) {
            $controller = $controllers[$i % count($controllers)];
            $action     = $actions[$i % count($actions)];
            $section    = $sections[$i % count($sections)];
            $slug       = $slugPool[$i % count($slugPool)];
            $id         = $i + 1;

            // Pattern 1: static route e.g. /admin/users/index
            $path1 = "/{$section}/{$controller}/{$action}";
            $router->add(['GET', 'POST'], $path1);
            $registered += 2; // two methods

            if ($registered >= $count) {
                break;
            }

            // Pattern 2: parametric route e.g. /api/v1/users/{id}
            $path2 = "/{$section}/{$controller}/{param{$id}:int}";
            $router->get($path2);
            $registered++;

            if ($registered >= $count) {
                break;
            }

            // Pattern 3: nested parametric e.g. /api/v1/users/{id}/posts/{postId}
            $path3 = "/{$section}/{$controller}/{param{$id}:int}/posts/{post{$id}:int}";
            $router->get($path3);
            $registered++;

            if ($registered >= $count) {
                break;
            }

            // Pattern 4: slug parametric e.g. /blog/hello-world
            $path4 = "/blog/{$slug}";
            $router->get($path4);
            $registered++;

            if ($registered >= $count) {
                break;
            }

            // Pattern 5: wildcard e.g. /assets/css/{file:*}
            $path5 = "/assets/" . strtolower($controller) . "/{file{$id}:*}";
            $router->get($path5);
            $registered++;

            $i++;
        }
    }
}