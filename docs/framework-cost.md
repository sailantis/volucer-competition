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

Better still: **compiling the table at deploy time takes that 121 µs to ~1 µs**,
lifting `/echo` from 24,657 to 38,706 rps. [That is the fix, and it is
measured](#a-compiled-route-table-does-fix-it--my-first-answer-was-wrong).

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

### A compiled route table DOES fix it — my first answer was wrong

The first version of this document said a route cache would not help, on the
evidence that `require`ing a `var_export`ed table cost 436 µs against 108 µs to
rebuild from source. **That was wrong, and the way it was wrong is worth recording
because it is an easy trap.**

The probe wrote the cache file and `require`d it in the same PHP process. OPcache
declines to cache a file the same process just wrote, and it does so *silently* —
`require` still succeeds, it just recompiles. So the "cached" arm was recompiling
61 KB of PHP every iteration and was measuring `zend_compile`, not file loading.
`opcache_is_script_cached()` reported `NOT cached` and the probe printed that fact
without treating it as fatal.

Measured properly — generated in one process, loaded in another, cache state
asserted before timing:

| encoding | size | load | + hydrate into a Router |
|---|---:|---:|---:|
| `var_export` + `require` | 61.1 KB | **0.1 µs** | **3.1 µs** |
| `unserialize()` | 24.9 KB | 67.5 µs | 163.1 µs |
| `igbinary_unserialize()` | 8.7 KB | 38.9 µs | 100.1 µs |
| `json_decode()` | 13.2 KB | 136.7 µs | — |
| rebuild from source | — | — | 148.4 µs |
| build-direct (no `add()`) | — | — | 3.1 µs |

`var_export` wins **because** it is PHP source: OPcache compiles it once and the
file then costs 0.1 µs to include, where `unserialize` has to rebuild 120 nested
arrays in C on every request. Loading a cached PHP file is essentially free in a
way no data format can match — which is the whole reason Symfony and Laravel
generate PHP rather than serialized blobs.

Boot goes from **110 µs to 10.6 µs**, all 9 probe routes still answer identically,
and match latency is unchanged at 0.18 µs.

**On the wire**, same server, same concurrency, only the cache differing:

| nginx + php-fpm, `/echo`, c=96 | rps | µs CPU per request |
|---|---:|---:|
| rebuild from source | 24,657 | 396.9 |
| load compiled table | **38,706** | **220.9** |
| bare (no framework) | 80,945 | 71.5 |

**+57% throughput, and framework cost falls from 325 µs to 150 µs.** That is the
single largest improvement available anywhere in this investigation, and it is a
deploy-time change, not a runtime one.

It also reframes the published comparison. Volucer's cold arms
(`volucer-fastcgi` 21,848, `volucer-external` 25,545, `volucer-prefork` 27,529) are
currently *below* fpm-with-a-route-cache, because none of them has one. They share
the same `Bootstrap`, so they would benefit identically — but as measured today,
fpm's cold path is competing with one hand behind its back and so is everything
else.

## How a route cache handles closures

Short answer: **it never has to, and the one place closures appear is code rather
than data.** Both halves of that are measured, not assumed.

### A closure cannot be a route handler

`Router::add()` is typed `string|array|null $handler`, and `get()`/`post()` pass
straight through to it. A closure is rejected by the type system before any caching
question arises:

```
TypeError: Azera\Core\Router::get(): Argument #2 ($handler) must be of type
array|string|null, Closure given
```

So there is nothing to persist and nothing to special-case. A grep across all four
repositories (`sailantis-homepage`, `azera-competition`, `volucer-competition`,
`azera-framework`) finds **zero** closure handlers — which is what a signature that
forbids them should produce.

### The closures that *do* exist are validators, and they are code

`Router::$types` is initialised in the constructor with five closures:

```
int, alpha, alnum, uuid, *
```

and `Router::type($name, callable $validator)` lets an application add more. This is
the **only** property in the router's state that blocks a naive `var_export` —
`probe-route-serialisation.php` checks all 12:

| property | types | exportable |
|---|---|---|
| `static`, `groups`, `namedRoutes`, `unsortedBuckets`, `autoOptions`, … | arrays/scalars | yes |
| **`types`** | **array(5) → Closure** | **no** |

`var_export` would emit `\Closure::__set_state(array())`, which fatals on include.
So the cache **omits `types` entirely and lets the constructor rebuild it** — because
`new Router()` runs the constructor, and the validators are code, not state.

That is verified, not argued: a cached table with `$types` omitted still answers
`/items/7` (whose `{id:int}` needs the `int` validator) and still returns **404 for
`/items/abc`** — the validator came back with the constructor.

### Custom validators are the application's job, and forget them loudly

An app that registers `Router::type('slug', fn(...))` owns that closure. The cache
records *which* names were custom (the generated file has a
`// Custom parameter types the application must re-register:` line) and the app has
to re-register them. Measured if you forget:

```
no re-register  /blog/ok-slug      THROWS Unknown validator: slug
no re-register  /blog/BAD-SLUG     THROWS Unknown validator: slug
re-registered   /blog/ok-slug      MATCH
re-registered   /blog/BAD-SLUG     no match
```

It **throws** rather than silently matching everything. That matters: a cache that
quietly dropped a validation constraint would be a security bug, and this design
would rather 500.

### The design, then, is fifteen lines of filtering

`scripts/route-cache.php` is the whole thing:

- persist every instance property **except** `types` (code) and `resolvedOverrides`
  (a per-handler memo worth 0.41 µs once, so persisting it buys nothing and risks a
  stale triple after a deploy);
- **refuse to write** if any persisted value still contains a closure or object,
  naming the property — a cache that silently drops state is worse than one that
  will not build;
- emit the route count, the PHP version, and the custom-type list in a header so a
  stale file is diagnosable from its first six lines;
- write atomically (`rename`), because a half-written route file picked up mid-deploy
  is a fatal error;
- ship `--verify`, which rebuilds the table and compares it to the file property by
  property, so CI can fail on a stale cache rather than serve one.

The one thing it deliberately does *not* do is guess. If a future Azera release adds
a property holding an object, the write fails and names it. That is the intended
behaviour.

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

And it is not an artefact of `/echo` being a bootstrap benchmark. On the realistic
page the same ranking holds, with the same ~4× spread:

| arm, `/items`, c=96 | rps | µs of CPU per request |
|---|---:|---:|
| volucer-attach w=32 | 41,521 | **289.0** |
| volucer-tcp w=32 | 32,728 | 366.7 |
| RoadRunner 3.0.1 w=32 | 26,188 | 458.2 |
| FrankenPHP w=8 | 22,377 | 536.3 |
| *volucer-prefork w=1 ch=32* | *10,082* | *1,190.3* |
| *volucer-external w=32* | *9,915* | *1,210.3* |
| nginx+php-fpm w=32 | 9,867 | **1,216.1** |

289 µs against 1,216 µs. The absolute gap is four times larger than on `/echo`
(927 µs vs 320 µs) because each of the four cold arms pays the whole bootstrap
*plus* the connection, the ORM and the template, while the warm arm pays only the
ORM and the template.

So the headline should not be "Volucer is 4× faster at serving a page". It is:

> For an application whose bootstrap costs 100–200 µs, a cold SAPI pays it on every
> request. Volucer pays it once, which is why its framed `/echo` lands *below* bare
> php-fpm rather than at 4× framed php-fpm — and why the same 4× holds on a
> realistic page where the boot is a minority of the work.

### And the caveat that keeps this honest

The filler routes are **38% of the framework cost on `/echo` but only ~12% on
`/items`**, because a realistic page has 700 µs of ORM, SQLite and template work
that `/echo` does not.

Two independent runs of the phase probe, both with 100 filler routes:

| | `/echo` | `/items` |
|---|---:|---:|
| bootstrap (incl. fillers) | 171 µs | 213 µs |
| of which filler routes | ~121 µs | ~107 µs |
| dispatch | 55 µs | 698 µs |
| autoload + entry point | 21 µs | 21 µs |
| **total, CONC=1 wall clock** | **247 µs** | **985 µs** |
| **filler share of the request** | **49%** | **11%** |

The bootstrap column disagreeing by 42 µs between two runs of the same code is
worth saying rather than smoothing over: these are single-child, CONC=1 wall-clock
measurements, and the two runs differ by 25% on that phase. The filler *slope* is
the robust number — it was measured four ways (route-count sweep in CLI, wire CPU
with and without fillers, and the phase probe both ways) and landed at 107–128 µs
every time.

`/echo` is therefore a bootstrap benchmark and `/items` is an application
benchmark, and the two tell different stories. Removing the filler routes is worth
31% of throughput on `/echo` (24,656 → 32,351 rps, measured on the wire) and about
12% on `/items` (from the phase totals, 985 → 878 µs).

**Both are honest.** `/echo` answers "what does the framework cost", `/items`
answers "what does this page cost", and the reason to publish both is that the
first number is not a prediction of the second. Quoting the 4× from `/echo` as
though it described page serving would be wrong; so would quoting `/items` alone
and concluding that boot does not matter.

An application with 12 routes and no container would show a much smaller gap
entirely, and one that preloads its container would show none. **The measured
quantity is cold-start cost**, and the matrix is a fair measurement of it precisely
because all six frameworks register the same 100 filler routes:

- CakePHP, CodeIgniter, Laravel, Symfony and Spiral each have an explicit
  "route-table size parity" block in `azera-competition`.
- The filler routes are a shared, deliberate input — no arm is penalised alone.
- What differs is what each framework *offers* for the cold path. Laravel and
  Symfony both ship a route cache a deployment is expected to warm; the harness
  does not warm it, so those arms also rebuild. Azera has no route cache at all.

### The three things this application could stop doing per request

In cost order, all measured:

1. **Rebuild the route table** — 121 µs of the cold boot. Fixed by a compiled
   table: 121 µs → ~1 µs, worth +57% throughput on the cold path. This is a
   framework feature (a `route:cache` deploy step), not an app change.
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
| `probe-route-encodings.php` | **the fix**: encoded table vs rebuild, two processes |
| `probe-route-serialisation.php` | what in router state blocks a cache (only `types`) |
| `route-cache.php` | the deploy step: `--write` / `--verify` |
| `probe-route-cache.php` | superseded — measured compilation, not loading |
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
