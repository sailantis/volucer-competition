# 4 endpoints, 8 arms, PHP 8.5

Every arm measured on the same four pages, one host, one harness. The pages are
not comparable with each other — they are four different amounts of work — so
each has its own tables below, and a number from one section says nothing
about the same arm in another.

| path | what it measures |
|---|---|
| `/echo` | a routed 5-byte reply: router, dispatcher, both middlewares, then nothing. The framework's floor, and the closest this application gets to no work. |
| `/` | the landing page, rendered through a template. |
| `/api/items` | a JSON list from SQLite through the query builder. |
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

Rows: `/home/competition/matrix-final-5r/matrix.tsv`. Memory: `/home/competition/matrix-final-5r/memory.tsv`.

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

### rps at concurrency 32

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 52,604 (50,485–53,500) | 64,453 (63,915–64,940) | 64,348 (63,787–65,027) |
| volucer attach (warm, unix relay) | on | — | 58,598 (57,324–59,866) | 75,900 (75,427–76,206) | 78,975 (78,646–80,863) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 22,674 (22,467–22,865) | 26,409 (25,721–27,055) | 24,690 (24,339–24,928) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 25,591 (24,696–26,812) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 31,699 (30,936–32,313) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 30,919 (30,142–31,642) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 26,179 (25,531–26,349) | 30,622 (29,553–31,033) | 27,178 (26,139–27,646) |
| RoadRunner worker (warm, pipe) | on | — | 51,889 (51,310–52,662) | 68,848 (67,463–69,509) | 58,638 (57,501–58,760) |
| FrankenPHP worker (warm, embedded) | on | — | 63,770 (63,452–64,156) | 53,447 (52,811–54,211) | 49,504 (8,401–49,792) |
| nginx + php-fpm (cold, unix) | on | — | 33,853 (32,832–34,380) | 38,559 (38,329–39,221) | 35,141 (34,712–35,781) |

### rps at concurrency 64

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 53,062 (52,619–53,808) | 71,666 (70,939–73,246) | 84,041 (83,067–84,455) |
| volucer attach (warm, unix relay) | on | — | 58,766 (58,279–59,514) | 85,835 (85,028–86,840) | 108,569 (106,777–110,881) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 24,059 (22,999–24,356) | 27,658 (27,159–27,903) | 29,949 (29,303–30,425) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 26,215 (24,658–26,595) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 33,364 (33,097–33,842) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 38,895 (38,610–39,455) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 25,793 (25,505–26,160) | 32,892 (31,110–33,597) | 37,243 (35,526–37,795) |
| RoadRunner worker (warm, pipe) | on | — | 52,137 (51,617–52,661) | 69,453 (68,507–69,675) | 74,179 (72,656–74,221) |
| FrankenPHP worker (warm, embedded) | on | — | 69,920 (62,690–70,591) | 49,079 (2,583–50,371) | 42,937 (42,460–43,061) |
| nginx + php-fpm (cold, unix) | on | — | 33,834 (32,963–34,334) | 38,435 (37,906–38,624) | 41,869 (41,288–42,184) |

### rps at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 54,049 (51,503–56,253) | 72,586 (71,444–73,788) | 88,057 (87,231–88,422) |
| volucer attach (warm, unix relay) | on | — | 59,175 (58,210–61,574) | 85,807 (84,917–86,278) | 110,830 (109,868–112,527) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 24,876 (23,495–25,604) | 28,657 (28,408–28,857) | 30,767 (30,137–31,302) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 26,276 (25,270–26,774) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 34,090 (33,307–34,443) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 40,096 (39,644–40,495) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 25,772 (25,376–25,958) | 32,600 (31,605–33,115) | 37,720 (35,879–37,936) |
| RoadRunner worker (warm, pipe) | on | — | 52,168 (51,649–52,312) | 69,785 (68,347–70,511) | 74,833 (73,344–75,807) |
| FrankenPHP worker (warm, embedded) | on | — | 74,076 (73,423–74,883) | 51,514 (50,930–52,036) | 45,004 (30,144–45,692) |
| nginx + php-fpm (cold, unix) | on | — | 34,069 (33,435–34,761) | 38,440 (37,969–38,909) | 41,428 (41,069–42,302) |

## Headline readings

### Best configuration per arm

| arm | rps | workers | children | opcache | concurrency |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | 88,057 | 32 | — | on | 96 |
| volucer attach (warm, unix relay) | 110,830 | 32 | — | on | 96 |
| volucer spawn_cgi (cold, unix, 1/slot) | 30,767 | 32 | — | on | 96 |
| volucer spawn_cgi children (cold, unix) | 26,276 | 1 | 8 | on | 96 |
| volucer spawn_cgi children (cold, unix) | 34,090 | 1 | 16 | on | 96 |
| volucer spawn_cgi children (cold, unix) | 40,096 | 1 | 32 | on | 96 |
| volucer external -> php-fpm (cold, unix) | 37,720 | 32 | — | on | 96 |
| RoadRunner worker (warm, pipe) | 74,833 | 32 | — | on | 96 |
| FrankenPHP worker (warm, embedded) | 74,076 | 8 | — | on | 96 |
| nginx + php-fpm (cold, unix) | 41,869 | 32 | — | on | 64 |

### Does another worker help? (concurrency 96, opcache on)

| arm | w=1 | w=8 | w=16 | w=32 | peak | change from w=1 |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | — | 54,049 | 72,586 | 88,057 | w=32 | — |
| volucer attach (warm, unix relay) | — | 59,175 | 85,807 | 110,830 | w=32 | — |
| volucer spawn_cgi (cold, unix, 1/slot) | — | 24,876 | 28,657 | 30,767 | w=32 | — |
| volucer external -> php-fpm (cold, unix) | — | 25,772 | 32,600 | 37,720 | w=32 | — |
| RoadRunner worker (warm, pipe) | — | 52,168 | 69,785 | 74,833 | w=32 | — |
| FrankenPHP worker (warm, embedded) | — | 74,076 | 51,514 | 45,004 | w=8 | — |
| nginx + php-fpm (cold, unix) | — | 34,069 | 38,440 | 41,428 | w=32 | — |

## Latency, p50 (ms)

### p50 at concurrency 32

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 0.431 (0.424–0.452) | 0.342 (0.339–0.346) | 0.344 (0.340–0.347) |
| volucer attach (warm, unix relay) | on | — | 0.386 (0.374–0.397) | 0.289 (0.289–0.292) | 0.279 (0.275–0.282) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 0.596 (0.586–0.622) | 0.717 (0.699–0.753) | 0.920 (0.910–0.930) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 0.900 (0.860–0.930) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 0.718 (0.702–0.732) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 0.731 (0.715–0.749) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 1.030 (1.010–1.050) | 0.742 (0.734–0.767) | 0.821 (0.806–0.850) |
| RoadRunner worker (warm, pipe) | on | — | 0.433 (0.427–0.438) | 0.303 (0.299–0.309) | 0.363 (0.362–0.370) |
| FrankenPHP worker (warm, embedded) | on | — | 0.306 (0.303–0.308) | 0.360 (0.357–0.365) | 0.375 (0.364–0.380) |
| nginx + php-fpm (cold, unix) | on | — | 0.690 (0.677–0.710) | 0.586 (0.576–0.589) | 0.622 (0.609–0.629) |

### p50 at concurrency 64

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 1.120 (1.100–1.130) | 0.796 (0.776–0.804) | 0.663 (0.659–0.670) |
| volucer attach (warm, unix relay) | on | — | 1.010 (1.000–1.020) | 0.660 (0.656–0.664) | 0.517 (0.508–0.524) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 2.010 (1.940–2.060) | 1.440 (1.420–1.560) | 1.750 (1.740–1.790) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 2.250 (2.210–2.390) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1.760 (1.740–1.780) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1.480 (1.460–1.490) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 3.260 (3.190–3.310) | 2.210 (2.170–2.340) | 1.570 (1.550–1.640) |
| RoadRunner worker (warm, pipe) | on | — | 1.100 (1.090–1.110) | 0.800 (0.798–0.808) | 0.694 (0.691–0.708) |
| FrankenPHP worker (warm, embedded) | on | — | 0.741 (0.735–0.787) | 1.100 (1.050–1.150) | 1.230 (1.210–1.240) |
| nginx + php-fpm (cold, unix) | on | — | 1.750 (1.720–1.790) | 1.530 (1.520–1.550) | 1.340 (1.330–1.360) |

### p50 at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 1.780 (1.690–1.870) | 1.280 (1.260–1.310) | 1.030 (1.020–1.040) |
| volucer attach (warm, unix relay) | on | — | 1.620 (1.560–1.650) | 1.080 (1.070–1.090) | 0.820 (0.809–0.820) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 3.590 (3.510–3.770) | 2.550 (2.520–2.680) | 2.550 (2.490–2.610) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 3.610 (3.540–3.770) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 2.790 (2.760–2.860) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 2.320 (2.300–2.350) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 5.150 (4.650–5.210) | 4.020 (3.940–4.100) | 2.930 (2.890–3.040) |
| RoadRunner worker (warm, pipe) | on | — | 1.760 (1.750–1.780) | 1.280 (1.270–1.310) | 1.140 (1.130–1.160) |
| FrankenPHP worker (warm, embedded) | on | — | 1.150 (1.140–1.170) | 1.745 (1.730–1.760) | 1.900 (1.830–1.920) |
| nginx + php-fpm (cold, unix) | on | — | 2.790 (2.720–2.840) | 2.460 (2.430–2.490) | 2.220 (2.160–2.230) |

## Latency, p99 (ms)

