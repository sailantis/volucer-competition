# 5 endpoints, 8 arms, PHP 8.5

Every arm measured on the same four pages, one host, one harness. The pages are
not comparable with each other — they are four different amounts of work — so
each has its own tables below, and a number from one section says nothing
about the same arm in another.

| path | what it measures |
|---|---|
| `/echo` | a routed 5-byte reply: router, dispatcher, both middlewares, then nothing. The framework's floor, and the closest this application gets to no work. |
| `/` | the landing page, rendered through a template. |
| `/api/items` | a JSON list from SQLite through the query builder. |
| `/items` | the same list rendered as a template. |
| `/items-fast` | the same page as `/items` with the identity map removed: `->objects()` instead of `->entities()`, so the only difference between the two rows is hydration. Byte-identical output, verified. |

Reading the sections together is the point of the run: a server whose
`/echo` is level with another's but whose `/api/items` is behind is losing
on the *work* rather than on the request, and a server that is behind on
`/echo` is paying for the request itself.
## `/echo`

a routed 5-byte reply: router, dispatcher, both middlewares, then nothing. The framework's floor, and the closest this application gets to no work.

# Worker / opcache / concurrency matrix

Every arm on one host, through one harness, so a difference between two
rows is the server rather than the measurement:

| arm | what it is |
|---|---|
| `volucer-tcp` | volucer worker (warm, loopback TCP port) |
| `volucer-attach` | volucer attach (warm, unix relay) |
| `volucer-fastcgi` | volucer spawn_cgi (cold, unix, 1/slot) |
| `volucer-prefork` | volucer spawn_cgi children (cold, unix) |
| `volucer-external` | volucer external -> php-fpm (cold, unix) |
| `rr` | RoadRunner worker (warm, pipe) |
| `frankenphp` | FrankenPHP worker (warm, embedded) |
| `fpm` | nginx + php-fpm (cold, unix) |

Rows: `results\matrix-0.4.1-reval60\matrix.tsv`. Memory: `results\matrix-0.4.1-reval60\memory.tsv`.

Every cell is the **median over the rounds**, with the min–max spread across
rounds in parentheses where there was more than one round. `p50` and `p99` are
each their own median across the rounds of that cell — not the percentile of
whichever round happened to have the median throughput.

`ch=N` marks the `children` axis, which only `volucer-prefork` has: there
`workers` counts listening sockets and `children` counts `php-cgi` processes
behind each, so `w=16 ch=4` is one master, four children, per socket. Every
other arm leaves it empty because it has no such setting.

**A `workers` column is not one quantity across arms, so do not read it
down as if it were.** It is spawned processes for `rr` and the `spawn_cgi`
arms, connections into somebody else's supervisor for `attach`, php-fpm's
`pm.max_children` for `fpm` and `external`, and **threads** — not
processes — for `frankenphp`, which is a single OS process at every
setting. `proc_kind` in `matrix.tsv` records which. The rows that are
actually comparable are the ones whose *total PHP process count* matches:
`prefork` costs `workers x (children + 1)` because every socket carries a
master as well as its children, so `w=1 ch=15` is 16 PHP processes and
equals `w=16` on any one-process-per-slot arm.

## Throughput (requests/sec)

### rps at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 53,409 (52,722–54,662) | 73,498 (72,328–73,774) | 87,679 (87,178–87,927) |
| volucer attach (warm, unix relay) | on | — | 59,272 (59,128–60,746) | 87,506 (86,874–87,552) | 109,874 (108,365–110,321) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 17,540 (17,418–17,655) | 20,280 (20,260–20,647) | 21,664 (21,407–21,848) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 19,042 (18,714–19,243) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 23,964 (23,583–24,225) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 27,447 (27,409–27,732) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 19,480 (19,273–19,668) | 22,435 (22,082–22,441) | 25,425 (25,003–25,545) |
| RoadRunner worker (warm, pipe) | on | — | 51,716 (51,341–52,117) | 69,296 (67,398–69,513) | 72,253 (67,986–72,718) |
| FrankenPHP worker (warm, embedded) | on | — | 71,154 (70,292–71,443) | 49,408 (48,009–50,099) | 41,810 (11,878–42,546) |
| nginx + php-fpm (cold, unix) | on | — | 21,443 (21,070–21,690) | 25,112 (24,157–25,122) | 27,895 (27,815–27,946) |

## Headline readings

### Best configuration per arm

| arm | rps | workers | children | opcache | concurrency |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | 87,679 | 32 | — | on | 96 |
| volucer attach (warm, unix relay) | 109,874 | 32 | — | on | 96 |
| volucer spawn_cgi (cold, unix, 1/slot) | 21,664 | 32 | — | on | 96 |
| volucer spawn_cgi children (cold, unix) | 19,042 | 1 | 8 | on | 96 |
| volucer spawn_cgi children (cold, unix) | 23,964 | 1 | 16 | on | 96 |
| volucer spawn_cgi children (cold, unix) | 27,447 | 1 | 32 | on | 96 |
| volucer external -> php-fpm (cold, unix) | 25,425 | 32 | — | on | 96 |
| RoadRunner worker (warm, pipe) | 72,253 | 32 | — | on | 96 |
| FrankenPHP worker (warm, embedded) | 71,154 | 8 | — | on | 96 |
| nginx + php-fpm (cold, unix) | 27,895 | 32 | — | on | 96 |

### Does another worker help? (concurrency 96, opcache on)

| arm | w=1 | w=8 | w=16 | w=32 | peak | change from w=1 |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | — | 53,409 | 73,498 | 87,679 | w=32 | — |
| volucer attach (warm, unix relay) | — | 59,272 | 87,506 | 109,874 | w=32 | — |
| volucer spawn_cgi (cold, unix, 1/slot) | — | 17,540 | 20,280 | 21,664 | w=32 | — |
| volucer external -> php-fpm (cold, unix) | — | 19,480 | 22,435 | 25,425 | w=32 | — |
| RoadRunner worker (warm, pipe) | — | 51,716 | 69,296 | 72,253 | w=32 | — |
| FrankenPHP worker (warm, embedded) | — | 71,154 | 49,408 | 41,810 | w=8 | — |
| nginx + php-fpm (cold, unix) | — | 21,443 | 25,112 | 27,895 | w=32 | — |

## Latency, p50 (ms)

### p50 at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 1.800 (1.750–1.820) | 1.260 (1.260–1.280) | 1.030 (1.030–1.030) |
| volucer attach (warm, unix relay) | on | — | 1.620 (1.580–1.630) | 1.060 (1.050–1.070) | 0.821 (0.818–0.829) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 5.430 (5.360–5.490) | 4.210 (4.170–4.250) | 3.380 (3.320–3.420) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 5.000 (4.950–5.070) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 3.980 (3.930–4.020) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 3.430 (3.380–3.440) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 5.390 (5.340–5.470) | 5.970 (5.960–6.070) | 4.510 (4.480–4.580) |
| RoadRunner worker (warm, pipe) | on | — | 1.770 (1.760–1.790) | 1.300 (1.290–1.330) | 1.190 (1.180–1.270) |
| FrankenPHP worker (warm, embedded) | on | — | 1.200 (1.200–1.220) | 1.830 (1.800–1.870) | 2.040 (2.040–2.070) |
| nginx + php-fpm (cold, unix) | on | — | 4.430 (4.370–4.510) | 3.770 (3.770–3.910) | 3.330 (3.330–3.340) |

## Latency, p99 (ms)

### p99 at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 6.630 (6.510–6.630) | 3.790 (3.780–3.870) | 3.020 (2.890–3.070) |
| volucer attach (warm, unix relay) | on | — | 6.170 (6.070–6.210) | 3.270 (3.270–3.290) | 2.140 (2.120–2.240) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 33.440 (29.210–34.060) | 27.740 (27.030–33.570) | 26.310 (24.030–27.510) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 14.650 (14.420–14.820) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 10.420 (10.220–10.480) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 6.930 (6.890–7.020) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 11.550 (11.460–11.560) | 8.260 (8.240–8.370) | 7.160 (7.100–7.240) |
| RoadRunner worker (warm, pipe) | on | — | 3.050 (3.030–3.060) | 2.720 (2.690–2.790) | 3.730 (3.670–3.870) |
| FrankenPHP worker (warm, embedded) | on | — | 4.380 (4.330–4.430) | 5.690 (5.640–5.880) | 6.250 (6.210–6.310) |
| nginx + php-fpm (cold, unix) | on | — | 5.500 (5.440–5.570) | 4.930 (4.900–5.090) | 5.300 (5.270–5.340) |

## opcache

Every cell in this run was measured with opcache **on**, which is the
production case and the only one where a shared OPcache segment can exist —
so the ON/OFF ratio is not a column here.
The 8.5 pass that measured it (`results/matrix85-opcache/report.md`)
has the ON/OFF ratio for the arms both runs share.

## Shape comparisons

### Shape comparisons at concurrency 96

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| transport: unix vs pipe | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| memory model: attach vs pipe | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| control: children=1 vs plain spawn_cgi | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| prefork: children=8 vs children=1 | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| prefork: children=16 vs children=1 | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| prefork: children=32 vs children=1 | rps | — | — | — | — |
|  | PSS | — | — | — | — |

## At equal PHP process counts

