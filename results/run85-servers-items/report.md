# Worker / opcache / concurrency matrix

Every arm on one host, through one harness, so a difference between two
rows is the server rather than the measurement:

| arm | what it is |
|---|---|
| `volucer-attach` | volucer attach (warm, unix relay) |
| `volucer-prefork` | volucer spawn_cgi children (cold, unix) |
| `volucer-external` | volucer external -> php-fpm (cold, unix) |
| `rr` | RoadRunner worker (warm, pipe) |
| `frankenphp` | FrankenPHP worker (warm, embedded) |
| `fpm` | nginx + php-fpm (cold, unix) |

Rows: `/home/competition/full-run/matrix.tsv`. Memory: `/home/competition/full-run/memory.tsv`.

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

### rps at concurrency 8

| arm | opcache | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | on | — | 16,362 (16,059–16,490) | 15,173 (14,839–15,408) | 15,284 (15,002–15,354) | 15,290 (14,438–15,306) |
| volucer spawn_cgi children (cold, unix), ch=6 | on | 4,814 (4,801–4,829) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=12 | on | 5,538 (5,537–5,554) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 5,508 (5,428–5,544) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 5,544 (5,525–5,556) | — | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 4,794 (4,715–4,816) | 4,626 (4,602–4,644) | 4,250 (4,230–4,270) | 4,233 (4,217–4,269) |
| RoadRunner worker (warm, pipe) | on | — | 15,250 (14,993–15,364) | 11,672 (11,512–11,821) | 10,624 (10,461–10,643) | 10,302 (10,300–10,401) |
| FrankenPHP worker (warm, embedded) | on | — | 16,315 (16,120–16,463) | 14,776 (14,588–14,785) | 14,812 (14,576–14,885) | 14,741 (14,490–14,904) |
| nginx + php-fpm (cold, unix) | on | — | 4,883 (4,874–4,916) | 4,930 (4,829–4,941) | 4,596 (4,573–4,645) | 4,549 (4,508–4,569) |

### rps at concurrency 16

| arm | opcache | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | on | — | 17,579 (17,281–17,644) | 18,333 (18,075–18,424) | 18,161 (18,005–18,400) | 18,525 (18,165–18,643) |
| volucer spawn_cgi children (cold, unix), ch=6 | on | 4,830 (4,784–4,852) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=12 | on | 6,249 (6,240–6,285) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 6,280 (6,238–6,292) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 6,256 (6,193–6,354) | — | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 4,778 (4,755–4,794) | 6,346 (6,314–6,378) | 5,638 (5,560–5,699) | 5,569 (5,565–5,587) |
| RoadRunner worker (warm, pipe) | on | — | 15,663 (15,598–15,731) | 15,591 (15,378–15,888) | 13,844 (13,787–13,860) | 13,489 (13,434–13,802) |
| FrankenPHP worker (warm, embedded) | on | — | 18,094 (18,073–18,348) | 16,238 (15,878–16,369) | 16,287 (16,043–16,363) | 16,184 (15,904–16,383) |
| nginx + php-fpm (cold, unix) | on | — | 4,876 (4,870–4,876) | 6,715 (6,629–6,717) | 6,130 (6,064–6,204) | 5,961 (5,919–6,047) |

### rps at concurrency 32

| arm | opcache | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | on | — | 18,287 (18,114–18,637) | 23,013 (22,741–23,081) | 25,069 (24,849–25,169) | 24,993 (24,673–25,058) |
| volucer spawn_cgi children (cold, unix), ch=6 | on | 4,824 (4,817–4,847) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=12 | on | 7,406 (7,398–7,407) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 8,138 (8,133–8,216) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 8,130 (8,051–8,175) | — | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 4,791 (4,778–4,798) | 7,602 (7,589–7,635) | 8,134 (8,088–8,244) | 7,790 (7,784–7,850) |
| RoadRunner worker (warm, pipe) | on | — | 15,758 (15,689–16,058) | 18,833 (18,766–19,105) | 19,270 (19,242–19,460) | 18,853 (18,462–19,076) |
| FrankenPHP worker (warm, embedded) | on | — | 18,317 (18,226–18,523) | 16,446 (16,294–16,513) | 12,955 (12,803–12,996) | 12,813 (12,716–12,903) |
| nginx + php-fpm (cold, unix) | on | — | 4,856 (4,847–4,875) | 7,883 (7,870–7,988) | 9,031 (9,024–9,062) | 8,753 (8,680–8,988) |

