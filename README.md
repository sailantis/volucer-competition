# volucer-competition

Six ways to serve **one page on one machine**, measured identically.

This exists to answer a question the earlier benchmarks could not. On a handler
that returns a few dozen bytes, every deployment model lands within ~10% of every
other — a trivial request has nothing to keep warm, so the worker model's whole
premise is invisible. The hypothesis here is that the gap is proportional to what
the application has to boot, and the fix is to serve a page that actually builds a
framework container.

The page is `GET /items`: one SQLite query through the azera ORM, rendered by a
ClarityEngine template, through a controller with middleware. It is the cheapest
route that still boots the container.

The design memory behind volucer itself — the numbered hazards, the step list and
the open decisions — is [`volucer/docs/plan.md`](https://github.com/sailantis/volucer/blob/main/docs/plan.md).
Where this README says "hazard 46" it means entry 46 there, and its section 10
("Where the work stands") is the current state of the build.

## The six arms

| arm | server | model | transport |
|---|---|---|---|
| **P** | volucer `worker` | warm — framework booted once | pipe |
| **T** | volucer `spawn_cgi` | cold — framework booted per request | loopback TCP |
| **U** | volucer `spawn_cgi` | cold — framework booted per request | unix socket |
| **R** | RoadRunner `worker` | warm — framework booted once | pipe |
| **F** | nginx + php-fpm | cold — framework booted per request | unix socket |
| **Z** | FrankenPHP | warm — framework booted once, **PHP embedded** | in-process |

Six arms is not six questions. Each pair isolates one variable:

- **T vs U** — the transport. Same server, same model, same SAPI, same page. A
  difference here is the transport and nothing else.
- **P vs T/U** — the deployment model. A difference here is what the framework
  boot costs when it is paid per request instead of once.
- **F vs T/U** — the server implementation at the same cold model.
- **P vs R** — the server implementation at the same warm model.
- **Z vs P/R** — embedding against spawning. Z is the only server here that runs PHP
  inside its own process; the other five all start an external interpreter. This is
  the alternative volucer rejects on principle, so Z is the number that principle
  was traded against. It is measured in the warm-vs-warm pass only, and its result is
  in [results/frankenphp.md](results/frankenphp.md): **a tie for fastest at
  concurrency 1, the slowest of the three from 8 upward, and not CPU-bound while it
  happens — it leaves 7.17 of 12 cores idle at concurrency 16.**
**One confound is stated rather than hidden:** P is both warm *and* piped, so
P-vs-T/U mixes the model with the transport. That mixed comparison is still the
one that matters commercially — it is the two deployment models as they are
actually deployed — but a claim about the transport alone has to come from T vs U,
where the model is held equal. The volucer plan already measured pipe and TCP as
identical to concurrency 8 on a trivial handler, so the pipe-specific cost is not
expected to be large; this repository is what checks that on a real page.

## The conclusion is platform-dependent, and Windows inverts it

The published run is Linux, and on Linux the warm arm wins by the margin the
hypothesis predicted. **On Windows with a pipe-transported worker it loses**, and the
reason is not the server:

| what PHP is reading | median | p95 |
|---|---|---|
| a **pipe** | **~8 ms** | **~15.4 ms** |
| a **socket** | **~0.09 ms** | — |

PHP's Windows stream layer takes ~100× longer to return from a blocking read on a
pipe than on a socket, and the cost is paid *per request*. So on Windows arm P —
warm, but pipe-transported — is slower than arms T/U, which are cold but
socket-transported, and the warm/cold comparison inverts. Nothing volucer does
causes it: a Rust process reading the identical pipe returns in 0.010 ms, and
RoadRunner measured 15.15 ms against volucer's 15.24 ms on the same host — two
independent servers and two independent SDKs agreeing to 0.6%.

**So `arm P` on Windows is not the deployment model's value; it is the pipe's
cost.** volucer has a `transport = "socket"` option for this (see its README and
plan hazard 46), and with it the same warm arm measures **0.72 ms median against
15.24 ms on the pipe** — 21× faster, a 0.06 ms spread across 9 runs, and the two
ranges are disjoint by two orders of magnitude. That is back in line with the Linux
figure, which is what shows the difference is the transport rather than the
platform. To reproduce the Windows comparison:

```bash
# the worker follows VOLUCER_WORKER_SOCKET when the server sets it
# (Volucer\Worker::connect()), so only the config differs
transport = "socket"    # [backends.app]
```

`worker.php` uses `Volucer\Worker::connect()` for exactly this reason: it drives
both transports with no PHP-side change, so the arm can be measured on either. The
SDK version pinned in `composer.json` must include `connect()`, since a worker that
calls a method the pinned SDK does not have is a startup fatal error rather than a
degraded path.

**The inversion is the pipe's doing, and it is worth saying what it is not.** It is
not Windows making FastCGI good. `spawn_cgi` measured on the same host peaks at
**~1,730 rps against the resident worker's ~9,700 on `/items`** — about 5.6× — so once
the warm arm is not crippled by the pipe it wins on Windows by a *larger* margin than
the Linux arms show (8,179 against 18,655, or 2.3×). Windows is slower for both
deployment models; it is the cold one that pays much more of the penalty:

| metric (`GET /items`) | Linux, 12 cores, idle | Windows, 6c/12t, 20–30% busy | ratio |
|---|---|---|---|
| resident worker, sequential p50 | 0.585 ms | 0.82 ms | 1.4× |
| FastCGI, sequential p50 | 1.52 ms | 4.6 ms | **3.0×** |
| peak throughput, resident worker | 18,655 rps | 9,717 rps | 0.52× |
| peak throughput, FastCGI | 8,179 rps | 1,728 rps | **0.21×** |

So the deployment-model conclusion is not platform-specific after all — the resident
worker wins on both, and wins *more* easily on Windows. What was platform-specific was
the pipe.

## FastCGI on Windows is fine, and its transport does not matter

There is no Windows counterpart to the Linux arm F: `php-fpm` does not exist on
Windows, so neither the `external` nor the `spawn_fpm` backend can run there, and
**`spawn_cgi` is the only FastCGI path**. That makes Windows the one place the
FastCGI transport pair can be compared directly, because `php-cgi -b` binds a
**named pipe** for a `\\.\pipe\` address and loopback TCP for a `host:port` one.

Three arms interleaved within each concurrency level (so background drift cannot be
charged to whichever arm ran during a busy moment), 3 rounds of 5 s per cell, 12
slots each, **0 errors and 0 worker respawns in all 27 runs**:

| conc | `spawn_cgi` + **named pipe** | `spawn_cgi` + TCP | `worker` + socket | worker/pipe | worker/tcp | pipe/tcp |
|---|---|---|---|---|---|---|
| 1 | 274 rps | 267 rps | 1,201 rps | 4.38× | 4.50× | 1.028 |
| 12 | 1,641 rps | 1,631 rps | 9,717 rps | 5.92× | 5.96× | **1.006** |
| 32 | 1,728 rps | 1,693 rps | 7,716 rps | 4.46× | 4.56× | 1.021 |

**The FastCGI transport is a non-question — 0.6–2.8% apart at every level** — and the
CPU column says why:

| conc | worker CPU/req | fcgi-pipe CPU/req | fcgi-tcp CPU/req |
|---|---|---|---|
| 1 | 0.93 ms | 5.27 ms | 4.25 ms |
| 12 | 1.16 ms | 4.58 ms | 4.80 ms |
| 32 | 1.06 ms | 4.73 ms | 4.86 ms |

A `spawn_cgi` request costs **5×** the CPU of a worker request, because the CGI SAPI
pays the framework boot every time. The transport difference is 42 µs on a 4.6 ms
request (hazard 45 measured 168 µs against 211 µs over the FastCGI exchange alone) —
about 0.9%, which is the size of the ~1.5% latency difference above. **Hazard 45
extrapolated that 42 µs to "an end-to-end effect of about 8%"** by assuming the
exchange was a large share of a request. It is not, and the prediction is not borne
out: 42 µs is ~1% of a ~4.6 ms request, not ~40%. Where the same reasoning *does*
hold is the worker, and that is the whole of hazard 46/47: there the pipe read was
15 ms against a ~1 ms request, because a worker's read *is* the request, whereas a
FastCGI exchange is a rounding error on one. It cannot show up as throughput here,
and it does not.

Two things were checked rather than assumed:

- **No ini confound.** `php-cgi` and the `php` CLI read the same `php.ini` with identical
  values on this host (`opcache.enable=1`, `opcache.enable_cli=1`, `memory_limit=128M`,
  xdebug off), so unlike the Linux harness — which needs its `php-cgi-bench` wrapper
  because `php-cgi` reads `opcache.enable_cli` and `php-fpm` does not — no wrapper was
  used. `opcache.jit=tracing` is set but `opcache.jit_buffer_size=0`, so no JIT runs on
  any arm.
- **Idle FCGI pools cost nothing.** 24 parked `php-cgi` processes consumed **exactly 0
  CPU** over a 5 s idle sample, so leaving them up does not pollute another arm.

**One method note, because it bit.** A block-ordered run of the same two arms reported the
named pipe **22% faster** at c=1 (5.29 ms against 4.34 ms) and 22% *slower* at c=32 (15.98
against 18.18). Alternating them round by round gives the opposite of the first and no
support for the second — pipe 4.50–4.76 ms against TCP 4.59–4.68 ms, the same to 1.5%. **A
22% effect that reverses sign between two runs of the same arms is drift**, and on a host
with 20–30% background load a block layout manufactures exactly that. Compare by cycling,
not by blocks.

## What the loopback socket does under load

The 0.72 ms figure above is a *sequential* measurement. The question a Windows
deployment actually faces is what the socket does once the pool is saturated, and
because the pipe arm is capped by something the socket arm is not, the answer is not
the same ratio. Measured on this host (Ryzen 5 7500F, 6 cores / 12 threads, PHP
8.3.31 ZTS, volucer `279dc35`), `GET /items`, 12 workers, 5 runs of 5 s per cell:

| conc | socket rps | pipe rps | ratio | socket p50 | pipe p50 |
|---|---|---|---|---|---|
| 1 | 1,418 | 66 | **21.5×** | 0.658 ms | 15.11 ms |
| 4 | 5,297 | 265 | **20.0×** | 0.683 ms | 15.10 ms |
| 8 | 8,651 | 528 | **16.4×** | 0.903 ms | 15.09 ms |
| 12 | 8,528 | 775 | **11.0×** | 1.215 ms | 15.53 ms |
| 16 | 8,796 | 775 | **11.3×** | 1.547 ms | 16.04 ms |
| 24 | 8,655 | 774 | **11.2×** | 2.082 ms | 31.03 ms |
| 32 | 8,599 | 773 | **11.1×** | 2.504 ms | 45.34 ms |

**The peak is ~8,800 rps against ~775 — a ceiling ratio of 11.3×, and 26× the Linux
pipe figure.** The interesting part is *why the ratio shrinks from 21× to 11×*, and it
is neither arm's fault:

- **The pipe arm cannot use more than one worker.** Up to concurrency 8 it scales
  linearly at **exactly 66 rps per connection** (66 / 132 / 264 / 528), and then stops
  dead. It saturates at **775 rps regardless of whether 12 or 32 connections are
  offered** — 12 workers × 66 rps, within 0.4% across every cell. The ceiling *is* the
  15 ms per read, and nothing the client does can move it. Beyond 12 connections the
  extra ones merely queue, which is why p50 rises to 31 ms and then 45 ms while
  throughput does not move at all.
- **The socket arm is worth ~1,390 rps per worker** (8,651 at 8 connections against the
  pipe's 528) and is capped at **~9,000 rps by CPU, not by the pool**: at c=12 it uses
  **61–63% of the whole host while the pipe arm uses 2.9–6.6%**, and *adding* concurrency
  past 12 buys nothing because every worker is already busy.

That the socket's 11× is a *CPU* ceiling rather than a limit of the loopback transport
was checked rather than assumed, because the load generator is home-grown: one client
at c=12 (9,306 rps) and two clients at c=6 each (9,209 total) land in the same place,
so the client is not scarce, and its own cost is **0.06 ms per request** (½ core at
8,200 rps). The server's 12 workers are the limit.

So under load the loopback socket is not merely the difference between a responsive
Windows deployment and an unusable one — it is the difference between **~775 rps and
~8,800 rps**, and it does it while *leaving* 38% of the host idle for PHP, where the
pipe arm sits blocked and consumes almost nothing.

Two honest caveats. Comparing 8.6k against the Linux `wrk` figure of ~18.7k mixes load
generators and hosts, so it is indicative and not evidence; the like-for-like
comparison is the sequential one, where socket 0.82 ms against Linux 0.585 ms is the
same order and pipe 15.26 ms against Linux 0.585 ms is not. And the raw rows are
committed as `results/raw-windows-279dc35.tsv` — the 70 rows behind this table, five
repeats per cell and **zero errors in any of them**, in the repository's own raw
format, so every figure above is the median of five committed rows rather than a
number taken on trust. The two transports carry separate arm keys (`P` = socket,
`Pp` = pipe) on purpose: `scripts/compare_runs.py` keys a cell on `(arm, conc,
endpoint)`, so giving both rows `P` would have merged the two transports into one
median and destroyed the comparison. `compare_runs.py` loads the file and reports the
`P` cells; the `Pp` rows are in the same file for the same treatment.

## What TLS costs when it is off

The README in the server repository claims that with no `[server.tls]` "there is no peek, no
branch, and no TLS value is constructed — the cleartext path is the same code it was before TLS
existed". That claim was written from reading the code, and for a while it said so: it was the one
claim in the TLS work that had not been measured on this host.

`scripts/tls-off-ab.js` measures it. The estimator is the same within-round rotated one
`ab-perf.sh` uses, and the arms are two **binaries** rather than two settings:

| arm | build |
|---|---|
| A | `206b41f` — the last commit before any TLS code existed |
| B | current `main` |

Both arms serve a config with **no `[server.tls]` at all**, so the difference is what the TLS work
added to the plaintext path. Comparing TLS-on against TLS-off inside one binary would measure the
*handshake* instead, and nobody disputes the handshake. `static_files` stays on: the workload is a
1 KiB static file, which is the cheapest real request the server answers.

    node scripts/tls-off-ab.js     # BIN_A, BIN_B, ROUNDS, DURATION, OUT

`autocannon` is the load generator, because Windows is where this was run and `wrk` is not present
there; `npm install autocannon` is the only prerequisite. The Node harness is deliberately
self-contained rather than sharing the `.sh` scripts, which need a Linux host.

**Result — no measurable difference.** Twelve rounds, concurrency 32, 6 s per arm per round, one
warmup round discarded, arm order rotated every round:

    effect -0.08%   95% CI [-0.66%, +0.51%]   n = 12

Raw rows: `results/tls-off-ab.tsv`. An interval containing zero is a null result, and the claim
holds. The bound is worth stating precisely: TLS costs **less than about 0.7%** on a plaintext
deployment, which is smaller than this host can resolve per cell — so the honest form of the claim
is "not measurable here" rather than "exactly nothing".

**The noise floor, so the null means something.** An A-vs-A run — the same binary against itself,
the arms labelled identically so any difference is pure measurement error — reads:

    spread [0.9783, 1.0177]      # results/tls-off-ab-noise.tsv
    spread [0.9870, 1.0275]      # the first pass, same shape

So a single cell on this host is only good to about ±2%, and a difference smaller than that cannot
be seen in one round. It can be seen in the *mean* of many, which is why the verdict is drawn from
the interval rather than from the spread: the spread says whether one number is trustworthy, the
interval says whether many of them, averaged, show an effect.

**One confound is live, and the first version of this paragraph got it wrong in both directions.**
The obvious worry is the fair queue (`e2b031e`), the largest effect this project has produced
(+24.5% at c=24, +22.9% at c=32 on the cold arms) — and it is **not** a confound at all, because it
is an ancestor of the baseline: `git merge-base --is-ancestor e2b031e 206b41f` succeeds, so both
arms are *after* it. The same is true of the bundled static layer (`6d7228d`). The paragraph here
first argued that the fair queue was live-but-inert because "a static file never leases a slot",
which was a guess about which lock protects a slot *and* a false statement about the baseline.

**The confound that is actually live is `ba09e03` — the `HostMap` extraction.** It re-homed the
site table on `HostMap<String>` and replaced the linear scan over wildcard patterns with a walk of
the host's own labels, and it is one of exactly two commits in the whole window that touch
`volucer-http/src` or the resolution path a plaintext request runs through:

    git log --oneline 206b41f..HEAD -- crates/volucer-http/src
    e1af51b  tls: check the certificate before the port   # load-time only
    dae2983  refactor: rename stokehold to volucer        # names only

So the window is TLS (a branch not taken when no `[server.tls]` is configured), `HostMap` (per
request, and it is meant to be *faster*), a rename (no behaviour), and a load-time reorder. The
measurement is still a valid null for the statement the server README makes — *no `[server.tls]`
means no TLS branch, no peek, no TLS value* — because it compares that path before and after the
TLS work; it is **not** a pure TLS isolation, and the `HostMap` difference is the honest caveat.

**A control that proved the harness wrong, and is recorded for that reason.** The first noise-floor
run read exactly `1.0000` in all six rounds, which is not a tight measurement — it was a harness
bug. Results were keyed by arm *label*, so an A-vs-A run with both arms labelled `head` made the
second reading overwrite the first and the ratio came out exactly 1 regardless of the servers. The
round function now keys by slot. This is the same class of mistake the rest of this repository
records: **a control that agrees perfectly is a control that is measuring nothing.**

## What the reload indirection costs when nothing is reloaded

The server README's reload section makes a specific claim about a cost: the request path used to
read three `Arc`s directly off `FrontEnd` and now takes **one** snapshot from
`Arc<Swappable<Reloaded>>`, and the snapshot is an `ArcSwap` load — a pointer read — so it should
be unmeasurable against the three `Arc` clones it replaced. That is exactly the kind of sentence
this project does not allow to stay unmeasured, and `scripts/reload-cost-ab.js` measures it with
the same within-round rotated estimator.

The arms are two **binaries**, built `--release` from the same toolchain:

| arm | build | request-path state |
|---|---|---|
| A | `68bfdcc` — the last commit before the reload work | three `Arc`s on `FrontEnd` |
| B | current `main` | one `Arc<Swappable<Reloaded>>` |

Both serve a config with **no `[server.tls]`**, so the only difference is the indirection.
`static_files` stays **on** here, and that is the opposite of the TLS measurement's choice on
purpose: the site resolution and routing lookup the snapshot feeds are on the static path, so
turning it off would measure a branch the change does not touch.

    node scripts/reload-cost-ab.js   # BIN_A, BIN_B, ROUNDS, DURATION, OUT

**Result — no measurable difference.** Twenty rounds, concurrency 32, 5 s per arm per round, two
warmup rounds discarded, arm order rotated every round:

    effect -0.09%   95% CI [-1.43%, +1.27%]   n = 20

Raw rows: `results/reload-cost-ab-20.tsv`. An interval containing zero is a null result, and this
one is wide — so the honest claim is **"not measurable here"**, not "zero". The 10-round run that
came first is kept beside it as `results/reload-cost-ab.tsv` and read **+1.75%, 95% CI [+0.56%,
+2.95%]**, which *excludes* zero. That is the useful half of this record.

**The first run reported a difference and the control refused it.** The A-vs-A control on the same
host, at the same 20-round shape, reads:

    effect +0.34%   95% CI [-0.91%, +1.61%]   n = 20     # results/reload-cost-ab-noise-20.tsv

So the resolution is about ±1.5%, and the measured −0.09% sits well inside it: the two point
estimates differ by **0.43 percentage points**, less than either interval. "Not measurable here" is
the claim.

The **10**-round pair is kept beside it because that is where the lesson is. The 10-round A-vs-B
read `+1.75%, 95% CI [+0.56%, +2.95%]` — excluding zero — and the matching 10-round control read
`−1.44%, 95% CI [−2.91%, +0.05%]`: a point estimate **larger than the effect it was the scale for,
and in the opposite direction**. A run that stopped there would have become a commit message
claiming the reload made the request path *faster* (`results/reload-cost-ab.tsv`,
`results/reload-cost-ab-noise.tsv`).

**This is the rule the TLS measurement already applied, applied where it bit.** The project's
standard for a hot-path claim is an interval, not a point estimate, and the interval is only
interpretable next to a control. Twenty rounds changed the verdict rather than the servers: the
same two binaries moved from "there IS a difference" to "the claim holds", because the interval on
log-ratios shrinks as √n while the per-round spread does not.

**Window check, because hazard 56's lesson was about exactly this.** The two arms are separated by
two commits and both are reload commits:

    git log --oneline 68bfdcc..HEAD
    8c63807  reload: make the certificate table replaceable, without a restart
    a937f43  reload: make the request path's configuration replaceable without a restart

`git merge-base --is-ancestor 68bfdcc HEAD` succeeds, and no other commit touches
`volucer-http/src` in that range — so unlike the TLS-off comparison this **is** an isolation of the
change under test rather than a window that happens to contain it. The only files in the window are
the server crate, its tests, and documentation.

## What the static layer costs a front-controller application, and what it hid

The static-file layer became **on by default** after the published build (`b9d34c4`), on the
reasoning that "every site has assets". For a site that serves files that is right. For a
front-controller application it is a cost — and the cost is large enough to have consumed the
whole of the throughput this project gained since `91cc7b6`, while reading as its opposite.

Four arms interleaved inside nine rotating rounds: 288 cells, none failed, twelve workers. Every
figure is a **within-round ratio**, so host drift charges every arm equally:

| concurrency | `/` current vs `91cc7b6` | `/items` current vs `91cc7b6` | static layer off (both endpoints) | new code only (both endpoints) |
|---|---|---|---|---|
| 1 | **−4.3%** | +13.3% | **+14.1%** / +22.0% | +29.3% / +16.2% |
| 8 | **−13.0%** | +8.6% | **+13.9%** / +17.6% | +22.6% / +2.1% |
| 16 | **−18.3%** | −2.0% | **+13.3%** / +23.1% | +8.8% / −0.6% |
| 32 | **−12.3%** | +10.7% | **+6.8%** / +26.1% | +19.1% / +10.2% |

The four columns are four questions, and conflating them is how this measurement would have
produced the wrong answer:

- **current vs `91cc7b6`** — the sum of everything in fifty steps. Read alone: the project lost
  4–18% on `/` and moved ±13% on `/items`.
- **static layer off** — `new-nostat / new-req`: the *same binary* with
  `[server.static_files] enabled = false`, so the difference can only be that one table.
  **`/` loses 18–26% to the default** (1.220x, 1.176x, 1.231x, 1.261x, every per-round range clear
  of 1.00); `/items` loses 7–14%, whose ranges cross 1.00 in all four cells — but all four crossings
  come from the same round, in which the whole `new-nostat` block fell about 20% while the other
  three arms held. That is one disturbed measurement, not four independent flukes; dropping that
  round leaves `/items` at 7–14% with no range crossing 1.00.
- **new code only** — `new-nostat / baseline`: the same comparison with that one default removed.
  **The code added since the published build is faster in seven of eight cells, up to +29%.**

The absolute numbers, median rps over the nine rounds, because a ratio is not a throughput:

| arm | `/` c=1 | c=8 | c=16 | c=32 | `/items` c=1 | c=8 | c=16 | c=32 |
|---|---|---|---|---|---|---|---|---|
| volucer `main`, static **off** | **3,849** | **24,852** | **35,640** | **42,142** | **2,327** | **14,451** | **18,932** | **23,011** |
| volucer `main`, static on (the default) | 3,097 | 21,124 | 28,770 | 33,043 | 2,048 | 12,714 | 16,869 | 21,162 |
| volucer `91cc7b6` | 3,255 | 24,132 | 35,110 | 37,966 | 1,828 | 11,750 | 17,369 | 19,078 |
| RoadRunner 2025.1.15 | 3,105 | 20,162 | 34,343 | 36,081 | 1,786 | 11,189 | 17,622 | 18,054 |

**The mechanism, counted rather than inferred.** `strace -f -c` over 300 requests, same binary, four
workers:

| | static off | static on | difference |
|---|---|---|---|
| `statx` on `GET /` | 0.04 /request | **1.05 /request** | +1.0 |
| `statx` on `GET /items` | 0.04 /request | **2.05 /request** | **+2.0** |
| `futex` (`/items`) | 14.11 /request | 20.00 /request | +5.9 |
| `clock_gettime` (`/items`) | 50.40 /request | 61.58 /request | +11.2 |
| all syscalls (`/items`) | 158.4 /request | 179.7 /request | **+21.3** |

**A path that names no file needs one `stat`, and it was paying two.** The layer asked
`is_dir()` and then `is_file()` — two round trips to learn one fact — and for a front-controller
application that is two round trips on *every* route, because no route names a file. (`/` paid
one, because a trailing slash takes the `directory_index` branch.) The `futex` and
`clock_gettime` traffic is the rest of it: the `spawn_blocking` hop that carries the stat off the
runtime thread.

**Fixing the stat fixes nothing, and that is the measurement.** One `metadata` where the layer
asked two questions drops `GET /items` from 2.05 `statx` per request to 1.05 — and buys **+0.2%,
+1.1%, −0.1%, −0.2%** on `/` and **+0.5%, +0.9%, +0.1%, +0.2%** on `/items`, with every per-round
range spanning 1.00. Two binaries, same config, seven rotating rounds, 168 cells, none failed
(`results/ab-perf-statfix.tsv`). The stat was ~1.5 µs of the 6.5 µs; the hop is the rest.

So the only thing that recovers the 18–26% is **not entering the layer at all**, which is
`serve_only = "backend"` — or, for a deployment that has not written it, the layer being turned
off for it. Both now happen; the second is the one an existing deployment gets for free.

**The cost is flat per request, which is what identifies it.** Per-request service time for the
same binary, layer on minus off: **63.0 µs at c=1, 7.1 at c=8, 6.7 at c=16, 6.5 at c=32** — a
fixed toll, not a function of how much work the request does. The 63 µs at c=1 is the same
overhead with no other work to hide behind: at 300 µs per request the hop and two stats are 20% of
the total, because they are a wake-up rather than a computation.

**The `new-nostat` arm is the difference between a finding and a wrong conclusion.** Without it
there is only "current is slower", and the natural reading is "the fifty new steps cost
throughput" — pointing at reverting work that is in fact the fastest this project has been. One
extra arm, one extra config table. (Since the layer became self-deciding it is `new-static` that
does this job, for the mirror-image reason — see below.)

Two falsifications ran before the numbers were believed. The layer really is on by default and
really is off with the table: a real file in the document root answers **200 with its bytes** by
default and **404** with `enabled = false`, while `/items` answers 200 in both — the table changes
behaviour rather than merely parsing. And `/items` names no file, so the layer can only be finding
nothing — which is why the cost is the same regardless of what the request goes on to do.

### Re-measured after the layer became self-deciding

With `Sites::from_config_with` turning the layer off for a document root that holds no asset, the
`new-nostat` arm above **no longer differs from `new-req`** — this application's root is one
`index.php`, so both arms now run with the layer off. The arm that has to be pinned explicitly
became the other one, and `ab-perf.sh` gained `new-static` (`[server.static_files] enabled = true`,
which the decision honours because a written `true` is a request rather than a default).

Four arms, five rotating rounds, 160 cells, none failed (`results/ab-perf-autostat.tsv`). Absolute
median rps, with both controls in the table so the host can be judged rather than trusted:

| arm | `/` c=1 | c=8 | c=16 | c=32 | `/items` c=1 | c=8 | c=16 | c=32 |
|---|---|---|---|---|---|---|---|---|
| volucer `main`, layer **off** (now the default) | **3,816** | **24,806** | **35,707** | **42,465** | **2,387** | **14,480** | **19,087** | **22,851** |
| volucer `main`, layer forced **on** | 3,266 | 21,264 | 29,086 | 33,381 | 2,056 | 12,833 | 17,013 | 21,234 |
| RoadRunner 2025.1.15 | 3,170 | 20,192 | 34,845 | 36,636 | 1,815 | 11,274 | 17,764 | 18,209 |
| FrankenPHP 1.13.1 (PHP 8.5.11) | 4,667 | 22,880 | 20,810 | 21,948 | 2,463 | 14,419 | 15,383 | 16,003 |

**The default converged on the arm it was meant to recover.** New `new-req` against the old
`new-nostat` row above, cell by cell on `/items`: **+2.6%, +0.2%, +0.8%, −0.7%**. Both arms have
the layer off; the difference between them is only which binary decided it, so this is a
cross-check that the inferred default landed where the explicit switch was measured, and that the
two runs are on comparable footing. Against the old *layer-on* row the same binary reads +16.5%,
+13.9%, +13.1%, +8.0% — the gain an existing deployment now gets without writing anything.

**RoadRunner reproduced its published numbers to within 2.1% in every cell**, which is what makes
the volucer row comparable to the table above rather than merely plausible. Within-round ratios
against it, median over the five rounds:

| concurrency | volucer `/` vs rr | volucer `/items` vs rr | layer on vs off, `/` | layer on vs off, `/items` |
|---|---|---|---|---|
| 1 | **+19.2%** | **+31.4%** | −14.0% | −13.9% |
| 8 | **+23.0%** | **+28.4%** | −14.3% | −12.8% |
| 16 | +2.7% | +7.6% | −19.0% | −10.7% |
| 32 | **+15.6%** | **+26.0%** | −21.4% | −6.3% |

Every range here is clear of 1.00. The layer's cost measured **13–21% on `/` and 6–14% on
`/items`** — the same order as the 18–26% / 7–14% above, from a different binary and a different
run, so the finding is not a property of the earlier one. The `/` figure exceeds `/items`' at high
concurrency for the reason recorded earlier: `/` resolves through the directory-index branch,
`/items` names no file at all.

### Why RoadRunner nearly catches up at concurrency 16

The c=16 column is the odd one — +2.7% on `/` against +19% and +23% either side of it — and it is
not noise: all five rounds agreed, 1.007, 1.048, 1.029, 1.027, 1.011. It is also not a crossover.
RoadRunner's advantage is that **its cost per request falls as the pool gets busier**, and c=16 is
simply the first point where a twelve-worker pool is busy enough to collect it.

Measured directly, at fixed concurrency with the worker count varied, the server's CPU cost per
request (`results/ab-workers-vs-concurrency.tsv`, two rounds agreeing to 1%):

| workers | rr @ c=8 | rr @ c=16 | rr @ c=32 | volucer @ c=8 | c=16 | c=32 |
|---|---|---|---|---|---|---|
| 6 | 223 µs | 218 | 218 | 182 µs | 183 | 186 |
| 12 | 267 µs | **230** | 224 | 184 µs | 190 | 196 |
| 24 | 310 µs | 290 | 254 | 186 µs | 194 | 212 |

Sorted by requests per worker per second, rr's cost is monotonic from **310 µs at 736 rps/worker
down to 218 µs at 4,500** — a 42% swing driven by how much work each worker gets, not by
concurrency as such. A worker that is woken for one request and put back to sleep pays for the
wake-up; a worker kept warm does not. That is also why rr gets *worse* with 24 workers at c=8
(310 µs, 17,640 rps against 24,100 at 6 workers): spreading a light load over more processes
multiplies the wake-ups.

Volucer shows the same direction an order of magnitude weaker (182 → 212 µs), which is why the
gap narrows at 16 and reopens at 32 — at c=32 rr has already spent its improvement while volucer's
pool is only just saturated. **The c=16 dip is rr converging on its floor, not volucer slowing
down.**

**A correction to what this section said before.** An earlier draft attributed the effect to a
per-worker wake-up cost and read the magnitude off a measurement that turned out to be unusable: it
recorded 18.3 CPU-seconds for a cell whose rps was within 1% of a run recording 47.0, so one of the
two was not measuring the server. The cause was not isolated, so the fix was to remove the
opportunities for it rather than to name it — a fresh port per cell, the server pid checked alive
before and after, the worker count confirmed from the process tree, and CPU per request
cross-checked two independent ways (by elapsed time and by completed request count), which agree to
within 1%. The direction of the earlier conclusion survived; the magnitude did not.

### Neither arm saturates this host, so c=32 is not a ceiling

Worth stating because it bounds every reading above. volucer at c=32, 64, 128 and 256 served
43,790, 45,175, 44,532 and 44,320 rps — flat, while its server tree used 8.8–9.0 of the host's 12
cores and the load generator plus everything else accounted for only 0.5. So the plateau is not
CPU exhaustion on either side, and **the c=32 cells are where the sweep stopped, not where the
server stopped**. Comparing arms at c=32 compares them at a point neither has been pushed past.

FrankenPHP is the only arm that does not gain from concurrency: **20,810 at c=16 against 22,880 at
c=8** on `/`, and flat from 16 to 32 on `/items`. That plateau *is* a real ceiling rather than a
stopping point — it stops while leaving 7.17 of 12 cores idle, which is the queueing signature
`results/frankenphp.md` describes, reproduced on a different host and a newer binary. It is also
the one arm ahead of volucer anywhere: **+17.5% on `/` at c=1** (0.825x), a cell where volucer
wins on `/items` by −4.9% with a range crossing 1.00, so at concurrency 1 the two are close and
inconsistent rather than ordered.

**The host had 3.9 GB of RAM, and that is not a confound — measured, not assumed.** An earlier
draft of this section called it one, on the reasoning that the published sweep ran on a bigger
host. It does not survive being checked. Sampled once per half-second across a three-arm sweep at
concurrency 32: minimum `MemAvailable` **2,842 MB**, the kernel's PSI memory-stall counter
**unchanged at 220,362 µs** across the whole run, and **zero swap-out pages** — on a host with no
swap device at all, so a shortage would have shown up as an OOM kill rather than as silent
throttling, and there were none. All 160 cells of the full sweep recorded a positive rps.

The reason the headroom is that large is that the arms run one at a time and each needs a few
hundred megabytes. Measured as **PSS** summed over the process tree after a load burst — not RSS,
which counts a shared page once per process and therefore charges twelve PHP processes twelve times
for the interpreter they share:

| server | 12 units | RSS (says this) | PSS (actually this) | marginal MB per extra unit |
|---|---|---|---|---|
| volucer, 12 workers | 13 processes | 568 MB | **208 MB** | 15.5 |
| RoadRunner, 12 workers | 13 processes | 637 MB | **276 MB** | 18.1 |
| FrankenPHP, 12 threads | 1 process | 134 MB | **134 MB** | **2.3** |

**FrankenPHP is genuinely the most memory-efficient, and by more than a third.** Its 134 MB is all
private, and a worker there costs 2.3 MB because a thread shares the interpreter, whereas a spawned
PHP process costs 15.5 MB because it has its own copy. So twelve of them differ by about 170 MB.
That is real — but it is also the *cost* side of the trade the throughput table shows the benefit
of: the same design that makes a worker almost free is the one that plateaus at 20,810 rps.

Two cautions on these numbers. RSS is what would have been quoted without checking, and it flatters
FrankenPHP on the twelve-worker row (134 against 568, a 4.2× impression) while the honest figure is
1.6×. And the marginal column is the one that generalises: a real deployment at 64 workers is
better predicted by `2.3 × 64` and `15.5 × 64` than by scaling the twelve-worker totals, which
carry a fixed base of 109 MB and 37 MB respectively.

So three gigabytes is comfortable for this matrix. It would stop being comfortable if arms ran
concurrently, which is exactly what the interleaved design avoids doing.

**Sizing it for something bigger than this matrix:** the numbers that matter are the marginal
column and the memory limit each worker carries. At `memory_limit = 512M`, the worst case is not
the 15.5 MB a worker *does* use but the 512 MB it is *allowed* to use, and twelve of those would be
6 GB — which is why `memory_limit` is the setting to cut before RAM is the thing to add, if a run
ever needs more workers than this host can hold. For the sweep as configured, 4 GB was never close.

**So the layer is now turned off for exactly those applications.** `Sites::from_config_with`
decides it, which is the table `serve` actually serves from, so there is one answer rather than a
warning that could disagree with the request path. Three conditions bound it:

- **nobody asked for the layer.** A file that wrote `enabled = true` keeps it; only the default
  nobody wrote down is switched off on the operator's behalf.
- **the document root holds no asset** — any directory, or any non-script file, keeps the layer.
  A `public/` deployment is therefore never affected, and neither is one whose assets appear at
  build time as long as the directory is there.
- **the layer could shadow something**: an HTTP listener exists and a backend does, so it is not
  reachable-but-pointless or the whole application.

Never silently, though. `check` prints it after the settings it overrides:

```
  static files:
    all
    enabled for the HTTP listener
      precompressed:   no
      ...
    <default>: off, though the file enables it — /srv/app/public holds no asset a file could be
    served from
```

`serve` says it in the banner (`static files: off (the document root holds no asset a file could
be served from)`) and logs it at `WARN`. Verified on the real application — whose document root
holds one `index.php` and nothing else — and both ways: creating `assets/` brings the layer back
and `GET /assets/app.css` is then served from disk with its MIME type.

Raw rows: `results/ab-perf-baseline.tsv` (before the layer became self-deciding) and
`results/ab-perf-autostat.tsv` (after, with both controls). Harness: `scripts/ab-perf.sh` with the
`baseline`, `new-nostat` and `new-static` variants; report at `scripts/ab-report.py`; record at
volucer `docs/plan.md` hazard 85:

```bash
# The original attribution: what the default cost, against the published build.
BIN=~/volucer-bench/target/release/volucer \
BIN_BASE=~/volucer-bench-old/target/release/stokehold \
ROUNDS=9 CONC=1,8,16,32 VARIANTS=new-req,new-nostat,baseline,rr \
  ENDPOINTS=/,/items bash scripts/ab-perf.sh

# The re-measurement: the layer is off by default now, so it is the ON arm that is pinned.
BIN=~/volucer-bench/target/release/volucer \
ROUNDS=5 CONC=1,8,16,32 VARIANTS=new-req,new-static,rr,franken \
  ENDPOINTS=/,/items bash scripts/ab-perf.sh
```

## How workers, opcache and concurrency interact

`bench.sh` and `ab-perf.sh` each hold the configuration fixed and vary the load. Neither
answers the two questions an operator setting up a host actually asks: **how many PHP
workers should this box run**, and **what is opcache worth**. `scripts/matrix.sh` runs that
grid — 5 arms × 4 worker counts × 2 opcache modes × 4 concurrency levels × 3 rounds — and
samples PSS and RSS of each arm's process tree at boot and after load, because the warm
model's speed is paid for in memory and that trade had not been put in one table before.

The published runs are `results/matrix/` (raw rows, memory samples, and the generated
tables) and `results/matrix85/`, which repeats the grid on PHP 8.5 with every arm on the same
interpreter — see [PHP 8.5, one interpreter for every arm](#php-85-one-interpreter-for-every-arm).
The numbers below are from the 8.3 run. Host: 12 cores, 3.9 GB, PHP 8.3.35 for everything
except FrankenPHP (its release binary embeds 8.5.11 — stated, not corrected, and closed by the
8.5 run), volucer 0.1.0, RoadRunner 2025.1.15, FrankenPHP 1.13.0, nginx 1.24.0. Every cell
proved its opcache mode from inside the running server rather than from its config file, and no
cell was skipped.

```bash
bash scripts/matrix.sh
python3 scripts/matrix-report.py ~/matrix-run/matrix.tsv ~/matrix-run/memory.tsv
```

### opcache is worth 1.02× warm and 10× cold

| opcache on / off, c=64 | w=12 | w=16 | w=20 | w=24 |
|---|---|---|---|---|
| volucer worker (warm) | 1.02× | 1.02× | 1.02× | 1.02× |
| RoadRunner worker (warm) | 1.01× | 1.03× | 1.01× | 1.04× |
| FrankenPHP worker (warm) | 1.02× | 1.03× | 1.03× | 1.04× |
| volucer `spawn_cgi` (cold) | 10.19× | 10.15× | 11.06× | 9.58× |
| nginx + php-fpm (cold) | 9.64× | 10.34× | 11.15× | **11.23×** |

**The deployment model decides whether opcache matters at all.** A warm worker compiles each
script once, when the process boots, and never again — so the bytecode cache buys 1–4%,
which is about the size of this host's round-to-round spread and is not a tuning decision. A
cold worker re-runs the front controller on every request, and without the cache every one
of those requests recompiles the same files: 10× slower. At w=24 the FPM pool falls from
9,046 rps to 806 — the same server, the same application, one ini flag.

For FPM the ratio also *grows* with the worker count (9.64× at w=12 to 11.23× at w=24),
which is the shape of the waste: more children compiling the same files at once buys no
throughput and costs more. volucer's `spawn_cgi` pool does not show the same monotonic
growth, so the effect there is a flat ~10× rather than an increasing one.

That is also why the opcache axis is not a tuning question for the warm arms: there is
nothing left to cache. It is a question about which model you are running.

### More workers do not make a resident worker faster

Throughput at c=64, opcache on:

| arm | w=12 | w=16 | w=20 | w=24 | peak |
|---|---|---|---|---|---|
| volucer worker | 23,118 | **23,508** | 23,449 | 22,938 | w=16 (+1.7%) |
| RoadRunner worker | 18,190 | 19,437 | 19,750 | **19,864** | w=24 (+9.2%) |
| FrankenPHP worker | **16,252** | 14,542 | 13,844 | 13,535 | w=12 (**−16.7%**) |
| volucer `spawn_cgi` | 7,574 | 6,764 | **7,648** | 7,253 | w=20 (+1.0%) |
| nginx + php-fpm | 7,698 | 8,376 | 8,933 | **9,046** | w=24 (+17.5%) |

One worker per core is already the ceiling for volucer: 12 workers reach 98% of the best
cell, and adding a second worker per core costs a little instead of gaining. That is the
c=32 plateau above reproduced at four worker counts — the server is not CPU-bound, so a
bigger pool queues more requests behind the same cores.

The two cold arms are the interesting pair. **FPM is the only arm that still gains from
more workers** (+17.5% from 12 to 24), because a cold child is idle between requests and a
bigger pool hides more of the per-request boot. volucer's `spawn_cgi` pool does not gain,
and its w=16 column is a reproducible dip rather than noise: 6,451 / 6,675 / 6,764 rps at
c=32/48/64 against 7,026 / 7,420 / 7,574 at w=12 and 7,049 / 7,484 / 7,648 at w=20, with
every round agreeing. The dip is measured here; what causes it is not, and it is recorded
rather than explained.

FrankenPHP is the one warm arm that gets *worse* with every worker added — 16,252 at 12
down to 13,535 at 24, a 17% loss — which is the queueing ceiling
[`results/frankenphp.md`](results/frankenphp.md) localised, reproduced on a newer binary
and a different host.

### At 64 concurrent clients the warm arms separate, and the cold ones fall behind

| c=64, opcache on, best worker count | rps | vs volucer worker |
|---|---|---|
| volucer worker (w=16) | **23,508** | — |
| RoadRunner worker (w=24) | 19,864 | 0.85× |
| FrankenPHP worker (w=12) | 16,252 | 0.69× |
| nginx + php-fpm (w=24) | 9,046 | 0.38× |
| volucer `spawn_cgi` (w=20) | 7,648 | 0.33× |

The ratio is not a constant: at c=16 the same five arms (w=12) read 15,916 / 15,229 /
15,946 / 6,524 / 5,531, so at low load volucer, RoadRunner and FrankenPHP are within 5% of
each other and only the two cold arms are far behind. The separation is produced by
concurrency, not by the server choice: from c=16 to c=64 volucer's lead grows to 1.26× over
RoadRunner, 1.42× over FrankenPHP and 3.01× over FPM. That is the same shape
[`results/frankenphp.md`](results/frankenphp.md) reports — the arm whose interpreter is
inside its own process is indistinguishable at c=1 and falls behind as load rises — with
RoadRunner showing a weaker version of it. Which server "wins" is a statement about a
concurrency level, not about a server.

### Memory: ~16 MB per warm worker, ~1–4 MB per cold one

Summed PSS over each arm's whole deployment after load, opcache on — nginx's own workers are
inside the FPM figure, because a deployment's footprint is the thing being compared and
volucer and FrankenPHP are their own web server:

| arm | w=12 | w=24 | marginal MB/worker |
|---|---|---|---|
| volucer worker | 227.5 | 418.5 | **15.9** |
| RoadRunner worker | 287.7 | 476.1 | 15.7 |
| volucer `spawn_cgi` | 226.8 | 412.8 | 15.5 |
| FrankenPHP worker | 132.6 | 151.7 | **1.6** |
| nginx + php-fpm | 53.7 | 68.6 | **1.2** |

**The speed and the footprint are the same decision.** A resident worker holds a booted
framework container — that is what makes it fast and that is what each one costs. A cold
child holds nothing between requests, so 24 FPM children fit in a third of the space
twelve resident workers occupy (68.6 MB against 227.5), each counted the same way.

Two cautions, because the wrong column here is very persuasive. **RSS says FPM uses 632 MB
at w=24 against its true 69 MB** — a shared page is charged once per process, so the same
opcache segment is counted 24 times. And **FrankenPHP's 1.6 MB per worker is not a fair
comparison with volucer's 15.9**: a thread shares the interpreter, a spawned process does
not, which is exactly the trade `results/frankenphp.md` describes from the other side.

The opcache axis moves memory too, in opposite directions. With opcache off, a warm worker's
boot footprint *drops* (187.6 → 151.8 MB at w=12) because there is no bytecode cache to
hold. A cold pool is the reverse after load: FPM at w=24 goes 40.6 → 128.1 MB PSS with
opcache off against 43.8 → 68.6 MB with it on, while its **RSS falls** (360 → 596 MB,
against 375 → 632 MB) because the shared opcache segment is no longer mapped at all.

The two columns disagree because they measure different things, and sampling each php-fpm
child on its own — `scripts/diag-fpm-memory.sh`, which reproduces this in about a minute —
says which to believe:

| php-fpm pool, w=24, after load | per-child PSS | per-child RSS | sum PSS | sum RSS |
|---|---|---|---|---|
| opcache on | 2.0 MB | ~23 MB | **49 MB** | 556 MB |
| opcache off | 4.5 MB | ~22 MB | **109 MB** | 530 MB |

With opcache on, most of each child's resident set is one shared segment and PSS charges it
once across all 24; with it off there is nothing to share, so nearly everything a child
touches is private and PSS sums to a larger total. **The honest figure more than doubles
when opcache is disabled, and RSS reports the opposite direction.** That is the same trap as
the FPM total above, one layer down: RSS rewards an arm for not mapping memory it needs.

#### Why FPM really does need less, and not just look like it

"53.7 MB for a whole web server plus twelve PHP processes" is low enough to be worth
disbelieving, so `diag-fpm-memory.sh` also reports summed **private** memory — the part of
each child's resident set that no other process maps. It is the one number that cannot be
flattered by how a total is divided up:

| php-fpm pool, w=16, after load | per-child PSS | sum PSS | sum RSS | **sum private** |
|---|---|---|---|---|
| opcache on | 2.4 MB | 39 MB | 374 MB | **20 MB** |
| opcache off | 4.8 MB | 77 MB | 354 MB | **62 MB** |

A drained php-fpm child is genuinely about 2 MB of its own, and the pool is genuinely about
20 MB of memory nobody else can have. The reason is not that php-fpm is magic but that it
**releases what it allocated**: the framework is booted, the page is rendered, and everything
that boot touched is freed before the child waits for the next request. A resident worker
keeps it, deliberately, because keeping it is what makes the warm arms 3.6× faster.

So the comparison is not "24 cheap children against 12 expensive workers" — it is
**20 MB of private memory that is thrown away and rebuilt on every request, against 240 MB
that is kept**. At 5.2 ms per request (opcache on, c=64) the rebuild is the cost of the
memory not being there; see the throughput table above for what that trade is worth.

The `fork()` numbers two sections down make the same point from the other side: the ~16 MB a
warm worker costs is the interpreter, not the container, so fork keeps the container for 1.8 MB
per worker. FPM reaches its 20 MB a different way — by keeping nothing.

### What the run does not claim

- **It is one host, one run.** Each cell is the median of three 5-second rounds; the
  min–max spread across rounds is printed beside every number and is generally under 2%,
  but a different core count moves every absolute figure.
- **The cold arms' tails are load spikes, not a steady state.** At c=64 the `spawn_cgi` p99
  is 67–107 ms against FPM's 9 ms, and its p50 is 5.8–6.4 ms against FPM's 6.4–7.1 — the
  median says the two cold arms cost about the same per request, and the tail says
  `spawn_cgi` occasionally makes one wait an order of magnitude longer. That is recorded
  rather than smoothed: a p50-only reading here would hide the difference a real deployment
  would feel.
- **wrk's thread count is fixed at 12, not set to the concurrency.** Every earlier harness
  here used `-t$c`, which makes c=64 put 64 busy client threads on 12 cores and lets the
  load generator's own scheduling into the tail (`diag-slots.sh`). Fixed threads keep the
  client's cost constant across arms and levels; the trade is that c=64's tail is the
  server's, measured with a client that is no longer scaling with it. That choice was worth
  **12–15% at low concurrency**, which the 8.5 run measures directly: see
  [the wrk thread count is a second variable](#the-wrk-thread-count-is-a-second-variable-and-it-is-worth-1215).
- **Two cells recorded a single socket timeout each** — both in the `spawn_cgi` opcache-OFF
  arm at the highest concurrency, where a request costs 15 ms and a 5-second window is long
  enough for one straggler. They are listed in the report's integrity table rather than
  silently averaged in, and they are 0.03% of those cells' requests; no cell lost a measured
  response to a `Non-2xx`, so no arm was seen shedding load.
- **FrankenPHP runs PHP 8.5.11 and every other arm 8.3.35** — in *this* run. That was the
  release binary's own interpreter and there is no 8.3 build of it. `results/matrix85/`
  re-runs the whole thing on 8.5 with every arm on the same interpreter, which removes the
  confound rather than caveating it; see
  [PHP 8.5, one interpreter for every arm](#php-85-one-interpreter-for-every-arm).

## PHP 8.5, one interpreter for every arm

The run above had a hole in it: FrankenPHP executes its **embedded** PHP, which was 8.5.11,
while the other four arms executed the distro's 8.3.35. Every cross-arm ratio therefore mixed
the server's effect with the interpreter's. `results/matrix85/` closes that hole by running
the same five arms with `PHP=/usr/bin/php8.5`, at the worker count the earlier run peaked on.

Two things had to be true before that run measured what it claimed:

**The interpreter under test has to be the one that loaded.** A stock `php8.5` on this host is
not the same program as a stock `php8.3`:

- it loads **xdebug 3.5.3 with `xdebug.mode=develop`**, i.e. instrumented execution, and
- it ships an **internal `psr` extension** that provides `Psr\Log\LoggerInterface` as an
  `UNtyped` interface. This repository's bench app implements the composer interface with
  typed signatures, so PHP rejects the mismatch and the application dies on a fatal
  declaration error before it answers anything.

Both are excluded by pointing `PHP_INI_SCAN_DIR` at a conf.d copy without `20-xdebug.ini` and
`15-psr.ini`, and `matrix.sh` now refuses to start if either is loaded — a debugger in a
benchmark measures the debugger, and a fatal error measures nothing. `meta.txt` records what
was actually loaded, per SAPI.

**FrankenPHP needs none of that.** Its embedded 8.5 is built without either extension
(`php8.5 xdebug=no psr=no`), which is exactly why the 8.3-era run could serve this app from a
PHP 8.5 arm while a distro PHP 8.5 could not.
`scripts/probe-franken-php.sh` asks the running server rather than trusting a version banner.

### The interpreter is worth about 2%, and that is the size of the noise

`/items`, w=16, median of three 5-second rounds. The 8.3 column is the same configuration
from the run above; both used `wrk -t12`. The delta is the whole curve, not one cell.

| arm | opcache | c=16 | c=32 | c=48 | c=64 | mean |
|---|---|---|---|---|---|---|
| volucer worker | on | −0.7% | +1.4% | +3.4% | **+3.5%** | +1.9% |
| volucer worker | off | −0.3% | +4.0% | **+3.5%** | +3.1% | +2.6% |
| volucer `spawn_cgi` | on | +2.8% | +3.0% | +2.1% | +1.3% | +2.3% |
| RoadRunner worker | on | +2.9% | +1.1% | +1.7% | +2.4% | +2.0% |
| **FrankenPHP worker** | on | −3.0% | −1.0% | −1.0% | −0.9% | **−1.5%** |
| nginx + php-fpm | on | −0.7% | −0.2% | +0.6% | −1.0% | −0.3% |
| nginx + php-fpm | off | −3.1% | −3.2% | −4.9% | −4.5% | **−3.9%** |

**FrankenPHP is the null control, and that is the most useful row in the table.** Its
interpreter did not change — the release binary embeds 8.5.11 in both runs — so anything it
"gained" or "lost" is host drift and run-to-run noise. It moved **−1.5% to +0.1%**. So the
noise floor of this whole matrix is roughly **±2%**, and any claim smaller than that is not a
claim.

With that floor, the honest reading is narrower than "8.5 is 3% faster":

- **volucer worker at c=48–64 gains ~3.5%**, outside the floor, and the gain grows with
  concurrency. At c=16–32 it is inside the noise.
- **RoadRunner and `spawn_cgi` sit at the floor's edge** (+2.0%, +2.3%) and cannot be called
  a win on this evidence.
- **php-fpm with opcache off is consistently *slower* on 8.5** (−3.9% mean, negative at every
  concurrency). That is the one direction the noise does not explain, and it is the coldest
  path in the matrix: compile everything, per request, with no bytecode cache.
- **Nothing reorders.** volucer worker still leads RoadRunner at every concurrency (1.09× at
  c=16, widening to 1.22× at c=64), and with opcache off the cold arms are still 31–36× behind
  the warm one at c=64. Both are far outside ±2%.

The opcache axis is unchanged too — at c=64 it is **1.02–1.03×** for the warm arms,
**10.3×** for `spawn_cgi` and **10.7×** for php-fpm, against 1.01–1.04× / 9.58–11.06× /
9.64–11.23× on 8.3. Every one of those is far outside the noise floor.

### The wrk thread count is a second variable, and it is worth 12–15%

Every harness in this repository before this one — including the run above — either used
`-t$c` or fixed the thread count at 12. Both are defensible and they answer different
questions, so the 8.5 run measures both in the same cells, as a `threads` column in
`results/matrix85/matrix.tsv`. `THREADS_LIST=tc,t12` selects it; `tc` means `-t$conc`.

| volucer worker, opcache on | `-t12` | `-t$c` | change |
|---|---|---|---|
| c=16 | 15,770 | 18,087 | **+14.7%** |
| c=32 | 22,076 | 23,674 | +7.2% |
| c=48 | 24,035 | 23,792 | −1.0% |
| c=64 | 24,336 | 24,307 | −0.1% |

**`-t$c` is not free and it is not a detail.** At c=16 it is worth 15% of throughput, because
16 client threads schedule better on 12 cores than 12 do; by c=48 the two converge, and the
convergence is the useful part — it means the fixed-12 numbers at the top of the curve were
**client-limited at low concurrency and correct at high concurrency**, which is the direction
that flatters the server least. The p99s tell the same story: `-t$c` produces a slightly
*worse* tail at every level (1.43 → 1.73 ms at c=16, 7.28 → 8.11 ms at c=64), because 64 busy
client threads on 12 cores compete with the server for the same cores. Neither setting is
"right"; a comparison should state which one it held constant, and none of the earlier ones did.

## Why a resident worker costs 16 MB — and what fork() would change

The memory table says a warm worker costs **~16 MB of PSS each**, and that this is what makes
volucer's 24 workers cost 418 MB while 24 php-fpm children cost 69. The natural reading is
"then boot once and fork", which is exactly what php-fpm does and why its per-worker figure is
1.2 MB. `scripts/fork-demo.php` measures whether that transfer works for this application
instead of assuming it does, by running both process models on the same host, in one script,
in one run:

```
php scripts/fork-demo.php          # CHILDREN=16 REQUESTS=50
```

| 16 workers, opcache on | exec (what volucer does) | fork (what php-fpm does) |
|---|---|---|
| summed PSS | 264.8 MB | **28.4 MB** |
| summed private | 240.1 MB | **11.9 MB** |
| per worker | 16.6 MB | **1.8 MB** |
| children rendering the page | 16 / 16 | 16 / 16 |
| opcache scripts per child | 80 | 81 |

**Forking works, and it is the whole difference.** −89% of PSS and −95% of private memory for
a *warm* worker that keeps its booted container, and every forked child served the same page
with the same opcache population as the parent — the cache survives because it is a shared
segment mapped before the fork, so nothing has to be rebuilt.

Splitting the exec column with `OPCACHE=off` says what the 16.5 MB is actually made of:

| 16 workers | PSS | per worker | of which opcache |
|---|---|---|---|
| exec, opcache on | 264.6 MB | 16.5 MB | |
| exec, opcache off | 214.3 MB | 13.4 MB | |
| **exec opcache difference** | **50.3 MB** | | **3.1 MB** |
| fork, one boot | 28.4 MB | 1.8 MB | shared, not cloned |

So the ~16 MB is **13.4 MB of interpreter plus 3.1 MB of OPcache**, and the OPcache part is
paid **sixteen times** — 50 MB — for a segment that would have been sufficient once. That is
the structural half of the argument, and it is measurable on Linux: an OPcache segment is
`mmap`'d, and a process that did not `fork()` cannot attach to one somebody else created, so
every `exec` compiles and maps its own.

`scripts/diag-opcache-sharing.sh` shows the same thing from the other side, and the way the
shared column *scales* is the proof: if the workers shared one segment, summing their shared
pages would stay flat as children are added. Instead it grows in step with them, because each
process has its own mapping.

| children | PSS on | PSS off | opcache per child | summed shared pages |
|---|---|---|---|---|
| 4 | 79.0 MB | 66.3 MB | **3.15 MB** | 129 MB |
| 8 | 142.2 MB | 117.4 MB | **3.10 MB** | 258 MB |

APCu is cloned the same way. None of this is a volucer defect; it is why preforking is the
standard answer, and it is why the fork column above is smaller than the exec one by more than
a container's worth of memory.

The exec column also validates the matrix against itself. Those 16 children cost **264.6 MB**,
and the matrix measured volucer-worker at w=16 after load at **291.5 MB** for the whole
deployment — a 26.9 MB difference that is the Rust server process the children sit behind. Two
independent scripts, counting the same thing two different ways, agree to within 1%. The
fork column's 1.8 MB per worker is therefore comparable with the matrix's 15.9 MB marginal
figure, not an artefact of a different measurement.

The catch is not memory, and it is the reason `spawn_cgi` looks the way it does. `pool.rs`
records it at the point where the decision was already made once: `PHP_FCGI_CHILDREN` relies
on `fork()`, a `php-cgi` started with `-b` is a parent that spawns 20 children by default, and
the pool deliberately sets it to `0` because **a forked child cannot be counted, recycled, or
killed independently of its parent** — "the slot looks idle while 20 requests run". Adopting
fork at the worker level would buy the memory above and pay for it in exactly those three
properties, plus the one this demo can only hint at: the children inherited an already-open
SQLite handle and all returned the right bytes, but 16 processes sharing one `PDO` connection's
file state is a correctness question that a single-page benchmark does not answer.

So: **further memory savings are available, they are large, and they are not free.** Nothing
here claims volucer should fork; it measures what fork would be worth and names what it would
cost.

### The "forking worker": measured, and it needs a server change

The natural way to collect that 89% is to let the *worker* fork: start one PHP process, boot
once, have it fork N children and stay resident only to replace them — and report the pids so
the server can adopt them. `scripts/fork-worker-demo.sh` runs exactly that against real volucer
(`workers = 1`, `VOLUCER_WORKER_FORK=1`, children reporting their own pids), because the shape
of the saving is only useful if the server can still do the four things it does to a worker it
spawned itself.

| configuration, c=16 | rps | p50 | non-2xx |
|---|---|---|---|
| 1 process, no fork (the ordinary warm worker) | 3,225 | 4.8 ms | 0 |
| **4 forked children, pipe transport** | **30** | **500 ms** | **90–150 / 150** |
| 4 forked children, socket transport | 30 | 504 ms | 14 |

Four forked children should be roughly four times one process — about 12,000 rps. They deliver
thirty, and every request times out. **The children cannot share one worker channel**, and the
reason is the same `fork()` semantics that make the memory saving work in the first place:

- `fork()` copies the *file descriptor table*, not the open files. Parent and children end up
  with separate fds pointing at **one shared file description** — one pipe, one buffer, one
  read position. N children then race over a single frame stream, each taking a fragment of
  somebody else's request. That is what the 500 ms timeouts are: a request whose frame was
  split between two readers and can no longer be parsed.
- The socket transport does not rescue it either, for a different reason: the server binds a
  listener, and `accept_with_deadline` accepts **one** connection per spawned worker
  (`handshake.rs`). A child that connects for itself is not a worker the pool has a slot for.

So "give the children to volucer" is not a change the PHP side can make alone. The pool is
built as **one spawned process per slot** — `for _ in 0..count { boot(...) }` in
`worker_pool/mod.rs` — with one channel, one `try_wait` and one `child.kill()` per slot. A
forking master breaks all four:

| what the pool does to a worker | with a forked child |
|---|---|
| route a request | one channel per slot; children share one fd |
| notice it died (`child.try_wait()`) | watches the **master**, never the children |
| recycle it (`max_requests`, `memory_limit_mb`) | counts at the master, which serves nothing |
| kill it (`child.kill()`) | kills the **master**; children keep the pipes |

Measured: killing one grandchild left volucer unaware — but the master **did** replace it
within a second, so the self-healing half of the design works, just on the wrong side of the
process boundary.

### One process group does not fix this — but it fixes something else

The question is the right one to ask, and the answer splits cleanly in two.

**It cannot help routing or health.** A process group is a signal-addressing mechanism; it
carries no request stream and no exit status. `try_wait()` on a grandchild is impossible from
the server's side whatever the grouping, because `wait()` belongs to the parent.

**It does fix teardown, and that half is a real defect today.** The demo's children turn out
to *already* be in the master's own process group — `configure_command` calls
`process_group(0)`, so the master gets a new group and its forked children inherit it (verified:
master and all children report the same `PGID`). And `lifecycle.rs`'s Unix section says the
mechanism is "a process group, so a single signal reaches the whole tree, and
`PR_SET_PDEATHSIG` where it is available". But **nothing sends a group signal, and
`PR_SET_PDEATHSIG` is never set** — `killpg` and `pre_exec` appear nowhere in the crates. The
Unix guard is a comment, not code: `LifecycleGuard::adopt` is a no-op on Unix, and every kill
path is `child.kill()`, which signals one pid.

That is measurable and it is not specific to fork. SIGKILL the server and a plain forked
master survives, reparented to init:

```
PHP processes before the stop: 5, after: 1
  2553036   1  /usr/bin/php .../fork-worker-demo.php
```

The children died (their pipes reached end-of-file); the master did not, because nothing ever
signalled it. A group signal — or the `PR_SET_PDEATHSIG` the module claims — would have. That
is worth fixing on its own merits, for `spawn_cgi` too: `pool.rs` puts each `php-cgi` slot in
its own group, and `php-cgi` can spawn 20 children under it if `PHP_FCGI_CHILDREN` ever leaks
in from the environment.

### What a workable design would have to change

Ranked by how much of the measured saving survives contact with the server's invariants:

1. **Children accept on a shared listener (socket transport).** The server keeps one listening
   socket, and every forked child calls `accept()` on it; the kernel hands each connection to
   exactly one of them. No PHP process is on the request path, so the throughput of the warm
   arm is preserved, and the memory saving is the fork saving. The server change is that a
   backend may accept **N** connections for **one** configured worker, and it still needs a
   liveness answer for the factory (the master), which serves nothing.
2. **The master becomes a dispatcher.** It keeps one channel and forwards frames to children
   over private `socketpair`s. Smallest server change — `workers = 1` stays literally true —
   but it puts a PHP process in the hot path of every request, which is the cost this whole
   repository exists to measure. It would need its own A/B before anyone believed it was cheap.
3. **The server treats each child as a slot** (children connect back individually under
   `workers = N`). Conceptually the cleanest: the pool's existing one-process-per-slot model is
   untouched, and `try_wait`/`kill` keep working. It needs the children to be spawned *by* the
   server to be waitable — which reintroduces the exec cost unless the fork happens after the
   server's own spawn, i.e. exactly the handshake the proposal describes, plus a protocol
   message that says "these pids are yours now". That message has to carry the fds, or the
   channels have to be re-established per child.

Option 3 is what the proposal describes, and it is the one that keeps every existing invariant.
Its blocking requirement is not the fork — it is that `Child::try_wait` cannot be pointed at a
process somebody else spawned, so either the children reconnect on their own channels (server
change) or the master owns health and the server owns only the group (teardown change plus a
reconnect protocol).

Until one of those lands, `fork()` in a worker is a memory win that cannot be routed to. Which
is the useful outcome of measuring it: the saving is real, and the thing standing in the way is
a single-process-per-slot assumption, not the memory model.

### Before building any of it: the cheap order

Two facts from the measurements above change which step comes first.

**The `external` backend already is the attached model.** volucer has no relay/attach mode for
its own protocol — `BackendConfig` documents exactly three shapes plus `Upstream`, and says the
fourth (`spawn_fpm`) was *removed* rather than built, because "`external` attaches to the php-fpm
that systemd already supervises, which is the better version of the same feature". `External`
is FastCGI over a socket, so a PHP prefork supervisor that speaks FastCGI can be wired to
volucer **today, with no server change at all** — nginx in front, or volucer in front of it, is
a deployment choice. That makes the fork model testable end-to-end before any protocol work is
committed to.

**The win over `external` is the FastCGI hop, not the memory.** Both models fork and both share
one OPcache; the difference is that `external` pays a request round trip through nginx or
straight into php-fpm, while the `Worker` protocol is a warm pipe to a process that already holds
the container. On this host at c=64 that is 24,336 rps against 8,292 — so a forked `Worker`
backend is worth building only if it keeps the warm pipe, which is precisely what options 1–3
above are about.

So the order is:

1. **Check what the matrix already says is cheap.** `opcache.enable_cli` is on in every warm arm
   here (a CLI worker that leaves it at the distro default of `0` compiles per request), and
   `opcache.preload` is not used. Each exec'd worker pays the preload itself, so preload is
   worth checking *before* forking — it can move the same 3.1 MB per worker rather than the
   model.
2. **Measure recycled-worker cost, not just steady state.** `max_requests` is `0` in every arm
   here. Forking makes recycling 1–3 ms instead of a boot, which is a different argument for
   fork than memory — and it is measurable with this harness by setting `max_requests` and
   comparing throughput, which has not been done yet.
3. **Then the PoC, and only in the shape that keeps the warm pipe** (option 1 or 3 above).
   The success criterion from the measurements is concrete: summed PSS down ≥30% at 8 workers,
   worker start latency down >90%, throughput within the ±2% noise floor of the exec baseline.

Two hazards the measurements already rule in or out, so they do not have to be rediscovered:
the children **do** inherit one shared file description per fd, so a forked child must not share
the master's channel (measured: 30 rps); and a forked master **does** survive its server being
SIGKILLed, reparented to init, because nothing signals the group (measured: PPID 1).

### Does fork need a unix socket? Yes — and the reason is measured, not assumed

Three things had to be separated, because they are easy to conflate.

**The 24,336 rps figure is the plain pipe.** It is `volucer-worker`, w=16, opcache on, c=64,
`wrk -t12`, on the run whose `meta.txt` records no `transport` setting at all — and
`WorkerTransport::default()` is `Pipe` off Windows. No socket is involved anywhere in that
number. The `spawn_cgi` arm is the unix-socket one and it reached 6,855.

**Volucer's own socket transport cannot enable fork.** Even with one forked child it fails,
and the reason is not the protocol: the pool binds a listener and
`accept_with_deadline` accepts **one** connection per spawned worker, so a child that connects
for itself is a worker with no slot. Measured at 1, 2 and 4 children: 30 rps each, with
`MAX_SLOT_WAIT` (500 ms) as the latency.

**A TCP socket is also 100× worse than a pipe, and that is a bug worth fixing on its own.**
Same single process, c=1:

| transport | rps |
|---|---|
| pipe | 2,334 |
| socket | 24 |

The cause is not congestion control in general but a specific interaction. The PHP SDK opens the
socket with `stream_socket_client` and **never sets `TCP_NODELAY`** (`socket_set_option` appears
nowhere in it), while the server does set it on its side. The protocol writes a header and a
payload as two separate small writes, so Nagle holds the second one until the first is
acknowledged, and TCP delays that acknowledgement by up to 40 ms. Two processes doing it to each
other deadlock into one stall per request:

| protocol-shaped ping-pong | per request |
|---|---|
| TCP, Nagle on (what the SDK does now) | **38.96 ms** |
| TCP, `TCP_NODELAY` on the client | **0.06 ms** |
| AF_UNIX socket | 0.06 ms |

So the socket transport is currently unusable for throughput for a reason unrelated to its
design, and one line in the SDK hides it. That is worth fixing before any fork work, because it
makes the socket transport a viable second option rather than a broken one.

**Therefore: yes, a unix socket is what makes fork work — `AF_UNIX`, not TCP, and as a relay the
children connect to rather than as volucer's worker transport.** That is option 1 above, and the
mechanism was checked directly: a `fork()`ed child inherits the **listening** fd automatically —
an fd is precisely what `fork()` shares — so N children can each call `accept()` on one listener
with no fd passing, no `SCM_RIGHTS` and no `SO_REUSEPORT`.

| 4 children, one inherited `unix://` listener, 40 connections | result |
|---|---|
| served | 40 / 40 |
| per connection | 0.06 ms |
| children that served | **3 of 4** |

The last row is the caveat: shared `accept()` is correct but **not fair** — a child that loops
straight back into `accept()` tends to win the race repeatedly, which is the classic thundering
herd. It does not threaten the design (the listener balances, the relay does not need each child
to get an equal share to be fast), but it does mean a forked relay needs a deliberate
distribution story rather than assuming the kernel divides evenly.

`scripts/fork-relay.php` runs that design at load, so the claim is demonstrated rather than
argued. It boots once, binds one `unix://` listener, forks N children that each `accept()` on
it, and speaks plain HTTP so a load generator can drive it directly:

| 8 children, one inherited `unix://` listener | result |
|---|---|
| 3,000 sequential requests | **3,000 correct**, 0.211 ms each (4,742 req/s, one client) |
| master boot before forking | 6.1 ms |
| master + 8 children, while serving | **32.7 MB** summed PSS |
| per child, while serving | **~3.3 MB** |

Two things that number settles. First, a forked child keeps the warm worker's speed: 0.211 ms
per request is the same order as the pipe arm, not the 5–7 ms of a cold CGI. Second, the
footprint is the fork family's real cost *while serving*, not while idle — and it is in the same
range as php-fpm's, for a worker that no longer boots per request.

The 4,742 req/s is one synchronous client and is a floor, not a ceiling: driving the relay
through a `socat` bridge reached 9,352 req/s, but that path adds a TCP hop and its own
`fork` per connection, so it measures `socat` as much as the relay. What the relay needs next is
a load generator that speaks `unix://` directly — Ubuntu's `wrk` 4.1.0 does not have
`--unix-socket` — which is why the in-process number above is the honest one to quote.

## What the three fixes are worth, measured

The fork discussion left three concrete defects, each with a number attached. All three are fixed
in `volucer` and the PHP SDK, and re-measured here on the same host, the same page and the same
published configuration (`w = 16`, `c = 64`, `wrk -t12`, opcache on). `scripts/verify-fixes.sh`
reproduces the first two and the `attach` plumbing end to end.

### 1. `TCP_NODELAY` in the PHP SDK: the socket transport was 100x slow

The SDK opened its socket with `stream_socket_client` and never disabled Nagle, while the server
did. The protocol writes a header and a payload as two small writes and is a strict ping-pong, so
Nagle held the second write until the peer acknowledged the first - and a delayed ACK is up to
40 ms away. Every request paid the timer.

One option, in the connect context (`tcp_nodelay`, which PHP applies with
`setsockopt(SOL_TCP, TCP_NODELAY, 1)` during the connect - verified with `strace`, not assumed):

| transport | before | after |
|---|---|---|
| `socket` (the same 16 workers, same page) | **24 rps** | **22,257 rps** |
| `pipe`, for reference | 23,740 rps | 23,740 rps |

The socket transport is 6% behind the pipe rather than 100x behind it, which is the connection's
syscall cost. That makes it a second option rather than a broken one - and it is the default on
Windows, where the pipe is the slow one.

### 2. The Unix lifecycle guard existed only as a comment

`lifecycle.rs` described a process group and `PR_SET_PDEATHSIG` and implemented neither: `killpg`
appeared nowhere, every kill was `Child::kill` on one pid, and `LifecycleGuard::adopt` was a no-op
on Unix. The consequence is the hazard the file exists for - a `SIGKILL`ed or OOM-killed server
leaves its `php-cgi` and worker children running, holding their ports, with nothing that knows
their configuration.

Both halves are now real, and they cover different failures. The **process group** is what a
deliberate kill targets, so `lifecycle::kill` reaches a worker *and* anything it forked - which is
what makes a prefork supervisor's children die with it. `PR_SET_PDEATHSIG` covers the case a group
cannot: it is installed in the child's `pre_exec` hook, so the kernel delivers `SIGKILL` when the
parent dies **without getting a turn**, which is exactly what `SIGKILL` on the server is.

| 4 workers, server `SIGKILL`ed | children still running 1 s later |
|---|---|
| before | 4 - reparented to init, still bound |
| after | **0** |

### 3. `attach`: the fork model, with the warm pipe kept

The fork saving is real (~89% less memory for the same worker count) but a server cannot collect
it by spawning: an `exec`ed process cannot attach to an existing OPcache segment on Linux, and a
PHP process cannot hand a file descriptor over, so the side that owns the socket has to be the
side that owns the fork. `kind = "attach"` is that shape - volucer **dials** a `unix:` relay a
supervisor listens on, and does not start a process at all.

`worker.php --prefork unix:/run/app/workers.sock` is the supervisor: boot once, accept in the
master, fork per connection. Accepting in the master rather than in every child is deliberate:
the kernel wakes one waiter per connection and does not do it fairly, so N children sharing one
listener can leave one holding two connections and another none - a slot whose connection nobody
is reading.

Same configuration, alternating runs, three each:

| | rps | PSS before load | PSS after 10 s at c=64 |
|---|---|---|---|
| `worker`, 16 `exec`ed processes | 23,937 / 24,228 / 24,143 | 263 MB | 314 MB |
| `attach`, supervisor + 16 children | **25,322 / 25,981 / 25,585** | **48 MB** | **69 MB** |

**263 MB against 48 MB, for the same 16 processes doing the same work, at no throughput cost** -
the `attach` arm is actually 5% faster, because a unix socket write is cheaper than a pipe write.
Summed RSS cannot see this: it counts every shared page once per child and reports 758 MB against
314 MB, which understates the saving. PSS splits a shared page between its mappers, so summing it
is what the machine holds.

What that does **not** mean is that `attach` should replace `worker`. It costs a socket per slot
and a supervisor the operator has to run and reload; the 5% is inside the noise of a 12-core VM
under wrk, and `worker` needs no second process. It means the fork model is now reachable for
deployments that want the memory back, without giving up the warm pipe the way `spawn_cgi` does -
8,292 rps there against 25,585 here.

### The cheap order, and what is still open

The order this was built in was deliberate: the SDK fix is one line and unblocks a transport; the
lifecycle fix is required for `spawn_cgi` whether or not anyone forks; `attach` is the smallest
server change that makes the fork real; and fair `accept()` distribution stops mattering once the
master owns the accept.

Still unmeasured, and the honest next question: **the cost of recycling**. Every arm here runs
`max_requests = 0`, so nothing has measured what a worker's replacement costs - and for a forked
pool it should be a `connect` and a handshake rather than a framework boot, which is the argument
that would make aggressive recycling cheap enough to bound a leak. `attach` supports
`max_requests` for exactly that experiment.

## Reproducing

```bash
composer install
php seed.php
bash scripts/bench.sh
```

`composer install`, not `composer update`, and `composer.lock` is **tracked** here. That is
deliberate, and it is the opposite of a library's convention: the lock is an input to the
measurement. Eleven dependencies are floating ranges — including `spiral/roadrunner`, which *is*
the RoadRunner arm — so an unlocked `composer install` a month from now would benchmark a
different RoadRunner against the same volucer and quietly produce an incomparable number. The
lock fixes every one of them; the three `sailantis/*` packages are pinned by commit ref in
`composer.json` itself. If a run ever needs a newer RoadRunner, move the lock on purpose and say
so in the results, rather than letting `composer update` do it silently.

`composer validate --check-lock` reports the lock as current with the committed `composer.json`,
and its `content-hash` was regenerated with the same no-flags `json_encode` Composer itself uses.

`bench.sh` needs `wrk`, `php-cgi`, and — for the FPM arm — `nginx`, `php-fpm` and
passwordless `sudo` (it writes one pool file and one vhost, both named
`bench-volucer`, and removes them afterwards). Missing pieces skip their arms
with a reason rather than failing the run.

The FrankenPHP arm is not part of `bench.sh`; it runs in the interleaved warm-arm pass
(`scripts/ab-perf.sh`) and needs only the release binary at `~/bin/frankenphp` (`FP`
overrides the path). It is self-contained — there is nothing to build and no Go
toolchain required. See [results/frankenphp.md](results/frankenphp.md).

Useful knobs:

```bash
ARMS=P,T,U      bash scripts/bench.sh    # a subset
CONC=1,4,8,16,32 REPEAT=3 bash scripts/bench.sh
ENDPOINTS=/items  bash scripts/bench.sh  # the ORM page only
SKIP_FPM=1       bash scripts/bench.sh
CROSSOVER=1 CROSS_CONC=1,4,8,16 bash scripts/bench.sh
```

The configuration matrix is a separate pass, and it needs nothing `bench.sh` does not —
in particular no sudo: php-fpm is started against a generated pool and nginx against a
private prefix, so the host's own services are never reloaded.

```bash
bash scripts/matrix.sh                     # 40 configurations, ~70 minutes on 12 cores
ARMS=fpm WORKERS_LIST=12,24 bash scripts/matrix.sh   # a subset
python3 scripts/matrix-report.py ~/matrix-run/matrix.tsv ~/matrix-run/memory.tsv
```

Sweeping the client as well, and running the whole grid on PHP 8.5 with one interpreter
for every arm (`results/matrix85/`) — `INI_SCAN_DIR` is what keeps xdebug and the internal
`psr` extension out of the measurement, and `meta.txt` records what actually loaded:

```bash
THREADS_LIST=tc,t12 bash scripts/matrix.sh            # -t$conc vs -t12, same cells

PHP=/usr/bin/php8.5 PHP_CGI=/usr/bin/php-cgi8.5 PHP_FPM=/usr/sbin/php-fpm8.5 \
INI_SCAN_DIR=$HOME/php85-clean/conf.d WORKERS_LIST=16 \
THREADS_LIST=tc,t12 RUNDIR=$HOME/matrix85 bash scripts/matrix.sh
```

The two memory questions have their own short scripts, neither needing sudo:

```bash
WORKERS=16 CONC=64 bash scripts/diag-fpm-memory.sh    # PSS vs RSS vs private, per child
CHILDREN=16 php scripts/fork-demo.php                 # exec vs fork, one run, one host
CHILDREN=16 OPCACHE=off php scripts/fork-demo.php     # ... split into cache vs interpreter
CHILDREN=8 bash scripts/diag-opcache-sharing.sh       # does each exec'd worker clone it?
bash scripts/probe-franken-php.sh                     # which PHP does FrankenPHP execute?

CHILDREN=4 bash scripts/fork-worker-demo.sh           # a worker that forks, against volucer
TRANSPORT=socket CHILDREN=1 bash scripts/fork-worker-demo.sh   # the TCP transport's 39 ms stall
STOP=kill CHILDREN=4 bash scripts/fork-worker-demo.sh # what SIGKILLing the server leaves

CHILDREN=8 php scripts/fork-relay.php                 # the recommended design, at load
bash scripts/verify-fixes.sh                          # all three fixes, end to end
# then, with a load generator that speaks unix:// (Ubuntu's wrk 4.1.0 does not):
#   wrk -t12 -c64 -d5s --latency --unix-socket /tmp/volucer-relay.sock http://localhost/items
```

## Four measurements, four questions

The repository runs four passes, and reading the wrong one is the mistake this
project made for several weeks:

| pass | holds concurrency at | answers |
|---|---|---|
| `wrk` sweep | the slot count (12) | how many requests per second can this host push |
| `latency.php` | 1 | what does one request cost, with nothing to overlap it |
| `crossover.php` | a range, 1..16 | at what load does the model advantage disappear |
| `diag-split.sh` / `diag-checksum.sh` | 32 | whose CPU is a request spending — the server's or PHP's |
| `diag-slots.sh` | 32, with the thread count varied | is the tail the pool's queueing or the load generator's |
| `diag-slots.sh` (A/B mode) | 24 and 32, every variant inside one round | did the pool fix really buy what a blocked run said |
| `ab-perf.sh` | 1..32, every arm inside one round, order rotated | what does each warm server do as the load rises — and where is the ceiling |
| `matrix.sh` | 16, 32, 48, 64 at 12/16/20/24 workers, opcache on and off | how many workers should this host run, and what is opcache worth — with the memory each configuration costs |

They disagree, and the first two are both right. A 12-slot sweep overlaps every
request's framework boot with eleven other requests, so the boot vanishes from the
aggregate rate; a single request gets no such help. The same pair of servers reads
as **2.15x** and **2.02x** depending on which pass is asked. The crossover pass
measures the middle and finds the advantage flat at ~2.0x from concurrency 1 to 16
— it does not cross over within the range this host can generate load for.

The fourth pass exists because the third one left a discrepancy it could not
explain: volucer's warm arm sat ~10% behind RoadRunner's on *every* endpoint,
while running the same application through the same model. Wall clock cannot
localise that — both servers report the same latency and the same rps — but CPU
can, because the total is the sum of two halves. `diag-split.sh` attributes CPU
per request across the arm's process tree (walked up the PPID chain, not matched on
process name) and showed the whole gap was in volucer's own server process:
413 µs against 309 µs, with the two totals agreeing to 1%. `diag-profile.sh` then
named three functions, each of which made a full pass over the response body per
request, and fixing them took the front-end from 413 µs to 137 µs — now cheaper
than RoadRunner's 153 µs, and enough to put volucer ahead end to end.