### p99 at concurrency 32

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 1.140 (1.130–1.170) | 0.930 (0.920–0.940) | 0.940 (0.930–0.980) |
| volucer attach (warm, unix relay) | on | — | 1.030 (1.030–1.040) | 0.790 (0.768–0.801) | 0.707 (0.676–0.746) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 6.780 (6.470–7.010) | 3.590 (3.500–3.690) | 1.890 (1.880–1.930) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 2.110 (2.060–2.220) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1.540 (1.510–1.580) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1.570 (1.530–1.620) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 1.960 (1.920–2.000) | 1.620 (1.610–1.680) | 1.900 (1.870–1.990) |
| RoadRunner worker (warm, pipe) | on | — | 1.040 (1.020–1.040) | 1.200 (1.190–1.230) | 1.210 (1.200–1.220) |
| FrankenPHP worker (warm, embedded) | on | — | 1.500 (1.470–1.510) | 2.770 (2.450–4.820) | 2.670 (1.950–3.460) |
| nginx + php-fpm (cold, unix) | on | — | 1.000 (0.990–1.040) | 1.230 (1.220–1.250) | 1.770 (1.740–1.800) |

### p99 at concurrency 64

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 3.830 (3.800–3.860) | 2.130 (2.110–2.170) | 1.920 (1.880–1.930) |
| volucer attach (warm, unix relay) | on | — | 3.570 (3.530–3.600) | 1.810 (1.770–1.840) | 1.280 (1.230–1.360) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 19.950 (17.230–23.120) | 20.160 (15.690–22.140) | 6.480 (6.270–6.510) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 6.630 (6.460–6.950) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 4.090 (4.050–4.130) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 3.010 (2.960–3.040) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 5.070 (4.970–5.120) | 3.830 (3.750–4.000) | 3.640 (3.520–3.750) |
| RoadRunner worker (warm, pipe) | on | — | 1.930 (1.910–1.970) | 1.940 (1.930–2.010) | 3.100 (3.050–3.180) |
| FrankenPHP worker (warm, embedded) | on | — | 2.970 (2.940–991.740) | 3.760 (3.690–873.030) | 4.960 (4.930–5.070) |
| nginx + php-fpm (cold, unix) | on | — | 2.260 (2.210–2.310) | 2.230 (2.200–2.250) | 3.350 (3.320–3.400) |

### p99 at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 6.660 (6.530–6.830) | 3.800 (3.730–3.840) | 2.650 (2.630–2.700) |
| volucer attach (warm, unix relay) | on | — | 6.200 (6.010–6.230) | 3.250 (3.240–3.290) | 2.020 (1.930–2.100) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 27.810 (24.050–37.760) | 37.010 (32.250–38.060) | 13.660 (13.410–15.620) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 10.950 (10.870–11.460) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 7.220 (7.120–7.360) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 4.860 (4.830–4.920) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 8.080 (7.990–8.210) | 6.220 (6.100–6.370) | 5.220 (5.130–5.440) |
| RoadRunner worker (warm, pipe) | on | — | 3.020 (3.010–3.070) | 2.730 (2.680–2.760) | 3.610 (3.570–3.740) |
| FrankenPHP worker (warm, embedded) | on | — | 4.250 (4.240–4.280) | 5.335 (5.120–5.380) | 5.850 (5.800–5.900) |
| nginx + php-fpm (cold, unix) | on | — | 3.510 (3.400–3.560) | 3.250 (3.240–3.330) | 4.130 (4.030–4.200) |

## opcache

Every cell in this run was measured with opcache **on**, which is the
production case and the only one where a shared OPcache segment can exist —
so the ON/OFF ratio is not a column here.
The 8.5 pass that measured it (`results/matrix85-opcache/report.md`)
has the ON/OFF ratio for the arms both runs share.

## Shape comparisons

### Shape comparisons at concurrency 32

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

### Shape comparisons at concurrency 64

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

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer worker (warm, loopback TCP port) (w=8) | 52,604 | 53,062 | 54,049 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=8) | 22,674 | 24,059 | 24,876 |
| RoadRunner worker (warm, pipe) (w=8) | 51,889 | 52,137 | 52,168 |

**10 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer attach (warm, unix relay) (w=8) | 58,598 | 58,766 | 59,175 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=8) | 25,591 | 26,215 | 26,276 |
| volucer external -> php-fpm (cold, unix) (w=8) | 26,179 | 25,793 | 25,772 |

**17 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer worker (warm, loopback TCP port) (w=16) | 64,453 | 71,666 | 72,586 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=16) | 26,409 | 27,658 | 28,657 |
| RoadRunner worker (warm, pipe) (w=16) | 68,848 | 69,453 | 69,785 |

**18 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer attach (warm, unix relay) (w=16) | 75,900 | 85,835 | 85,807 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=16) | 31,699 | 33,364 | 34,090 |
| volucer external -> php-fpm (cold, unix) (w=16) | 30,622 | 32,892 | 32,600 |

**33 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer worker (warm, loopback TCP port) (w=32) | 64,348 | 84,041 | 88,057 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=32) | 24,690 | 29,949 | 30,767 |
| RoadRunner worker (warm, pipe) (w=32) | 58,638 | 74,179 | 74,833 |

**34 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer attach (warm, unix relay) (w=32) | 78,975 | 108,569 | 110,830 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=32) | 30,919 | 38,895 | 40,096 |
| volucer external -> php-fpm (cold, unix) (w=32) | 27,178 | 37,243 | 37,720 |

## Memory

### Memory, boot (before any request)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8 | 9 | 204.7 | 460.0 | 22.7 |
| volucer worker (warm, loopback TCP port) | on | 16 | 17 | 348.7 | 874.3 | 20.5 |
| volucer worker (warm, loopback TCP port) | on | 32 | 33 | 594.0 | 1,652.7 | 18.0 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 65.5 | 281.7 | 6.5 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 72.6 | 449.9 | 4.0 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 82.5 | 710.4 | 2.4 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 186.9 | 441.1 | 20.8 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 336.3 | 865.1 | 19.8 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 626.3 | 1,708.6 | 19.0 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 61.2 | 295.7 | 6.1 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 65.2 | 452.8 | 3.6 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 66.1 | 630.8 | 1.9 |
| volucer external -> php-fpm (cold, unix) | on | 8 | 10 | 60.0 | 301.1 | 6.0 |
| volucer external -> php-fpm (cold, unix) | on | 16 | 18 | 69.8 | 531.4 | 3.9 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 85.4 | 990.1 | 2.5 |
| RoadRunner worker (warm, pipe) | on | 8 | 9 | 248.3 | 500.6 | 27.6 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 415.3 | 944.8 | 24.4 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 744.3 | 1,831.4 | 22.6 |
| FrankenPHP worker (warm, embedded) | on | 8 | 1 | 126.2 | 126.2 | 126.2 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 140.5 | 140.5 | 140.5 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 156.2 | 156.2 | 156.2 |
| nginx + php-fpm (cold, unix) | on | 8 | 14 | 53.7 | 310.7 | 3.8 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 62.7 | 541.8 | 2.9 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 79.0 | 1,000.6 | 2.1 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8: 204.7 | 32: 594.0 | 389.3 | 24 | 16.2 |
| volucer attach (warm, unix relay) | on | 8: 65.5 | 32: 82.5 | 17.0 | 24 | 0.7 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8: 186.9 | 32: 626.3 | 439.4 | 24 | 18.3 |
| volucer external -> php-fpm (cold, unix) | on | 8: 60.0 | 32: 85.4 | 25.4 | 24 | 1.1 |
| RoadRunner worker (warm, pipe) | on | 8: 248.3 | 32: 744.3 | 496.0 | 24 | 20.7 |
| FrankenPHP worker (warm, embedded) | on | 8: 126.2 | 32: 156.2 | 30.0 | 24 | 1.2 |
| nginx + php-fpm (cold, unix) | on | 8: 53.7 | 32: 79.0 | 25.3 | 24 | 1.1 |

### Memory, after load (peak concurrency)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8 | 9 | 211.1 | 466.6 | 23.5 |
| volucer worker (warm, loopback TCP port) | on | 16 | 17 | 375.0 | 906.7 | 22.1 |
| volucer worker (warm, loopback TCP port) | on | 32 | 33 | 699.8 | 1,788.5 | 21.2 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 68.8 | 279.7 | 6.9 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 82.0 | 487.1 | 4.6 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 100.2 | 878.1 | 2.9 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 193.8 | 448.0 | 21.5 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 340.3 | 869.9 | 20.0 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 633.7 | 1,716.3 | 19.2 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 65.5 | 300.7 | 6.5 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 73.3 | 523.4 | 4.1 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 93.2 | 972.9 | 2.7 |
| volucer external -> php-fpm (cold, unix) | on | 8 | 10 | 68.5 | 310.4 | 6.8 |
| volucer external -> php-fpm (cold, unix) | on | 16 | 18 | 76.0 | 538.9 | 4.2 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 95.2 | 1,001.0 | 2.8 |
| RoadRunner worker (warm, pipe) | on | 8 | 9 | 252.8 | 505.2 | 28.1 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 420.5 | 949.5 | 24.7 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 749.6 | 1,836.8 | 22.7 |
| FrankenPHP worker (warm, embedded) | on | 8 | 1 | 131.8 | 131.8 | 131.8 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 146.4 | 146.4 | 146.4 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 170.0 | 170.0 | 170.0 |
| nginx + php-fpm (cold, unix) | on | 8 | 14 | 54.8 | 312.2 | 3.9 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 63.6 | 543.4 | 2.9 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 80.5 | 1,002.6 | 2.1 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8: 211.1 | 32: 699.8 | 488.7 | 24 | 20.4 |
| volucer attach (warm, unix relay) | on | 8: 68.8 | 32: 100.2 | 31.4 | 24 | 1.3 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8: 193.8 | 32: 633.7 | 439.9 | 24 | 18.3 |
| volucer external -> php-fpm (cold, unix) | on | 8: 68.5 | 32: 95.2 | 26.7 | 24 | 1.1 |
| RoadRunner worker (warm, pipe) | on | 8: 252.8 | 32: 749.6 | 496.8 | 24 | 20.7 |
| FrankenPHP worker (warm, embedded) | on | 8: 131.8 | 32: 170.0 | 38.2 | 24 | 1.6 |
| nginx + php-fpm (cold, unix) | on | 8: 54.8 | 32: 80.5 | 25.7 | 24 | 1.1 |

## Integrity checks