`workers` is not one quantity across arms (see the note above), so this is
the axis on which the arms can be read against each other. The count is the
measured `pids` of each arm's process tree, not the configured value, and the
parenthesised config is what produced it.

**9 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer worker (warm, loopback TCP port) (w=8) | 53,409 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=8) | 17,540 |
| RoadRunner worker (warm, pipe) (w=8) | 51,716 |

**10 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer attach (warm, unix relay) (w=8) | 59,272 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=8) | 19,042 |
| volucer external -> php-fpm (cold, unix) (w=8) | 19,480 |

**17 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer worker (warm, loopback TCP port) (w=16) | 73,498 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=16) | 20,280 |
| RoadRunner worker (warm, pipe) (w=16) | 69,296 |

**18 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer attach (warm, unix relay) (w=16) | 87,506 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=16) | 23,964 |
| volucer external -> php-fpm (cold, unix) (w=16) | 22,435 |

**33 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer worker (warm, loopback TCP port) (w=32) | 87,679 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=32) | 21,664 |
| RoadRunner worker (warm, pipe) (w=32) | 72,253 |

**34 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer attach (warm, unix relay) (w=32) | 109,874 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=32) | 27,447 |
| volucer external -> php-fpm (cold, unix) (w=32) | 25,425 |

## Memory

### Memory, boot (before any request)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8 | 9 | 204.2 | 458.3 | 22.7 |
| volucer worker (warm, loopback TCP port) | on | 16 | 17 | 348.4 | 871.6 | 20.5 |
| volucer worker (warm, loopback TCP port) | on | 32 | 33 | 594.8 | 1,652.3 | 18.0 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 65.5 | 281.3 | 6.5 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 73.6 | 451.0 | 4.1 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 82.8 | 713.8 | 2.4 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 186.5 | 438.7 | 20.7 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 333.6 | 858.8 | 19.6 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 620.8 | 1,697.3 | 18.8 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 62.1 | 300.0 | 6.2 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 67.5 | 455.7 | 3.8 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 68.6 | 649.4 | 2.0 |
| volucer external -> php-fpm (cold, unix) | on | 8 | 10 | 59.1 | 298.8 | 5.9 |
| volucer external -> php-fpm (cold, unix) | on | 16 | 18 | 71.4 | 527.9 | 4.0 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 90.4 | 979.7 | 2.7 |
| RoadRunner worker (warm, pipe) | on | 8 | 9 | 252.3 | 502.3 | 28.0 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 425.8 | 951.4 | 25.0 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 767.8 | 1,849.0 | 23.3 |
| FrankenPHP worker (warm, embedded) | on | 8 | 1 | 123.4 | 123.4 | 123.4 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 136.8 | 136.8 | 136.8 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 153.3 | 153.3 | 153.3 |
| nginx + php-fpm (cold, unix) | on | 8 | 14 | 55.1 | 312.6 | 3.9 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 65.2 | 541.0 | 3.0 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 84.5 | 999.8 | 2.2 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8: 204.2 | 32: 594.8 | 390.6 | 24 | 16.3 |
| volucer attach (warm, unix relay) | on | 8: 65.5 | 32: 82.8 | 17.3 | 24 | 0.7 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8: 186.5 | 32: 620.8 | 434.3 | 24 | 18.1 |
| volucer external -> php-fpm (cold, unix) | on | 8: 59.1 | 32: 90.4 | 31.3 | 24 | 1.3 |
| RoadRunner worker (warm, pipe) | on | 8: 252.3 | 32: 767.8 | 515.5 | 24 | 21.5 |
| FrankenPHP worker (warm, embedded) | on | 8: 123.4 | 32: 153.3 | 29.9 | 24 | 1.2 |
| nginx + php-fpm (cold, unix) | on | 8: 55.1 | 32: 84.5 | 29.4 | 24 | 1.2 |

### Memory, after load (peak concurrency)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8 | 9 | 213.0 | 466.4 | 23.7 |
| volucer worker (warm, loopback TCP port) | on | 16 | 17 | 374.7 | 902.9 | 22.0 |
| volucer worker (warm, loopback TCP port) | on | 32 | 33 | 700.7 | 1,782.9 | 21.2 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 69.2 | 283.0 | 6.9 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 82.3 | 490.1 | 4.6 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 102.9 | 880.8 | 3.0 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 193.9 | 446.8 | 21.5 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 339.1 | 865.0 | 19.9 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 629.4 | 1,706.6 | 19.1 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 69.8 | 309.1 | 7.0 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 76.5 | 528.1 | 4.2 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 100.1 | 982.0 | 2.9 |
| volucer external -> php-fpm (cold, unix) | on | 8 | 10 | 66.3 | 304.4 | 6.6 |
| volucer external -> php-fpm (cold, unix) | on | 16 | 18 | 78.3 | 535.8 | 4.3 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 100.5 | 990.9 | 3.0 |
| RoadRunner worker (warm, pipe) | on | 8 | 9 | 257.5 | 508.0 | 28.6 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 431.5 | 957.6 | 25.4 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 776.3 | 1,856.2 | 23.5 |
| FrankenPHP worker (warm, embedded) | on | 8 | 1 | 130.9 | 130.9 | 130.9 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 144.6 | 144.6 | 144.6 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 168.3 | 168.3 | 168.3 |
| nginx + php-fpm (cold, unix) | on | 8 | 14 | 56.1 | 313.9 | 4.0 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 66.5 | 543.0 | 3.0 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 85.9 | 1,001.8 | 2.3 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8: 213.0 | 32: 700.7 | 487.7 | 24 | 20.3 |
| volucer attach (warm, unix relay) | on | 8: 69.2 | 32: 102.9 | 33.7 | 24 | 1.4 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8: 193.9 | 32: 629.4 | 435.5 | 24 | 18.1 |
| volucer external -> php-fpm (cold, unix) | on | 8: 66.3 | 32: 100.5 | 34.2 | 24 | 1.4 |
| RoadRunner worker (warm, pipe) | on | 8: 257.5 | 32: 776.3 | 518.8 | 24 | 21.6 |
| FrankenPHP worker (warm, embedded) | on | 8: 130.9 | 32: 168.3 | 37.4 | 24 | 1.6 |
| nginx + php-fpm (cold, unix) | on | 8: 56.1 | 32: 85.9 | 29.8 | 24 | 1.2 |

## Integrity checks

No failed cells and no dropped responses in any measured cell.


## `/`

the landing page, rendered through a template.

# Worker / opcache / concurrency matrix

Every arm on one host, through one harness, so a difference between two
rows is the server rather than the measurement:

| arm | what it is |
|---|---|
| `volucer-tcp` | volucer worker (warm, loopback TCP port) |
| `volucer-attach` | volucer attach (warm, unix relay) |
| `volucer-fastcgi` | volucer spawn_cgi (cold, unix, 1/slot) |
| `volucer-prefork` | volucer spawn_cgi children (cold, unix) |
| `volucer-external` | volucer external -> php-fpm (cold, unix) |
| `rr` | RoadRunner worker (warm, pipe) |
| `frankenphp` | FrankenPHP worker (warm, embedded) |
| `fpm` | nginx + php-fpm (cold, unix) |

Rows: `results\matrix-0.4.1-reval60\matrix.tsv`. Memory: `results\matrix-0.4.1-reval60\memory.tsv`.

Every cell is the **median over the rounds**, with the min–max spread across
rounds in parentheses where there was more than one round. `p50` and `p99` are
each their own median across the rounds of that cell — not the percentile of
whichever round happened to have the median throughput.

`ch=N` marks the `children` axis, which only `volucer-prefork` has: there
`workers` counts listening sockets and `children` counts `php-cgi` processes
behind each, so `w=16 ch=4` is one master, four children, per socket. Every
other arm leaves it empty because it has no such setting.

**A `workers` column is not one quantity across arms, so do not read it
down as if it were.** It is spawned processes for `rr` and the `spawn_cgi`
arms, connections into somebody else's supervisor for `attach`, php-fpm's
`pm.max_children` for `fpm` and `external`, and **threads** — not
processes — for `frankenphp`, which is a single OS process at every
setting. `proc_kind` in `matrix.tsv` records which. The rows that are
actually comparable are the ones whose *total PHP process count* matches:
`prefork` costs `workers x (children + 1)` because every socket carries a
master as well as its children, so `w=1 ch=15` is 16 PHP processes and
equals `w=16` on any one-process-per-slot arm.

## Throughput (requests/sec)

### rps at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 47,710 (46,292–48,629) | 63,400 (63,008–63,609) | 75,651 (75,249–76,057) |
| volucer attach (warm, unix relay) | on | — | 53,131 (50,573–53,344) | 74,893 (74,796–75,794) | 97,248 (96,368–97,546) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 14,574 (14,313–14,843) | 16,698 (16,583–16,750) | 18,253 (17,965–18,270) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 15,622 (15,528–15,681) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 19,437 (19,340–19,782) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 22,624 (22,402–22,681) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 16,127 (16,042–16,367) | 18,403 (18,270–18,539) | 20,876 (20,313–20,949) |
| RoadRunner worker (warm, pipe) | on | — | 43,849 (43,532–44,156) | 54,665 (53,516–54,913) | 56,415 (56,324–56,595) |
| FrankenPHP worker (warm, embedded) | on | — | 28,631 (28,600–29,233) | 24,599 (23,949–24,600) | 23,286 (0–23,637) |
| nginx + php-fpm (cold, unix) | on | — | 16,384 (15,962–16,385) | 19,235 (19,060–19,501) | 22,120 (21,992–22,148) |

