# What framework boot costs, and why

Measured on the benchmark VM (12 cores, PHP 8.5.11, OPcache + JIT on) while
answering one question: **if php-fpm is this fast without a framework, what is
Volucer for?**

The premise came from `results/matrix-0.4.1-reval60/bare-echo.tsv`. Removing the
framework from `/echo` lifted php-fpm from 27,885 to 104,261 rps. That is a ratio,
not a cost. On 12 fixed cores a request rate *is* a CPU-time statement, so the
same data says 427 µs of CPU per framed request against 72 µs bare — **355 µs of
framework**, about 5× what a warm worker spends on the same dispatch.

Everything below is measured by the probes in `scripts/`, on this host, with the
same OPcache and JIT configuration the matrix uses.

```bash
bash scripts/probe-framework-cost.sh        # the whole investigation, in order
```

## The short answer

Boot is not expensive because the application is large or badly written. It is
expensive because **every cold request rebuilds the whole route table from
source**, and the table is deliberately 100 routes larger than the benchmark
needs. A route costs a flat ~0.6–0.9 µs to register, whatever the table size, so
120 routes is ~120 µs — per request, forever, on every SAPI that resets between
requests.

| what | µs of CPU per framed `/echo` |
|---|---:|
| bare (server + nginx + FastCGI only) | 72 |
| + autoload, entry point, BenchApp | 8 |
| + **bootstrap (route table, container, services)** | **171** |
| + dispatch (router match, middleware, controller) | 55 |
| + response write | 2 |
| **framed total** | **393** |

Of the 171 µs bootstrap, **121 µs is the 100 filler routes** — 70% of the boot,
31% of everything above bare. Removing them lifts `/echo` from 24,656 to 32,351
rps and drops framework cost from 322 µs to 194 µs.

The answer to "so what is Volucer for?", which is the question that started this, is
in [the last section](#what-this-means-for-the-benchmark--and-what-volucer-is-for):
**framed Volucer costs 108.8 µs of CPU per request and bare php-fpm costs 114.6.**
The framework is nearly free on a warm worker and costs three quarters of the
budget on a cold one. Nothing below changes that ranking.

## Finding 1 — the route table is rebuilt per cold request

Registration is ~0.6 µs/route marginal, ~1.0 µs/route from an empty router:

| routes registered | median boot | marginal per route |
|---:|---:|---:|
| 0 | 28.2 µs | — |
| 25 | 44.8 µs | 0.66 µs |
| 50 | 69.2 µs | 0.98 µs |
| 100 | 103.7 µs | 0.69 µs |
| 200 | 184.5 µs | 0.81 µs |
| 400 | 356.9 µs | 0.86 µs |

The slope is flat, so this is per-route work, not a bad data structure. The router
already defers its specificity sort to the first match (`7.4 µs` once for a
200-route bucket, then `1.20 µs` per match) and that deferral is doing its job:
match cost is **0.18 µs at 0, 100 and 400 filler routes alike**.

The cost is `Router::add()`: `parsePattern()` (0.26–0.69 µs) plus the hash insert
and `calculateSpecificity()` walk. Nothing here is pathological; it is simply paid
~120 times per request instead of once per deploy.

### A compiled route table does not fix it

The obvious fix — Symfony/Laravel style `route:cache`, `var_export` the compiled
table to a PHP file and `require` it — was measured and **made things 4× worse**:

| | median |
|---|---:|
| rebuild from source | 107.9 µs |
| `require` the compiled table + hydrate | 514.0 µs |
| `require` alone, no hydrate | 435.7 µs |

The compiled table is 61 KB of PHP. Parsing 61 KB is more expensive than calling
`add()` 119 times. Symfony's cache wins because its route table is also the
*compiled matcher* (a regex → handler map it can answer in one `preg_match`),
whereas `var_export`ing Azera's token arrays saves the construction but not the
representation. A real fix would have to serialize the *matcher*, not the input to
it.

Equivalence was verified: all 8 probe routes match identically between the source
table and the compiled one, so this is a performance result, not a correctness
one.

## Finding 2 — `Bootstrap::$wired` is dead code on every SAPI that reuses a process

`apps/azera/Bootstrap.php` memoises the wired container in `private static array
$wired`, with a comment saying it exists so "a worker-mode re-bootstrap (same
process, same database) can skip straight to the request loop", and that
re-registering ~120 routes on every warm recycle "cost ~0.38 ms of pure rebuild".