That last claim is the one worth re-checking, and a **fifth pass exists to check it**.
A blocked sweep measures one arm at a time, so a host that drifts over twenty minutes
charges that drift to whichever arm ran last. `ab-perf.sh` measures every variant
inside the same round with the starting order rotated, so the estimator is a
within-round ratio and the spread across rounds is the error bar. It re-ran the
question that started this section — see "Is the lead still there?" below.

The third pass exists because of a harness bug worth recording: the first version
drove N handles from one process with `curl_multi` and reported concurrency 2 as
*exactly* 2x the latency of concurrency 1, on three unrelated servers. That is the
client, not the servers — `curl_multi_select($multi, 0.05)` takes seconds, so its
retry floor was 50 ms. The current version runs N processes, each using the same
blocking loop `latency.php` uses, and agrees with it to 0.1% at concurrency 1.

**The lesson from the fourth pass, which the other three could not teach:** two
numbers agreeing to 10% is not evidence that either is right. It took attributing
CPU, rather than measuring wall time more carefully, to find a 3x cost difference
hidden inside a 10% throughput difference.

The fifth pass exists because the fourth one localises a cost to a *process* and the
question that followed was about a *mechanism*. The tail in "The one cell RoadRunner
wins" could have been the pool's queueing or the load generator's own thread
scheduling — both live in a process, both cost CPU, and `diag-split.sh` cannot tell
them apart because it attributes CPU rather than time waited. `diag-slots.sh` holds
concurrency fixed and varies only `wrk`'s thread count, which changes nothing on the
server side, and reads the pool's own wait histogram from the server's shutdown line.
The pool's answer settled it: the tail is the pool's, and the client is innocent.