## Headline readings

### Best configuration per arm

| arm | rps | workers | children | opcache | concurrency |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | 75,651 | 32 | — | on | 96 |
| volucer attach (warm, unix relay) | 97,248 | 32 | — | on | 96 |
| volucer spawn_cgi (cold, unix, 1/slot) | 18,253 | 32 | — | on | 96 |
| volucer spawn_cgi children (cold, unix) | 15,622 | 1 | 8 | on | 96 |
| volucer spawn_cgi children (cold, unix) | 19,437 | 1 | 16 | on | 96 |
| volucer spawn_cgi children (cold, unix) | 22,624 | 1 | 32 | on | 96 |
| volucer external -> php-fpm (cold, unix) | 20,876 | 32 | — | on | 96 |
| RoadRunner worker (warm, pipe) | 56,415 | 32 | — | on | 96 |
| FrankenPHP worker (warm, embedded) | 28,631 | 8 | — | on | 96 |
| nginx + php-fpm (cold, unix) | 22,120 | 32 | — | on | 96 |

### Does another worker help? (concurrency 96, opcache on)

| arm | w=1 | w=8 | w=16 | w=32 | peak | change from w=1 |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | — | 47,710 | 63,400 | 75,651 | w=32 | — |
| volucer attach (warm, unix relay) | — | 53,131 | 74,893 | 97,248 | w=32 | — |
| volucer spawn_cgi (cold, unix, 1/slot) | — | 14,574 | 16,698 | 18,253 | w=32 | — |
| volucer external -> php-fpm (cold, unix) | — | 16,127 | 18,403 | 20,876 | w=32 | — |
| RoadRunner worker (warm, pipe) | — | 43,849 | 54,665 | 56,415 | w=32 | — |
| FrankenPHP worker (warm, embedded) | — | 28,631 | 24,599 | 23,286 | w=8 | — |
| nginx + php-fpm (cold, unix) | — | 16,384 | 19,235 | 22,120 | w=32 | — |

## Latency, p50 (ms)

### p50 at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 2.030 (1.980–2.080) | 1.470 (1.460–1.480) | 1.200 (1.190–1.200) |
| volucer attach (warm, unix relay) | on | — | 1.810 (1.800–1.900) | 1.250 (1.230–1.250) | 0.940 (0.930–0.940) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 6.370 (6.200–6.400) | 5.210 (5.110–5.290) | 4.050 (4.030–4.060) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 6.050 (6.050–6.100) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 4.910 (4.820–4.930) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 4.160 (4.130–4.180) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 6.520 (6.460–6.590) | 7.320 (7.280–7.380) | 5.470 (5.460–5.660) |
| RoadRunner worker (warm, pipe) | on | — | 2.070 (2.060–2.080) | 1.630 (1.630–1.670) | 1.530 (1.520–1.530) |
| FrankenPHP worker (warm, embedded) | on | — | 3.160 (3.090–3.160) | 3.660 (3.660–3.760) | 3.710 (0.000–3.770) |
| nginx + php-fpm (cold, unix) | on | — | 5.800 (5.790–5.950) | 4.930 (4.860–4.990) | 4.220 (4.220–4.250) |

## Latency, p99 (ms)

### p99 at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 7.420 (7.310–7.560) | 4.300 (4.270–4.310) | 3.210 (3.190–3.240) |
| volucer attach (warm, unix relay) | on | — | 6.920 (6.900–7.180) | 3.720 (3.710–3.740) | 2.320 (2.290–2.320) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 40.300 (39.700–42.370) | 33.320 (31.640–33.500) | 30.560 (30.160–34.270) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 17.600 (17.590–17.940) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 12.880 (12.700–12.940) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 8.430 (8.370–8.500) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 14.350 (14.310–14.530) | 9.890 (9.820–9.910) | 8.400 (8.320–8.620) |
| RoadRunner worker (warm, pipe) | on | — | 3.450 (3.450–3.510) | 3.390 (3.330–3.460) | 4.470 (4.440–4.570) |
| FrankenPHP worker (warm, embedded) | on | — | 5.510 (5.410–5.530) | 7.070 (7.060–7.260) | 10.340 (0.000–10.380) |
| nginx + php-fpm (cold, unix) | on | — | 7.140 (7.050–7.310) | 6.300 (6.240–6.360) | 6.500 (6.460–6.510) |

## opcache

Every cell in this run was measured with opcache **on**, which is the
production case and the only one where a shared OPcache segment can exist —
so the ON/OFF ratio is not a column here.
The 8.5 pass that measured it (`results/matrix85-opcache/report.md`)
has the ON/OFF ratio for the arms both runs share.

## Shape comparisons

### Shape comparisons at concurrency 96

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| transport: unix vs pipe | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| memory model: attach vs pipe | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| control: children=1 vs plain spawn_cgi | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| prefork: children=8 vs children=1 | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| prefork: children=16 vs children=1 | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| prefork: children=32 vs children=1 | rps | — | — | — | — |
|  | PSS | — | — | — | — |

## At equal PHP process counts

`workers` is not one quantity across arms (see the note above), so this is
the axis on which the arms can be read against each other. The count is the
measured `pids` of each arm's process tree, not the configured value, and the
parenthesised config is what produced it.

**9 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer worker (warm, loopback TCP port) (w=8) | 47,710 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=8) | 14,574 |
| RoadRunner worker (warm, pipe) (w=8) | 43,849 |

**10 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer attach (warm, unix relay) (w=8) | 53,131 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=8) | 15,622 |
| volucer external -> php-fpm (cold, unix) (w=8) | 16,127 |

**17 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer worker (warm, loopback TCP port) (w=16) | 63,400 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=16) | 16,698 |
| RoadRunner worker (warm, pipe) (w=16) | 54,665 |

**18 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer attach (warm, unix relay) (w=16) | 74,893 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=16) | 19,437 |
| volucer external -> php-fpm (cold, unix) (w=16) | 18,403 |

**33 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer worker (warm, loopback TCP port) (w=32) | 75,651 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=32) | 18,253 |
| RoadRunner worker (warm, pipe) (w=32) | 56,415 |

**34 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer attach (warm, unix relay) (w=32) | 97,248 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=32) | 22,624 |
| volucer external -> php-fpm (cold, unix) (w=32) | 20,876 |

## Memory

### Memory, boot (before any request)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8 | 9 | 204.2 | 458.3 | 22.7 |
| volucer worker (warm, loopback TCP port) | on | 16 | 17 | 348.4 | 871.6 | 20.5 |
| volucer worker (warm, loopback TCP port) | on | 32 | 33 | 594.8 | 1,652.3 | 18.0 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 65.5 | 281.3 | 6.5 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 73.6 | 451.0 | 4.1 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 82.8 | 713.8 | 2.4 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 186.5 | 438.7 | 20.7 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 333.6 | 858.8 | 19.6 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 620.8 | 1,697.3 | 18.8 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 62.1 | 300.0 | 6.2 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 67.5 | 455.7 | 3.8 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 68.6 | 649.4 | 2.0 |
| volucer external -> php-fpm (cold, unix) | on | 8 | 10 | 59.1 | 298.8 | 5.9 |
| volucer external -> php-fpm (cold, unix) | on | 16 | 18 | 71.4 | 527.9 | 4.0 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 90.4 | 979.7 | 2.7 |
| RoadRunner worker (warm, pipe) | on | 8 | 9 | 252.3 | 502.3 | 28.0 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 425.8 | 951.4 | 25.0 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 767.8 | 1,849.0 | 23.3 |
| FrankenPHP worker (warm, embedded) | on | 8 | 1 | 123.4 | 123.4 | 123.4 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 136.8 | 136.8 | 136.8 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 153.3 | 153.3 | 153.3 |
| nginx + php-fpm (cold, unix) | on | 8 | 14 | 55.1 | 312.6 | 3.9 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 65.2 | 541.0 | 3.0 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 84.5 | 999.8 | 2.2 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8: 204.2 | 32: 594.8 | 390.6 | 24 | 16.3 |
| volucer attach (warm, unix relay) | on | 8: 65.5 | 32: 82.8 | 17.3 | 24 | 0.7 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8: 186.5 | 32: 620.8 | 434.3 | 24 | 18.1 |
| volucer external -> php-fpm (cold, unix) | on | 8: 59.1 | 32: 90.4 | 31.3 | 24 | 1.3 |
| RoadRunner worker (warm, pipe) | on | 8: 252.3 | 32: 767.8 | 515.5 | 24 | 21.5 |
| FrankenPHP worker (warm, embedded) | on | 8: 123.4 | 32: 153.3 | 29.9 | 24 | 1.2 |
| nginx + php-fpm (cold, unix) | on | 8: 55.1 | 32: 84.5 | 29.4 | 24 | 1.2 |