### rps at concurrency 64

| arm | opcache | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | on | — | 18,447 (18,275–18,504) | 23,812 (23,767–24,524) | 29,560 (29,263–30,047) | 30,432 (30,432–30,656) |
| volucer spawn_cgi children (cold, unix), ch=6 | on | 4,835 (4,832–4,843) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=12 | on | 7,427 (7,419–7,443) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 9,031 (8,918–9,051) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 9,479 (9,465–9,585) | — | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 4,735 (4,697–4,757) | 7,541 (7,540–7,612) | 8,866 (8,849–9,075) | 9,307 (9,212–9,373) |
| RoadRunner worker (warm, pipe) | on | — | 15,950 (15,898–16,005) | 19,007 (18,739–19,163) | 21,171 (20,652–21,400) | 21,378 (20,979–21,557) |
| FrankenPHP worker (warm, embedded) | on | — | 18,764 (18,488–18,811) | 16,837 (16,751–16,886) | 14,130 (13,925–14,171) | 13,849 (13,822–13,888) |
| nginx + php-fpm (cold, unix) | on | — | 4,876 (4,856–4,897) | 7,932 (7,855–7,947) | 9,250 (9,166–9,290) | 9,421 (9,322–9,525) |

### rps at concurrency 96

| arm | opcache | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | on | — | 18,362 (18,243–18,749) | 24,475 (24,248–24,594) | 29,684 (29,649–29,746) | 31,009 (30,860–31,253) |
| volucer spawn_cgi children (cold, unix), ch=6 | on | 4,793 (4,781–4,810) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=12 | on | 7,407 (7,316–7,407) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 9,025 (8,890–9,199) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 9,530 (9,445–9,673) | — | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 4,734 (4,721–4,803) | 7,519 (7,471–7,544) | 8,876 (8,860–8,920) | 9,334 (9,310–9,411) |
| RoadRunner worker (warm, pipe) | on | — | 15,769 (15,648–15,916) | 18,939 (18,601–19,037) | 20,921 (20,468–20,953) | 21,282 (21,073–21,418) |
| FrankenPHP worker (warm, embedded) | on | — | 18,887 (18,630–19,014) | 16,848 (16,653–16,956) | 14,108 (13,871–14,197) | 13,617 (5,798–13,778) |
| nginx + php-fpm (cold, unix) | on | — | 4,855 (4,841–4,895) | 7,900 (7,856–8,078) | 9,243 (9,149–9,350) | 9,427 (9,251–9,613) |

## Headline readings

### Best configuration per arm

| arm | rps | workers | children | opcache | concurrency |
|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | 31,009 | 32 | — | on | 96 |
| volucer spawn_cgi children (cold, unix) | 4,835 | 1 | 6 | on | 64 |
| volucer spawn_cgi children (cold, unix) | 7,427 | 1 | 12 | on | 64 |
| volucer spawn_cgi children (cold, unix) | 9,031 | 1 | 24 | on | 64 |
| volucer spawn_cgi children (cold, unix) | 9,530 | 1 | 32 | on | 96 |
| volucer external -> php-fpm (cold, unix) | 9,334 | 32 | — | on | 96 |
| RoadRunner worker (warm, pipe) | 21,378 | 32 | — | on | 64 |
| FrankenPHP worker (warm, embedded) | 18,887 | 6 | — | on | 96 |
| nginx + php-fpm (cold, unix) | 9,427 | 32 | — | on | 96 |

### Does another worker help? (concurrency 96, opcache on)

