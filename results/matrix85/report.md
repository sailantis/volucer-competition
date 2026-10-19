# Worker / opcache / concurrency matrix

Rows: `/home/competition/matrix85/matrix.tsv`. Memory: `/home/competition/matrix85/memory.tsv`.

Every cell is the **median over the rounds**, with the min–max spread across
rounds in parentheses where there was more than one round. `p50` and `p99` are
each their own median across the rounds of that cell — not the percentile of
whichever round happened to have the median throughput.

## Throughput (requests/sec)

### wrk thread count at concurrency 16 (rps | p50 ms | p99 ms)

| arm | opcache | workers | t=12 | t=16 | t=32 | t=48 | t=64 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 16 | 15,324 (0.73 / 1.47) | 17,670 (0.85 / 1.75) | — | — | — |
| volucer worker (warm, pipe) | on | 16 | 15,770 (0.71 / 1.43) | 18,087 (0.83 / 1.73) | — | — | — |
| volucer spawn_cgi (cold, unix) | off | 16 | 542 (20.84 / 38.84) | 593 (23.25 / 71.90) | — | — | — |
| volucer spawn_cgi (cold, unix) | on | 16 | 5,210 (2.12 / 4.79) | 6,034 (2.47 / 6.49) | — | — | — |
| RoadRunner worker (warm, pipe) | off | 16 | 13,900 (0.77 / 1.90) | 16,785 (0.86 / 2.29) | — | — | — |
| RoadRunner worker (warm, pipe) | on | 16 | 14,439 (0.76 / 1.85) | 17,238 (0.84 / 2.21) | — | — | — |
| FrankenPHP worker (warm, embedded) | off | 16 | 15,571 (0.69 / 1.97) | 13,800 (1.04 / 3.28) | — | — | — |
| FrankenPHP worker (warm, embedded) | on | 16 | 15,516 (0.69 / 2.01) | 13,934 (1.04 / 3.38) | — | — | — |
| nginx + php-fpm (cold, unix) | off | 16 | 637 (17.10 / 33.56) | 753 (16.87 / 43.45) | — | — | — |
| nginx + php-fpm (cold, unix) | on | 16 | 6,336 (1.71 / 3.87) | 7,957 (1.85 / 4.13) | — | — | — |

Each cell is `rps (p50 / p99)`. Where the columns differ, the choice of
thread count was a variable and not a constant.

### wrk thread count at concurrency 32 (rps | p50 ms | p99 ms)

| arm | opcache | workers | t=12 | t=16 | t=32 | t=48 | t=64 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 16 | 21,959 (1.03 / 2.18) | — | 23,027 (1.30 / 2.97) | — | — |
| volucer worker (warm, pipe) | on | 16 | 22,076 (1.02 / 2.15) | — | 23,674 (1.28 / 2.88) | — | — |
| volucer spawn_cgi (cold, unix) | off | 16 | 623 (27.97 / 232.09) | — | 635 (36.99 / 362.09) | — | — |
| volucer spawn_cgi (cold, unix) | on | 16 | 6,647 (2.88 / 20.37) | — | 6,715 (3.68 / 35.90) | — | — |
| RoadRunner worker (warm, pipe) | off | 16 | 19,293 (1.13 / 3.21) | — | 19,078 (1.55 / 3.80) | — | — |
| RoadRunner worker (warm, pipe) | on | 16 | 19,945 (1.09 / 3.12) | — | 19,426 (1.52 / 3.74) | — | — |
| FrankenPHP worker (warm, embedded) | off | 16 | 13,625 (1.52 / 5.66) | — | 13,891 (2.08 / 6.44) | — | — |
| FrankenPHP worker (warm, embedded) | on | 16 | 13,892 (1.50 / 5.49) | — | 14,171 (2.04 / 6.33) | — | — |
| nginx + php-fpm (cold, unix) | off | 16 | 782 (28.24 / 47.14) | — | 785 (37.77 / 57.96) | — | — |
| nginx + php-fpm (cold, unix) | on | 16 | 8,292 (2.79 / 4.94) | — | 8,167 (3.79 / 5.93) | — | — |