### Memory, after load (peak concurrency)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8 | 9 | 213.0 | 466.4 | 23.7 |
| volucer worker (warm, loopback TCP port) | on | 16 | 17 | 374.7 | 902.9 | 22.0 |
| volucer worker (warm, loopback TCP port) | on | 32 | 33 | 700.7 | 1,782.9 | 21.2 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 69.2 | 283.0 | 6.9 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 82.3 | 490.1 | 4.6 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 102.9 | 880.8 | 3.0 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 193.9 | 446.8 | 21.5 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 339.1 | 865.0 | 19.9 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 629.4 | 1,706.6 | 19.1 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 69.8 | 309.1 | 7.0 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 76.5 | 528.1 | 4.2 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 100.1 | 982.0 | 2.9 |
| volucer external -> php-fpm (cold, unix) | on | 8 | 10 | 66.3 | 304.4 | 6.6 |
| volucer external -> php-fpm (cold, unix) | on | 16 | 18 | 78.3 | 535.8 | 4.3 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 100.5 | 990.9 | 3.0 |
| RoadRunner worker (warm, pipe) | on | 8 | 9 | 257.5 | 508.0 | 28.6 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 431.5 | 957.6 | 25.4 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 776.3 | 1,856.2 | 23.5 |
| FrankenPHP worker (warm, embedded) | on | 8 | 1 | 130.9 | 130.9 | 130.9 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 144.6 | 144.6 | 144.6 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 168.3 | 168.3 | 168.3 |
| nginx + php-fpm (cold, unix) | on | 8 | 14 | 56.1 | 313.9 | 4.0 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 66.5 | 543.0 | 3.0 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 85.9 | 1,001.8 | 2.3 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8: 213.0 | 32: 700.7 | 487.7 | 24 | 20.3 |
| volucer attach (warm, unix relay) | on | 8: 69.2 | 32: 102.9 | 33.7 | 24 | 1.4 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8: 193.9 | 32: 629.4 | 435.5 | 24 | 18.1 |
| volucer external -> php-fpm (cold, unix) | on | 8: 66.3 | 32: 100.5 | 34.2 | 24 | 1.4 |
| RoadRunner worker (warm, pipe) | on | 8: 257.5 | 32: 776.3 | 518.8 | 24 | 21.6 |
| FrankenPHP worker (warm, embedded) | on | 8: 130.9 | 32: 168.3 | 37.4 | 24 | 1.6 |
| nginx + php-fpm (cold, unix) | on | 8: 56.1 | 32: 85.9 | 29.8 | 24 | 1.2 |

## Integrity checks

No failed cells and no dropped responses in any measured cell.


## `/api/items`

a JSON list from SQLite through the query builder.

# Worker / opcache / concurrency matrix

Every arm on one host, through one harness, so a difference between two
rows is the server rather than the measurement:

| arm | what it is |
|---|---|
| `volucer-tcp` | volucer worker (warm, loopback TCP port) |
| `volucer-attach` | volucer attach (warm, unix relay) |
| `volucer-fastcgi` | volucer spawn_cgi (cold, unix, 1/slot) |
| `volucer-prefork` | volucer spawn_cgi children (cold, unix) |
| `volucer-external` | volucer external -> php-fpm (cold, unix) |
| `rr` | RoadRunner worker (warm, pipe) |
| `frankenphp` | FrankenPHP worker (warm, embedded) |
| `fpm` | nginx + php-fpm (cold, unix) |

Rows: `results\matrix-0.4.1-reval60\matrix.tsv`. Memory: `results\matrix-0.4.1-reval60\memory.tsv`.

Every cell is the **median over the rounds**, with the min–max spread across
rounds in parentheses where there was more than one round. `p50` and `p99` are
each their own median across the rounds of that cell — not the percentile of
whichever round happened to have the median throughput.

`ch=N` marks the `children` axis, which only `volucer-prefork` has: there
`workers` counts listening sockets and `children` counts `php-cgi` processes
behind each, so `w=16 ch=4` is one master, four children, per socket. Every
other arm leaves it empty because it has no such setting.

**A `workers` column is not one quantity across arms, so do not read it
down as if it were.** It is spawned processes for `rr` and the `spawn_cgi`
arms, connections into somebody else's supervisor for `attach`, php-fpm's
`pm.max_children` for `fpm` and `external`, and **threads** — not
processes — for `frankenphp`, which is a single OS process at every
setting. `proc_kind` in `matrix.tsv` records which. The rows that are
actually comparable are the ones whose *total PHP process count* matches:
`prefork` costs `workers x (children + 1)` because every socket carries a
master as well as its children, so `w=1 ch=15` is 16 PHP processes and
equals `w=16` on any one-process-per-slot arm.

## Throughput (requests/sec)

### rps at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 39,719 (37,410–40,900) | 47,394 (47,094–48,722) | 54,150 (51,662–54,546) |
| volucer attach (warm, unix relay) | on | — | 41,525 (39,057–43,131) | 55,661 (55,650–56,741) | 73,062 (71,528–73,339) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 7,945 (7,812–7,970) | 9,294 (9,268–9,302) | 10,771 (10,512–10,900) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 8,087 (8,036–8,179) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 10,625 (10,605–10,719) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 12,730 (12,431–12,744) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 8,132 (8,130–8,203) | 10,718 (10,551–10,735) | 12,248 (12,015–12,433) |
| RoadRunner worker (warm, pipe) | on | — | 37,763 (37,734–38,142) | 44,450 (38,455–45,926) | 44,808 (44,411–45,335) |
| FrankenPHP worker (warm, embedded) | on | — | 58,830 (57,499–59,419) | 38,997 (38,282–39,033) | 32,351 (29,466–32,696) |
| nginx + php-fpm (cold, unix) | on | — | 8,144 (8,087–8,156) | 10,897 (10,776–10,988) | 12,422 (12,200–12,592) |

## Headline readings

### Best configuration per arm

| arm | rps | workers | children | opcache | concurrency |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | 54,150 | 32 | — | on | 96 |
| volucer attach (warm, unix relay) | 73,062 | 32 | — | on | 96 |
| volucer spawn_cgi (cold, unix, 1/slot) | 10,771 | 32 | — | on | 96 |
| volucer spawn_cgi children (cold, unix) | 8,087 | 1 | 8 | on | 96 |
| volucer spawn_cgi children (cold, unix) | 10,625 | 1 | 16 | on | 96 |
| volucer spawn_cgi children (cold, unix) | 12,730 | 1 | 32 | on | 96 |
| volucer external -> php-fpm (cold, unix) | 12,248 | 32 | — | on | 96 |
| RoadRunner worker (warm, pipe) | 44,808 | 32 | — | on | 96 |
| FrankenPHP worker (warm, embedded) | 58,830 | 8 | — | on | 96 |
| nginx + php-fpm (cold, unix) | 12,422 | 32 | — | on | 96 |

### Does another worker help? (concurrency 96, opcache on)

| arm | w=1 | w=8 | w=16 | w=32 | peak | change from w=1 |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | — | 39,719 | 47,394 | 54,150 | w=32 | — |
| volucer attach (warm, unix relay) | — | 41,525 | 55,661 | 73,062 | w=32 | — |
| volucer spawn_cgi (cold, unix, 1/slot) | — | 7,945 | 9,294 | 10,771 | w=32 | — |
| volucer external -> php-fpm (cold, unix) | — | 8,132 | 10,718 | 12,248 | w=32 | — |
| RoadRunner worker (warm, pipe) | — | 37,763 | 44,450 | 44,808 | w=32 | — |
| FrankenPHP worker (warm, embedded) | — | 58,830 | 38,997 | 32,351 | w=8 | — |
| nginx + php-fpm (cold, unix) | — | 8,144 | 10,897 | 12,422 | w=32 | — |

## Latency, p50 (ms)

### p50 at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 2.410 (2.340–2.590) | 1.990 (1.930–2.000) | 1.680 (1.670–1.750) |
| volucer attach (warm, unix relay) | on | — | 2.330 (2.240–2.470) | 1.690 (1.650–1.690) | 1.240 (1.240–1.270) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 12.190 (11.710–12.350) | 9.440 (9.390–9.480) | 7.100 (6.890–7.160) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 11.800 (11.650–11.870) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 8.940 (8.880–8.960) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 7.400 (7.390–7.590) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 13.810 (13.610–13.990) | 12.900 (12.870–13.150) | 9.650 (9.580–9.840) |
| RoadRunner worker (warm, pipe) | on | — | 2.450 (2.420–2.450) | 2.050 (1.980–2.390) | 2.000 (1.980–2.020) |
| FrankenPHP worker (warm, embedded) | on | — | 1.410 (1.400–1.450) | 2.340 (2.320–2.380) | 2.710 (2.670–2.850) |
| nginx + php-fpm (cold, unix) | on | — | 11.670 (11.640–11.720) | 8.680 (8.650–8.790) | 7.530 (7.450–7.690) |

## Latency, p99 (ms)

