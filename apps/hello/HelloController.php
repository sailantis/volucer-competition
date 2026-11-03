<?php

declare(strict_types=1);

namespace App\Hello;

use Azera\Core\Controller;
use Azera\Http\Response;

/**
 * The one route the hello arms serve.
 *
 * `GET /` answers `{"hello":"world"}` as `application/json`, which is the body and
 * the content type the Fastify arm answers with. Nothing here may differ between the
 * arms: this file is shared by every PHP arm, and the Node arm is written to produce
 * byte-identical output. A benchmark whose two sides return different bytes measures
 * the difference between their bodies.
 */
final class HelloController extends Controller
{
    public function indexAction(): Response
    {
        return Response::json(['hello' => 'world']);
    }
}