| arm | w=1 | w=6 | w=12 | w=24 | w=32 | peak | change from w=1 |
|---|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | — | 18,362 | 24,475 | 29,684 | 31,009 | w=32 | — |
| volucer external -> php-fpm (cold, unix) | — | 4,734 | 7,519 | 8,876 | 9,334 | w=32 | — |
| RoadRunner worker (warm, pipe) | — | 15,769 | 18,939 | 20,921 | 21,282 | w=32 | — |
| FrankenPHP worker (warm, embedded) | — | 18,887 | 16,848 | 14,108 | 13,617 | w=6 | — |
| nginx + php-fpm (cold, unix) | — | 4,855 | 7,900 | 9,243 | 9,427 | w=32 | — |

## Latency, p50 (ms)

### p50 at concurrency 8

| arm | opcache | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | on | — | 0.448 (0.446–0.457) | 0.491 (0.485–0.504) | 0.487 (0.484–0.496) | 0.489 (0.486–0.518) |
| volucer spawn_cgi children (cold, unix), ch=6 | on | 1.590 (1.590–1.600) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=12 | on | 1.330 (1.330–1.330) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 1.330 (1.330–1.350) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1.330 (1.320–1.340) | — | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 1.280 (1.280–1.300) | 1.520 (1.500–1.530) | 1.680 (1.670–1.680) | 1.690 (1.680–1.690) |
| RoadRunner worker (warm, pipe) | on | — | 0.475 (0.475–0.487) | 0.620 (0.612–0.629) | 0.672 (0.671–0.688) | 0.692 (0.684–0.693) |
| FrankenPHP worker (warm, embedded) | on | — | 0.456 (0.448–0.462) | 0.496 (0.495–0.501) | 0.494 (0.492–0.505) | 0.499 (0.491–0.506) |
| nginx + php-fpm (cold, unix) | on | — | 1.550 (1.540–1.560) | 1.450 (1.450–1.490) | 1.560 (1.530–1.570) | 1.570 (1.560–1.590) |

### p50 at concurrency 16

| arm | opcache | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | on | — | 0.642 (0.641–0.652) | 0.609 (0.605–0.618) | 0.613 (0.606–0.618) | 0.602 (0.599–0.613) |
| volucer spawn_cgi children (cold, unix), ch=6 | on | 2.380 (2.370–2.410) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=12 | on | 1.720 (1.700–1.730) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 1.710 (1.700–1.720) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1.710 (1.680–1.740) | — | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 1.310 (1.300–1.320) | 1.670 (1.670–1.700) | 1.920 (1.890–1.950) | 1.950 (1.950–1.960) |
| RoadRunner worker (warm, pipe) | on | — | 0.701 (0.700–0.707) | 0.687 (0.674–0.695) | 0.775 (0.775–0.786) | 0.793 (0.782–0.803) |
| FrankenPHP worker (warm, embedded) | on | — | 0.618 (0.609–0.618) | 0.659 (0.658–0.674) | 0.658 (0.657–0.669) | 0.663 (0.654–0.673) |
| nginx + php-fpm (cold, unix) | on | — | 2.350 (2.340–2.350) | 1.620 (1.620–1.650) | 1.760 (1.730–1.780) | 1.800 (1.760–1.810) |

### p50 at concurrency 32

| arm | opcache | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | on | — | 1.270 (1.250–1.290) | 1.000 (1.000–1.010) | 0.900 (0.900–0.900) | 0.900 (0.900–0.910) |
| volucer spawn_cgi children (cold, unix), ch=6 | on | 4.870 (4.870–4.880) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=12 | on | 3.140 (3.130–3.140) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 2.760 (2.720–2.760) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 2.750 (2.740–2.780) | — | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 1.360 (1.350–1.380) | 3.160 (3.150–3.160) | 2.770 (2.730–2.780) | 2.860 (2.840–2.870) |
| RoadRunner worker (warm, pipe) | on | — | 1.460 (1.430–1.470) | 1.200 (1.180–1.210) | 1.110 (1.100–1.130) | 1.150 (1.140–1.160) |
| FrankenPHP worker (warm, embedded) | on | — | 1.250 (1.230–1.250) | 1.340 (1.340–1.360) | 1.700 (1.690–1.720) | 1.700 (1.700–1.730) |
| nginx + php-fpm (cold, unix) | on | — | 4.810 (4.780–4.820) | 2.940 (2.890–2.940) | 2.480 (2.480–2.490) | 2.520 (2.450–2.530) |

