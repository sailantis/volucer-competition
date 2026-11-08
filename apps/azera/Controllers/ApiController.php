<?php
/**
 * Azera REST API controller.
 *
 * Implements a minimal JSON REST API over the shared `items` table.
 * These endpoints are the "REST API" competition category — every
 * framework implements the same routes so the JSON serialization +
 * routing + controller overhead is compared apples-to-apples.
 *
 * Endpoints:
 *   GET    /api/items       — list items (JSON array)
 *   GET    /api/items/{id}  — fetch a single item (JSON object)
 *   POST   /api/items       — create an item (JSON with new id)
 */

namespace App\Azera\Controllers;

use App\Azera\Models\Item;
use Azera\Core\Controller;
use Azera\Db\Query;
use Azera\Http\Response;

class ApiController extends Controller
{
    /**
     * GET /api/items — list items as a JSON array.
     */
    public function indexAction(): Response
    {
        $items = Item::query()->orderBy('id', 'asc')->limit(20)->select();

        return Response::json($items->toArray());
    }

    /**
     * GET /api/items-fast — GET /api/items with the model replaced by the literal table.
     *
     * The JSON counterpart of `/items-fast`. It is a much smaller control than that
     * one, because `indexAction()` already calls `select()`, whose `toArray()` is
     * `ResultSet::fetchAllAssoc()` — i.e. `PDO::FETCH_ASSOC`. So `/api/items` hands the
     * serializer **associative arrays**, never entities: no instantiation, no
     * identity map, no snapshot. The expensive shape is already absent.
     *
     * What `indexAction()` still does is resolve the model: the model-backed builder
     * asks `Item::source()` for the table and builds its column list from metadata,
     * where `Query::raw()->table('items')` names the table literally. That is the only
     * difference between the two routes, and it is small — measured at ~1.7 us of a
     * ~24 us request (`scripts/api-fast-compare.php`), against the ~48 us that
     * dropping hydration is worth on the HTML route.
     *
     * Verified byte-identical JSON (`scripts/api-fast-compare.php`), so the two routes
     * differ only in how they name the table.
     *
     * For context on why the gap is so much smaller here: measured per row, an assoc
     * array costs 1.21 us, a stdClass 1.39 us, and a hydrated entity 3.84 us
     * (`scripts/data-shapes.php`). `/api/items` picked the cheapest shape on its own.
     */
    public function indexFastAction(): Response
    {
        $items = Query::raw()->table('items')->orderBy('id', 'asc')->limit(20)->select();

        return Response::json($items->toArray());
    }

    /**
     * GET /api/items/{id} — fetch a single item as a JSON object.
     */
    public function showAction(int $id): Response
    {
        $item = Item::find($id);
        if ($item === null) {
            return Response::json(['error' => 'Not Found'], 404);
        }
        return Response::json($this->serialize($item));
    }

    /**
     * POST /api/items — create an item and return its id as JSON.
     */
    public function createAction(): Response
    {
        $item = Item::upsert([
            'id'         => 999998,
            'title'      => 'API Item ' . date('Y-m-d H:i:s'),
            'created_at' => date('Y-m-d H:i:s'),
        ]);

        return Response::json(['id' => $item->id]);
    }

    /**
     * Serialize a model to a plain array for JSON output.
     *
     * The Item model exposes public properties (id, title, created_at);
     * we read them directly to avoid coupling the API to any internal
     * attribute storage.
     */
    private function serialize(Item $item): array
    {
        return [
            'id'         => $item->id,
            'title'      => $item->title,
            'created_at' => $item->created_at,
        ];
    }
}