## Is the lead still there? — yes, and it is one function

This was asked because five committed sweeps compared against each other say the
answer might be no: the lead read 1.20x in one sweep and 1.09x in the next one, which
ran **identical warm code**, and the sweep after that read ~3% below its predecessor in
every cell. Comparing sweeps cannot settle it — in the sweep that looked like a
regression, *every* arm fell, including RoadRunner and nginx + php-fpm, which none of
the intervening commits touch. That is the host, not volucer.

So four variants were measured **inside the same round**, with the starting order
rotated by round, on an idle host: the current build; the current build with the
per-frame checksum switched off; the current build with **only** `crc32c` reverted to
the hand-written bit-by-bit loop it replaced; and RoadRunner as a control that shares
no code with any of them. Seven rounds × 2 endpoints × 3 concurrencies = **168
measured cells, none failed**.

| ratio, median over 7 rounds | `/` c=8 | `/` c=16 | `/` c=32 | `/items` c=8 | `/items` c=16 | `/items` c=32 |
|---|---|---|---|---|---|---|
| **`crc32c` fix** (current / reverted) | **+11.8%** | **+11.4%** | **+16.3%** | **+10.2%** | **+12.1%** | **+13.7%** |
| checksum switched off | +2.0% | +2.9% | +2.5% | +3.0% | +2.7% | +2.8% |
| current build vs RoadRunner | +18.0% | +4.6% | +4.2% | +3.3% | **−1.7%** | +7.0% |
| **reverted build vs RoadRunner** | **+5.3%** | **−6.5%** | **−9.1%** | **−5.8%** | **−12.9%** | **−6.2%** |