### p50 at concurrency 64

| arm | opcache | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | on | — | 3.210 (3.210–3.230) | 2.500 (2.420–2.510) | 1.950 (1.920–1.970) | 1.890 (1.880–1.890) |
| volucer spawn_cgi children (cold, unix), ch=6 | on | 12.300 (12.300–12.310) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=12 | on | 8.030 (7.980–8.030) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 6.510 (6.500–6.600) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 6.200 (6.110–6.210) | — | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 14.200 (14.090–14.210) | 10.770 (10.670–10.820) | 7.820 (7.680–7.830) | 6.840 (6.810–6.910) |
| RoadRunner worker (warm, pipe) | on | — | 3.680 (3.660–3.690) | 3.060 (3.050–3.110) | 2.680 (2.650–2.750) | 2.640 (2.620–2.690) |
| FrankenPHP worker (warm, embedded) | on | — | 3.100 (3.090–3.160) | 3.400 (3.390–3.420) | 3.840 (3.840–3.900) | 3.870 (3.840–3.880) |
| nginx + php-fpm (cold, unix) | on | — | 12.190 (12.100–12.260) | 7.480 (7.450–7.550) | 6.320 (6.300–6.380) | 6.160 (6.070–6.220) |

### p50 at concurrency 96

| arm | opcache | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | on | — | 5.160 (5.130–5.210) | 3.910 (3.900–3.940) | 3.160 (3.160–3.170) | 3.010 (2.990–3.010) |
| volucer spawn_cgi children (cold, unix), ch=6 | on | 19.920 (19.820–19.930) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=12 | on | 12.940 (12.890–13.070) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 10.510 (10.310–10.670) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 9.950 (9.800–10.010) | — | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 23.620 (23.590–24.070) | 18.650 (18.420–18.730) | 14.220 (14.180–14.310) | 12.810 (12.630–12.840) |
| RoadRunner worker (warm, pipe) | on | — | 5.990 (5.950–6.040) | 4.970 (4.950–5.060) | 4.410 (4.390–4.510) | 4.320 (4.280–4.360) |
| FrankenPHP worker (warm, embedded) | on | — | 4.990 (4.940–5.050) | 5.490 (5.460–5.560) | 6.360 (6.330–6.450) | 6.400 (6.360–6.490) |
| nginx + php-fpm (cold, unix) | on | — | 19.630 (19.420–19.630) | 12.060 (11.790–12.140) | 10.230 (10.100–10.330) | 9.980 (9.780–10.150) |

## Latency, p99 (ms)

### p99 at concurrency 8

| arm | opcache | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | on | — | 1.050 (1.040–1.070) | 1.080 (1.060–1.100) | 1.080 (1.060–1.120) | 1.080 (1.070–1.130) |
| volucer spawn_cgi children (cold, unix), ch=6 | on | 3.000 (2.990–3.010) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=12 | on | 2.700 (2.690–2.790) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 2.850 (2.730–2.920) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 2.730 (2.690–2.810) | — | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 4.640 (4.450–4.670) | 3.560 (3.550–3.870) | 3.930 (3.870–4.080) | 3.910 (3.870–4.020) |
| RoadRunner worker (warm, pipe) | on | — | 1.220 (1.200–1.240) | 1.480 (1.480–1.510) | 1.610 (1.580–1.650) | 1.660 (1.650–1.670) |
| FrankenPHP worker (warm, embedded) | on | — | 1.170 (1.150–1.180) | 1.310 (1.300–1.310) | 1.320 (1.290–1.330) | 1.320 (1.280–1.330) |
| nginx + php-fpm (cold, unix) | on | — | 3.000 (2.970–3.060) | 3.090 (3.060–3.120) | 3.500 (3.500–3.550) | 3.630 (3.580–3.640) |