**4 cell(s) reported failures or dropped responses.** A cell with `Non-2xx` responses is a pool shedding load, which is a
throughput number that looks like the fix working; it is listed here rather
than silently averaged in.

| arm | workers | opcache | conc | round | rps | errors |
|---|---|---|---|---|---|---|
| frankenphp | 16 | on | 96 | 4 | FAIL | 0 |
| frankenphp | 32 | on | 64 | 4 | FAIL | 0 |
| frankenphp | 32 | on | 64 | 5 | FAIL | 0 |
| frankenphp | 32 | on | 96 | 4 | 30143.94 | 1 |


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

Rows: `/home/competition/matrix-final-5r/matrix.tsv`. Memory: `/home/competition/matrix-final-5r/memory.tsv`.

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

### rps at concurrency 32

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 46,221 (45,830–49,261) | 55,874 (55,733–56,254) | 55,300 (54,537–55,575) |
| volucer attach (warm, unix relay) | on | — | 51,315 (49,927–52,040) | 65,437 (64,713–66,198) | 69,562 (68,867–70,564) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 17,885 (16,522–18,227) | 20,256 (19,997–20,587) | 19,570 (19,487–19,894) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 20,746 (20,293–20,894) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 24,828 (24,064–25,337) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 23,798 (23,337–24,123) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 20,932 (20,419–21,410) | 24,409 (23,640–25,208) | 21,649 (20,783–21,921) |
| RoadRunner worker (warm, pipe) | on | — | 43,370 (42,600–43,749) | 55,050 (54,391–55,810) | 46,923 (46,265–47,638) |
| FrankenPHP worker (warm, embedded) | on | — | 29,375 (29,217–30,043) | 24,772 (24,606–25,019) | 21,417 (21,080–21,747) |
| nginx + php-fpm (cold, unix) | on | — | 23,665 (23,365–24,147) | 27,858 (27,103–28,179) | 26,322 (26,129–26,578) |

### rps at concurrency 64

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 47,532 (46,182–48,014) | 62,013 (61,330–62,846) | 72,265 (71,995–72,627) |
| volucer attach (warm, unix relay) | on | — | 51,082 (49,525–52,116) | 73,480 (72,742–74,040) | 93,937 (91,580–95,609) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 19,436 (18,903–19,627) | 22,373 (21,752–22,881) | 23,738 (23,563–23,952) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 20,902 (20,184–21,156) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 26,620 (26,133–27,248) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 30,180 (29,612–30,955) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 20,826 (20,718–21,240) | 25,853 (24,853–26,205) | 28,864 (28,153–29,175) |
| RoadRunner worker (warm, pipe) | on | — | 43,707 (43,420–44,351) | 54,963 (53,583–55,622) | 57,396 (56,558–58,203) |
| FrankenPHP worker (warm, embedded) | on | — | 30,388 (29,942–30,835) | 25,775 (25,256–26,074) | 24,538 (24,365–24,970) |
| nginx + php-fpm (cold, unix) | on | — | 23,439 (23,266–23,904) | 27,209 (26,982–27,428) | 30,677 (30,574–30,815) |

### rps at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 48,255 (46,681–49,360) | 62,660 (62,332–63,298) | 75,194 (74,421–76,540) |
| volucer attach (warm, unix relay) | on | — | 52,552 (51,034–54,248) | 74,361 (73,064–75,358) | 97,681 (94,386–98,612) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 20,101 (19,370–20,357) | 23,167 (22,587–23,417) | 24,403 (24,020–24,533) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 21,118 (19,952–21,309) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 26,522 (26,106–27,533) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 31,213 (30,588–31,429) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 20,743 (20,295–21,327) | 25,766 (24,575–25,992) | 29,006 (27,799–29,349) |
| RoadRunner worker (warm, pipe) | on | — | 43,895 (42,811–44,518) | 54,759 (53,740–55,408) | 57,377 (55,056–57,847) |
| FrankenPHP worker (warm, embedded) | on | — | 31,268 (22,311–31,517) | 25,988 (16,130–26,544) | 24,854 (24,379–25,456) |
| nginx + php-fpm (cold, unix) | on | — | 23,503 (23,058–23,665) | 27,258 (26,977–27,563) | 30,452 (30,043–30,843) |

## Headline readings

### Best configuration per arm

| arm | rps | workers | children | opcache | concurrency |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | 75,194 | 32 | — | on | 96 |
| volucer attach (warm, unix relay) | 97,681 | 32 | — | on | 96 |
| volucer spawn_cgi (cold, unix, 1/slot) | 24,403 | 32 | — | on | 96 |
| volucer spawn_cgi children (cold, unix) | 21,118 | 1 | 8 | on | 96 |
| volucer spawn_cgi children (cold, unix) | 26,620 | 1 | 16 | on | 64 |
| volucer spawn_cgi children (cold, unix) | 31,213 | 1 | 32 | on | 96 |
| volucer external -> php-fpm (cold, unix) | 29,006 | 32 | — | on | 96 |
| RoadRunner worker (warm, pipe) | 57,396 | 32 | — | on | 64 |
| FrankenPHP worker (warm, embedded) | 31,268 | 8 | — | on | 96 |
| nginx + php-fpm (cold, unix) | 30,677 | 32 | — | on | 64 |

### Does another worker help? (concurrency 96, opcache on)

| arm | w=1 | w=8 | w=16 | w=32 | peak | change from w=1 |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | — | 48,255 | 62,660 | 75,194 | w=32 | — |
| volucer attach (warm, unix relay) | — | 52,552 | 74,361 | 97,681 | w=32 | — |
| volucer spawn_cgi (cold, unix, 1/slot) | — | 20,101 | 23,167 | 24,403 | w=32 | — |
| volucer external -> php-fpm (cold, unix) | — | 20,743 | 25,766 | 29,006 | w=32 | — |
| RoadRunner worker (warm, pipe) | — | 43,895 | 54,759 | 57,377 | w=32 | — |
| FrankenPHP worker (warm, embedded) | — | 31,268 | 25,988 | 24,854 | w=8 | — |
| nginx + php-fpm (cold, unix) | — | 23,503 | 27,258 | 30,452 | w=32 | — |

## Latency, p50 (ms)

### p50 at concurrency 32

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 0.487 (0.456–0.498) | 0.397 (0.394–0.399) | 0.403 (0.401–0.407) |
| volucer attach (warm, unix relay) | on | — | 0.439 (0.434–0.454) | 0.337 (0.335–0.342) | 0.321 (0.318–0.325) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 0.757 (0.719–0.814) | 0.940 (0.910–0.970) | 1.150 (1.140–1.170) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1.110 (1.100–1.130) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 0.920 (0.900–0.950) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 0.950 (0.930–0.970) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 1.270 (1.260–1.310) | 0.930 (0.900–0.960) | 1.030 (1.010–1.070) |
| RoadRunner worker (warm, pipe) | on | — | 0.507 (0.503–0.517) | 0.372 (0.369–0.377) | 0.448 (0.441–0.455) |
| FrankenPHP worker (warm, embedded) | on | — | 0.698 (0.682–0.704) | 0.812 (0.802–0.818) | 1.030 (1.020–1.050) |
| nginx + php-fpm (cold, unix) | on | — | 0.990 (0.970–1.000) | 0.817 (0.808–0.842) | 0.834 (0.827–0.840) |

### p50 at concurrency 64

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 1.250 (1.230–1.290) | 0.920 (0.910–0.930) | 0.773 (0.768–0.776) |
| volucer attach (warm, unix relay) | on | — | 1.160 (1.140–1.200) | 0.769 (0.766–0.783) | 0.599 (0.589–0.611) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 2.580 (2.490–2.600) | 1.900 (1.890–1.980) | 2.130 (2.110–2.140) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 2.800 (2.790–2.920) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 2.210 (2.150–2.250) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1.930 (1.860–1.970) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 3.860 (3.740–3.960) | 2.900 (2.860–3.010) | 2.050 (2.040–2.110) |
| RoadRunner worker (warm, pipe) | on | — | 1.290 (1.270–1.300) | 1.000 (0.990–1.030) | 0.900 (0.890–0.920) |
| FrankenPHP worker (warm, embedded) | on | — | 1.810 (1.780–1.840) | 2.110 (2.080–2.150) | 2.190 (2.150–2.210) |
| nginx + php-fpm (cold, unix) | on | — | 2.520 (2.480–2.540) | 2.160 (2.140–2.180) | 1.850 (1.840–1.860) |

### p50 at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 1.990 (1.920–2.060) | 1.490 (1.480–1.500) | 1.200 (1.190–1.220) |
| volucer attach (warm, unix relay) | on | — | 1.840 (1.780–1.880) | 1.250 (1.240–1.280) | 0.930 (0.920–0.960) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 4.690 (4.600–4.760) | 3.470 (3.360–3.620) | 3.100 (3.050–3.230) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 4.490 (4.460–4.780) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 3.590 (3.450–3.640) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 3.000 (2.970–3.050) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 5.180 (5.100–5.320) | 5.210 (5.170–5.430) | 3.900 (3.830–4.050) |
| RoadRunner worker (warm, pipe) | on | — | 2.070 (2.030–2.120) | 1.630 (1.610–1.660) | 1.500 (1.490–1.570) |
| FrankenPHP worker (warm, embedded) | on | — | 2.870 (2.850–2.930) | 3.410 (3.340–3.480) | 3.510 (3.430–3.590) |
| nginx + php-fpm (cold, unix) | on | — | 4.040 (4.020–4.120) | 3.470 (3.440–3.500) | 3.040 (3.010–3.090) |

## Latency, p99 (ms)

