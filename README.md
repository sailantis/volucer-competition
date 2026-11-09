# volucer-competition

Eight ways to serve **one page on one machine**, measured identically.

The page is `GET /items`: one SQLite query through the azera ORM, rendered by a
ClarityEngine template, through a controller with middleware. It is the cheapest
route that still boots the framework container — and that is the point. On a handler
that returns a few dozen bytes every deployment model lands within ~10% of every
other, because a trivial request has nothing to keep warm. The gap appears in
proportion to what the application has to boot.

```bash
composer install
php seed.php
bash scripts/bench.sh                     # five arms, one at a time
bash scripts/run-full-matrix.sh           # the published grid
python3 scripts/bench-report.py           # the report and its charts
```

This repository measures; it does not argue. Where a number appears in prose it is a
median of interleaved rounds on one host, and the rows behind it are committed beside
it. **Absolute throughput is a property of the host; every conclusion here is a
ratio** — between two arms in the same round, or between two configurations of one
arm. Ratios survive a host change; absolute figures do not.

## The arms

| arm | server | model | transport |
|---|---|---|---|
| `volucer-attach` | volucer `attach` | warm — booted once | unix relay + fork |
| `volucer-worker` | volucer `worker` | warm — booted once | pipe |
| `volucer-unix` | volucer `worker` | warm — booted once | unix socket |
| `volucer-fastcgi` | volucer `spawn_cgi` | cold — booted per request | unix, 1 process per slot |
| `volucer-prefork` | volucer `spawn_cgi` | cold — booted per request | unix, `children` per slot |
| `volucer-external` | volucer `external` | no PHP of its own | a real php-fpm pool |
| `rr` | RoadRunner `worker` | warm — booted once | pipe |
| `frankenphp` | FrankenPHP | warm — **PHP embedded** | in-process |
| `fpm` | nginx + php-fpm | cold — booted per request | unix socket |

Eight arms is not eight questions. Each pair isolates one variable, and only a pair
answers anything:

- **`volucer-worker` vs `volucer-unix`** — the transport. Same server, same model,
  same SAPI. A difference here is the transport and nothing else.
- **`volucer-attach` vs `volucer-worker`** — the fork shape. One booted master with N
  inherited children, against N spawned processes that each pay their own boot and
  their own OPcache.
- **`volucer-fastcgi` vs `volucer-prefork`** — the same fork question on the cold path,
  and it is where the answer is largest: `children` buys concurrency out of one slot,
  so 16 PHP processes cost ~4.5x less memory forked than as 16 separate slots.
- **warm vs cold** — what the framework boot costs when it is paid per request instead
  of once.
- **`fpm` vs `volucer-fastcgi`** — the server implementation at the same cold model,
  same SAPI, same transport.
- **`rr` vs `volucer-worker`** — the server implementation at the same warm model.
- **`frankenphp` vs the rest** — embedding against spawning. It is the only server here
  that runs PHP inside its own process. It is the alternative volucer rejects on
  principle, so it is the number that principle is traded against.

**One confound is stated rather than hidden:** the popular warm arm is both warm *and*
relayed, so warm-vs-cold mixes the model with the transport. That mixed comparison is
still the commercially interesting one — it is the two deployment models as they are
actually deployed — but a claim about the transport alone has to come from the pair
that holds the model equal.

## The result

Each arm at the configuration it measured **best**, as a factor against the fastest arm
in that column. This is the shape a benchmark page reports, and it is the honest one:
the programs do not peak together, so holding everything at one setting would show a
server at a configuration it measured worse than it can do.

The published run, `results/run85-scale-items-2` — eight arms, 16/32/64 serving PHP
processes, c=8/16/32/64, interleaved rounds, PHP 8.5.11 for every arm, 12 cores:

| arm | `/items` | best config |
|---|---:|---|
| `volucer-attach` | **1.00x** | w=32, c=64 |
| `volucer-worker` | 1.07x | w=16, c=64 |
| `volucer-unix` | 1.08x | w=16, c=64 |
| `rr` | 1.24x | w=32, c=64 |
| `frankenphp` | 1.61x | w=16, c=16 |
| `fpm` | 2.74x | w=64, c=64 |
| `volucer-prefork` | 2.93x | w=1, c=64 |
| `volucer-fastcgi` | 3.51x | w=32, c=64 |

And the same grid on the landing page, `results/run85-scale-root`:

| arm | `/` | best config |
|---|---:|---|
| `volucer-attach` | **1.00x** | w=16, c=64 |
| `volucer-worker` | 1.03x | w=16, c=64 |
| `volucer-unix` | 1.11x | w=16, c=64 |
| `rr` | 1.19x | w=32, c=64 |
| `frankenphp` | 2.11x | w=64, c=8 |
| `fpm` | 2.30x | w=64, c=64 |
| `volucer-prefork` | 2.67x | w=1, c=64 |
| `volucer-fastcgi` | 3.23x | w=16, c=64 |

The multi-endpoint run, `results/matrix-jit-5r` — five rounds, JIT on, c=32/64/96,
which is a different configuration and therefore **not comparable in absolute terms**
with the two tables above (every arm is about 1.6x faster there). The ratios are what
it is for:

| arm | `/echo` | `/` | `/api/items` | `/items-fast` |
|---|---:|---:|---:|---:|
| `volucer-attach` | **1.00x** | **1.00x** | **1.00x** | **1.00x** |
| `volucer-tcp` | 1.26x | 1.30x | 1.34x | 1.29x |
| `rr` | 1.48x | 1.70x | 1.58x | 1.59x |
| `frankenphp` | 1.50x | 3.12x | **1.15x** | 2.16x |
| `fpm` | 2.65x | 3.18x | 4.86x | 4.16x |
| `volucer-external` | 2.94x | 3.37x | 4.92x | 4.21x |
| `volucer-prefork` | 3.25x | 3.67x | 5.65x | 4.78x |
| `volucer-fastcgi` | 3.60x | 4.00x | 5.67x | 4.95x |

What those ratios say, and what they do not:

- **The cold/cold gap widens with the work the request does.** Against `fpm`,
  `attach` is 2.65x on a handler that returns a constant and 4.95x on the ORM page.
  What a cold SAPI pays is the framework boot, so the cost scales with the framework,
  not with the response size.
- **The warm arms cluster within ~8% of each other**, and the transport is not what
  separates them: `worker` (pipe) and `unix` (socket) land on top of each other on
  `/items`. A transport claim has to come from that pair, not from warm-vs-cold.
- **`frankenphp` inverts.** It is the second-fastest arm on `/api/items` at 1.15x and
  nearly the slowest on `/` at 3.12x. It is also non-monotonic in workers: a single OS
  process at every setting whose `num` is worker *threads*, so above 12 it
  oversubscribes this host, and its best config is w=16/c=16 on one endpoint and
  w=64/c=8 on another. A single "FrankenPHP factor" would be a fiction.
- **`volucer-external` sits with `fpm`, not with the warm arms**, which is the point of
  it: it owns no PHP, so it pays the cold boot too. It is a decomposition — what the
  front-end costs when PHP is held constant — not a candidate deployment.

The published page — with the absolute numbers, the round-paired ranges and the memory
section — is `12-BENCHMARKS.md` in the volucer repository, generated from those exact
rows by `scripts/bench-report.py`. It is the only place the figures live: a table
copied into this file is a second copy, and the second copy is the one that goes stale.

**Why a ratio and not a rate.** `ddaada7` read 1-3% below `841c963` in every cell, and
the only change between them was four micro-optimizations whose own measurements
claimed no throughput. Re-derived from the two committed files: every arm fell *except*
the one the commits touched. Read as a ratio against a control arm — which cancels
whatever the host did underneath both — those four commits *improved* volucer's lead by
5.3% on `/`. A ratio that moves further than its own spread is the thing worth
explaining; a throughput delta of the same size is not.

## What the harness refuses to do

Every one of these is a wrong number this project published first:

- **No arm is measured until a real request succeeds** — HTTP 200 *and* rendered rows.
  A server that starts and answers 500 would otherwise publish a plausible figure for
  an arm that never ran the application. A cell that cannot be measured is `FAIL`,
  never a zero; and a cell whose retries all return zero is a failure, not a zero.
- **Every arm runs the same PHP.** `opcache.enable_cli` is read by php-cgi and ignored
  by php-fpm, so both are wrapped. This is not hypothetical: removing xdebug from this
  host's CLI package roughly **doubled** the two warm arms while the cold arms did not
  move — a difference of ini mistaken for a difference of server, on the one pair
  nobody had wrapped. `matrix.sh` refuses to start if xdebug or `psr` is loaded.
- **A freshly modified checkout is waited out.** `opcache.file_update_protection`
  defaults to 2 s and opcache declines to cache a newer file, which looks exactly like
  an opcache that does not persist. `filemtime()` is worse: PHP caches its own stat
  result, so a long-lived worker needs `clearstatcache()`.
- **RoadRunner is stopped by config path, not binary path.** Its argv is `./rr serve`,
  so a `pkill` on the resolved binary matches nothing and the worker survives into the
  next run holding its port.