### p99 at concurrency 16

| arm | opcache | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | on | — | 1.440 (1.400–1.440) | 1.320 (1.320–1.340) | 1.330 (1.320–1.350) | 1.300 (1.300–1.320) |
| volucer spawn_cgi children (cold, unix), ch=6 | on | 4.360 (4.310–4.390) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=12 | on | 3.800 (3.790–3.940) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 3.820 (3.770–3.870) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 3.810 (3.730–3.830) | — | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 8.850 (8.710–9.380) | 3.780 (3.780–3.890) | 4.540 (4.540–4.660) | 4.660 (4.660–4.780) |
| RoadRunner worker (warm, pipe) | on | — | 1.530 (1.520–1.540) | 1.730 (1.710–1.770) | 1.920 (1.910–1.940) | 2.000 (1.980–2.030) |
| FrankenPHP worker (warm, embedded) | on | — | 1.470 (1.450–1.490) | 1.950 (1.940–1.990) | 1.930 (1.930–1.980) | 1.970 (1.970–1.990) |
| nginx + php-fpm (cold, unix) | on | — | 3.630 (3.560–3.930) | 3.490 (3.480–3.520) | 4.130 (4.110–4.170) | 4.390 (4.380–4.470) |

### p99 at concurrency 32

| arm | opcache | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | on | — | 3.490 (3.420–3.590) | 2.070 (2.050–2.080) | 1.930 (1.930–1.940) | 1.940 (1.930–1.970) |
| volucer spawn_cgi children (cold, unix), ch=6 | on | 9.540 (9.340–9.890) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=12 | on | 6.080 (6.070–6.100) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 6.020 (6.010–6.140) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 6.070 (6.000–6.200) | — | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 20.490 (19.860–20.850) | 6.080 (6.050–6.120) | 6.240 (6.110–6.250) | 6.870 (6.810–6.880) |
| RoadRunner worker (warm, pipe) | on | — | 2.480 (2.410–2.500) | 2.550 (2.530–2.570) | 3.150 (3.120–3.190) | 3.260 (3.220–3.300) |
| FrankenPHP worker (warm, embedded) | on | — | 2.390 (2.310–2.420) | 3.500 (3.430–3.520) | 6.350 (6.260–6.380) | 6.400 (6.330–6.480) |
| nginx + php-fpm (cold, unix) | on | — | 6.480 (6.430–6.490) | 4.890 (4.830–5.000) | 5.480 (5.380–5.610) | 6.390 (6.060–6.660) |

### p99 at concurrency 64

| arm | opcache | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | on | — | 10.480 (10.460–10.740) | 6.560 (6.320–6.560) | 4.050 (3.980–4.070) | 3.940 (3.930–3.970) |
| volucer spawn_cgi children (cold, unix), ch=6 | on | 25.080 (25.000–25.230) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=12 | on | 19.740 (19.460–20.670) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 12.970 (12.750–13.100) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 11.470 (11.430–11.590) | — | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 48.940 (48.580–50.010) | 15.390 (15.200–15.440) | 12.400 (12.060–12.510) | 11.600 (11.430–11.740) |
| RoadRunner worker (warm, pipe) | on | — | 5.230 (5.130–5.250) | 4.740 (4.720–4.820) | 5.660 (5.640–5.790) | 6.530 (6.490–6.570) |
| FrankenPHP worker (warm, embedded) | on | — | 4.790 (4.710–4.840) | 6.240 (6.160–6.260) | 11.320 (11.220–11.320) | 14.130 (14.080–14.220) |
| nginx + php-fpm (cold, unix) | on | — | 14.600 (14.340–14.670) | 9.670 (9.650–9.750) | 9.390 (9.200–9.440) | 9.670 (9.500–9.880) |

### p99 at concurrency 96