### p99 at concurrency 32

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 1.310 (1.280–1.360) | 1.050 (1.010–1.050) | 1.050 (1.040–1.070) |
| volucer attach (warm, unix relay) | on | — | 1.200 (1.180–1.220) | 0.900 (0.860–0.940) | 0.765 (0.724–0.777) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 9.260 (7.880–10.690) | 4.930 (4.700–5.040) | 2.430 (2.390–2.440) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 2.700 (2.630–2.720) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1.910 (1.870–1.980) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 2.030 (1.990–2.070) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 2.470 (2.380–2.540) | 1.970 (1.930–2.040) | 2.350 (2.320–2.440) |
| RoadRunner worker (warm, pipe) | on | — | 1.250 (1.240–1.260) | 1.490 (1.490–1.540) | 1.540 (1.520–1.560) |
| FrankenPHP worker (warm, embedded) | on | — | 2.280 (2.250–2.290) | 3.960 (3.950–3.990) | 4.570 (4.490–4.640) |
| nginx + php-fpm (cold, unix) | on | — | 1.390 (1.340–1.400) | 1.620 (1.600–1.650) | 2.200 (2.170–2.230) |

### p99 at concurrency 64

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 4.310 (4.260–4.410) | 2.450 (2.420–2.460) | 2.120 (2.050–2.160) |
| volucer attach (warm, unix relay) | on | — | 4.110 (4.050–4.200) | 2.120 (2.080–2.150) | 1.490 (1.430–1.600) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 23.180 (18.020–26.770) | 16.360 (14.870–17.450) | 10.300 (9.920–10.620) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 8.180 (8.130–8.510) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 5.220 (5.070–5.300) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 3.740 (3.660–3.800) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 6.350 (6.170–6.430) | 4.570 (4.510–4.750) | 4.280 (4.270–4.430) |
| RoadRunner worker (warm, pipe) | on | — | 2.290 (2.240–2.310) | 2.370 (2.340–2.400) | 3.640 (3.580–3.750) |
| FrankenPHP worker (warm, embedded) | on | — | 3.860 (3.820–3.930) | 5.390 (5.330–5.440) | 8.690 (8.610–8.780) |
| nginx + php-fpm (cold, unix) | on | — | 3.240 (3.170–3.300) | 3.050 (3.030–3.080) | 3.870 (3.840–3.960) |

### p99 at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 7.420 (7.340–8.900) | 4.330 (4.300–4.340) | 3.050 (2.970–3.190) |
| volucer attach (warm, unix relay) | on | — | 7.000 (6.870–7.140) | 3.730 (3.720–3.810) | 2.270 (2.230–2.470) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 29.330 (26.020–34.570) | 27.710 (25.450–28.200) | 19.740 (17.850–21.020) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 13.540 (13.230–14.460) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 9.410 (8.980–9.490) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 6.110 (6.090–6.220) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 10.250 (9.890–10.470) | 7.430 (7.370–7.690) | 6.430 (6.340–6.750) |
| RoadRunner worker (warm, pipe) | on | — | 3.510 (3.410–3.540) | 3.370 (3.320–3.420) | 4.460 (4.340–4.540) |
| FrankenPHP worker (warm, embedded) | on | — | 5.220 (5.180–5.300) | 6.780 (6.710–6.890) | 10.100 (9.770–10.180) |
| nginx + php-fpm (cold, unix) | on | — | 5.090 (5.060–5.280) | 4.520 (4.460–4.580) | 5.080 (5.050–5.160) |

## opcache

Every cell in this run was measured with opcache **on**, which is the
production case and the only one where a shared OPcache segment can exist —
so the ON/OFF ratio is not a column here.
The 8.5 pass that measured it (`results/matrix85-opcache/report.md`)
has the ON/OFF ratio for the arms both runs share.

## Shape comparisons

### Shape comparisons at concurrency 32

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

### Shape comparisons at concurrency 64

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

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer worker (warm, loopback TCP port) (w=8) | 46,221 | 47,532 | 48,255 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=8) | 17,885 | 19,436 | 20,101 |
| RoadRunner worker (warm, pipe) (w=8) | 43,370 | 43,707 | 43,895 |

**10 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer attach (warm, unix relay) (w=8) | 51,315 | 51,082 | 52,552 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=8) | 20,746 | 20,902 | 21,118 |
| volucer external -> php-fpm (cold, unix) (w=8) | 20,932 | 20,826 | 20,743 |

**17 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer worker (warm, loopback TCP port) (w=16) | 55,874 | 62,013 | 62,660 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=16) | 20,256 | 22,373 | 23,167 |
| RoadRunner worker (warm, pipe) (w=16) | 55,050 | 54,963 | 54,759 |

**18 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer attach (warm, unix relay) (w=16) | 65,437 | 73,480 | 74,361 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=16) | 24,828 | 26,620 | 26,522 |
| volucer external -> php-fpm (cold, unix) (w=16) | 24,409 | 25,853 | 25,766 |

**33 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer worker (warm, loopback TCP port) (w=32) | 55,300 | 72,265 | 75,194 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=32) | 19,570 | 23,738 | 24,403 |
| RoadRunner worker (warm, pipe) (w=32) | 46,923 | 57,396 | 57,377 |

**34 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer attach (warm, unix relay) (w=32) | 69,562 | 93,937 | 97,681 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=32) | 23,798 | 30,180 | 31,213 |
| volucer external -> php-fpm (cold, unix) (w=32) | 21,649 | 28,864 | 29,006 |

## Memory

### Memory, boot (before any request)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8 | 9 | 204.7 | 460.0 | 22.7 |
| volucer worker (warm, loopback TCP port) | on | 16 | 17 | 348.7 | 874.3 | 20.5 |
| volucer worker (warm, loopback TCP port) | on | 32 | 33 | 594.0 | 1,652.7 | 18.0 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 65.5 | 281.7 | 6.5 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 72.6 | 449.9 | 4.0 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 82.5 | 710.4 | 2.4 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 186.9 | 441.1 | 20.8 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 336.3 | 865.1 | 19.8 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 626.3 | 1,708.6 | 19.0 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 61.2 | 295.7 | 6.1 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 65.2 | 452.8 | 3.6 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 66.1 | 630.8 | 1.9 |
| volucer external -> php-fpm (cold, unix) | on | 8 | 10 | 60.0 | 301.1 | 6.0 |
| volucer external -> php-fpm (cold, unix) | on | 16 | 18 | 69.8 | 531.4 | 3.9 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 85.4 | 990.1 | 2.5 |
| RoadRunner worker (warm, pipe) | on | 8 | 9 | 248.3 | 500.6 | 27.6 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 415.3 | 944.8 | 24.4 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 744.3 | 1,831.4 | 22.6 |
| FrankenPHP worker (warm, embedded) | on | 8 | 1 | 126.2 | 126.2 | 126.2 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 140.5 | 140.5 | 140.5 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 156.2 | 156.2 | 156.2 |
| nginx + php-fpm (cold, unix) | on | 8 | 14 | 53.7 | 310.7 | 3.8 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 62.7 | 541.8 | 2.9 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 79.0 | 1,000.6 | 2.1 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8: 204.7 | 32: 594.0 | 389.3 | 24 | 16.2 |
| volucer attach (warm, unix relay) | on | 8: 65.5 | 32: 82.5 | 17.0 | 24 | 0.7 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8: 186.9 | 32: 626.3 | 439.4 | 24 | 18.3 |
| volucer external -> php-fpm (cold, unix) | on | 8: 60.0 | 32: 85.4 | 25.4 | 24 | 1.1 |
| RoadRunner worker (warm, pipe) | on | 8: 248.3 | 32: 744.3 | 496.0 | 24 | 20.7 |
| FrankenPHP worker (warm, embedded) | on | 8: 126.2 | 32: 156.2 | 30.0 | 24 | 1.2 |
| nginx + php-fpm (cold, unix) | on | 8: 53.7 | 32: 79.0 | 25.3 | 24 | 1.1 |

### Memory, after load (peak concurrency)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8 | 9 | 211.1 | 466.6 | 23.5 |
| volucer worker (warm, loopback TCP port) | on | 16 | 17 | 375.0 | 906.7 | 22.1 |
| volucer worker (warm, loopback TCP port) | on | 32 | 33 | 699.8 | 1,788.5 | 21.2 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 68.8 | 279.7 | 6.9 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 82.0 | 487.1 | 4.6 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 100.2 | 878.1 | 2.9 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 193.8 | 448.0 | 21.5 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 340.3 | 869.9 | 20.0 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 633.7 | 1,716.3 | 19.2 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 65.5 | 300.7 | 6.5 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 73.3 | 523.4 | 4.1 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 93.2 | 972.9 | 2.7 |
| volucer external -> php-fpm (cold, unix) | on | 8 | 10 | 68.5 | 310.4 | 6.8 |
| volucer external -> php-fpm (cold, unix) | on | 16 | 18 | 76.0 | 538.9 | 4.2 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 95.2 | 1,001.0 | 2.8 |
| RoadRunner worker (warm, pipe) | on | 8 | 9 | 252.8 | 505.2 | 28.1 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 420.5 | 949.5 | 24.7 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 749.6 | 1,836.8 | 22.7 |
| FrankenPHP worker (warm, embedded) | on | 8 | 1 | 131.8 | 131.8 | 131.8 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 146.4 | 146.4 | 146.4 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 170.0 | 170.0 | 170.0 |
| nginx + php-fpm (cold, unix) | on | 8 | 14 | 54.8 | 312.2 | 3.9 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 63.6 | 543.4 | 2.9 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 80.5 | 1,002.6 | 2.1 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8: 211.1 | 32: 699.8 | 488.7 | 24 | 20.4 |
| volucer attach (warm, unix relay) | on | 8: 68.8 | 32: 100.2 | 31.4 | 24 | 1.3 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8: 193.8 | 32: 633.7 | 439.9 | 24 | 18.3 |
| volucer external -> php-fpm (cold, unix) | on | 8: 68.5 | 32: 95.2 | 26.7 | 24 | 1.1 |
| RoadRunner worker (warm, pipe) | on | 8: 252.8 | 32: 749.6 | 496.8 | 24 | 20.7 |
| FrankenPHP worker (warm, embedded) | on | 8: 131.8 | 32: 170.0 | 38.2 | 24 | 1.6 |
| nginx + php-fpm (cold, unix) | on | 8: 54.8 | 32: 80.5 | 25.7 | 24 | 1.1 |

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

Rows: `/home/competition/matrix-final-5r/matrix.tsv`. Memory: `/home/competition/matrix-final-5r/memory.tsv`.

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