### p99 at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 8.430 (8.390–8.810) | 5.540 (5.450–5.570) | 4.340 (4.280–5.790) |
| volucer attach (warm, unix relay) | on | — | 8.250 (7.890–8.590) | 4.780 (4.720–4.790) | 3.040 (3.010–3.130) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 59.600 (57.440–60.940) | 56.090 (54.810–60.150) | 57.700 (48.750–65.180) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 33.180 (33.060–33.640) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 23.200 (22.920–23.220) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 15.090 (14.780–16.100) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 33.020 (33.010–33.190) | 17.160 (17.040–17.330) | 13.950 (13.730–14.500) |
| RoadRunner worker (warm, pipe) | on | — | 3.910 (3.870–3.910) | 3.820 (3.740–4.430) | 4.730 (4.680–4.750) |
| FrankenPHP worker (warm, embedded) | on | — | 5.070 (4.990–5.120) | 6.910 (6.820–6.980) | 7.640 (7.630–645.510) |
| nginx + php-fpm (cold, unix) | on | — | 14.010 (13.970–14.420) | 11.150 (10.780–11.250) | 10.880 (10.360–10.930) |

## opcache

Every cell in this run was measured with opcache **on**, which is the
production case and the only one where a shared OPcache segment can exist —
so the ON/OFF ratio is not a column here.
The 8.5 pass that measured it (`results/matrix85-opcache/report.md`)
has the ON/OFF ratio for the arms both runs share.

## Shape comparisons

### Shape comparisons at concurrency 96

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| transport: unix vs pipe | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| memory model: attach vs pipe | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| control: children=1 vs plain spawn_cgi | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| prefork: children=8 vs children=1 | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| prefork: children=16 vs children=1 | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| prefork: children=32 vs children=1 | rps | — | — | — | — |
|  | PSS | — | — | — | — |

## At equal PHP process counts

`workers` is not one quantity across arms (see the note above), so this is
the axis on which the arms can be read against each other. The count is the
measured `pids` of each arm's process tree, not the configured value, and the
parenthesised config is what produced it.

**9 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer worker (warm, loopback TCP port) (w=8) | 39,719 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=8) | 7,945 |
| RoadRunner worker (warm, pipe) (w=8) | 37,763 |

**10 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer attach (warm, unix relay) (w=8) | 41,525 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=8) | 8,087 |
| volucer external -> php-fpm (cold, unix) (w=8) | 8,132 |

**17 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer worker (warm, loopback TCP port) (w=16) | 47,394 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=16) | 9,294 |
| RoadRunner worker (warm, pipe) (w=16) | 44,450 |

**18 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer attach (warm, unix relay) (w=16) | 55,661 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=16) | 10,625 |
| volucer external -> php-fpm (cold, unix) (w=16) | 10,718 |

**33 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer worker (warm, loopback TCP port) (w=32) | 54,150 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=32) | 10,771 |
| RoadRunner worker (warm, pipe) (w=32) | 44,808 |

**34 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer attach (warm, unix relay) (w=32) | 73,062 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=32) | 12,730 |
| volucer external -> php-fpm (cold, unix) (w=32) | 12,248 |

## Memory

### Memory, boot (before any request)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8 | 9 | 204.2 | 458.3 | 22.7 |
| volucer worker (warm, loopback TCP port) | on | 16 | 17 | 348.4 | 871.6 | 20.5 |
| volucer worker (warm, loopback TCP port) | on | 32 | 33 | 594.8 | 1,652.3 | 18.0 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 65.5 | 281.3 | 6.5 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 73.6 | 451.0 | 4.1 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 82.8 | 713.8 | 2.4 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 186.5 | 438.7 | 20.7 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 333.6 | 858.8 | 19.6 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 620.8 | 1,697.3 | 18.8 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 62.1 | 300.0 | 6.2 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 67.5 | 455.7 | 3.8 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 68.6 | 649.4 | 2.0 |
| volucer external -> php-fpm (cold, unix) | on | 8 | 10 | 59.1 | 298.8 | 5.9 |
| volucer external -> php-fpm (cold, unix) | on | 16 | 18 | 71.4 | 527.9 | 4.0 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 90.4 | 979.7 | 2.7 |
| RoadRunner worker (warm, pipe) | on | 8 | 9 | 252.3 | 502.3 | 28.0 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 425.8 | 951.4 | 25.0 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 767.8 | 1,849.0 | 23.3 |
| FrankenPHP worker (warm, embedded) | on | 8 | 1 | 123.4 | 123.4 | 123.4 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 136.8 | 136.8 | 136.8 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 153.3 | 153.3 | 153.3 |
| nginx + php-fpm (cold, unix) | on | 8 | 14 | 55.1 | 312.6 | 3.9 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 65.2 | 541.0 | 3.0 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 84.5 | 999.8 | 2.2 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8: 204.2 | 32: 594.8 | 390.6 | 24 | 16.3 |
| volucer attach (warm, unix relay) | on | 8: 65.5 | 32: 82.8 | 17.3 | 24 | 0.7 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8: 186.5 | 32: 620.8 | 434.3 | 24 | 18.1 |
| volucer external -> php-fpm (cold, unix) | on | 8: 59.1 | 32: 90.4 | 31.3 | 24 | 1.3 |
| RoadRunner worker (warm, pipe) | on | 8: 252.3 | 32: 767.8 | 515.5 | 24 | 21.5 |
| FrankenPHP worker (warm, embedded) | on | 8: 123.4 | 32: 153.3 | 29.9 | 24 | 1.2 |
| nginx + php-fpm (cold, unix) | on | 8: 55.1 | 32: 84.5 | 29.4 | 24 | 1.2 |

### Memory, after load (peak concurrency)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8 | 9 | 213.0 | 466.4 | 23.7 |
| volucer worker (warm, loopback TCP port) | on | 16 | 17 | 374.7 | 902.9 | 22.0 |
| volucer worker (warm, loopback TCP port) | on | 32 | 33 | 700.7 | 1,782.9 | 21.2 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 69.2 | 283.0 | 6.9 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 82.3 | 490.1 | 4.6 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 102.9 | 880.8 | 3.0 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 193.9 | 446.8 | 21.5 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 339.1 | 865.0 | 19.9 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 629.4 | 1,706.6 | 19.1 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 69.8 | 309.1 | 7.0 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 76.5 | 528.1 | 4.2 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 100.1 | 982.0 | 2.9 |
| volucer external -> php-fpm (cold, unix) | on | 8 | 10 | 66.3 | 304.4 | 6.6 |
| volucer external -> php-fpm (cold, unix) | on | 16 | 18 | 78.3 | 535.8 | 4.3 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 100.5 | 990.9 | 3.0 |
| RoadRunner worker (warm, pipe) | on | 8 | 9 | 257.5 | 508.0 | 28.6 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 431.5 | 957.6 | 25.4 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 776.3 | 1,856.2 | 23.5 |
| FrankenPHP worker (warm, embedded) | on | 8 | 1 | 130.9 | 130.9 | 130.9 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 144.6 | 144.6 | 144.6 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 168.3 | 168.3 | 168.3 |
| nginx + php-fpm (cold, unix) | on | 8 | 14 | 56.1 | 313.9 | 4.0 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 66.5 | 543.0 | 3.0 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 85.9 | 1,001.8 | 2.3 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8: 213.0 | 32: 700.7 | 487.7 | 24 | 20.3 |
| volucer attach (warm, unix relay) | on | 8: 69.2 | 32: 102.9 | 33.7 | 24 | 1.4 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8: 193.9 | 32: 629.4 | 435.5 | 24 | 18.1 |
| volucer external -> php-fpm (cold, unix) | on | 8: 66.3 | 32: 100.5 | 34.2 | 24 | 1.4 |
| RoadRunner worker (warm, pipe) | on | 8: 257.5 | 32: 776.3 | 518.8 | 24 | 21.6 |
| FrankenPHP worker (warm, embedded) | on | 8: 130.9 | 32: 168.3 | 37.4 | 24 | 1.6 |
| nginx + php-fpm (cold, unix) | on | 8: 56.1 | 32: 85.9 | 29.8 | 24 | 1.2 |

## Integrity checks

No failed cells and no dropped responses in any measured cell.


## `/items`

the same list rendered as a template.

# Worker / opcache / concurrency matrix

Every arm on one host, through one harness, so a difference between two
rows is the server rather than the measurement:

| arm | what it is |
|---|---|
| `volucer-tcp` | volucer worker (warm, loopback TCP port) |
| `volucer-attach` | volucer attach (warm, unix relay) |
| `volucer-fastcgi` | volucer spawn_cgi (cold, unix, 1/slot) |
| `volucer-prefork` | volucer spawn_cgi children (cold, unix) |
| `volucer-external` | volucer external -> php-fpm (cold, unix) |
| `rr` | RoadRunner worker (warm, pipe) |
| `frankenphp` | FrankenPHP worker (warm, embedded) |
| `fpm` | nginx + php-fpm (cold, unix) |

Rows: `results\matrix-0.4.1-reval60\matrix.tsv`. Memory: `results\matrix-0.4.1-reval60\memory.tsv`.

Every cell is the **median over the rounds**, with the min–max spread across
rounds in parentheses where there was more than one round. `p50` and `p99` are
each their own median across the rounds of that cell — not the percentile of
whichever round happened to have the median throughput.

`ch=N` marks the `children` axis, which only `volucer-prefork` has: there
`workers` counts listening sockets and `children` counts `php-cgi` processes
behind each, so `w=16 ch=4` is one master, four children, per socket. Every
other arm leaves it empty because it has no such setting.

