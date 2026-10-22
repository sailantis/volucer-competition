# Worker / opcache / concurrency matrix

Every arm on one host, through one harness, so a difference between two
rows is the server rather than the measurement:

| arm | what it is |
|---|---|
| `volucer-worker` | volucer worker (warm, pipe) |
| `volucer-unix` | volucer worker (warm, unix socket) |
| `volucer-attach` | volucer attach (warm, unix relay) |
| `volucer-fastcgi` | volucer spawn_cgi (cold, unix, 1/slot) |
| `volucer-prefork` | volucer spawn_cgi children (cold, unix) |
| `rr` | RoadRunner worker (warm, pipe) |
| `frankenphp` | FrankenPHP worker (warm, embedded) |
| `fpm` | nginx + php-fpm (cold, unix) |

Rows: `results/matrix85/matrix.tsv`. Memory: `results/matrix85/memory.tsv`.

Every cell is the **median over the rounds**, with the min–max spread across
rounds in parentheses where there was more than one round. `p50` and `p99` are
each their own median across the rounds of that cell — not the percentile of
whichever round happened to have the median throughput.

`ch=N` marks the `children` axis, which only `volucer-prefork` has: there
`workers` counts listening sockets and `children` counts `php-cgi` processes
behind each, so `w=16 ch=4` is one master, four children, per socket. Every
other arm leaves it empty because it has no such setting.

## Throughput (requests/sec)

### rps at concurrency 16

| arm | opcache | w=1 | w=16 | w=32 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | on | — | 15,929 (15,724–16,282) | — |
| volucer worker (warm, unix socket) | on | — | 15,663 (15,406–16,104) | — |
| volucer attach (warm, unix relay) | on | — | 16,003 (15,649–16,302) | — |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 5,234 (5,233–5,356) | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 6,044 (6,029–6,119) | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 6,167 (6,063–6,261) | — | — |
| RoadRunner worker (warm, pipe) | on | — | 14,237 (14,037–14,323) | — |
| FrankenPHP worker (warm, embedded) | on | — | 15,799 (15,742–15,808) | — |
| nginx + php-fpm (cold, unix) | on | — | 6,398 (6,390–6,451) | 5,854 (5,770–5,927) |

### rps at concurrency 32

| arm | opcache | w=1 | w=16 | w=32 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | on | — | 22,168 (21,739–22,230) | — |
| volucer worker (warm, unix socket) | on | — | 21,651 (21,643–21,687) | — |
| volucer attach (warm, unix relay) | on | — | 22,563 (22,456–22,785) | — |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 6,690 (6,568–6,769) | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 8,481 (8,293–8,546) | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 7,900 (7,813–7,993) | — | — |
| RoadRunner worker (warm, pipe) | on | — | 19,804 (19,360–19,825) | — |
| FrankenPHP worker (warm, embedded) | on | — | 13,904 (13,882–13,954) | — |
| nginx + php-fpm (cold, unix) | on | — | 8,347 (8,236–8,410) | 8,642 (8,582–8,702) |

### rps at concurrency 48

| arm | opcache | w=1 | w=16 | w=32 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | on | — | 24,308 (23,848–24,452) | — |
| volucer worker (warm, unix socket) | on | — | 23,268 (23,202–23,359) | — |
| volucer attach (warm, unix relay) | on | — | 25,497 (24,906–25,704) | — |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 6,833 (6,786–6,978) | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 8,504 (8,497–8,545) | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 8,945 (8,923–9,116) | — | — |
| RoadRunner worker (warm, pipe) | on | — | 19,653 (19,128–20,136) | — |
| FrankenPHP worker (warm, embedded) | on | — | 14,487 (14,379–14,673) | — |
| nginx + php-fpm (cold, unix) | on | — | 8,360 (8,333–8,430) | 9,251 (9,224–9,268) |

### rps at concurrency 64