### rps at concurrency 32

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 37,808 (36,059–40,355) | 42,705 (41,813–44,158) | 41,396 (39,763–41,697) |
| volucer attach (warm, unix relay) | on | — | 41,546 (38,789–43,907) | 51,257 (49,846–51,585) | 52,458 (51,711–53,270) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 8,871 (8,806–9,010) | 10,179 (9,904–10,235) | 10,625 (10,346–10,776) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 9,539 (9,306–9,632) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 12,653 (12,399–12,802) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 12,659 (12,497–12,807) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 9,425 (9,266–9,539) | 12,516 (12,051–12,600) | 11,928 (11,328–12,012) |
| RoadRunner worker (warm, pipe) | on | — | 37,829 (36,651–38,238) | 45,609 (44,467–46,316) | 38,017 (37,616–38,226) |
| FrankenPHP worker (warm, embedded) | on | — | 52,421 (50,601–53,412) | 41,092 (40,484–41,617) | 39,366 (39,293–40,408) |
| nginx + php-fpm (cold, unix) | on | — | 9,664 (9,497–9,866) | 12,986 (12,897–13,082) | 13,537 (13,406–13,624) |

### rps at concurrency 64

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 38,906 (37,931–40,029) | 46,237 (45,403–47,382) | 51,528 (49,909–52,348) |
| volucer attach (warm, unix relay) | on | — | 41,160 (40,935–43,829) | 55,974 (53,889–56,139) | 68,609 (66,392–69,318) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 9,124 (9,012–9,222) | 10,886 (10,597–10,943) | 12,481 (12,286–12,590) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 9,469 (9,238–9,570) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 12,802 (12,602–12,899) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 15,448 (15,216–15,699) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 9,395 (9,280–9,497) | 12,549 (12,149–12,693) | 14,691 (14,050–14,843) |
| RoadRunner worker (warm, pipe) | on | — | 38,013 (37,098–38,279) | 45,774 (45,233–45,885) | 45,479 (44,889–45,548) |
| FrankenPHP worker (warm, embedded) | on | — | 59,806 (59,703–60,632) | 39,833 (39,575–40,560) | 32,362 (31,659–32,548) |
| nginx + php-fpm (cold, unix) | on | — | 9,722 (9,527–9,757) | 12,997 (12,847–13,025) | 14,840 (14,766–15,145) |

### rps at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 39,546 (38,123–40,430) | 46,985 (46,441–47,508) | 53,785 (52,423–54,365) |
| volucer attach (warm, unix relay) | on | — | 43,562 (41,868–44,110) | 55,913 (55,573–56,242) | 72,286 (69,812–73,041) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 9,289 (9,066–9,338) | 11,040 (10,856–11,232) | 12,756 (12,372–13,080) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 9,412 (9,149–9,459) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 12,757 (12,636–12,927) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 15,388 (15,021–15,591) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 9,392 (9,199–9,498) | 12,515 (11,954–12,730) | 14,579 (14,111–14,802) |
| RoadRunner worker (warm, pipe) | on | — | 37,431 (37,075–38,411) | 45,756 (44,805–46,383) | 45,394 (44,968–45,948) |
| FrankenPHP worker (warm, embedded) | on | — | 62,800 (15,393–63,393) | 41,469 (41,102–42,386) | 34,846 (33,988–35,470) |
| nginx + php-fpm (cold, unix) | on | — | 9,662 (9,602–9,749) | 12,916 (12,792–13,100) | 14,876 (14,648–15,078) |

## Headline readings

### Best configuration per arm

| arm | rps | workers | children | opcache | concurrency |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | 53,785 | 32 | — | on | 96 |
| volucer attach (warm, unix relay) | 72,286 | 32 | — | on | 96 |
| volucer spawn_cgi (cold, unix, 1/slot) | 12,756 | 32 | — | on | 96 |
| volucer spawn_cgi children (cold, unix) | 9,539 | 1 | 8 | on | 32 |
| volucer spawn_cgi children (cold, unix) | 12,802 | 1 | 16 | on | 64 |
| volucer spawn_cgi children (cold, unix) | 15,448 | 1 | 32 | on | 64 |
| volucer external -> php-fpm (cold, unix) | 14,691 | 32 | — | on | 64 |
| RoadRunner worker (warm, pipe) | 45,774 | 16 | — | on | 64 |
| FrankenPHP worker (warm, embedded) | 62,800 | 8 | — | on | 96 |
| nginx + php-fpm (cold, unix) | 14,876 | 32 | — | on | 96 |

### Does another worker help? (concurrency 96, opcache on)

| arm | w=1 | w=8 | w=16 | w=32 | peak | change from w=1 |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | — | 39,546 | 46,985 | 53,785 | w=32 | — |
| volucer attach (warm, unix relay) | — | 43,562 | 55,913 | 72,286 | w=32 | — |
| volucer spawn_cgi (cold, unix, 1/slot) | — | 9,289 | 11,040 | 12,756 | w=32 | — |
| volucer external -> php-fpm (cold, unix) | — | 9,392 | 12,515 | 14,579 | w=32 | — |
| RoadRunner worker (warm, pipe) | — | 37,431 | 45,756 | 45,394 | w=16 | — |
| FrankenPHP worker (warm, embedded) | — | 62,800 | 41,469 | 34,846 | w=8 | — |
| nginx + php-fpm (cold, unix) | — | 9,662 | 12,916 | 14,876 | w=32 | — |

## Latency, p50 (ms)

### p50 at concurrency 32

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 0.600 (0.557–0.634) | 0.524 (0.508–0.536) | 0.544 (0.540–0.565) |
| volucer attach (warm, unix relay) | on | — | 0.552 (0.517–0.595) | 0.437 (0.432–0.449) | 0.428 (0.421–0.434) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 1.980 (1.950–2.060) | 1.860 (1.860–1.920) | 2.090 (2.050–2.130) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 2.420 (2.390–2.490) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1.820 (1.800–1.850) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1.770 (1.750–1.800) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 1.060 (1.030–1.070) | 1.880 (1.870–1.960) | 1.870 (1.850–1.960) |
| RoadRunner worker (warm, pipe) | on | — | 0.595 (0.588–0.614) | 0.464 (0.458–0.476) | 0.562 (0.559–0.568) |
| FrankenPHP worker (warm, embedded) | on | — | 0.369 (0.362–0.380) | 0.501 (0.494–0.506) | 0.515 (0.505–0.517) |
| nginx + php-fpm (cold, unix) | on | — | 2.390 (2.340–2.430) | 1.770 (1.750–1.780) | 1.630 (1.620–1.640) |

### p50 at concurrency 64

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 1.520 (1.480–1.570) | 1.250 (1.230–1.280) | 1.100 (1.080–1.130) |
| volucer attach (warm, unix relay) | on | — | 1.450 (1.350–1.460) | 1.030 (1.020–1.070) | 0.813 (0.806–0.841) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 5.690 (5.670–6.080) | 4.450 (4.350–4.470) | 3.650 (3.580–3.720) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 6.240 (6.210–6.430) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 4.610 (4.560–4.680) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 3.800 (3.730–3.850) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 7.090 (7.070–7.200) | 6.240 (6.180–6.460) | 4.280 (4.240–4.450) |
| RoadRunner worker (warm, pipe) | on | — | 1.510 (1.500–1.550) | 1.230 (1.230–1.250) | 1.210 (1.200–1.220) |
| FrankenPHP worker (warm, embedded) | on | — | 0.841 (0.833–0.850) | 1.410 (1.370–1.410) | 1.650 (1.640–1.700) |
| nginx + php-fpm (cold, unix) | on | — | 6.080 (6.050–6.190) | 4.530 (4.530–4.580) | 3.900 (3.830–3.910) |

### p50 at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 2.430 (2.380–2.530) | 2.010 (1.990–2.040) | 1.710 (1.680–1.750) |
| volucer attach (warm, unix relay) | on | — | 2.220 (2.180–2.310) | 1.680 (1.670–1.690) | 1.250 (1.240–1.300) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 9.880 (9.580–10.330) | 7.840 (7.700–8.040) | 5.900 (5.710–6.230) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 10.110 (10.100–10.420) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 7.460 (7.340–7.530) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 6.150 (6.070–6.250) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 11.440 (11.330–11.560) | 10.940 (10.820–11.460) | 8.140 (7.990–8.340) |
| RoadRunner worker (warm, pipe) | on | — | 2.470 (2.410–2.490) | 1.990 (1.960–2.030) | 1.970 (1.950–2.000) |
| FrankenPHP worker (warm, embedded) | on | — | 1.340 (1.250–1.350) | 2.200 (2.130–2.200) | 2.500 (2.450–2.570) |
| nginx + php-fpm (cold, unix) | on | — | 9.880 (9.770–9.930) | 7.330 (7.250–7.410) | 6.310 (6.220–6.400) |

## Latency, p99 (ms)

### p99 at concurrency 32

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 1.570 (1.540–1.990) | 1.240 (1.200–1.320) | 1.270 (1.250–1.340) |
| volucer attach (warm, unix relay) | on | — | 1.430 (1.370–1.500) | 1.040 (1.030–1.070) | 0.990 (0.970–1.000) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 11.180 (10.220–11.640) | 8.940 (8.510–9.150) | 5.330 (5.180–5.890) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 5.710 (5.590–5.950) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 3.850 (3.800–3.960) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 4.010 (3.950–4.040) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 6.430 (6.380–6.610) | 3.850 (3.840–3.990) | 4.550 (4.470–4.900) |
| RoadRunner worker (warm, pipe) | on | — | 1.290 (1.280–1.330) | 1.600 (1.580–1.620) | 1.730 (1.720–1.760) |
| FrankenPHP worker (warm, embedded) | on | — | 1.720 (1.690–1.780) | 2.070 (2.050–2.110) | 2.250 (2.190–2.290) |
| nginx + php-fpm (cold, unix) | on | — | 3.830 (3.730–3.880) | 3.460 (3.390–3.520) | 4.280 (4.230–4.710) |