**A `workers` column is not one quantity across arms, so do not read it
down as if it were.** It is spawned processes for `rr` and the `spawn_cgi`
arms, connections into somebody else's supervisor for `attach`, php-fpm's
`pm.max_children` for `fpm` and `external`, and **threads** — not
processes — for `frankenphp`, which is a single OS process at every
setting. `proc_kind` in `matrix.tsv` records which. The rows that are
actually comparable are the ones whose *total PHP process count* matches:
`prefork` costs `workers x (children + 1)` because every socket carries a
master as well as its children, so `w=1 ch=15` is 16 PHP processes and
equals `w=16` on any one-process-per-slot arm.

## Throughput (requests/sec)

### rps at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 25,511 (25,352–25,640) | 30,259 (30,220–30,481) | 32,444 (31,827–32,728) |
| volucer attach (warm, unix relay) | on | — | 26,443 (26,327–27,397) | 34,395 (34,344–34,649) | 41,481 (41,247–41,521) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 6,489 (6,481–6,515) | 7,455 (7,414–7,499) | 8,241 (8,091–8,328) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 6,624 (6,594–6,658) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 8,590 (8,468–8,591) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 9,957 (9,878–10,082) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 6,612 (6,559–6,656) | 8,567 (8,447–8,641) | 9,824 (9,622–9,915) |
| RoadRunner worker (warm, pipe) | on | — | 22,485 (22,254–22,624) | 25,459 (21,887–25,789) | 25,911 (25,830–26,188) |
| FrankenPHP worker (warm, embedded) | on | — | 21,763 (21,738–22,377) | 16,520 (16,151–16,627) | 15,141 (14,881–15,387) |
| nginx + php-fpm (cold, unix) | on | — | 6,678 (6,636–6,681) | 8,837 (8,770–8,849) | 9,789 (9,699–9,867) |

## Headline readings

### Best configuration per arm

| arm | rps | workers | children | opcache | concurrency |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | 32,444 | 32 | — | on | 96 |
| volucer attach (warm, unix relay) | 41,481 | 32 | — | on | 96 |
| volucer spawn_cgi (cold, unix, 1/slot) | 8,241 | 32 | — | on | 96 |
| volucer spawn_cgi children (cold, unix) | 6,624 | 1 | 8 | on | 96 |
| volucer spawn_cgi children (cold, unix) | 8,590 | 1 | 16 | on | 96 |
| volucer spawn_cgi children (cold, unix) | 9,957 | 1 | 32 | on | 96 |
| volucer external -> php-fpm (cold, unix) | 9,824 | 32 | — | on | 96 |
| RoadRunner worker (warm, pipe) | 25,911 | 32 | — | on | 96 |
| FrankenPHP worker (warm, embedded) | 21,763 | 8 | — | on | 96 |
| nginx + php-fpm (cold, unix) | 9,789 | 32 | — | on | 96 |

### Does another worker help? (concurrency 96, opcache on)

| arm | w=1 | w=8 | w=16 | w=32 | peak | change from w=1 |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | — | 25,511 | 30,259 | 32,444 | w=32 | — |
| volucer attach (warm, unix relay) | — | 26,443 | 34,395 | 41,481 | w=32 | — |
| volucer spawn_cgi (cold, unix, 1/slot) | — | 6,489 | 7,455 | 8,241 | w=32 | — |
| volucer external -> php-fpm (cold, unix) | — | 6,612 | 8,567 | 9,824 | w=32 | — |
| RoadRunner worker (warm, pipe) | — | 22,485 | 25,459 | 25,911 | w=32 | — |
| FrankenPHP worker (warm, embedded) | — | 21,763 | 16,520 | 15,141 | w=8 | — |
| nginx + php-fpm (cold, unix) | — | 6,678 | 8,837 | 9,789 | w=32 | — |

## Latency, p50 (ms)

### p50 at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 3.720 (3.720–3.750) | 3.140 (3.120–3.150) | 2.870 (2.840–2.920) |
| volucer attach (warm, unix relay) | on | — | 3.650 (3.510–3.660) | 2.760 (2.730–2.770) | 2.220 (2.220–2.230) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 14.610 (14.530–15.060) | 11.560 (11.560–11.710) | 9.270 (9.250–9.280) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 14.430 (14.380–14.530) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 11.070 (11.070–11.240) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 9.510 (9.390–9.600) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 17.130 (16.940–17.390) | 16.220 (15.990–16.460) | 12.100 (12.070–12.400) |
| RoadRunner worker (warm, pipe) | on | — | 4.180 (4.160–4.210) | 3.630 (3.580–4.260) | 3.520 (3.470–3.530) |
| FrankenPHP worker (warm, embedded) | on | — | 4.220 (4.100–4.220) | 5.550 (5.520–5.690) | 5.820 (5.710–5.910) |
| nginx + php-fpm (cold, unix) | on | — | 14.290 (14.270–14.370) | 10.750 (10.730–10.830) | 9.600 (9.520–9.700) |

## Latency, p99 (ms)

### p99 at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 13.330 (12.110–19.280) | 8.210 (8.210–8.240) | 6.360 (6.180–6.440) |
| volucer attach (warm, unix relay) | on | — | 12.050 (11.950–12.110) | 7.330 (7.240–7.350) | 4.940 (4.910–4.990) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 60.130 (53.630–60.370) | 76.460 (72.610–76.650) | 72.510 (60.240–75.560) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 38.240 (37.920–39.340) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 28.830 (28.760–29.060) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 19.020 (18.460–19.130) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 46.640 (46.560–46.930) | 21.690 (21.530–21.880) | 17.160 (17.060–17.730) |
| RoadRunner worker (warm, pipe) | on | — | 5.980 (5.930–5.990) | 5.950 (5.900–6.740) | 7.650 (7.610–7.690) |
| FrankenPHP worker (warm, embedded) | on | — | 6.720 (6.580–6.750) | 9.900 (9.810–10.060) | 15.460 (15.210–15.660) |
| nginx + php-fpm (cold, unix) | on | — | 16.680 (16.670–16.860) | 13.290 (13.140–13.330) | 13.140 (13.000–13.230) |

## opcache

Every cell in this run was measured with opcache **on**, which is the
production case and the only one where a shared OPcache segment can exist —
so the ON/OFF ratio is not a column here.
The 8.5 pass that measured it (`results/matrix85-opcache/report.md`)
has the ON/OFF ratio for the arms both runs share.

## Shape comparisons

### Shape comparisons at concurrency 96

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| transport: unix vs pipe | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| memory model: attach vs pipe | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| control: children=1 vs plain spawn_cgi | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| prefork: children=8 vs children=1 | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| prefork: children=16 vs children=1 | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| prefork: children=32 vs children=1 | rps | — | — | — | — |
|  | PSS | — | — | — | — |

## At equal PHP process counts

`workers` is not one quantity across arms (see the note above), so this is
the axis on which the arms can be read against each other. The count is the
measured `pids` of each arm's process tree, not the configured value, and the
parenthesised config is what produced it.

**9 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer worker (warm, loopback TCP port) (w=8) | 25,511 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=8) | 6,489 |
| RoadRunner worker (warm, pipe) (w=8) | 22,485 |

**10 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer attach (warm, unix relay) (w=8) | 26,443 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=8) | 6,624 |
| volucer external -> php-fpm (cold, unix) (w=8) | 6,612 |

**17 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer worker (warm, loopback TCP port) (w=16) | 30,259 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=16) | 7,455 |
| RoadRunner worker (warm, pipe) (w=16) | 25,459 |

**18 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer attach (warm, unix relay) (w=16) | 34,395 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=16) | 8,590 |
| volucer external -> php-fpm (cold, unix) (w=16) | 8,567 |

**33 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer worker (warm, loopback TCP port) (w=32) | 32,444 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=32) | 8,241 |
| RoadRunner worker (warm, pipe) (w=32) | 25,911 |

**34 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer attach (warm, unix relay) (w=32) | 41,481 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=32) | 9,957 |
| volucer external -> php-fpm (cold, unix) (w=32) | 9,824 |

## Memory

### Memory, boot (before any request)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8 | 9 | 204.2 | 458.3 | 22.7 |
| volucer worker (warm, loopback TCP port) | on | 16 | 17 | 348.4 | 871.6 | 20.5 |
| volucer worker (warm, loopback TCP port) | on | 32 | 33 | 594.8 | 1,652.3 | 18.0 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 65.5 | 281.3 | 6.5 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 73.6 | 451.0 | 4.1 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 82.8 | 713.8 | 2.4 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 186.5 | 438.7 | 20.7 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 333.6 | 858.8 | 19.6 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 620.8 | 1,697.3 | 18.8 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 62.1 | 300.0 | 6.2 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 67.5 | 455.7 | 3.8 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 68.6 | 649.4 | 2.0 |
| volucer external -> php-fpm (cold, unix) | on | 8 | 10 | 59.1 | 298.8 | 5.9 |
| volucer external -> php-fpm (cold, unix) | on | 16 | 18 | 71.4 | 527.9 | 4.0 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 90.4 | 979.7 | 2.7 |
| RoadRunner worker (warm, pipe) | on | 8 | 9 | 252.3 | 502.3 | 28.0 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 425.8 | 951.4 | 25.0 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 767.8 | 1,849.0 | 23.3 |
| FrankenPHP worker (warm, embedded) | on | 8 | 1 | 123.4 | 123.4 | 123.4 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 136.8 | 136.8 | 136.8 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 153.3 | 153.3 | 153.3 |
| nginx + php-fpm (cold, unix) | on | 8 | 14 | 55.1 | 312.6 | 3.9 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 65.2 | 541.0 | 3.0 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 84.5 | 999.8 | 2.2 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8: 204.2 | 32: 594.8 | 390.6 | 24 | 16.3 |
| volucer attach (warm, unix relay) | on | 8: 65.5 | 32: 82.8 | 17.3 | 24 | 0.7 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8: 186.5 | 32: 620.8 | 434.3 | 24 | 18.1 |
| volucer external -> php-fpm (cold, unix) | on | 8: 59.1 | 32: 90.4 | 31.3 | 24 | 1.3 |
| RoadRunner worker (warm, pipe) | on | 8: 252.3 | 32: 767.8 | 515.5 | 24 | 21.5 |
| FrankenPHP worker (warm, embedded) | on | 8: 123.4 | 32: 153.3 | 29.9 | 24 | 1.2 |
| nginx + php-fpm (cold, unix) | on | 8: 55.1 | 32: 84.5 | 29.4 | 24 | 1.2 |