Two things are wrong with that.

**The memo does not survive a request in php-fpm.** With OPcache on, the class
entry lives in shared memory, so PHP restores mutable statics to their
compile-time defaults at the start of every request. Measured with one fpm child
and five sequential requests (`scripts/probe-static.sh`): same pid throughout, and
the counter reads `1` every time.

```
pid      counter   store    mem
1801568  1         1        421928
1801568  1         1        418704     <- same child, same static, reset
1801568  1         1        418704
```

**But it does work in a long-lived CLI process**, which is the Volucer worker
model: first boot 6,924 µs (cold autoload), then 0.45–2.5 µs per re-bootstrap.

So the memo is not useless — it is *SAPI-dependent*, and the comment describes
only the case where it works. In fpm `boot()` is 171 µs on every single request
because the memo is empty by the time it is read. That is why the phase probe sees
cold-boot money on a warm child.

This also corrects the figure in that comment. "~0.38 ms of pure rebuild" was
measured under the CLI, where the memo hit; the rebuild the comment is trying to
avoid is real, but it is ~120 µs, and on fpm the memo never avoids it.

## Finding 3 — a cold `/items` costs 4× a warm one

| | µs |
|---|---:|
| warm dispatch (reused container, reused connection) | 91.2 |
| cold dispatch (fresh container per request) | 363.4 |
| boot, measured separately | 365.1 |

Inside a cold dispatch: connect **174.0**, paginate 19.0, render 53.2 → sum 246.1,
leaving 117 µs unaccounted (lazy autoload plus container resolution on the path).

The connect number is the surprise, and it is mostly one PRAGMA:

| operation | µs |
|---|---:|
| `new PDO` | 21.6 |
| + `PRAGMA busy_timeout` | 2.4 |
| + `PRAGMA synchronous = NORMAL` | 61.5 |
| + `PRAGMA journal_mode = WAL` | 61.6 |
| whole wiring as `Bootstrap` does it | 112.3 |
| the same without `journal_mode = WAL` | 24.4 |

`journal_mode = WAL` is idempotent — the mode is stored in the file header, so from
the second connection onward it is re-asserting a property that cannot have
changed. Measured on an already-warm connection where the first-statement cost has
been paid, the statement on its own still costs **59.0 µs**, against 1.5 µs for
`SELECT 1` on the same connection. Dropping it takes the cold connect from 112 µs
to 24 µs.

(One earlier reading was wrong and is worth recording: `PRAGMA synchronous =
NORMAL` also showed ~61 µs, which made it look as though any write-ish PRAGMA cost
the same. On a warm connection it costs nothing, so the 61 µs there was the *first
statement on a fresh connection* — `SELECT 1` costs 23 µs that way too. The WAL
statement is the only one that is expensive both as a first statement and on a
warm connection, which is what makes it genuinely worth removing. See
`scripts/probe-db-first-statement.php`.)

Both are only paid by the cold arms; a warm worker connects once.

## What this means for the benchmark — and what Volucer is for

A request rate on 12 fixed cores is a CPU-time statement, so the matrix and the
bare diagnostic can be put on one axis (`12e6 / rps`):

| arm, `/echo`, c=96, opcache on | rps | µs of CPU per request |
|---|---:|---:|
| volucer-attach w=32 | 110,321 | **108.8** |
| *volucer-attach, bare* | *121,175* | *99.0* |
| *nginx+php-fpm, bare* | *104,698* | *114.6* |
| volucer-tcp w=32 | 87,927 | 136.5 |
| RoadRunner 3.0.1 w=32 | 72,718 | 165.0 |
| FrankenPHP w=8 | 71,443 | 168.0 |
| nginx+php-fpm w=32 | 27,946 | **429.4** |

**Framed Volucer is cheaper per request than bare php-fpm.** 108.8 µs against
114.6 µs. The framework costs Volucer ~10 µs of CPU amortised over a worker's life,
and it costs php-fpm ~315 µs on *every* request — 32× more — because fpm throws the
boot away each time.