### p99 at concurrency 64

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 4.950 (4.880–5.050) | 3.120 (3.050–3.170) | 2.630 (2.620–2.720) |
| volucer attach (warm, unix relay) | on | — | 4.800 (4.620–4.830) | 2.640 (2.640–2.720) | 2.100 (2.050–2.190) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 30.410 (26.450–32.300) | 29.980 (28.100–33.670) | 24.710 (24.300–26.180) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 17.030 (16.850–17.750) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 10.830 (10.790–11.040) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 7.110 (6.960–7.310) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 16.400 (16.000–16.800) | 9.030 (8.920–9.400) | 7.510 (7.260–7.760) |
| RoadRunner worker (warm, pipe) | on | — | 2.540 (2.510–2.620) | 2.580 (2.540–2.610) | 3.730 (3.700–3.860) |
| FrankenPHP worker (warm, embedded) | on | — | 3.345 (3.310–3.350) | 4.470 (4.420–4.510) | 5.950 (5.890–6.100) |
| nginx + php-fpm (cold, unix) | on | — | 7.660 (7.560–7.740) | 6.290 (6.260–6.410) | 6.430 (6.260–6.700) |

### p99 at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 8.420 (8.280–8.680) | 5.630 (5.530–5.660) | 3.990 (3.990–4.070) |
| volucer attach (warm, unix relay) | on | — | 8.040 (7.960–8.210) | 4.800 (4.790–4.830) | 3.140 (3.070–3.200) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 48.540 (41.180–52.520) | 53.140 (49.700–61.400) | 45.520 (40.900–52.320) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 28.520 (28.360–29.850) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 19.600 (19.320–19.720) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 12.310 (11.940–13.150) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 25.340 (24.990–25.790) | 14.450 (14.040–15.140) | 11.680 (11.430–12.180) |
| RoadRunner worker (warm, pipe) | on | — | 3.940 (3.820–3.980) | 3.720 (3.690–3.820) | 4.680 (4.590–4.690) |
| FrankenPHP worker (warm, embedded) | on | — | 4.740 (4.590–4.770) | 6.420 (6.290–6.490) | 7.240 (7.120–7.400) |
| nginx + php-fpm (cold, unix) | on | — | 11.680 (11.530–11.780) | 9.260 (9.080–9.400) | 8.890 (8.710–9.230) |

## opcache

Every cell in this run was measured with opcache **on**, which is the
production case and the only one where a shared OPcache segment can exist —
so the ON/OFF ratio is not a column here.
The 8.5 pass that measured it (`results/matrix85-opcache/report.md`)
has the ON/OFF ratio for the arms both runs share.

## Shape comparisons

### Shape comparisons at concurrency 32

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

### Shape comparisons at concurrency 64

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

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer worker (warm, loopback TCP port) (w=8) | 37,808 | 38,906 | 39,546 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=8) | 8,871 | 9,124 | 9,289 |
| RoadRunner worker (warm, pipe) (w=8) | 37,829 | 38,013 | 37,431 |

**10 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer attach (warm, unix relay) (w=8) | 41,546 | 41,160 | 43,562 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=8) | 9,539 | 9,469 | 9,412 |
| volucer external -> php-fpm (cold, unix) (w=8) | 9,425 | 9,395 | 9,392 |

**17 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer worker (warm, loopback TCP port) (w=16) | 42,705 | 46,237 | 46,985 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=16) | 10,179 | 10,886 | 11,040 |
| RoadRunner worker (warm, pipe) (w=16) | 45,609 | 45,774 | 45,756 |

**18 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer attach (warm, unix relay) (w=16) | 51,257 | 55,974 | 55,913 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=16) | 12,653 | 12,802 | 12,757 |
| volucer external -> php-fpm (cold, unix) (w=16) | 12,516 | 12,549 | 12,515 |

**33 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer worker (warm, loopback TCP port) (w=32) | 41,396 | 51,528 | 53,785 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=32) | 10,625 | 12,481 | 12,756 |
| RoadRunner worker (warm, pipe) (w=32) | 38,017 | 45,479 | 45,394 |

**34 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer attach (warm, unix relay) (w=32) | 52,458 | 68,609 | 72,286 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=32) | 12,659 | 15,448 | 15,388 |
| volucer external -> php-fpm (cold, unix) (w=32) | 11,928 | 14,691 | 14,579 |

## Memory

### Memory, boot (before any request)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8 | 9 | 204.7 | 460.0 | 22.7 |
| volucer worker (warm, loopback TCP port) | on | 16 | 17 | 348.7 | 874.3 | 20.5 |
| volucer worker (warm, loopback TCP port) | on | 32 | 33 | 594.0 | 1,652.7 | 18.0 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 65.5 | 281.7 | 6.5 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 72.6 | 449.9 | 4.0 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 82.5 | 710.4 | 2.4 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 186.9 | 441.1 | 20.8 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 336.3 | 865.1 | 19.8 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 626.3 | 1,708.6 | 19.0 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 61.2 | 295.7 | 6.1 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 65.2 | 452.8 | 3.6 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 66.1 | 630.8 | 1.9 |
| volucer external -> php-fpm (cold, unix) | on | 8 | 10 | 60.0 | 301.1 | 6.0 |
| volucer external -> php-fpm (cold, unix) | on | 16 | 18 | 69.8 | 531.4 | 3.9 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 85.4 | 990.1 | 2.5 |
| RoadRunner worker (warm, pipe) | on | 8 | 9 | 248.3 | 500.6 | 27.6 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 415.3 | 944.8 | 24.4 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 744.3 | 1,831.4 | 22.6 |
| FrankenPHP worker (warm, embedded) | on | 8 | 1 | 126.2 | 126.2 | 126.2 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 140.5 | 140.5 | 140.5 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 156.2 | 156.2 | 156.2 |
| nginx + php-fpm (cold, unix) | on | 8 | 14 | 53.7 | 310.7 | 3.8 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 62.7 | 541.8 | 2.9 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 79.0 | 1,000.6 | 2.1 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8: 204.7 | 32: 594.0 | 389.3 | 24 | 16.2 |
| volucer attach (warm, unix relay) | on | 8: 65.5 | 32: 82.5 | 17.0 | 24 | 0.7 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8: 186.9 | 32: 626.3 | 439.4 | 24 | 18.3 |
| volucer external -> php-fpm (cold, unix) | on | 8: 60.0 | 32: 85.4 | 25.4 | 24 | 1.1 |
| RoadRunner worker (warm, pipe) | on | 8: 248.3 | 32: 744.3 | 496.0 | 24 | 20.7 |
| FrankenPHP worker (warm, embedded) | on | 8: 126.2 | 32: 156.2 | 30.0 | 24 | 1.2 |
| nginx + php-fpm (cold, unix) | on | 8: 53.7 | 32: 79.0 | 25.3 | 24 | 1.1 |

### Memory, after load (peak concurrency)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8 | 9 | 211.1 | 466.6 | 23.5 |
| volucer worker (warm, loopback TCP port) | on | 16 | 17 | 375.0 | 906.7 | 22.1 |
| volucer worker (warm, loopback TCP port) | on | 32 | 33 | 699.8 | 1,788.5 | 21.2 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 68.8 | 279.7 | 6.9 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 82.0 | 487.1 | 4.6 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 100.2 | 878.1 | 2.9 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 193.8 | 448.0 | 21.5 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 340.3 | 869.9 | 20.0 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 633.7 | 1,716.3 | 19.2 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 65.5 | 300.7 | 6.5 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 73.3 | 523.4 | 4.1 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 93.2 | 972.9 | 2.7 |
| volucer external -> php-fpm (cold, unix) | on | 8 | 10 | 68.5 | 310.4 | 6.8 |
| volucer external -> php-fpm (cold, unix) | on | 16 | 18 | 76.0 | 538.9 | 4.2 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 95.2 | 1,001.0 | 2.8 |
| RoadRunner worker (warm, pipe) | on | 8 | 9 | 252.8 | 505.2 | 28.1 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 420.5 | 949.5 | 24.7 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 749.6 | 1,836.8 | 22.7 |
| FrankenPHP worker (warm, embedded) | on | 8 | 1 | 131.8 | 131.8 | 131.8 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 146.4 | 146.4 | 146.4 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 170.0 | 170.0 | 170.0 |
| nginx + php-fpm (cold, unix) | on | 8 | 14 | 54.8 | 312.2 | 3.9 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 63.6 | 543.4 | 2.9 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 80.5 | 1,002.6 | 2.1 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8: 211.1 | 32: 699.8 | 488.7 | 24 | 20.4 |
| volucer attach (warm, unix relay) | on | 8: 68.8 | 32: 100.2 | 31.4 | 24 | 1.3 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8: 193.8 | 32: 633.7 | 439.9 | 24 | 18.3 |
| volucer external -> php-fpm (cold, unix) | on | 8: 68.5 | 32: 95.2 | 26.7 | 24 | 1.1 |
| RoadRunner worker (warm, pipe) | on | 8: 252.8 | 32: 749.6 | 496.8 | 24 | 20.7 |
| FrankenPHP worker (warm, embedded) | on | 8: 131.8 | 32: 170.0 | 38.2 | 24 | 1.6 |
| nginx + php-fpm (cold, unix) | on | 8: 54.8 | 32: 80.5 | 25.7 | 24 | 1.1 |

## Integrity checks

**2 cell(s) reported failures or dropped responses.** A cell with `Non-2xx` responses is a pool shedding load, which is a
throughput number that looks like the fix working; it is listed here rather
than silently averaged in.

| arm | workers | opcache | conc | round | rps | errors |
|---|---|---|---|---|---|---|
| frankenphp | 8 | on | 64 | 5 | FAIL | 0 |
| frankenphp | 8 | on | 96 | 5 | 15393.14 | 1 |


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

Rows: `/home/competition/matrix-final-5r/matrix.tsv`. Memory: `/home/competition/matrix-final-5r/memory.tsv`.

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