| arm | opcache | w=1 | w=16 | w=32 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | on | — | 23,989 (23,504–24,426) | — |
| volucer worker (warm, unix socket) | on | — | 23,357 (22,873–23,427) | — |
| volucer attach (warm, unix relay) | on | — | 26,009 (24,762–26,430) | — |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 6,832 (6,761–6,985) | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 8,572 (8,500–8,582) | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 9,199 (9,113–9,200) | — | — |
| RoadRunner worker (warm, pipe) | on | — | 19,755 (19,511–20,172) | — |
| FrankenPHP worker (warm, embedded) | on | — | 14,566 (14,389–14,575) | — |
| nginx + php-fpm (cold, unix) | on | — | 8,231 (8,229–8,416) | 9,098 (8,998–9,224) |

## Headline readings

### Best configuration per arm

| arm | rps | workers | children | opcache | concurrency |
|---|---|---|---|---|---|
| volucer worker (warm, pipe) | 24,308 | 16 | — | on | 48 |
| volucer worker (warm, unix socket) | 23,357 | 16 | — | on | 64 |
| volucer attach (warm, unix relay) | 26,009 | 16 | — | on | 64 |
| volucer spawn_cgi (cold, unix, 1/slot) | 6,833 | 16 | — | on | 48 |
| volucer spawn_cgi children (cold, unix) | 8,572 | 1 | 16 | on | 64 |
| volucer spawn_cgi children (cold, unix) | 9,199 | 1 | 32 | on | 64 |
| RoadRunner worker (warm, pipe) | 19,804 | 16 | — | on | 32 |
| FrankenPHP worker (warm, embedded) | 15,799 | 16 | — | on | 16 |
| nginx + php-fpm (cold, unix) | 9,251 | 32 | — | on | 48 |

### Does another worker help? (concurrency 64, opcache on)

| arm | w=1 | w=16 | w=32 | peak | change from w=1 |
|---|---|---|---|---|---|
| nginx + php-fpm (cold, unix) | — | 8,231 | 9,098 | w=32 | — |

## Latency, p50 (ms)

### p50 at concurrency 16

| arm | opcache | w=1 | w=16 | w=32 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | on | — | 0.708 (0.691–0.713) | — |
| volucer worker (warm, unix socket) | on | — | 0.716 (0.692–0.726) | — |
| volucer attach (warm, unix relay) | on | — | 0.701 (0.688–0.710) | — |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 2.110 (2.090–2.120) | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1.800 (1.770–1.800) | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1.770 (1.740–1.790) | — | — |
| RoadRunner worker (warm, pipe) | on | — | 0.756 (0.751–0.761) | — |
| FrankenPHP worker (warm, embedded) | on | — | 0.675 (0.675–0.679) | — |
| nginx + php-fpm (cold, unix) | on | — | 1.680 (1.670–1.700) | 1.830 (1.810–1.860) |

### p50 at concurrency 32

| arm | opcache | w=1 | w=16 | w=32 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | on | — | 1.010 (1.010–1.030) | — |
| volucer worker (warm, unix socket) | on | — | 1.030 (1.030–1.040) | — |
| volucer attach (warm, unix relay) | on | — | 1.000 (0.990–1.000) | — |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 2.900 (2.840–2.900) | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 2.720 (2.700–2.750) | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 2.860 (2.830–2.890) | — | — |
| RoadRunner worker (warm, pipe) | on | — | 1.100 (1.090–1.120) | — |
| FrankenPHP worker (warm, embedded) | on | — | 1.520 (1.490–1.520) | — |
| nginx + php-fpm (cold, unix) | on | — | 2.770 (2.740–2.770) | 2.570 (2.530–2.570) |

### p50 at concurrency 48

| arm | opcache | w=1 | w=16 | w=32 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | on | — | 1.850 (1.850–1.880) | — |
| volucer worker (warm, unix socket) | on | — | 1.940 (1.930–1.940) | — |
| volucer attach (warm, unix relay) | on | — | 1.750 (1.740–1.810) | — |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 5.430 (5.400–5.450) | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 5.490 (5.440–5.520) | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 5.140 (5.050–5.160) | — | — |
| RoadRunner worker (warm, pipe) | on | — | 2.310 (2.230–2.340) | — |
| FrankenPHP worker (warm, embedded) | on | — | 3.090 (3.020–3.100) | — |
| nginx + php-fpm (cold, unix) | on | — | 5.620 (5.580–5.660) | 4.950 (4.880–4.970) |

### p50 at concurrency 64