| arm | opcache | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | on | — | 17.880 (17.330–18.000) | 10.980 (10.940–11.000) | 7.300 (7.270–7.310) | 6.370 (6.350–6.380) |
| volucer spawn_cgi children (cold, unix), ch=6 | on | 41.990 (40.870–42.420) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=12 | on | 34.870 (34.260–34.980) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 22.480 (21.380–22.790) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 19.470 (19.110–19.530) | — | — | — | — |
| volucer external -> php-fpm (cold, unix) | on | — | 75.250 (73.540–76.450) | 24.830 (24.530–25.070) | 19.660 (19.390–19.730) | 18.220 (17.810–18.440) |
| RoadRunner worker (warm, pipe) | on | — | 8.150 (7.940–8.180) | 6.960 (6.930–7.080) | 8.210 (8.190–8.420) | 9.020 (8.940–9.130) |
| FrankenPHP worker (warm, embedded) | on | — | 7.040 (6.970–7.160) | 8.700 (8.610–8.760) | 13.820 (13.580–13.990) | 16.670 (16.570–16.950) |
| nginx + php-fpm (cold, unix) | on | — | 22.940 (22.610–23.240) | 14.490 (14.160–14.530) | 13.270 (13.240–13.490) | 13.590 (13.180–13.990) |

## opcache

Every cell in this run was measured with opcache **on**, which is the
production case and the only one where a shared OPcache segment can exist —
so the ON/OFF ratio is not a column here.
The 8.5 pass that measured it (`results/matrix85-opcache/report.md`)
has the ON/OFF ratio for the arms both runs share.

## Shape comparisons

### Shape comparisons at concurrency 8

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| transport: unix vs pipe | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| memory model: attach vs pipe | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| control: children=1 vs plain spawn_cgi | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=6 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=12 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=24 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=32 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |

### Shape comparisons at concurrency 16

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| transport: unix vs pipe | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| memory model: attach vs pipe | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| control: children=1 vs plain spawn_cgi | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=6 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=12 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=24 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=32 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |

### Shape comparisons at concurrency 32

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| transport: unix vs pipe | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| memory model: attach vs pipe | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| control: children=1 vs plain spawn_cgi | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=6 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=12 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=24 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=32 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |

### Shape comparisons at concurrency 64

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| transport: unix vs pipe | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| memory model: attach vs pipe | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| control: children=1 vs plain spawn_cgi | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=6 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=12 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=24 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=32 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |

### Shape comparisons at concurrency 96

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=6 | w=12 | w=24 | w=32 |
|---|---|---|---|---|---|---|
| transport: unix vs pipe | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| memory model: attach vs pipe | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| control: children=1 vs plain spawn_cgi | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=6 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=12 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=24 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |
| prefork: children=32 vs children=1 | rps | — | — | — | — | — |
|  | PSS | — | — | — | — | — |

## At equal PHP process counts

`workers` is not one quantity across arms (see the note above), so this is
the axis on which the arms can be read against each other. The count is the
measured `pids` of each arm's process tree, not the configured value, and the
parenthesised config is what produced it.

**8 PHP processes**

| arm (config) | c=8 | c=16 | c=32 | c=64 | c=96 |
|---|---|---|---|---|---|
| volucer spawn_cgi children (cold, unix) (w=1 ch=6) | 4,814 | 4,830 | 4,824 | 4,835 | 4,793 |
| volucer external -> php-fpm (cold, unix) (w=6) | 4,794 | 4,778 | 4,791 | 4,735 | 4,734 |

**12 PHP processes**

| arm (config) | c=8 | c=16 | c=32 | c=64 | c=96 |
|---|---|---|---|---|---|
| volucer attach (warm, unix relay) (w=6) | 16,362 | 17,579 | 18,287 | 18,447 | 18,362 |
| nginx + php-fpm (cold, unix) (w=6) | 4,883 | 4,876 | 4,856 | 4,876 | 4,855 |

**14 PHP processes**