### rps at concurrency 32

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 28,972 (28,567–30,226) | 33,328 (32,924–33,931) | 31,845 (31,304–32,413) |
| volucer attach (warm, unix relay) | on | — | 30,244 (28,825–31,208) | 37,709 (36,529–37,920) | 38,880 (37,373–39,383) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 7,818 (7,651–7,927) | 8,610 (8,419–8,679) | 8,831 (8,701–8,885) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 8,430 (8,264–8,481) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 10,454 (10,335–10,715) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 10,526 (10,464–10,730) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 8,202 (8,049–8,299) | 10,415 (10,265–10,557) | 9,945 (9,479–10,046) |
| RoadRunner worker (warm, pipe) | on | — | 26,698 (26,208–26,820) | 31,344 (30,913–31,640) | 27,625 (27,166–27,776) |
| FrankenPHP worker (warm, embedded) | on | — | 22,927 (22,823–23,026) | 18,471 (18,262–18,718) | 16,702 (16,336–16,772) |
| nginx + php-fpm (cold, unix) | on | — | 8,377 (8,360–8,474) | 10,726 (10,668–10,855) | 11,195 (11,060–11,302) |

### rps at concurrency 64

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 30,189 (29,803–30,737) | 35,623 (35,387–36,229) | 38,887 (37,974–38,979) |
| volucer attach (warm, unix relay) | on | — | 32,270 (30,933–33,213) | 40,909 (40,227–41,370) | 48,752 (47,523–49,613) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 8,194 (7,943–8,237) | 9,213 (8,955–9,342) | 9,905 (9,857–10,338) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 8,388 (8,299–8,464) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 10,718 (10,317–10,794) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 12,607 (12,554–12,838) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 8,146 (8,081–8,251) | 10,567 (10,310–10,639) | 12,173 (11,456–12,237) |
| RoadRunner worker (warm, pipe) | on | — | 27,101 (26,270–27,350) | 31,360 (30,652–31,719) | 32,171 (31,700–32,332) |
| FrankenPHP worker (warm, embedded) | on | — | 23,358 (11,417–23,683) | 19,113 (11,990–19,465) | 18,214 (17,929–18,628) |
| nginx + php-fpm (cold, unix) | on | — | 8,404 (8,294–8,426) | 10,782 (10,754–10,860) | 12,318 (12,128–12,324) |

### rps at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 30,494 (29,430–30,877) | 36,087 (35,765–36,781) | 39,742 (39,074–40,244) |
| volucer attach (warm, unix relay) | on | — | 32,368 (31,753–33,528) | 41,433 (41,080–41,939) | 51,281 (49,659–51,403) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 8,259 (8,056–8,328) | 9,393 (9,130–9,520) | 10,365 (10,060–10,490) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 8,433 (8,234–8,502) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 10,571 (10,520–10,796) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 12,631 (12,469–12,827) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 8,149 (8,025–8,235) | 10,513 (10,223–10,564) | 12,093 (11,715–12,387) |
| RoadRunner worker (warm, pipe) | on | — | 27,112 (26,084–27,488) | 31,342 (30,552–31,599) | 31,707 (31,339–31,939) |
| FrankenPHP worker (warm, embedded) | on | — | 23,692 (23,501–23,796) | 19,341 (19,097–19,601) | 18,164 (17,979–18,559) |
| nginx + php-fpm (cold, unix) | on | — | 8,346 (8,338–8,464) | 10,786 (10,711–10,890) | 12,165 (12,062–12,232) |

## Headline readings

### Best configuration per arm

| arm | rps | workers | children | opcache | concurrency |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | 39,742 | 32 | — | on | 96 |
| volucer attach (warm, unix relay) | 51,281 | 32 | — | on | 96 |
| volucer spawn_cgi (cold, unix, 1/slot) | 10,365 | 32 | — | on | 96 |
| volucer spawn_cgi children (cold, unix) | 8,433 | 1 | 8 | on | 96 |
| volucer spawn_cgi children (cold, unix) | 10,718 | 1 | 16 | on | 64 |
| volucer spawn_cgi children (cold, unix) | 12,631 | 1 | 32 | on | 96 |
| volucer external -> php-fpm (cold, unix) | 12,173 | 32 | — | on | 64 |
| RoadRunner worker (warm, pipe) | 32,171 | 32 | — | on | 64 |
| FrankenPHP worker (warm, embedded) | 23,692 | 8 | — | on | 96 |
| nginx + php-fpm (cold, unix) | 12,318 | 32 | — | on | 64 |

### Does another worker help? (concurrency 96, opcache on)

| arm | w=1 | w=8 | w=16 | w=32 | peak | change from w=1 |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | — | 30,494 | 36,087 | 39,742 | w=32 | — |
| volucer attach (warm, unix relay) | — | 32,368 | 41,433 | 51,281 | w=32 | — |
| volucer spawn_cgi (cold, unix, 1/slot) | — | 8,259 | 9,393 | 10,365 | w=32 | — |
| volucer external -> php-fpm (cold, unix) | — | 8,149 | 10,513 | 12,093 | w=32 | — |
| RoadRunner worker (warm, pipe) | — | 27,112 | 31,342 | 31,707 | w=32 | — |
| FrankenPHP worker (warm, embedded) | — | 23,692 | 19,341 | 18,164 | w=8 | — |
| nginx + php-fpm (cold, unix) | — | 8,346 | 10,786 | 12,165 | w=32 | — |

## Latency, p50 (ms)

### p50 at concurrency 32

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 0.789 (0.754–0.796) | 0.679 (0.660–0.687) | 0.705 (0.693–0.717) |
| volucer attach (warm, unix relay) | on | — | 0.761 (0.736–0.802) | 0.601 (0.597–0.618) | 0.580 (0.573–0.604) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 1.940 (1.870–2.090) | 2.240 (2.220–2.290) | 2.520 (2.490–2.560) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 2.760 (2.740–2.810) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 2.190 (2.140–2.220) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 2.130 (2.100–2.150) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 1.160 (1.150–1.170) | 2.270 (2.240–2.310) | 2.250 (2.230–2.370) |
| RoadRunner worker (warm, pipe) | on | — | 0.844 (0.841–0.860) | 0.679 (0.675–0.688) | 0.771 (0.763–0.782) |
| FrankenPHP worker (warm, embedded) | on | — | 0.960 (0.960–0.970) | 1.125 (1.110–1.140) | 1.320 (1.310–1.350) |
| nginx + php-fpm (cold, unix) | on | — | 2.770 (2.750–2.780) | 2.150 (2.130–2.170) | 1.980 (1.960–2.000) |

### p50 at concurrency 64

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 1.960 (1.930–1.990) | 1.640 (1.610–1.650) | 1.460 (1.460–1.500) |
| volucer attach (warm, unix relay) | on | — | 1.840 (1.780–1.920) | 1.420 (1.400–1.450) | 1.160 (1.130–1.190) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 6.540 (6.400–6.710) | 5.150 (5.010–5.370) | 4.570 (4.430–4.770) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 7.080 (7.040–7.170) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 5.500 (5.470–5.720) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 4.660 (4.580–4.680) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 8.380 (8.270–8.470) | 7.420 (7.390–7.600) | 5.200 (5.180–5.530) |
| RoadRunner worker (warm, pipe) | on | — | 2.130 (2.110–2.200) | 1.820 (1.790–1.860) | 1.720 (1.700–1.730) |
| FrankenPHP worker (warm, embedded) | on | — | 2.430 (2.390–2.480) | 2.910 (2.850–2.940) | 2.950 (2.880–3.020) |
| nginx + php-fpm (cold, unix) | on | — | 7.090 (7.050–7.140) | 5.480 (5.420–5.490) | 4.700 (4.690–4.760) |

### p50 at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 3.150 (3.100–3.280) | 2.630 (2.570–2.650) | 2.320 (2.290–2.380) |
| volucer attach (warm, unix relay) | on | — | 2.970 (2.870–3.040) | 2.280 (2.250–2.300) | 1.790 (1.770–1.840) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 11.590 (10.970–11.740) | 9.230 (9.150–9.630) | 7.280 (6.920–7.610) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 11.340 (11.220–11.590) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 8.980 (8.830–9.050) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 7.490 (7.380–7.600) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 13.710 (13.650–14.270) | 13.050 (12.940–13.360) | 9.720 (9.590–10.110) |
| RoadRunner worker (warm, pipe) | on | — | 3.440 (3.400–3.590) | 2.920 (2.900–3.010) | 2.850 (2.820–2.870) |
| FrankenPHP worker (warm, embedded) | on | — | 3.880 (3.850–3.920) | 4.720 (4.650–4.780) | 4.850 (4.760–4.890) |
| nginx + php-fpm (cold, unix) | on | — | 11.410 (11.290–11.470) | 8.820 (8.710–8.890) | 7.720 (7.680–7.790) |

## Latency, p99 (ms)

### p99 at concurrency 32

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 2.150 (1.980–2.490) | 1.510 (1.500–2.170) | 1.630 (1.610–1.860) |
| volucer attach (warm, unix relay) | on | — | 1.940 (1.890–2.010) | 1.320 (1.310–1.350) | 1.260 (1.250–1.320) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 14.060 (12.770–15.020) | 9.840 (9.740–10.060) | 6.340 (6.180–6.490) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 6.180 (5.610–6.830) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 4.610 (4.520–4.750) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 4.720 (4.660–4.780) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 7.890 (7.780–8.070) | 4.570 (4.430–4.650) | 5.340 (5.240–5.570) |
| RoadRunner worker (warm, pipe) | on | — | 1.740 (1.730–1.770) | 2.200 (2.160–2.220) | 2.340 (2.300–2.360) |
| FrankenPHP worker (warm, embedded) | on | — | 2.310 (2.310–2.320) | 4.525 (4.460–4.560) | 5.420 (5.320–5.570) |
| nginx + php-fpm (cold, unix) | on | — | 4.070 (4.060–4.100) | 3.860 (3.820–3.900) | 4.970 (4.880–5.020) |