- **Leftovers are caught per arm.** One host accumulated 68 orphans, each holding a
  port. The guard matches `-b` as its own word via `ps -eww` — the `-ww` is
  load-bearing, since without it a long wrapper command line is truncated — which never
  matches php-fpm's `php-fpm: pool www` children, so a host serving its own sites is
  neither counted nor reaped.
- **`max_requests = 0` means never recycle.** Reading it as "recycle after every
  request" is a mistake this project made, and it silently turns every warm arm cold.
- **The order is recorded.** Blocked order measures one arm's whole grid and then the
  next, so a host that drifts charges the drift to whichever arm ran last. The
  published runs are interleaved with a rotating start, and `meta.txt` states it,
  because it cannot be recovered from the rows by a reader who does not know the
  harness.

**When a ratio surprises you, measure whose CPU it is before theorising.** That is how
the largest finding here was made: a 10% throughput gap between two servers was a 3x
difference in *server* CPU per request, invisible in wall clock, and fixing it moved
the result more than any configuration change in the history of the harness.

## Layout

```
BenchApp.php            the application: bootstrap once, dispatch, cleanup
public/index.php        the COLD entry point (the cold arms)
worker.php              the WARM entry point (volucer warm arms)
roadrunner-worker.php   the WARM entry point (RoadRunner)
frankenphp-worker.php   the WARM entry point (FrankenPHP), PHP embedded in the server
seed.php                creates data/bench.sqlite
apps/azera/             the application, copied from azera-competition
conf/                   one stamped config per arm
```

The harness, in the order a reader needs it:

| script | what it is |
|---|---|
| `run-full-matrix.sh` | the published grid: arms, endpoints, process counts, concurrency |
| `matrix.sh` | the grid itself: workers x opcache x concurrency, with memory sampling |
| `matrix-report.py` | reads a matrix: medians, spread, opcache ratios, PSS/RSS tables |
| `bench.sh` | five arms one at a time (`P`, `T`, `U`, `R`, `F`) — the original sweep |
| `arms.sh` | the arm definitions every script sources |
| `ab-perf.sh` / `ab-report.py` | interleaved warm-arm pass: every arm inside one round |
| `bench-report.py` | the published page and its charts |
| `matrix_cells.py` | groups matrix rows into cells without merging two configurations |
| `compare_runs.py` | two sweeps side by side, cell by cell and ratio by ratio |

`bench.sh` predates the fork and embedded arms: it measures `P` (worker/pipe), `T`
(`spawn_cgi`/TCP), `U` (`spawn_cgi`/unix), `R` (RoadRunner), `F` (nginx + php-fpm) and
nothing else. `attach`, `prefork`, `external` and `frankenphp` are `matrix.sh` arms, so
a claim about any of them comes from the matrix, not from `bench.sh`.

Diagnostics, kept because each one settled a question that was otherwise argued:

| script | the question it answers |
|---|---|
| `diag-split.sh` | server CPU versus PHP-worker CPU, per arm |
| `diag-profile.sh` | `perf record` on the server process, flat symbol report |
| `diag-slots.sh` | the pool's own slot-wait histogram against the client's p99 |
| `diag-checksum.sh` | what the checksum cost, in CPU per request, across three builds |
| `diag-fpm-memory.sh` | per-child PSS vs RSS vs private: is opcache shared or copied? |
| `diag-opcache-sharing.sh` | do exec'd workers share OPcache, in the same segment? |

Behaviour, measured against a real server rather than a unit test:

| script | what it demonstrates |
|---|---|
| `fork-demo.php` | exec vs fork, one host, one run: what `fork()` saves |
| `fork-relay.php` | the forking-worker design at load: one boot, N children, one listener |
| `fork-worker-demo.sh` | the same against real volucer: transport, liveness, teardown |
| `recycle-cost.sh` | what replacing a worker costs, which every other number sets to zero |
| `verify-fixes.sh` | the socket transport, a SIGKILLed server's children, `kind = "attach"` |
| `verify-stall.sh` | does a stalled backend end the request, or hold the slot for ever? |
| `verify-idle-fix.sh` | the read-deadline fix, in the shape that reproduced a mass death |
| `verify-keepalive-rescue.sh` | does `idle_ping_ms` rescue a worker that reads a deadline as a close? |
| `probe-franken-php.sh` | which interpreter does FrankenPHP actually execute? |

## The framework-boot investigation