| arm | opcache | w=1 | w=16 | w=32 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | on | — | 2.360 (2.330–2.420) | — |
| volucer worker (warm, unix socket) | on | — | 2.420 (2.400–2.460) | — |
| volucer attach (warm, unix relay) | on | — | 2.180 (2.130–2.280) | — |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 6.490 (6.240–6.530) | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 6.890 (6.870–6.930) | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 6.340 (6.330–6.380) | — | — |
| RoadRunner worker (warm, pipe) | on | — | 2.880 (2.820–2.880) | — |
| FrankenPHP worker (warm, embedded) | on | — | 3.870 (3.870–3.870) | — |
| nginx + php-fpm (cold, unix) | on | — | 7.090 (7.020–7.100) | 6.340 (6.280–6.360) |

## Latency, p99 (ms)

### p99 at concurrency 16

| arm | opcache | w=1 | w=16 | w=32 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | on | — | 1.420 (1.390–1.440) | — |
| volucer worker (warm, unix socket) | on | — | 1.470 (1.450–1.500) | — |
| volucer attach (warm, unix relay) | on | — | 1.430 (1.420–1.460) | — |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 4.660 (4.620–4.660) | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 4.010 (3.960–4.040) | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 3.770 (3.690–3.910) | — | — |
| RoadRunner worker (warm, pipe) | on | — | 1.880 (1.860–1.910) | — |
| FrankenPHP worker (warm, embedded) | on | — | 1.960 (1.930–2.050) | — |
| nginx + php-fpm (cold, unix) | on | — | 3.830 (3.780–4.160) | 4.510 (4.460–4.840) |

### p99 at concurrency 32

| arm | opcache | w=1 | w=16 | w=32 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | on | — | 2.210 (2.200–2.240) | — |
| volucer worker (warm, unix socket) | on | — | 2.300 (2.260–2.310) | — |
| volucer attach (warm, unix relay) | on | — | 2.170 (2.130–2.180) | — |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 12.970 (12.700–13.750) | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 5.420 (5.370–5.530) | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 6.320 (6.210–6.340) | — | — |
| RoadRunner worker (warm, pipe) | on | — | 3.160 (3.140–3.180) | — |
| FrankenPHP worker (warm, embedded) | on | — | 5.540 (5.500–5.630) | — |
| nginx + php-fpm (cold, unix) | on | — | 4.880 (4.820–4.920) | 6.490 (6.470–6.640) |

### p99 at concurrency 48

| arm | opcache | w=1 | w=16 | w=32 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | on | — | 5.250 (5.240–5.290) | — |
| volucer worker (warm, unix socket) | on | — | 5.460 (5.430–5.470) | — |
| volucer attach (warm, unix relay) | on | — | 4.940 (4.900–5.030) | — |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 40.430 (37.800–45.370) | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 12.630 (12.450–12.900) | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 10.300 (9.940–11.310) | — | — |
| RoadRunner worker (warm, pipe) | on | — | 4.730 (4.700–4.760) | — |
| FrankenPHP worker (warm, embedded) | on | — | 7.600 (7.510–7.750) | — |
| nginx + php-fpm (cold, unix) | on | — | 7.870 (7.850–7.960) | 8.670 (8.610–8.990) |

### p99 at concurrency 64

| arm | opcache | w=1 | w=16 | w=32 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | on | — | 7.340 (7.220–7.500) | — |
| volucer worker (warm, unix socket) | on | — | 7.400 (7.250–7.450) | — |
| volucer attach (warm, unix relay) | on | — | 6.730 (6.600–6.930) | — |
| volucer spawn_cgi (cold, unix, 1/slot) | on | — | 56.720 (46.880–57.140) | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 16.760 (16.610–16.890) | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 12.550 (12.430–12.600) | — | — |
| RoadRunner worker (warm, pipe) | on | — | 5.460 (5.450–5.500) | — |
| FrankenPHP worker (warm, embedded) | on | — | 8.480 (8.440–8.490) | — |
| nginx + php-fpm (cold, unix) | on | — | 9.400 (9.310–9.450) | 10.060 (9.990–10.230) |

## opcache

Every cell in this run was measured with opcache **on**, which is the
production case and the only one where a shared OPcache segment can exist —
so the ON/OFF ratio is not a column here.
The 8.5 pass that measured it (`results/matrix85-opcache/report.md`)
has the ON/OFF ratio for the arms both runs share.