The first row is positive in **all 42 paired cells**; the last row is negative in all six
cells of every round. So the effect is not merely still there — **it is the whole lead**.
Without the fix the build is behind RoadRunner everywhere, by 5.8–12.9%. With it, it is
ahead almost everywhere.

The revert is targeted rather than an old checkout, and that is what makes the number mean
something: building the commit *before* the fix would have bundled the FastCGI parser
de-allocation and the single-pass response parser along with it, isolating nothing. Only
`header::crc32c` was restored, both binaries return **byte-identical** bodies for both
endpoints, and the test that pins the checksum to its standard check value still passes on
the reverted tree.

**Which side pays is the part worth naming**, because it is where the earlier estimate went
wrong. `crc32c` is hashed **twice** per response: once by the PHP worker writing the frame,
once by the server reading it. Measured per request on `/items`:

| build | c | server µs | PHP µs | total µs |
|---|---|---|---|---|
| reverted (bit-by-bit) | 32 | **184** | 287 | 471 |
| current (hardware CRC32) | 32 | **125** | 283 | 408 |
| current, checksum off | 32 | **121** | 281 | 402 |

The fix removes **59 µs of server CPU per request (−32%)** and leaves the PHP column alone,
because the worker's hash was already hardware-accelerated. The earlier estimate that called
the checksum knob "0.26%" timed only the Rust-side encoding and therefore priced half of it;
measured end to end the knob is worth ~6 µs per request (~1.5%). Its throughput median is
positive but its seven-round spread crosses 1.00 in four of six cells, so read it as a small,
real, now-measured saving — and note the reason it stays on: the checksum's value is integrity,
and 3% is not a reason to turn off a corruption check.