Each cell is `rps (p50 / p99)`. Where the columns differ, the choice of
thread count was a variable and not a constant.

### wrk thread count at concurrency 48 (rps | p50 ms | p99 ms)

| arm | opcache | workers | t=12 | t=16 | t=32 | t=48 | t=64 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 16 | 23,600 (1.91 / 5.35) | — | — | 23,263 (1.94 / 5.45) | — |
| volucer worker (warm, pipe) | on | 16 | 24,035 (1.87 / 5.20) | — | — | 23,792 (1.90 / 5.38) | — |
| volucer spawn_cgi (cold, unix) | off | 16 | 659 (53.81 / 505.41) | — | — | 649 (54.85 / 535.06) | — |
| volucer spawn_cgi (cold, unix) | on | 16 | 6,818 (5.32 / 77.75) | — | — | 6,807 (5.21 / 70.08) | — |
| RoadRunner worker (warm, pipe) | off | 16 | 19,427 (2.32 / 4.88) | — | — | 19,034 (2.37 / 4.91) | — |
| RoadRunner worker (warm, pipe) | on | 16 | 19,918 (2.27 / 4.70) | — | — | 19,755 (2.28 / 4.75) | — |
| FrankenPHP worker (warm, embedded) | off | 16 | 14,025 (3.16 / 7.85) | — | — | 13,917 (3.17 / 7.67) | — |
| FrankenPHP worker (warm, embedded) | on | 16 | 14,461 (3.08 / 7.76) | — | — | 14,605 (3.05 / 7.21) | — |
| nginx + php-fpm (cold, unix) | off | 16 | 767 (59.26 / 84.00) | — | — | 773 (58.72 / 84.07) | — |
| nginx + php-fpm (cold, unix) | on | 16 | 8,355 (5.63 / 7.93) | — | — | 8,328 (5.66 / 7.94) | — |

Each cell is `rps (p50 / p99)`. Where the columns differ, the choice of
thread count was a variable and not a constant.

### wrk thread count at concurrency 64 (rps | p50 ms | p99 ms)

| arm | opcache | workers | t=12 | t=16 | t=32 | t=48 | t=64 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 16 | 23,713 (2.39 / 7.49) | — | — | — | 23,354 (2.64 / 8.24) |
| volucer worker (warm, pipe) | on | 16 | 24,336 (2.33 / 7.28) | — | — | — | 24,307 (2.54 / 8.11) |
| volucer spawn_cgi (cold, unix) | off | 16 | 666 (62.55 / 766.58) | — | — | — | 655 (72.96 / 798.23) |
| volucer spawn_cgi (cold, unix) | on | 16 | 6,855 (6.19 / 87.40) | — | — | — | 6,864 (6.75 / 108.51) |
| RoadRunner worker (warm, pipe) | off | 16 | 19,286 (2.94 / 5.64) | — | — | — | 19,277 (3.16 / 5.82) |
| RoadRunner worker (warm, pipe) | on | 16 | 19,904 (2.84 / 5.51) | — | — | — | 19,999 (3.03 / 5.73) |
| FrankenPHP worker (warm, embedded) | off | 16 | 14,153 (3.95 / 8.78) | — | — | — | 13,974 (4.31 / 8.68) |
| FrankenPHP worker (warm, embedded) | on | 16 | 14,406 (3.88 / 8.54) | — | — | — | 14,479 (4.17 / 8.40) |
| nginx + php-fpm (cold, unix) | off | 16 | 773 (73.51 / 95.00) | — | — | — | 780 (78.17 / 98.86) |
| nginx + php-fpm (cold, unix) | on | 16 | 8,292 (7.02 / 9.38) | — | — | — | 8,397 (7.51 / 9.82) |

Each cell is `rps (p50 / p99)`. Where the columns differ, the choice of
thread count was a variable and not a constant.

## Headline readings

### Best configuration per arm

