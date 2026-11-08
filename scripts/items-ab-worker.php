<?php

declare(strict_types=1);

/**
 * A/B worker for the /items application cost.
 *
 * Serves the *same* page from the *same* route through volucer, varying only the
 * one decision named by the tag, so a difference between two runs is that
 * decision and nothing else.
 *
 *   php scripts/items-ab-worker.php <tag>
 *
 * Tags:
 *   base      shipped: per-render freshness check, no policy-digest memo
 *   reval     the revalidate window and the memoized digest (setRevalidateFreq)
 *   objects   Paginator::objects() — rows as stdClass, no ORM identity map
 *   select    the API's read without the identity map (select()->toArray())
 *   untyped   the same table via a model with no PHP type declarations
 */

require __DIR__ . '/../vendor/autoload.php';
require __DIR__ . '/../apps/azera/Bootstrap.php';

use Azera\AppContext;
use Azera\Http\Request;

/** Untyped twin of the benchmark's Item: same table, same columns, no types. */
final class ItemsAbUntyped extends \Azera\Orm\Model
{
    public $id;
    public $title;
    public $created_at;

    public function source(): string
    {
        return 'items';
    }
}

final class ItemsAbApp
{
    private ?AppContext $ctx = null;
    private ?\BenchApp $real = null;

    public function __construct(private readonly string $dbPath, private readonly string $tag)
    {
    }

    public function bootstrap(): void
    {
        if ($this->tag === 'real') {
            // The unmodified application, dispatched exactly as worker.php does.
            // This is the control that separates "my rewrite is slow" from
            // "this harness is slow".
            $this->real = new \BenchApp($this->dbPath);
            $this->real->bootstrap();
            $this->ctx = AppContext::instance();
            return;
        }

        $this->ctx = App\Azera\Bootstrap::boot($this->dbPath);

        if ($this->tag === 'reval' || $this->tag === 'best') {
            $view = $this->ctx->view();
            if (!method_exists($view, 'setRevalidateFreq')) {
                fwrite(STDERR, "{$this->tag}: this clarity-engine has no setRevalidateFreq()\n");
                exit(1);
            }
            $view->setRevalidateFreq(60);
        }
    }

    public function cleanup(): void
    {
        if ($this->real !== null) {
            $this->real->cleanup();
            return;
        }
        $this->ctx?->clearRequestScope();
    }

    public function dispatch(string $method, string $uri): array
    {
        if ($this->real !== null) {
            $r = $this->real->dispatch($method, $uri);
            return [$r->status, $r->body];
        }

        $ctx = $this->ctx;
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
            return [404, '<h1>404 Not Found</h1>'];
        }

        // The API route, reproduced exactly (ApiController::indexAction):
        //   $items = Item::query()->orderBy('id','asc')->limit(20)->select();
        //   return Response::json($items->toArray());
        // The shipped version hydrates through entities() instead; both produce
        // byte-identical JSON (scripts/api-equivalence.php proves it), so this
        // isolates the identity map and nothing else.
        if ($this->tag === 'select' || $this->tag === 'api-base') {
            $query = App\Azera\Models\Item::query()->orderBy('id', 'asc')->limit(20);

            // entities() returns entities and select() returns a ResultSet, so each
            // is flattened the way the controller does it — toArray() for the
            // ResultSet, and json_encode's own view of each entity via
            // jsonSerialize-compatible extraction for the entities. Both then go
            // through the SAME json_encode call on the SAME array shape.
            if ($this->tag === 'select') {
                $rows = $query->select()->toArray();
            } else {
                $rows = [];
                foreach ($query->entities() as $e) {
                    $rows[] = ['id' => $e->id, 'title' => $e->title, 'created_at' => $e->created_at];
                }
            }

            return [200, json_encode($rows)];
        }

        // The HTML route, reproduced from BenchController::listAction(). Not through
        // the dispatcher: the middleware chain is identical for every variant and is
        // not what is being compared.
        $page    = (int) $request->query('page', 1);
        $pageSize = 20;

        if ($this->tag === 'objects' || $this->tag === 'best') {
            $paginator = App\Azera\Models\Item::query()->paginate($page, $pageSize);
            $items = $paginator->objects();
        } elseif ($this->tag === 'untyped') {
            $paginator = ItemsAbUntyped::query()->paginate($page, $pageSize);
            $items = $paginator->entities();
        } else {
            $paginator = App\Azera\Models\Item::query()->paginate($page, $pageSize);
            $items = $paginator->entities();
        }

        $html = $ctx->view()->render('items.list', [
            'baseUrl'    => '/items',
            'items'      => $items,
            'pagination' => [
                'currentPage'  => $paginator->currentPage(),
                'lastPage'     => $paginator->lastPage(),
                'previousPage' => $paginator->previousPage(),
                'nextPage'     => $paginator->nextPage(),
                'totalItems'   => $paginator->totalItems(),
                'firstItem'    => $paginator->firstItem(),
                'lastItem'     => $paginator->lastItem(),
                'hasPrevious'  => $paginator->hasPrevious(),
                'hasNext'      => $paginator->hasNext(),
            ],
        ]);

        return [200, $html];
    }
}

require __DIR__ . '/../vendor/autoload.php';
require __DIR__ . '/../BenchApp.php';

$tag = $argv[1] ?? 'base';
$app = new ItemsAbApp(__DIR__ . '/../data/bench.sqlite', $tag);
$app->bootstrap();

$worker = Volucer\Worker::connect();
$worker->run(static function (Volucer\Request $r) use ($app): Volucer\Response {
    [$status, $body] = $app->dispatch($r->method, $r->uri);
    $app->cleanup();
    return new Volucer\Response($status, [['Content-Type', 'text/html; charset=utf-8']], $body);
});