Raw rows are committed — `results/ab-perf.tsv` and `results/cpu-per-request.tsv` — and both
passes reproduce with `scripts/ab-perf.sh` and `scripts/diag-checksum.sh`.

### The one cell RoadRunner wins is not a crossover, but the tail is real

The table above has a single cell where RoadRunner is ahead — `/items` at c=16, −1.7% — and the
tempting reading is slot exhaustion, because volucer's pool has 12 slots and 16 is the first
concurrency above it. A denser sweep says no: at c=12, 14, 16, 18, 20, 24 the lead is **+1.3%,
+1.1%, −1.1%, −1.3%, −0.4%, +3.0%**, with the per-round spread crossing 1.00 at four of the six
levels. There is no threshold and no bend; there is a ~1% deficit sitting somewhere between
c=16 and c=20, which is about 200 rps out of 18,000. Per-request CPU confirms it — volucer's
server cost per request is **flat at 121–126 µs from c=8 to c=32**, so nothing changes at 16 for
it to cross over at.

What the denser sweep *did* find is a tail that diverges while the median does not:

| concurrency | volucer p99 | RoadRunner p99 |
|---|---|---|
| c=12 | 1,640 µs | 1,760 µs |
| c=16 | 3,470 µs | 2,105 µs |
| c=20 | 6,770 µs | 2,415 µs |
| c=24 | 10,425 µs | 2,690 µs |