| arm | rps | workers | opcache | concurrency |
|---|---|---|---|---|
| volucer worker (warm, pipe) | 24,322 | 16 | on | 64 |
| volucer spawn_cgi (cold, unix) | 6,860 | 16 | on | 64 |
| RoadRunner worker (warm, pipe) | 19,911 | 16 | on | 64 |
| FrankenPHP worker (warm, embedded) | 14,735 | 16 | off | 16 |
| nginx + php-fpm (cold, unix) | 8,363 | 16 | on | 64 |

## Latency, p50 (ms)

### p50 at concurrency 16

| arm | opcache | w=16 |
|---|---|---|
| volucer worker (warm, pipe) | off | 0.789 (0.723–0.860) |
| volucer worker (warm, pipe) | on | 0.766 (0.692–0.839) |
| volucer spawn_cgi (cold, unix) | off | 22.070 (20.800–24.070) |
| volucer spawn_cgi (cold, unix) | on | 2.295 (2.070–2.520) |
| RoadRunner worker (warm, pipe) | off | 0.818 (0.766–0.870) |
| RoadRunner worker (warm, pipe) | on | 0.799 (0.743–0.844) |
| FrankenPHP worker (warm, embedded) | off | 0.863 (0.685–1.040) |
| FrankenPHP worker (warm, embedded) | on | 0.867 (0.688–1.060) |
| nginx + php-fpm (cold, unix) | off | 17.090 (16.700–17.190) |
| nginx + php-fpm (cold, unix) | on | 1.785 (1.660–1.920) |

### p50 at concurrency 32

| arm | opcache | w=16 |
|---|---|---|
| volucer worker (warm, pipe) | off | 1.170 (1.030–1.300) |
| volucer worker (warm, pipe) | on | 1.145 (1.000–1.290) |
| volucer spawn_cgi (cold, unix) | off | 33.105 (27.550–38.640) |
| volucer spawn_cgi (cold, unix) | on | 3.270 (2.870–3.750) |
| RoadRunner worker (warm, pipe) | off | 1.325 (1.120–1.560) |
| RoadRunner worker (warm, pipe) | on | 1.305 (1.080–1.520) |
| FrankenPHP worker (warm, embedded) | off | 1.805 (1.520–2.080) |
| FrankenPHP worker (warm, embedded) | on | 1.775 (1.470–2.060) |
| nginx + php-fpm (cold, unix) | off | 33.055 (27.880–37.790) |
| nginx + php-fpm (cold, unix) | on | 3.250 (2.770–3.830) |

### p50 at concurrency 48

| arm | opcache | w=16 |
|---|---|---|
| volucer worker (warm, pipe) | off | 1.915 (1.910–1.960) |
| volucer worker (warm, pipe) | on | 1.895 (1.840–1.910) |
| volucer spawn_cgi (cold, unix) | off | 53.910 (51.530–55.040) |
| volucer spawn_cgi (cold, unix) | on | 5.290 (5.090–5.470) |
| RoadRunner worker (warm, pipe) | off | 2.340 (2.300–2.380) |
| RoadRunner worker (warm, pipe) | on | 2.270 (2.250–2.280) |
| FrankenPHP worker (warm, embedded) | off | 3.160 (3.100–3.230) |
| FrankenPHP worker (warm, embedded) | on | 3.065 (3.020–3.100) |
| nginx + php-fpm (cold, unix) | off | 58.990 (58.310–59.770) |
| nginx + php-fpm (cold, unix) | on | 5.640 (5.570–5.730) |

### p50 at concurrency 64

| arm | opcache | w=16 |
|---|---|---|
| volucer worker (warm, pipe) | off | 2.515 (2.390–2.650) |
| volucer worker (warm, pipe) | on | 2.435 (2.290–2.660) |
| volucer spawn_cgi (cold, unix) | off | 71.105 (61.820–77.490) |
| volucer spawn_cgi (cold, unix) | on | 6.515 (6.160–7.360) |
| RoadRunner worker (warm, pipe) | off | 3.055 (2.940–3.170) |
| RoadRunner worker (warm, pipe) | on | 2.935 (2.830–3.070) |
| FrankenPHP worker (warm, embedded) | off | 4.105 (3.910–4.320) |
| FrankenPHP worker (warm, embedded) | on | 4.030 (3.810–4.180) |
| nginx + php-fpm (cold, unix) | off | 76.225 (72.940–79.490) |
| nginx + php-fpm (cold, unix) | on | 7.340 (6.990–7.560) |