`docs/framework-cost.md` answers **"if php-fpm is this fast without a framework, what is
volucer for?"** — the premise being that removing the framework lifts php-fpm from
~27,900 to ~104,300 rps, which as CPU per request on 12 fixed cores is 427 us framed
against 72 us bare. Three findings, in cost order:

1. **Rebuilding the route table** — 121 us of the cold boot, fixed by a compiled table
   (121 us to ~1 us, worth +57% on the cold path). This is the framework's route cache.
2. **Re-asserting `journal_mode = WAL`** — 61 us, and idempotent: the mode is in the
   file header, so the second connection onwards re-sets a property that cannot have
   changed. Dropping it takes the cold connect from 112 us to 24 us.
3. **Rebuilding the container and its 12 feature routes** — 40 us together.

None of them change the ranking; they change how large the gap is. Run the whole
investigation in order:

```bash
bash scripts/probe-framework-cost.sh
```

The probes it drives (`probe-boot-cost.php`, `probe-route-cost.php`,
`probe-route-encodings.php`, `probe-route-serialisation.php`, `probe-boot-profile.sh`,
`probe-phases.sh`, `probe-static.sh`, `probe-cold-dispatch.php`, `probe-db-connect.php`,
`probe-db-first-statement.php`) are each a question the previous one raised, and
`docs/framework-cost.md` has the table of which is which.

## Reading the results

`bench.sh` writes `results.tsv` (every repeat) and prints a summary of medians. A
superseded sweep is kept beside the current one rather than overwritten, so
`compare_runs.py` prints both tables and the ratio change between them:

```bash
python3 scripts/compare_runs.py results/raw-ddaada7.tsv results/raw.tsv
```

| path | what it is |
|---|---|
| `results/run85-scale-items-2/` | **the published run**: 8 arms x 16/32/64 processes, `/items`, c=8-64 |
| `results/run85-scale-items/` | the first pass of that grid, kept because its artefact is why the second exists |
| `results/run85-scale-root/` | the same grid on the landing page `/` |
| `results/matrix-jit-5r/` | the multi-endpoint run: `/echo`, `/`, `/api/items`, `/items-fast`, 5 rounds, JIT on |
| `results/matrix85/` | the 8.5 grid: which arms, how many workers, on one interpreter |
| `results/matrix85-volucer-modes/` | one server in five shapes |
| `results/matrix85-opcache/` | opcache on/off, and the wrk thread count as a variable |
| `results/matrix/` | the original 8.3 grid: 5 arms x worker counts x opcache x concurrency |
| `results/matrix-0.4.1-reval60/` | `bare-echo.tsv`: framed vs bare, the premise of the boot investigation |
| `results/ab-perf*.tsv` | the interleaved warm-arm pass, current and superseded |
| `results/cpu-per-request.tsv` | the same three builds, attributed per process |
| `results/raw*.tsv` | the full sweeps, current and superseded |
| `results/frankenphp.md` | what the embedded runtime is worth, and why it is not CPU-bound |
| `results/prefork-vs-slots.md` | forked children vs one process per slot |
| `results/reload-cost-ab*.tsv` | what the reload indirection costs when nothing reloads |
| `results/tls-off-ab*.tsv` | what TLS costs on a deployment that never negotiates it |
| `results/slot-waits*.tsv` | the pool's own account of how long requests waited for a slot |

`-noise` files are A-vs-A controls: they set the resolution a null result is bounded
by, which is what makes "no measurable difference" a statement rather than a hope.

## Why the application is azera

The application is copied from `azera-competition` unchanged, because the published
figures there are the reference this repository's numbers are read against. Changing
the app would make the two datasets incomparable for no gain.

Its dependencies are pinned to exact commits rather than to a branch, and
`composer.lock` is **tracked** — the opposite of a library's convention, and deliberate:
the lock is an *input to the measurement*. Eleven dependencies are floating ranges,
including `spiral/roadrunner`, which *is* the RoadRunner arm. An unlocked
`composer install` a month from now would benchmark a different RoadRunner against the
same volucer and quietly produce an incomparable number. If a run needs a newer
RoadRunner, move the lock on purpose and say so in the results.

`data/` is not committed: it is 5 MB of generated rows, and a stale copy silently
changes what every arm measures.

## A note on history

This repository used to carry every script and every row that produced every
intermediate answer, which is why an earlier revision was 159 scripts and 2,300 lines of
chronological narrative. That is a search problem, not an archive: a reader looking for
"how do I measure this" had to skip past forty investigations that had already
concluded. The scripts kept here are the ones that produce a published number, answer a
question the documentation still makes, or verify behaviour against a real server. The
rest are in the git history, where the commit that introduced each one says what it was
for.