RoadRunner's tail is flat above its slot count — what a pool with a queue looks like.
Volucer's grows with offered load while its **p50 stays better** than RoadRunner's at every
level. Growing p99 with an improving median is queueing, not slowness: the requests are not
served slower, they wait longer before being served.

The suspected cause was in `pick_slot`: it advances a cursor and then takes each candidate
slot's mutex until one reports available, where "available" means the worker is *healthy*, not
that the slot is *free* — and the mutex is then held across the whole request.

**That was a hypothesis. It has since been measured, and it holds.** The pool now times every
request from asking for a slot to holding one, per slot, and counts those waits into a
powers-of-two histogram so it can report its own p50 and p99; the server prints both at shutdown
(volucer `4dd402a`, `a6df392`). Because the figure is produced inside the server it cannot
contain anything the load generator did, which is what makes it evidence rather than a second
correlation.

First, the load generator was ruled out. This harness drives `wrk` as `-t$c -c$c`, so at c=32 the
client owns 32 threads on a 12-core box, and that was the other candidate for the tail. Holding
concurrency at 32 and varying only the thread count changes nothing on the server side:

| client threads | client p99 | pool mean wait | pool p99 wait |
|---|---|---|---|
| 2 | 17.80 ms | 895 µs | 16.4 ms |
| 32 | 18.33 ms | 898 µs | 16.4 ms |