## Latency, p99 (ms)

### p99 at concurrency 16

| arm | opcache | w=16 |
|---|---|---|
| volucer worker (warm, pipe) | off | 1.610 (1.450–1.800) |
| volucer worker (warm, pipe) | on | 1.580 (1.410–1.740) |
| volucer spawn_cgi (cold, unix) | off | 52.610 (37.210–79.060) |
| volucer spawn_cgi (cold, unix) | on | 5.610 (4.680–7.000) |
| RoadRunner worker (warm, pipe) | off | 2.080 (1.900–2.320) |
| RoadRunner worker (warm, pipe) | on | 2.045 (1.850–2.240) |
| FrankenPHP worker (warm, embedded) | off | 2.605 (1.930–3.340) |
| FrankenPHP worker (warm, embedded) | on | 2.655 (1.970–3.430) |
| nginx + php-fpm (cold, unix) | off | 34.625 (33.310–43.970) |
| nginx + php-fpm (cold, unix) | on | 4.000 (3.860–4.740) |

### p99 at concurrency 32

| arm | opcache | w=16 |
|---|---|---|
| volucer worker (warm, pipe) | off | 2.605 (2.160–2.970) |
| volucer worker (warm, pipe) | on | 2.510 (2.110–2.930) |
| volucer spawn_cgi (cold, unix) | off | 303.095 (212.760–439.140) |
| volucer spawn_cgi (cold, unix) | on | 26.965 (19.510–37.080) |
| RoadRunner worker (warm, pipe) | off | 3.510 (3.130–3.860) |
| RoadRunner worker (warm, pipe) | on | 3.405 (3.120–3.780) |
| FrankenPHP worker (warm, embedded) | off | 6.040 (5.640–6.480) |
| FrankenPHP worker (warm, embedded) | on | 5.905 (5.480–6.390) |
| nginx + php-fpm (cold, unix) | off | 54.090 (46.610–60.660) |
| nginx + php-fpm (cold, unix) | on | 5.425 (4.900–6.060) |

### p99 at concurrency 48

| arm | opcache | w=16 |
|---|---|---|
| volucer worker (warm, pipe) | off | 5.415 (5.310–5.600) |
| volucer worker (warm, pipe) | on | 5.355 (5.200–5.390) |
| volucer spawn_cgi (cold, unix) | off | 528.840 (446.260–717.400) |
| volucer spawn_cgi (cold, unix) | on | 73.510 (60.250–78.040) |
| RoadRunner worker (warm, pipe) | off | 4.880 (4.800–4.930) |
| RoadRunner worker (warm, pipe) | on | 4.725 (4.660–4.770) |
| FrankenPHP worker (warm, embedded) | off | 7.710 (7.520–7.890) |
| FrankenPHP worker (warm, embedded) | on | 7.440 (7.180–8.070) |
| nginx + php-fpm (cold, unix) | off | 84.035 (80.500–95.430) |
| nginx + php-fpm (cold, unix) | on | 7.935 (7.720–7.980) |

### p99 at concurrency 64

| arm | opcache | w=16 |
|---|---|---|
| volucer worker (warm, pipe) | off | 7.850 (7.470–8.290) |
| volucer worker (warm, pipe) | on | 7.615 (7.030–8.490) |
| volucer spawn_cgi (cold, unix) | off | 782.405 (547.530–929.820) |
| volucer spawn_cgi (cold, unix) | on | 89.275 (82.610–123.010) |
| RoadRunner worker (warm, pipe) | off | 5.745 (5.520–5.890) |
| RoadRunner worker (warm, pipe) | on | 5.605 (5.440–5.730) |
| FrankenPHP worker (warm, embedded) | off | 8.720 (8.560–8.920) |
| FrankenPHP worker (warm, embedded) | on | 8.450 (8.310–8.680) |
| nginx + php-fpm (cold, unix) | off | 98.400 (94.450–101.620) |
| nginx + php-fpm (cold, unix) | on | 9.655 (9.240–9.880) |