### Memory, after load (peak concurrency)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8 | 9 | 213.0 | 466.4 | 23.7 |
| volucer worker (warm, loopback TCP port) | on | 16 | 17 | 374.7 | 902.9 | 22.0 |
| volucer worker (warm, loopback TCP port) | on | 32 | 33 | 700.7 | 1,782.9 | 21.2 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 69.2 | 283.0 | 6.9 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 82.3 | 490.1 | 4.6 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 102.9 | 880.8 | 3.0 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 193.9 | 446.8 | 21.5 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 339.1 | 865.0 | 19.9 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 629.4 | 1,706.6 | 19.1 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 69.8 | 309.1 | 7.0 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 76.5 | 528.1 | 4.2 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 100.1 | 982.0 | 2.9 |
| volucer external -> php-fpm (cold, unix) | on | 8 | 10 | 66.3 | 304.4 | 6.6 |
| volucer external -> php-fpm (cold, unix) | on | 16 | 18 | 78.3 | 535.8 | 4.3 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 100.5 | 990.9 | 3.0 |
| RoadRunner worker (warm, pipe) | on | 8 | 9 | 257.5 | 508.0 | 28.6 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 431.5 | 957.6 | 25.4 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 776.3 | 1,856.2 | 23.5 |
| FrankenPHP worker (warm, embedded) | on | 8 | 1 | 130.9 | 130.9 | 130.9 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 144.6 | 144.6 | 144.6 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 168.3 | 168.3 | 168.3 |
| nginx + php-fpm (cold, unix) | on | 8 | 14 | 56.1 | 313.9 | 4.0 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 66.5 | 543.0 | 3.0 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 85.9 | 1,001.8 | 2.3 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8: 213.0 | 32: 700.7 | 487.7 | 24 | 20.3 |
| volucer attach (warm, unix relay) | on | 8: 69.2 | 32: 102.9 | 33.7 | 24 | 1.4 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8: 193.9 | 32: 629.4 | 435.5 | 24 | 18.1 |
| volucer external -> php-fpm (cold, unix) | on | 8: 66.3 | 32: 100.5 | 34.2 | 24 | 1.4 |
| RoadRunner worker (warm, pipe) | on | 8: 257.5 | 32: 776.3 | 518.8 | 24 | 21.6 |
| FrankenPHP worker (warm, embedded) | on | 8: 130.9 | 32: 168.3 | 37.4 | 24 | 1.6 |
| nginx + php-fpm (cold, unix) | on | 8: 56.1 | 32: 85.9 | 29.8 | 24 | 1.2 |

## Integrity checks

No failed cells and no dropped responses in any measured cell.


## `/items-fast`

the same page as `/items` with the identity map removed: `->objects()` instead of `->entities()`, so the only difference between the two rows is hydration. Byte-identical output, verified.

# Worker / opcache / concurrency matrix

Every arm on one host, through one harness, so a difference between two
rows is the server rather than the measurement:

| arm | what it is |
|---|---|
| `volucer-tcp` | volucer worker (warm, loopback TCP port) |
| `volucer-attach` | volucer attach (warm, unix relay) |
| `volucer-fastcgi` | volucer spawn_cgi (cold, unix, 1/slot) |
| `volucer-prefork` | volucer spawn_cgi children (cold, unix) |
| `volucer-external` | volucer external -> php-fpm (cold, unix) |
| `rr` | RoadRunner worker (warm, pipe) |
| `frankenphp` | FrankenPHP worker (warm, embedded) |
| `fpm` | nginx + php-fpm (cold, unix) |

Rows: `results\matrix-0.4.1-reval60\matrix.tsv`. Memory: `results\matrix-0.4.1-reval60\memory.tsv`.

Every cell is the **median over the rounds**, with the min–max spread across
rounds in parentheses where there was more than one round. `p50` and `p99` are
each their own median across the rounds of that cell — not the percentile of
whichever round happened to have the median throughput.

`ch=N` marks the `children` axis, which only `volucer-prefork` has: there
`workers` counts listening sockets and `children` counts `php-cgi` processes
behind each, so `w=16 ch=4` is one master, four children, per socket. Every
other arm leaves it empty because it has no such setting.

**A `workers` column is not one quantity across arms, so do not read it
down as if it were.** It is spawned processes for `rr` and the `spawn_cgi`
arms, connections into somebody else's supervisor for `attach`, php-fpm's
`pm.max_children` for `fpm` and `external`, and **threads** — not
processes — for `frankenphp`, which is a single OS process at every
setting. `proc_kind` in `matrix.tsv` records which. The rows that are
actually comparable are the ones whose *total PHP process count* matches:
`prefork` costs `workers x (children + 1)` because every socket carries a
master as well as its children, so `w=1 ch=15` is 16 PHP processes and
equals `w=16` on any one-process-per-slot arm.

## Throughput (requests/sec)

### rps at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 30,776 (30,444–31,240) | 36,422 (36,348–36,636) | 39,658 (38,865–40,013) |
| volucer attach (warm, unix relay) | on | — | 32,668 (31,625–32,679) | 41,859 (40,318–43,280) | 50,974 (50,743–51,410) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 6,887 (6,837–6,887) | 8,008 (7,981–8,014) | 8,989 (8,880–8,995) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 7,071 (7,056–7,100) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 9,101 (9,093–9,103) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 10,803 (10,685–10,986) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 7,063 (7,002–7,119) | 9,281 (9,106–9,303) | 10,609 (10,568–10,622) |
| RoadRunner worker (warm, pipe) | on | — | 26,874 (26,055–26,910) | 30,491 (29,829–31,247) | 31,098 (30,228–31,191) |
| FrankenPHP worker (warm, embedded) | on | — | 23,153 (23,109–23,452) | 18,491 (17,754–18,772) | 17,415 (16,881–17,421) |
| nginx + php-fpm (cold, unix) | on | — | 7,027 (7,023–7,140) | 9,321 (9,313–9,350) | 10,594 (10,550–10,663) |

## Headline readings

### Best configuration per arm

| arm | rps | workers | children | opcache | concurrency |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | 39,658 | 32 | — | on | 96 |
| volucer attach (warm, unix relay) | 50,974 | 32 | — | on | 96 |
| volucer spawn_cgi (cold, unix, 1/slot) | 8,989 | 32 | — | on | 96 |
| volucer spawn_cgi children (cold, unix) | 7,071 | 1 | 8 | on | 96 |
| volucer spawn_cgi children (cold, unix) | 9,101 | 1 | 16 | on | 96 |
| volucer spawn_cgi children (cold, unix) | 10,803 | 1 | 32 | on | 96 |
| volucer external -> php-fpm (cold, unix) | 10,609 | 32 | — | on | 96 |
| RoadRunner worker (warm, pipe) | 31,098 | 32 | — | on | 96 |
| FrankenPHP worker (warm, embedded) | 23,153 | 8 | — | on | 96 |
| nginx + php-fpm (cold, unix) | 10,594 | 32 | — | on | 96 |

### Does another worker help? (concurrency 96, opcache on)

| arm | w=1 | w=8 | w=16 | w=32 | peak | change from w=1 |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | — | 30,776 | 36,422 | 39,658 | w=32 | — |
| volucer attach (warm, unix relay) | — | 32,668 | 41,859 | 50,974 | w=32 | — |
| volucer spawn_cgi (cold, unix, 1/slot) | — | 6,887 | 8,008 | 8,989 | w=32 | — |
| volucer external -> php-fpm (cold, unix) | — | 7,063 | 9,281 | 10,609 | w=32 | — |
| RoadRunner worker (warm, pipe) | — | 26,874 | 30,491 | 31,098 | w=32 | — |
| FrankenPHP worker (warm, embedded) | — | 23,153 | 18,491 | 17,415 | w=8 | — |
| nginx + php-fpm (cold, unix) | — | 7,027 | 9,321 | 10,594 | w=32 | — |

## Latency, p50 (ms)