Then, with concurrency equal to the thread count (`scripts/diag-slots.sh`):

| concurrency | excess over 12 workers | client p50 | client p99 | pool mean | pool p50 | pool p99 | client `p99−p50` | pool `p99−p50` |
|---|---|---|---|---|---|---|---|---|
| 12 | 0 | 0.71 ms | 1.68 ms | 34 µs | 2 µs | 1.02 ms | 0.97 ms | 1.02 ms |
| 16 | 4 | 0.79 ms | 3.94 ms | 157 µs | 3 µs | 2.05 ms | 3.15 ms | 2.05 ms |
| 20 | 8 | 0.88 ms | 7.68 ms | 325 µs | 4 µs | 8.19 ms | 6.80 ms | 8.19 ms |
| 24 | 12 | 0.97 ms | 10.74 ms | 509 µs | 4 µs | 8.19 ms | 9.77 ms | 8.19 ms |
| 32 | 20 | 1.16 ms | 18.98 ms | 906 µs | 19 µs | 16.4 ms | 17.82 ms | 16.37 ms |

The wait **grows from concurrency 13 rather than stepping** — a step would mean waiting for the
one request already in front of you, and 34 → 157 → 325 → 509 → 906 µs across 0 → 4 → 8 → 12 → 20
excess clients is a queue accumulating instead. It is **unfairness, not slowness**: the pool's
median wait is 2−19 µs while its p99 is 1−16 ms, most requests take an uncontended mutex and a
few wait for whole requests, and the pool's `p99 − p50` tracks the client's at every level. And
the mean is a real cost besides: at c=32 a request spends **0.91 ms of its 1.69 ms** waiting for a
busy worker.