That is the answer to "if fpm is so fast bare, what is Volucer for?":

- **fpm's 104,698 bare rps is not a framework number.** It is what nginx + FastCGI
  costs when PHP does nothing. Put the application back and fpm lands at 27,946 —
  a 3.7× drop. Volucer's framed number (110,321) is 5.4% *above* fpm's bare
  number, so for this application the framework is essentially free on Volucer and
  costs three quarters of the budget on fpm.
- **The gap was never the transport.** fpm bare and volucer-attach bare are within
  15% of each other (114.6 vs 99.0 µs); both are dominated by nginx/FastCGI/PHP
  bookkeeping. The 4× in the framed comparison comes almost entirely from paying
  bootstrap 27,946 times a second instead of once.

So the headline should not be "Volucer is 4× faster at serving a page". It is:

> For an application whose bootstrap costs ~300 µs, a cold SAPI spends 73% of its
> CPU rebuilding what it is about to discard. Volucer removes that term, which is
> why it lands where bare php-fpm does rather than where framed php-fpm does.

### And the caveat that keeps this honest

This application boots in the mid-hundreds of microseconds because it registers 120
routes, wires a container, and opens a SQLite connection — for every request on the
cold arms. An application with 12 routes and no container would show a much smaller
gap, and one that preloads its container would show none. **The measured quantity
is cold-start cost, and the matrix is a fair measurement of it** precisely because
all six frameworks register the same 100 filler routes:

- CakePHP, CodeIgniter, Laravel, Symfony and Spiral each have an explicit
  "route-table size parity" block in `azera-competition`.
- The filler routes are a shared, deliberate input — no arm is penalised alone.
- What differs is what each framework *offers* for the cold path. Laravel and
  Symfony both ship a route cache a deployment is expected to warm; the harness
  does not warm it, so those arms also rebuild. Azera has no route cache at all.

### The three things this application could stop doing per request

In cost order, all measured:

1. **Rebuild the route table** — 121 µs of the cold boot. A `var_export` cache does
   *not* fix it (measured 4× worse); serialising the compiled matcher might.
2. **Re-assert `journal_mode = WAL`** — 61 µs, and idempotent: the mode is stored in
   the file header, so the second connection onwards is re-setting a property that
   cannot have changed. Dropping it takes the cold connect from 112 µs to 24 µs.
3. **Rebuild the container and its 12 feature routes** — 40 µs together.

None of these change the ranking. They change how large the gap is, and #2 is the
only one that is free to fix.

## Reproducing

| probe | question |
|---|---|
| `probe-boot-cost.php` | total boot cost, phase split, filler-route scaling |
| `probe-route-cost.php` | per-route registration cost, deferred sort, match scaling |
| `probe-route-cache.php` | would a compiled table help? (no) |
| `probe-boot-profile.sh` | framework cost on the wire, as CPU per request |
| `probe-phases.sh` | per-phase attribution inside a real fpm child |
| `probe-static.sh` | does a class static survive between requests? (no) |
| `probe-cold-dispatch.php` | warm vs cold dispatch, and where it goes |
| `probe-db-connect.php` | cost of the connection, PRAGMA by PRAGMA |
| `probe-db-first-statement.php` | is that PRAGMA, or just the first statement? |
| `probe-framework-cost.sh` | runs all of the above in order |

`public/probe-phases.php` and `public/probe-static.php` are the front controllers
the last probes serve. They exist so the measurement happens in the real SAPI;
`public/index.php` cannot honour `BENCH_FILLERS`.

Two settings are easy to get wrong, and each invalidates a comparison silently:

- **JIT comes from `PHP_INI_SCAN_DIR=/home/competition/jit-on`**, not from `-d`.
  `opcache.jit` is read by the extension at startup, so a later `php_admin_value`
  in the pool is too late to compile anything.
- **fpm needs `clear_env = no`** plus an explicit `env[...]` per variable, or
  `BENCH_BARE` / `BENCH_FILLERS` never reach the worker and the run measures the
  wrong mode while every row claims otherwise.