### p50 at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 3.120 (3.060–3.140) | 2.590 (2.590–2.600) | 2.320 (2.310–2.380) |
| volucer attach (warm, unix relay) | on | — | 2.950 (2.940–3.060) | 2.250 (2.170–2.350) | 1.790 (1.780–1.800) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 13.330 (12.740–13.810) | 11.020 (10.750–11.260) | 8.800 (8.690–8.820) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 13.540 (13.460–13.560) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 10.460 (10.450–10.460) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 8.740 (8.630–8.860) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 16.420 (16.180–16.580) | 14.890 (14.810–15.190) | 11.240 (11.190–11.330) |
| RoadRunner worker (warm, pipe) | on | — | 3.480 (3.480–3.600) | 3.000 (2.930–3.080) | 2.920 (2.900–2.980) |
| FrankenPHP worker (warm, embedded) | on | — | 3.970 (3.910–3.970) | 4.950 (4.880–5.160) | 5.050 (5.040–5.220) |
| nginx + php-fpm (cold, unix) | on | — | 13.580 (13.330–13.590) | 10.200 (10.170–10.210) | 8.860 (8.820–8.900) |

## Latency, p99 (ms)

### p99 at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 10.700 (10.530–10.700) | 6.940 (6.920–6.970) | 5.170 (5.120–5.230) |
| volucer attach (warm, unix relay) | on | — | 10.400 (10.350–10.680) | 6.190 (6.060–6.420) | 4.220 (4.150–4.230) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 66.540 (59.690–84.860) | 64.140 (60.090–71.340) | 58.240 (51.160–59.430) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 37.060 (37.050–37.370) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 27.260 (27.120–27.310) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 17.630 (16.600–17.720) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 39.740 (39.430–40.030) | 20.200 (19.900–20.330) | 15.880 (15.860–16.640) |
| RoadRunner worker (warm, pipe) | on | — | 5.090 (5.080–5.230) | 5.220 (5.100–5.420) | 6.640 (6.580–6.710) |
| FrankenPHP worker (warm, embedded) | on | — | 6.330 (6.300–6.450) | 8.790 (8.760–9.210) | 13.740 (13.740–14.110) |
| nginx + php-fpm (cold, unix) | on | — | 15.870 (15.860–15.900) | 12.600 (12.450–12.610) | 12.180 (12.060–12.230) |

## opcache

Every cell in this run was measured with opcache **on**, which is the
production case and the only one where a shared OPcache segment can exist —
so the ON/OFF ratio is not a column here.
The 8.5 pass that measured it (`results/matrix85-opcache/report.md`)
has the ON/OFF ratio for the arms both runs share.

## Shape comparisons

### Shape comparisons at concurrency 96

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| transport: unix vs pipe | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| memory model: attach vs pipe | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| control: children=1 vs plain spawn_cgi | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| prefork: children=8 vs children=1 | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| prefork: children=16 vs children=1 | rps | — | — | — | — |
|  | PSS | — | — | — | — |
| prefork: children=32 vs children=1 | rps | — | — | — | — |
|  | PSS | — | — | — | — |

## At equal PHP process counts

`workers` is not one quantity across arms (see the note above), so this is
the axis on which the arms can be read against each other. The count is the
measured `pids` of each arm's process tree, not the configured value, and the
parenthesised config is what produced it.

**9 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer worker (warm, loopback TCP port) (w=8) | 30,776 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=8) | 6,887 |
| RoadRunner worker (warm, pipe) (w=8) | 26,874 |

**10 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer attach (warm, unix relay) (w=8) | 32,668 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=8) | 7,071 |
| volucer external -> php-fpm (cold, unix) (w=8) | 7,063 |

**17 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer worker (warm, loopback TCP port) (w=16) | 36,422 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=16) | 8,008 |
| RoadRunner worker (warm, pipe) (w=16) | 30,491 |

**18 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer attach (warm, unix relay) (w=16) | 41,859 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=16) | 9,101 |
| volucer external -> php-fpm (cold, unix) (w=16) | 9,281 |

**33 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer worker (warm, loopback TCP port) (w=32) | 39,658 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=32) | 8,989 |
| RoadRunner worker (warm, pipe) (w=32) | 31,098 |

**34 PHP processes**

| arm (config) | c=96 |
|---|---|
| volucer attach (warm, unix relay) (w=32) | 50,974 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=32) | 10,803 |
| volucer external -> php-fpm (cold, unix) (w=32) | 10,609 |

## Memory

### Memory, boot (before any request)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8 | 9 | 204.2 | 458.3 | 22.7 |
| volucer worker (warm, loopback TCP port) | on | 16 | 17 | 348.4 | 871.6 | 20.5 |
| volucer worker (warm, loopback TCP port) | on | 32 | 33 | 594.8 | 1,652.3 | 18.0 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 65.5 | 281.3 | 6.5 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 73.6 | 451.0 | 4.1 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 82.8 | 713.8 | 2.4 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 186.5 | 438.7 | 20.7 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 333.6 | 858.8 | 19.6 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 620.8 | 1,697.3 | 18.8 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 62.1 | 300.0 | 6.2 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 67.5 | 455.7 | 3.8 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 68.6 | 649.4 | 2.0 |
| volucer external -> php-fpm (cold, unix) | on | 8 | 10 | 59.1 | 298.8 | 5.9 |
| volucer external -> php-fpm (cold, unix) | on | 16 | 18 | 71.4 | 527.9 | 4.0 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 90.4 | 979.7 | 2.7 |
| RoadRunner worker (warm, pipe) | on | 8 | 9 | 252.3 | 502.3 | 28.0 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 425.8 | 951.4 | 25.0 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 767.8 | 1,849.0 | 23.3 |
| FrankenPHP worker (warm, embedded) | on | 8 | 1 | 123.4 | 123.4 | 123.4 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 136.8 | 136.8 | 136.8 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 153.3 | 153.3 | 153.3 |
| nginx + php-fpm (cold, unix) | on | 8 | 14 | 55.1 | 312.6 | 3.9 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 65.2 | 541.0 | 3.0 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 84.5 | 999.8 | 2.2 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8: 204.2 | 32: 594.8 | 390.6 | 24 | 16.3 |
| volucer attach (warm, unix relay) | on | 8: 65.5 | 32: 82.8 | 17.3 | 24 | 0.7 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8: 186.5 | 32: 620.8 | 434.3 | 24 | 18.1 |
| volucer external -> php-fpm (cold, unix) | on | 8: 59.1 | 32: 90.4 | 31.3 | 24 | 1.3 |
| RoadRunner worker (warm, pipe) | on | 8: 252.3 | 32: 767.8 | 515.5 | 24 | 21.5 |
| FrankenPHP worker (warm, embedded) | on | 8: 123.4 | 32: 153.3 | 29.9 | 24 | 1.2 |
| nginx + php-fpm (cold, unix) | on | 8: 55.1 | 32: 84.5 | 29.4 | 24 | 1.2 |

### Memory, after load (peak concurrency)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8 | 9 | 213.0 | 466.4 | 23.7 |
| volucer worker (warm, loopback TCP port) | on | 16 | 17 | 374.7 | 902.9 | 22.0 |
| volucer worker (warm, loopback TCP port) | on | 32 | 33 | 700.7 | 1,782.9 | 21.2 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 69.2 | 283.0 | 6.9 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 82.3 | 490.1 | 4.6 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 102.9 | 880.8 | 3.0 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 193.9 | 446.8 | 21.5 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 339.1 | 865.0 | 19.9 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 629.4 | 1,706.6 | 19.1 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 69.8 | 309.1 | 7.0 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 76.5 | 528.1 | 4.2 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 100.1 | 982.0 | 2.9 |
| volucer external -> php-fpm (cold, unix) | on | 8 | 10 | 66.3 | 304.4 | 6.6 |
| volucer external -> php-fpm (cold, unix) | on | 16 | 18 | 78.3 | 535.8 | 4.3 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 100.5 | 990.9 | 3.0 |
| RoadRunner worker (warm, pipe) | on | 8 | 9 | 257.5 | 508.0 | 28.6 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 431.5 | 957.6 | 25.4 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 776.3 | 1,856.2 | 23.5 |
| FrankenPHP worker (warm, embedded) | on | 8 | 1 | 130.9 | 130.9 | 130.9 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 144.6 | 144.6 | 144.6 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 168.3 | 168.3 | 168.3 |
| nginx + php-fpm (cold, unix) | on | 8 | 14 | 56.1 | 313.9 | 4.0 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 66.5 | 543.0 | 3.0 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 85.9 | 1,001.8 | 2.3 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8: 213.0 | 32: 700.7 | 487.7 | 24 | 20.3 |
| volucer attach (warm, unix relay) | on | 8: 69.2 | 32: 102.9 | 33.7 | 24 | 1.4 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8: 193.9 | 32: 629.4 | 435.5 | 24 | 18.1 |
| volucer external -> php-fpm (cold, unix) | on | 8: 66.3 | 32: 100.5 | 34.2 | 24 | 1.4 |
| RoadRunner worker (warm, pipe) | on | 8: 257.5 | 32: 776.3 | 518.8 | 24 | 21.6 |
| FrankenPHP worker (warm, embedded) | on | 8: 130.9 | 32: 168.3 | 37.4 | 24 | 1.6 |
| nginx + php-fpm (cold, unix) | on | 8: 56.1 | 32: 85.9 | 29.8 | 24 | 1.2 |

## Integrity checks

No failed cells and no dropped responses in any measured cell.