| arm (config) | c=8 | c=16 | c=32 | c=64 | c=96 |
|---|---|---|---|---|---|
| volucer attach (warm, unix relay) (w=12) | 15,173 | 18,333 | 23,013 | 23,812 | 24,475 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=12) | 5,538 | 6,249 | 7,406 | 7,427 | 7,407 |
| volucer external -> php-fpm (cold, unix) (w=12) | 4,626 | 6,346 | 7,602 | 7,541 | 7,519 |

**26 PHP processes**

| arm (config) | c=8 | c=16 | c=32 | c=64 | c=96 |
|---|---|---|---|---|---|
| volucer attach (warm, unix relay) (w=24) | 15,284 | 18,161 | 25,069 | 29,560 | 29,684 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=24) | 5,508 | 6,280 | 8,138 | 9,031 | 9,025 |
| volucer external -> php-fpm (cold, unix) (w=24) | 4,250 | 5,638 | 8,134 | 8,866 | 8,876 |

**34 PHP processes**

| arm (config) | c=8 | c=16 | c=32 | c=64 | c=96 |
|---|---|---|---|---|---|
| volucer attach (warm, unix relay) (w=32) | 15,290 | 18,525 | 24,993 | 30,432 | 31,009 |
| volucer spawn_cgi children (cold, unix) (w=1 ch=32) | 5,544 | 6,256 | 8,130 | 9,479 | 9,530 |
| volucer external -> php-fpm (cold, unix) (w=32) | 4,233 | 5,569 | 7,790 | 9,307 | 9,334 |

## Memory

### Memory, boot (before any request)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | on | 6 | 8 | 46.6 | 164.0 | 5.8 |
| volucer attach (warm, unix relay) | on | 12 | 14 | 50.3 | 259.1 | 3.6 |
| volucer attach (warm, unix relay) | on | 24 | 26 | 57.9 | 450.2 | 2.2 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 63.0 | 575.8 | 1.9 |
| volucer spawn_cgi children (cold, unix), ch=6 | on | 1 | 8 | 43.0 | 140.7 | 5.4 |
| volucer spawn_cgi children (cold, unix), ch=12 | on | 1 | 14 | 43.6 | 206.7 | 3.1 |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 1 | 26 | 44.7 | 337.9 | 1.7 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 45.1 | 424.0 | 1.3 |
| volucer external -> php-fpm (cold, unix) | on | 6 | 8 | 41.1 | 148.9 | 5.1 |
| volucer external -> php-fpm (cold, unix) | on | 12 | 14 | 42.4 | 224.0 | 3.0 |
| volucer external -> php-fpm (cold, unix) | on | 24 | 26 | 44.3 | 375.4 | 1.7 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 45.8 | 474.7 | 1.3 |
| RoadRunner worker (warm, pipe) | on | 6 | 7 | 160.7 | 331.7 | 23.0 |
| RoadRunner worker (warm, pipe) | on | 12 | 13 | 248.5 | 608.3 | 19.1 |
| RoadRunner worker (warm, pipe) | on | 24 | 25 | 417.4 | 1,160.9 | 16.7 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 529.2 | 1,528.0 | 16.0 |
| FrankenPHP worker (warm, embedded) | on | 6 | 1 | 108.8 | 108.8 | 108.8 |
| FrankenPHP worker (warm, embedded) | on | 12 | 1 | 117.7 | 117.7 | 117.7 |
| FrankenPHP worker (warm, embedded) | on | 24 | 1 | 133.2 | 133.2 | 133.2 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 141.7 | 141.7 | 141.7 |
| nginx + php-fpm (cold, unix) | on | 6 | 12 | 42.7 | 183.0 | 3.6 |
| nginx + php-fpm (cold, unix) | on | 12 | 18 | 43.8 | 259.0 | 2.4 |
| nginx + php-fpm (cold, unix) | on | 24 | 30 | 45.9 | 409.3 | 1.5 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 47.2 | 510.7 | 1.2 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | on | 6: 46.6 | 32: 63.0 | 16.4 | 26 | 0.6 |
| volucer external -> php-fpm (cold, unix) | on | 6: 41.1 | 32: 45.8 | 4.7 | 26 | 0.2 |
| RoadRunner worker (warm, pipe) | on | 6: 160.7 | 32: 529.2 | 368.5 | 26 | 14.2 |
| FrankenPHP worker (warm, embedded) | on | 6: 108.8 | 32: 141.7 | 32.9 | 26 | 1.3 |
| nginx + php-fpm (cold, unix) | on | 6: 42.7 | 32: 47.2 | 4.5 | 26 | 0.2 |