### p99 at concurrency 64

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 6.300 (6.210–6.370) | 3.900 (3.880–3.960) | 3.310 (3.280–3.450) |
| volucer attach (warm, unix relay) | on | — | 6.090 (5.970–6.260) | 3.500 (3.460–3.550) | 2.700 (2.650–2.750) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 36.310 (31.940–40.640) | 38.020 (33.170–38.560) | 31.810 (29.640–32.980) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 19.170 (18.790–19.840) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 13.120 (12.940–13.500) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 8.580 (8.410–8.640) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 20.460 (19.970–20.670) | 10.660 (10.620–11.010) | 8.780 (8.710–9.490) |
| RoadRunner worker (warm, pipe) | on | — | 3.430 (3.400–3.490) | 3.520 (3.450–3.560) | 4.790 (4.730–4.840) |
| FrankenPHP worker (warm, embedded) | on | — | 4.410 (4.370–4.590) | 6.570 (6.470–6.640) | 11.300 (11.110–11.460) |
| nginx + php-fpm (cold, unix) | on | — | 8.690 (8.520–8.880) | 7.340 (7.300–7.490) | 7.570 (7.530–7.890) |

### p99 at concurrency 96

| arm | opcache | w=1 | w=8 | w=16 | w=32 |
|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | — | 10.610 (10.570–10.960) | 6.970 (6.860–7.040) | 5.130 (5.030–5.220) |
| volucer attach (warm, unix relay) | on | — | 10.470 (10.130–10.510) | 6.240 (6.200–6.260) | 4.160 (4.110–4.240) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 53.740 (45.970–64.580) | 60.100 (55.190–71.720) | 57.340 (53.240–60.600) |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 31.880 (30.510–33.220) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 23.650 (22.890–24.020) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 14.800 (14.600–15.100) | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 31.950 (31.130–32.580) | 17.020 (16.910–17.860) | 13.760 (13.550–14.620) |
| RoadRunner worker (warm, pipe) | on | — | 5.050 (4.950–5.270) | 5.080 (5.050–5.210) | 6.450 (6.380–6.510) |
| FrankenPHP worker (warm, embedded) | on | — | 6.220 (6.210–6.270) | 8.560 (8.440–8.600) | 13.140 (12.850–13.310) |
| nginx + php-fpm (cold, unix) | on | — | 13.260 (13.120–13.380) | 10.800 (10.730–10.860) | 10.710 (10.620–10.940) |

## opcache

Every cell in this run was measured with opcache **on**, which is the
production case and the only one where a shared OPcache segment can exist —
so the ON/OFF ratio is not a column here.
The 8.5 pass that measured it (`results/matrix85-opcache/report.md`)
has the ON/OFF ratio for the arms both runs share.

## Shape comparisons

### Shape comparisons at concurrency 32

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

### Shape comparisons at concurrency 64

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

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer worker (warm, loopback TCP port) (w=8) | 28,972 | 30,189 | 30,494 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=8) | 7,818 | 8,194 | 8,259 |
| RoadRunner worker (warm, pipe) (w=8) | 26,698 | 27,101 | 27,112 |

**10 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer attach (warm, unix relay) (w=8) | 30,244 | 32,270 | 32,368 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=8) | 8,430 | 8,388 | 8,433 |
| volucer external -> php-fpm (cold, unix) (w=8) | 8,202 | 8,146 | 8,149 |

**17 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer worker (warm, loopback TCP port) (w=16) | 33,328 | 35,623 | 36,087 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=16) | 8,610 | 9,213 | 9,393 |
| RoadRunner worker (warm, pipe) (w=16) | 31,344 | 31,360 | 31,342 |

**18 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer attach (warm, unix relay) (w=16) | 37,709 | 40,909 | 41,433 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=16) | 10,454 | 10,718 | 10,571 |
| volucer external -> php-fpm (cold, unix) (w=16) | 10,415 | 10,567 | 10,513 |

**33 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer worker (warm, loopback TCP port) (w=32) | 31,845 | 38,887 | 39,742 |
| volucer spawn_cgi (cold, unix, 1/slot) (w=32) | 8,831 | 9,905 | 10,365 |
| RoadRunner worker (warm, pipe) (w=32) | 27,625 | 32,171 | 31,707 |

**34 PHP processes**

| arm (config) | c=32 | c=64 | c=96 |
|---|---|---|---|
| volucer attach (warm, unix relay) (w=32) | 38,880 | 48,752 | 51,281 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=32) | 10,526 | 12,607 | 12,631 |
| volucer external -> php-fpm (cold, unix) (w=32) | 9,945 | 12,173 | 12,093 |

## Memory

### Memory, boot (before any request)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8 | 9 | 204.7 | 460.0 | 22.7 |
| volucer worker (warm, loopback TCP port) | on | 16 | 17 | 348.7 | 874.3 | 20.5 |
| volucer worker (warm, loopback TCP port) | on | 32 | 33 | 594.0 | 1,652.7 | 18.0 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 65.5 | 281.7 | 6.5 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 72.6 | 449.9 | 4.0 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 82.5 | 710.4 | 2.4 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 186.9 | 441.1 | 20.8 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 336.3 | 865.1 | 19.8 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 626.3 | 1,708.6 | 19.0 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 61.2 | 295.7 | 6.1 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 65.2 | 452.8 | 3.6 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 66.1 | 630.8 | 1.9 |
| volucer external -> php-fpm (cold, unix) | on | 8 | 10 | 60.0 | 301.1 | 6.0 |
| volucer external -> php-fpm (cold, unix) | on | 16 | 18 | 69.8 | 531.4 | 3.9 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 85.4 | 990.1 | 2.5 |
| RoadRunner worker (warm, pipe) | on | 8 | 9 | 248.3 | 500.6 | 27.6 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 415.3 | 944.8 | 24.4 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 744.3 | 1,831.4 | 22.6 |
| FrankenPHP worker (warm, embedded) | on | 8 | 1 | 126.2 | 126.2 | 126.2 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 140.5 | 140.5 | 140.5 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 156.2 | 156.2 | 156.2 |
| nginx + php-fpm (cold, unix) | on | 8 | 14 | 53.7 | 310.7 | 3.8 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 62.7 | 541.8 | 2.9 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 79.0 | 1,000.6 | 2.1 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8: 204.7 | 32: 594.0 | 389.3 | 24 | 16.2 |
| volucer attach (warm, unix relay) | on | 8: 65.5 | 32: 82.5 | 17.0 | 24 | 0.7 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8: 186.9 | 32: 626.3 | 439.4 | 24 | 18.3 |
| volucer external -> php-fpm (cold, unix) | on | 8: 60.0 | 32: 85.4 | 25.4 | 24 | 1.1 |
| RoadRunner worker (warm, pipe) | on | 8: 248.3 | 32: 744.3 | 496.0 | 24 | 20.7 |
| FrankenPHP worker (warm, embedded) | on | 8: 126.2 | 32: 156.2 | 30.0 | 24 | 1.2 |
| nginx + php-fpm (cold, unix) | on | 8: 53.7 | 32: 79.0 | 25.3 | 24 | 1.1 |

### Memory, after load (peak concurrency)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8 | 9 | 211.1 | 466.6 | 23.5 |
| volucer worker (warm, loopback TCP port) | on | 16 | 17 | 375.0 | 906.7 | 22.1 |
| volucer worker (warm, loopback TCP port) | on | 32 | 33 | 699.8 | 1,788.5 | 21.2 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 68.8 | 279.7 | 6.9 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 82.0 | 487.1 | 4.6 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 100.2 | 878.1 | 2.9 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 193.8 | 448.0 | 21.5 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 340.3 | 869.9 | 20.0 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 633.7 | 1,716.3 | 19.2 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 65.5 | 300.7 | 6.5 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 73.3 | 523.4 | 4.1 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 93.2 | 972.9 | 2.7 |
| volucer external -> php-fpm (cold, unix) | on | 8 | 10 | 68.5 | 310.4 | 6.8 |
| volucer external -> php-fpm (cold, unix) | on | 16 | 18 | 76.0 | 538.9 | 4.2 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 95.2 | 1,001.0 | 2.8 |
| RoadRunner worker (warm, pipe) | on | 8 | 9 | 252.8 | 505.2 | 28.1 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 420.5 | 949.5 | 24.7 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 749.6 | 1,836.8 | 22.7 |
| FrankenPHP worker (warm, embedded) | on | 8 | 1 | 131.8 | 131.8 | 131.8 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 146.4 | 146.4 | 146.4 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 170.0 | 170.0 | 170.0 |
| nginx + php-fpm (cold, unix) | on | 8 | 14 | 54.8 | 312.2 | 3.9 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 63.6 | 543.4 | 2.9 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 80.5 | 1,002.6 | 2.1 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, loopback TCP port) | on | 8: 211.1 | 32: 699.8 | 488.7 | 24 | 20.4 |
| volucer attach (warm, unix relay) | on | 8: 68.8 | 32: 100.2 | 31.4 | 24 | 1.3 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8: 193.8 | 32: 633.7 | 439.9 | 24 | 18.3 |
| volucer external -> php-fpm (cold, unix) | on | 8: 68.5 | 32: 95.2 | 26.7 | 24 | 1.1 |
| RoadRunner worker (warm, pipe) | on | 8: 252.8 | 32: 749.6 | 496.8 | 24 | 20.7 |
| FrankenPHP worker (warm, embedded) | on | 8: 131.8 | 32: 170.0 | 38.2 | 24 | 1.6 |
| nginx + php-fpm (cold, unix) | on | 8: 54.8 | 32: 80.5 | 25.7 | 24 | 1.1 |

## Integrity checks

**4 cell(s) reported failures or dropped responses.** A cell with `Non-2xx` responses is a pool shedding load, which is a
throughput number that looks like the fix working; it is listed here rather
than silently averaged in.

| arm | workers | opcache | conc | round | rps | errors |
|---|---|---|---|---|---|---|
| frankenphp | 8 | on | 32 | 1 | FAIL | 0 |
| frankenphp | 8 | on | 64 | 1 | 11417.15 | 1 |
| frankenphp | 16 | on | 32 | 3 | FAIL | 0 |
| frankenphp | 16 | on | 64 | 3 | 11990.12 | 1 |