## opcache

### opcache effect at concurrency 16 (rps on / rps off)

| arm | w=16 |
|---|---|
| volucer worker (warm, pipe) | 1.04× |
| volucer spawn_cgi (cold, unix) | 9.92× |
| RoadRunner worker (warm, pipe) | 1.03× |
| FrankenPHP worker (warm, embedded) | 1.00× |
| nginx + php-fpm (cold, unix) | 10.24× |

### opcache effect at concurrency 32 (rps on / rps off)

| arm | w=16 |
|---|---|
| volucer worker (warm, pipe) | 1.02× |
| volucer spawn_cgi (cold, unix) | 10.54× |
| RoadRunner worker (warm, pipe) | 1.02× |
| FrankenPHP worker (warm, embedded) | 1.03× |
| nginx + php-fpm (cold, unix) | 10.51× |

### opcache effect at concurrency 48 (rps on / rps off)

| arm | w=16 |
|---|---|
| volucer worker (warm, pipe) | 1.02× |
| volucer spawn_cgi (cold, unix) | 10.44× |
| RoadRunner worker (warm, pipe) | 1.03× |
| FrankenPHP worker (warm, embedded) | 1.04× |
| nginx + php-fpm (cold, unix) | 10.83× |

### opcache effect at concurrency 64 (rps on / rps off)

| arm | w=16 |
|---|---|
| volucer worker (warm, pipe) | 1.04× |
| volucer spawn_cgi (cold, unix) | 10.40× |
| RoadRunner worker (warm, pipe) | 1.03× |
| FrankenPHP worker (warm, embedded) | 1.03× |
| nginx + php-fpm (cold, unix) | 10.77× |

## Memory

### Memory, boot (before any request)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 16 | 17 | 209.7 | 701.3 | 12.3 |
| volucer worker (warm, pipe) | on | 16 | 17 | 258.0 | 752.1 | 15.2 |
| volucer spawn_cgi (cold, unix) | off | 16 | 17 | 194.6 | 678.7 | 11.4 |
| volucer spawn_cgi (cold, unix) | on | 16 | 17 | 242.4 | 726.9 | 14.3 |
| RoadRunner worker (warm, pipe) | off | 16 | 17 | 247.7 | 737.2 | 14.6 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 296.5 | 788.1 | 17.4 |
| FrankenPHP worker (warm, embedded) | off | 16 | 1 | 122.6 | 122.6 | 122.6 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 123.4 | 123.4 | 123.4 |
| nginx + php-fpm (cold, unix) | off | 16 | 22 | 40.2 | 295.9 | 1.8 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 44.0 | 309.7 | 2.0 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|

### Memory, after load (peak concurrency)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 16 | 17 | 260.4 | 770.1 | 15.3 |
| volucer worker (warm, pipe) | on | 16 | 17 | 311.2 | 824.4 | 18.3 |
| volucer spawn_cgi (cold, unix) | off | 16 | 17 | 255.6 | 765.3 | 15.0 |
| volucer spawn_cgi (cold, unix) | on | 16 | 17 | 309.8 | 823.3 | 18.2 |
| RoadRunner worker (warm, pipe) | off | 16 | 17 | 318.6 | 826.9 | 18.7 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 368.6 | 879.7 | 21.7 |
| FrankenPHP worker (warm, embedded) | off | 16 | 1 | 172.0 | 172.0 | 172.0 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 139.3 | 139.3 | 139.3 |
| nginx + php-fpm (cold, unix) | off | 16 | 22 | 98.1 | 480.5 | 4.5 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 60.4 | 505.6 | 2.7 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|

## Integrity checks

No failed cells and no dropped responses in any measured cell.