### Memory, after load (peak concurrency)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | on | 6 | 8 | 58.9 | 203.4 | 7.4 |
| volucer attach (warm, unix relay) | on | 12 | 14 | 67.7 | 336.7 | 4.8 |
| volucer attach (warm, unix relay) | on | 24 | 26 | 82.2 | 598.5 | 3.2 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 92.2 | 773.3 | 2.7 |
| volucer spawn_cgi children (cold, unix), ch=6 | on | 1 | 8 | 58.5 | 227.4 | 7.3 |
| volucer spawn_cgi children (cold, unix), ch=12 | on | 1 | 14 | 67.2 | 386.7 | 4.8 |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 1 | 26 | 83.8 | 707.4 | 3.2 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 95.5 | 921.3 | 2.8 |
| volucer external -> php-fpm (cold, unix) | on | 6 | 8 | 57.0 | 227.6 | 7.1 |
| volucer external -> php-fpm (cold, unix) | on | 12 | 14 | 67.9 | 389.9 | 4.9 |
| volucer external -> php-fpm (cold, unix) | on | 24 | 26 | 84.6 | 709.1 | 3.3 |
| volucer external -> php-fpm (cold, unix) | on | 32 | 34 | 94.5 | 927.5 | 2.8 |
| RoadRunner worker (warm, pipe) | on | 6 | 7 | 188.8 | 365.3 | 27.0 |
| RoadRunner worker (warm, pipe) | on | 12 | 13 | 295.6 | 668.8 | 22.7 |
| RoadRunner worker (warm, pipe) | on | 24 | 25 | 502.1 | 1,275.6 | 20.1 |
| RoadRunner worker (warm, pipe) | on | 32 | 33 | 641.7 | 1,683.2 | 19.4 |
| FrankenPHP worker (warm, embedded) | on | 6 | 1 | 126.5 | 126.5 | 126.5 |
| FrankenPHP worker (warm, embedded) | on | 12 | 1 | 138.2 | 138.2 | 138.2 |
| FrankenPHP worker (warm, embedded) | on | 24 | 1 | 155.2 | 155.2 | 155.2 |
| FrankenPHP worker (warm, embedded) | on | 32 | 1 | 168.7 | 168.7 | 168.7 |
| nginx + php-fpm (cold, unix) | on | 6 | 12 | 48.4 | 233.5 | 4.0 |
| nginx + php-fpm (cold, unix) | on | 12 | 18 | 56.2 | 395.0 | 3.1 |
| nginx + php-fpm (cold, unix) | on | 24 | 30 | 70.7 | 715.4 | 2.4 |
| nginx + php-fpm (cold, unix) | on | 32 | 38 | 79.7 | 930.8 | 2.1 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer attach (warm, unix relay) | on | 6: 58.9 | 32: 92.2 | 33.3 | 26 | 1.3 |
| volucer external -> php-fpm (cold, unix) | on | 6: 57.0 | 32: 94.5 | 37.5 | 26 | 1.4 |
| RoadRunner worker (warm, pipe) | on | 6: 188.8 | 32: 641.7 | 452.9 | 26 | 17.4 |
| FrankenPHP worker (warm, embedded) | on | 6: 126.5 | 32: 168.7 | 42.2 | 26 | 1.6 |
| nginx + php-fpm (cold, unix) | on | 6: 48.4 | 32: 79.7 | 31.3 | 26 | 1.2 |

## Integrity checks

No failed cells and no dropped responses in any measured cell.