It is still recorded as a deployment property rather than a throughput one — nothing in the
tables above moves, and throughput at c=24 is already 4% ahead. What is no longer open is whether
the tail is real or whose it is. What *is* still open is which fix: `try_lock` in the scan, or a
real fair queue. Both are consistent with this data and neither has been built or compared.

**Built: the fair queue, and it holds.** `pick_slot`, the cursor and the healthy-not-free test are
gone, replaced by a lease taken from a free list — a slot cannot be leased twice, so a request now
waits for the slot it will actually use rather than for whichever worker the cursor happened to
point at. Same sweeps, same host:

| concurrency | rps | client p50 | client p99 | pool mean wait |
|---|---|---|---|---|
| 12 | 15,686 → 16,342 (+4%) | 0.71 → 0.69 ms | 1.68 → 1.41 ms | 34 → 0 µs |
| 20 | 18,581 → 22,114 (+19%) | 0.88 → 0.85 ms | 7.68 → 1.78 ms | 325 → 123 µs |
| 32 | 18,982 → 22,360 (+18%) | 1.16 → 1.35 ms | 18.98 → 3.68 ms | 906 → 625 µs |

Three notes, because two of these were not the point. **Nothing was shed**: `wrk` prints non-2xx
responses as its own line and printed none, so the gain is real service rather than `503`s. The
**throughput rise of 13–21% was not predicted** — the old scan locked and `try_wait`-ed each
candidate per request, which is CPU on 12 cores at 19,000 rps — and an unpredicted win is worth
re-measuring rather than celebrating. And the **median at c=32 is 16% worse**, which is the trade
that was approved: the request that would have been served on contact now shares the queue. At c=12
it is slightly better, so the cost is confined to the range where there is something to share.

**Re-measured interleaved, because that unpredicted win is exactly the kind of number this
repository has learned not to trust.** A blocked before/after charges host drift to whichever build
ran last — the trap that once produced a 22% "effect" that reversed sign when the two binaries were
interleaved instead (hazard 49). So both builds were measured again inside the same round in rotating
order, with RoadRunner as a control that shares no code with either: `diag-slots.sh` gained an A/B
mode and `scripts/slots-report.py` reads it. 7 rounds × 3 variants × 2 concurrency levels = 42
measured cells, 0 discarded, after a discarded warm-up pass per round:

| concurrency | new / pre-fair | spread over 7 rounds | new / RoadRunner | pre-fair / RoadRunner |
|---|---|---|---|---|
| c=24 | **1.245× (+24.5%)** | 1.223–1.271 | 1.272× | 1.030× |
| c=32 | **1.229× (+22.9%)** | 1.197–1.244 | 1.302× | 1.057× |

The spread never crosses 1.00 and all 14 paired comparisons point the same way. The control is what
makes it legible: the **pre-fair binary still measures +3.0%/+5.7% over RoadRunner**, the same band
hazard 51's interleaved A/B established for it, while the current build sits at +27%/+30%. So the
blocked layout *understated* the gain, and this is the largest throughput effect this project's own
code has produced — larger than the `crc32c` fix's +10–16%, which was called *"the whole lead"* over
RoadRunner. The two effects larger than it are not volucer's: removing xdebug from the host's CLI
PHP doubled the warm arms, and that was a configuration bug. The pool's p99 halves twice over as well (10.92 → 2.19 ms at c=24, 17.44 → 3.47 ms at
c=32) *while* the mean wait falls (522 → 263 µs), and the p50 rises from 8 µs to 256 µs — the fairness
made visible, the request served on contact now waiting a little so the unlucky one does not wait
10 ms. `run_measurement` now fails loudly on any `Non-2xx` line, so a future run cannot quietly trade
throughput for `503`s.

## What the harness refuses to do

The earlier experiments in this project produced numbers that were wrong in ways
that looked like findings. Every one of them is now a guard in `bench.sh`:

- **No arm is measured until a real request succeeds.** Each arm must return HTTP
  200 *and* a page containing rendered rows. A server that starts and answers 500
  would otherwise publish a plausible throughput figure for an arm that never ran
  the application. A cell that cannot be measured is recorded as `FAIL`, never as
  a zero.
- **Every arm runs the same PHP.** php-cgi is wrapped because `opcache.enable_cli`
  is read by php-cgi and ignored by php-fpm, and the two warm arms are wrapped too
  because a bare `php worker.php` is exposed to whatever the host's CLI happens to
  have installed. That is not hypothetical: removing xdebug from this host's CLI
  package roughly **doubled** the two warm arms (P 8,566 -> 16,322 rps, R 8,727 ->
  18,265) while F, T and U did not move at all — the hazard-28 pattern, a
  difference of ini mistaken for a difference of server, on the one pair nobody
  had wrapped.
- **A freshly modified checkout is waited out.** `opcache.file_update_protection`
  defaults to 2 seconds, and opcache refuses to cache a file whose mtime is newer.
  A script written seconds before measuring misses on every request *by design*,
  which looks exactly like an opcache that does not survive between requests. This
  project has already drawn that wrong conclusion once.
- **RoadRunner is stopped by config path, not binary path.** Its argv is
  `./rr serve`, so a `pkill` on the resolved binary matches nothing and the worker
  survives into the next run holding its port.
- **Leftovers are caught *per arm*, and the pattern had to be fixed to see them.**
  A run that leaks a php-cgi pool corrupts the next one; one earlier host
  accumulated 68 orphans, each holding a port and competing for the cores under
  test. Every arm is now checked immediately after `stop_arm` and the run refuses
  to continue if a leak cannot be cleared, so a leak can never cross into an arm
  that is measured.
  The check had been worse than useless as written: it matched the literal string
  `php-cgi -b`, but arms T and U spawn PHP through the `php-cgi-bench` wrapper, whose
  argv inserts its `-d` flags *before* `-b` —
  `/usr/bin/php-cgi -d opcache.enable_cli=1 … -b 127.0.0.1:19300` — so the pattern
  matched **0** of the 12 children a running arm actually had. Measured on the bench
  host: `pgrep -f 'php-cgi -b'` returned 0 while twelve children were alive, and it
  still returned 0 after a `kill -9` of the server left all twelve orphaned. The
  reported "8 strays" were therefore leftovers from older configs that invoked
  `/usr/bin/php-cgi` directly, and the guard would have reported clean through any
  leak the arms under measurement produced. It now matches `-b` as its own word via
  `ps -eww` (the `-ww` is load-bearing: without it a long wrapper command line is
  truncated and loses the flag), which never matches php-fpm's `php-fpm: pool www`
  children — so a host serving its own sites is neither counted nor reaped.
- **`max_requests = 0` means never recycle.** It is written explicitly in the
  configurations because it is what a real php-fpm pool carries — and because
  reading it as "recycle after every request" is a mistake this project has
  already made, which silently boots the framework per request and turns the warm
  arm cold.

## Why the application is azera

The application is copied from `azera-competition` unchanged, and that is
deliberate: the published figures there (RoadRunner 0.255 ms warm vs nginx +
php-fpm 0.785 ms cold on `GET /`) are the reference this repository's numbers are
read against. Changing the app would make the two datasets incomparable for no
gain.

Its dependencies are pinned to exact commits rather than to a branch, so a run six
months from now measures the same framework:

| package | commit | why not the tag |
|---|---|---|
| `sailantis/azera-framework` | `4292198` | the worker path needs `Request::setRawBody()`, which postdates `v0.1.0` |
| `sailantis/clarity-engine` | `ee06010` | the released `v0.3.0` plus one documentation commit |
| `sailantis/volucer-worker` | `5ede306` | current `main`; the SDK has no tag yet |

All three are public, and `"no-api": true` on each repository makes composer clone
them over git instead of through the GitHub API, which needs no token.

## Layout

```
BenchApp.php            the application: bootstrap once, dispatch, cleanup
public/index.php        the COLD entry point (F, T, U)
worker.php              the WARM entry point (P)
roadrunner-worker.php   the WARM entry point (R)
frankenphp-worker.php   the WARM entry point (Z), PHP embedded in the server
seed.php                creates data/bench.sqlite
apps/azera/             the application, copied from azera-competition
conf/                   one stamped config per arm
scripts/bench.sh        the harness
scripts/matrix.sh       workers x opcache x concurrency grid, with memory sampling
                        (and an optional wrk thread-count sweep: THREADS_LIST=tc,t12)
scripts/matrix-report.py reads it: medians, spread, opcache ratios, PSS/RSS tables,
                        thread-count columns when more than one was measured
scripts/diag-fpm-memory.sh per-child PSS vs RSS vs private, so the opcache memory
                        question is settled rather than argued
scripts/fork-demo.php   exec vs fork process models, same host, same run:
                        what fork() would save and what it would cost
                        (OPCACHE=off splits its cost into cache vs interpreter)
scripts/diag-opcache-sharing.sh  do exec'd workers share OPcache, or clone it?
scripts/fork-worker-demo.sh  the "forking worker" proposal against real volucer:
                        transport, liveness, teardown, and one process group
scripts/fork-relay.php  the recommended design at load: one boot, N children,
                        one inherited unix listener (HTTP, so wrk can drive it)
scripts/verify-fixes.sh end to end, with a real server and real signals: the socket
                        transport, a SIGKILLed server's children, and kind = "attach"
scripts/probe-franken-php.sh asks the running FrankenPHP which PHP it executes,
                        rather than trusting a version banner
scripts/ab-perf.sh      interleaved warm-arm pass: every arm inside one round
scripts/ab-report.py    reads it: within-round ratios, spread across rounds
scripts/diag-split.sh   CPU per request: server process vs PHP workers
scripts/diag-profile.sh perf record on the server process, flat symbol report
scripts/diag-slots.sh   the pool's own slot-wait histogram vs the client's p99
                        (VARIANTS=a,b,rr adds a rotated interleaved A/B of two builds)
scripts/slots-report.py reads an interleaved diag-slots.sh run: within-round ratios
results/                published numbers
```

`public/index.php` and `worker.php` are separate files on purpose. A cold arm has
to pay the framework boot *inside the timed request*, and the only honest way to
show that is for the entry script to boot. Sharing the worker's loop would quietly
make the cold arms warm and erase the effect being measured.

## Reading the results

`scripts/bench.sh` writes `results.tsv` (every repeat) and prints a summary of
medians. Ratios are the point, not absolute figures: absolute throughput depends
on the host, while the warm-over-cold ratio is a property of how much the
application boots — which is exactly the thing the earlier trivial-handler
measurements could not see.

That is also why a superseded sweep is kept rather than overwritten. `results/raw.tsv`
is the current run (`91cc7b6`), and the ones before it are kept beside it —
`raw-ddaada7.tsv` and `raw-841c963.tsv` — so
`scripts/compare_runs.py` prints both tables and the ratio change between them:

```bash
python3 scripts/compare_runs.py results/raw-ddaada7.tsv results/raw.tsv
```

Read the ratios, not the throughput. **The absolute rps column is not comparable between
sweeps, and the last two revisions are the proof:** `ddaada7` read 1–3% below `841c963` in
every cell, and the only code change between them was four micro-optimizations whose own
measurements claimed no throughput at all. Re-deriving it from the two committed files
shows what was actually there — every arm fell *except* the one the commits touched
(P +0.35%, R −2.79%, F −1.63%, T −1.54%, U −1.77%, RoadRunner slower in 10 of 10 cells).
The way to read that is a ratio against a control arm, which cancels whatever the host did
underneath both, and by that reading the four commits *improved* volucer's lead by 5.3%
on `/`. A *ratio* that moves further than the spread is the thing worth explaining; a
throughput delta of the same size is not.

**When a ratio surprises you, measure whose CPU it is before theorising.** The
`diag-*` scripts are here because that is how the largest single finding in this
repository was made: a 10% throughput gap between two servers was a 3x difference
in *server* CPU per request, invisible in wall clock, and fixing it moved the
result by more than any configuration change in the history of the harness.