## Shape comparisons

### Shape comparisons at concurrency 16

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=16 | w=32 |
|---|---|---|---|---|
| transport: unix vs pipe | rps | — | -1.7% | — |
|  | PSS | — | +0.0% | — |
| memory model: attach vs pipe | rps | — | +0.5% | — |
|  | PSS | — | -78.2% | — |
| control: children=1 vs plain spawn_cgi | rps | — | — | — |
|  | PSS | — | — | — |
| prefork: children=16 vs children=1 | rps | — | — | — |
|  | PSS | — | — | — |
| prefork: children=32 vs children=1 | rps | — | — | — |
|  | PSS | — | — | — |

### Shape comparisons at concurrency 32

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=16 | w=32 |
|---|---|---|---|---|
| transport: unix vs pipe | rps | — | -2.3% | — |
|  | PSS | — | +0.0% | — |
| memory model: attach vs pipe | rps | — | +1.8% | — |
|  | PSS | — | -78.2% | — |
| control: children=1 vs plain spawn_cgi | rps | — | — | — |
|  | PSS | — | — | — |
| prefork: children=16 vs children=1 | rps | — | — | — |
|  | PSS | — | — | — |
| prefork: children=32 vs children=1 | rps | — | — | — |
|  | PSS | — | — | — |

### Shape comparisons at concurrency 48

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=16 | w=32 |
|---|---|---|---|---|
| transport: unix vs pipe | rps | — | -4.3% | — |
|  | PSS | — | +0.0% | — |
| memory model: attach vs pipe | rps | — | +4.9% | — |
|  | PSS | — | -78.2% | — |
| control: children=1 vs plain spawn_cgi | rps | — | — | — |
|  | PSS | — | — | — |
| prefork: children=16 vs children=1 | rps | — | — | — |
|  | PSS | — | — | — |
| prefork: children=32 vs children=1 | rps | — | — | — |
|  | PSS | — | — | — |

### Shape comparisons at concurrency 64

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=16 | w=32 |
|---|---|---|---|---|
| transport: unix vs pipe | rps | — | -2.6% | — |
|  | PSS | — | +0.0% | — |
| memory model: attach vs pipe | rps | — | +8.4% | — |
|  | PSS | — | -78.2% | — |
| control: children=1 vs plain spawn_cgi | rps | — | — | — |
|  | PSS | — | — | — |
| prefork: children=16 vs children=1 | rps | — | — | — |
|  | PSS | — | — | — |
| prefork: children=32 vs children=1 | rps | — | — | — |
|  | PSS | — | — | — |

## Memory

### Memory, boot (before any request)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 16 | 17 | 264.4 | 757.8 | 15.6 |
| volucer worker (warm, unix socket) | on | 16 | 17 | 264.4 | 757.9 | 15.6 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 48.1 | 315.5 | 2.7 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 243.6 | 726.8 | 14.3 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 39.6 | 245.8 | 2.2 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 41.0 | 421.4 | 1.2 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 297.6 | 788.1 | 17.5 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 123.5 | 123.6 | 123.5 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 44.6 | 309.2 | 2.0 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 47.3 | 510.3 | 1.2 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| nginx + php-fpm (cold, unix) | on | 16: 44.6 | 32: 47.3 | 2.7 | 16 | 0.2 |

### Memory, after load (peak concurrency)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 16 | 17 | 312.1 | 824.4 | 18.4 |
| volucer worker (warm, unix socket) | on | 16 | 17 | 312.2 | 825.1 | 18.4 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 67.9 | 415.0 | 3.8 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 310.3 | 822.6 | 18.3 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 68.6 | 492.7 | 3.8 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 87.6 | 917.3 | 2.6 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 369.6 | 879.5 | 21.7 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 139.3 | 139.3 | 139.3 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 60.9 | 503.4 | 2.8 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 79.2 | 933.2 | 2.1 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| nginx + php-fpm (cold, unix) | on | 16: 60.9 | 32: 79.2 | 18.3 | 16 | 1.1 |

## Integrity checks

No failed cells and no dropped responses in any measured cell.

