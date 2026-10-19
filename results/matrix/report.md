# Worker / opcache / concurrency matrix

Rows: `results/matrix/matrix.tsv`. Memory: `results/matrix/memory.tsv`.

Every cell is the **median over the rounds**, with the min–max spread across
rounds in parentheses where there was more than one round. `p50` and `p99` are
each their own median across the rounds of that cell — not the percentile of
whichever round happened to have the median throughput.

## Throughput (requests/sec)

### rps at concurrency 16

| arm | opcache | w=12 | w=16 | w=20 | w=24 |
|---|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 15,793 (15,474–15,923) | 15,374 (15,165–15,444) | 15,310 (15,281–15,605) | 15,102 (14,953–15,415) |
| volucer worker (warm, pipe) | on | 16,014 (15,629–16,105) | 15,876 (15,750–16,001) | 15,543 (15,491–15,991) | 15,468 (15,246–16,104) |
| volucer spawn_cgi (cold, unix) | off | 620 (604–624) | 556 (545–562) | 598 (592–599) | 587 (572–602) |
| volucer spawn_cgi (cold, unix) | on | 5,524 (5,468–5,600) | 5,068 (5,045–5,179) | 5,037 (5,003–5,174) | 4,865 (4,825–4,885) |
| RoadRunner worker (warm, pipe) | off | 14,854 (14,630–15,272) | 13,762 (13,501–13,853) | 13,126 (13,100–13,208) | 12,746 (12,715–12,750) |
| RoadRunner worker (warm, pipe) | on | 15,192 (15,072–15,424) | 14,030 (13,909–14,245) | 13,481 (13,426–13,526) | 13,174 (12,996–13,210) |
| FrankenPHP worker (warm, embedded) | off | 15,389 (15,386–15,423) | 15,483 (15,437–15,689) | 15,402 (15,374–15,580) | 15,514 (15,213–15,592) |
| FrankenPHP worker (warm, embedded) | on | 15,966 (15,805–16,065) | 15,990 (15,890–16,080) | 15,860 (15,847–15,897) | 15,734 (15,626–16,113) |
| nginx + php-fpm (cold, unix) | off | 778 (771–790) | 658 (656–659) | 618 (617–618) | 600 (597–605) |
| nginx + php-fpm (cold, unix) | on | 6,544 (6,482–6,547) | 6,382 (6,349–6,392) | 6,177 (6,168–6,280) | 6,016 (5,944–6,038) |

### rps at concurrency 32

| arm | opcache | w=12 | w=16 | w=20 | w=24 |
|---|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 22,036 (21,973–22,214) | 21,118 (20,961–21,166) | 19,694 (19,646–19,862) | 19,075 (19,038–19,254) |
| volucer worker (warm, pipe) | on | 22,431 (22,073–22,513) | 21,778 (21,360–22,027) | 20,284 (20,102–20,559) | 19,193 (19,184–19,717) |
| volucer spawn_cgi (cold, unix) | off | 705 (673–720) | 630 (626–630) | 672 (671–676) | 733 (732–733) |
| volucer spawn_cgi (cold, unix) | on | 7,026 (6,950–7,033) | 6,451 (6,365–6,493) | 7,049 (6,774–7,079) | 6,763 (6,674–6,777) |
| RoadRunner worker (warm, pipe) | off | 17,901 (17,774–17,956) | 19,102 (18,668–19,224) | 18,694 (18,580–18,709) | 17,935 (17,742–17,997) |
| RoadRunner worker (warm, pipe) | on | 18,358 (18,294–18,464) | 19,733 (19,728–19,734) | 19,138 (18,885–19,209) | 18,280 (18,257–18,581) |
| FrankenPHP worker (warm, embedded) | off | 15,488 (15,476–15,670) | 13,690 (13,515–13,701) | 12,684 (12,577–12,713) | 12,210 (12,077–12,268) |
| FrankenPHP worker (warm, embedded) | on | 15,897 (15,828–16,053) | 14,032 (13,975–14,150) | 13,017 (12,949–13,076) | 12,640 (12,542–12,677) |
| nginx + php-fpm (cold, unix) | off | 797 (794–808) | 808 (793–811) | 809 (798–817) | 797 (793–810) |
| nginx + php-fpm (cold, unix) | on | 7,591 (7,560–7,821) | 8,308 (8,279–8,374) | 8,757 (8,661–8,959) | 8,724 (8,642–9,041) |

### rps at concurrency 48

| arm | opcache | w=12 | w=16 | w=20 | w=24 |
|---|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 22,748 (22,168–23,038) | 22,794 (22,713–23,086) | 22,860 (22,809–23,085) | 22,081 (21,627–22,114) |
| volucer worker (warm, pipe) | on | 22,854 (22,626–22,932) | 23,253 (23,231–23,654) | 23,291 (23,098–23,583) | 22,314 (22,155–22,504) |
| volucer spawn_cgi (cold, unix) | off | 732 (721–743) | 671 (642–673) | 689 (686–690) | 754 (749–762) |
| volucer spawn_cgi (cold, unix) | on | 7,420 (7,412–7,424) | 6,675 (6,616–6,713) | 7,484 (7,376–7,612) | 7,158 (7,134–7,402) |
| RoadRunner worker (warm, pipe) | off | 17,820 (17,787–18,000) | 19,104 (18,355–19,112) | 19,460 (19,393–19,577) | 19,606 (19,411–19,726) |
| RoadRunner worker (warm, pipe) | on | 18,322 (18,129–18,370) | 19,587 (19,363–19,632) | 19,897 (19,679–20,110) | 19,808 (19,798–19,962) |
| FrankenPHP worker (warm, embedded) | off | 16,030 (15,940–16,063) | 14,050 (13,932–14,316) | 13,514 (13,487–13,539) | 13,072 (12,926–13,171) |
| FrankenPHP worker (warm, embedded) | on | 16,257 (16,156–16,404) | 14,613 (14,567–14,666) | 13,878 (13,693–13,947) | 13,557 (13,431–13,563) |
| nginx + php-fpm (cold, unix) | off | 781 (773–791) | 807 (790–818) | 803 (798–805) | 810 (800–815) |
| nginx + php-fpm (cold, unix) | on | 7,755 (7,559–7,769) | 8,305 (8,261–8,341) | 8,893 (8,876–8,992) | 8,885 (8,795–9,089) |

### rps at concurrency 64

| arm | opcache | w=12 | w=16 | w=20 | w=24 |
|---|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 22,720 (21,880–22,829) | 23,007 (22,534–23,069) | 23,057 (22,539–23,105) | 22,418 (22,175–22,635) |
| volucer worker (warm, pipe) | on | 23,118 (23,100–23,151) | 23,508 (23,087–23,599) | 23,449 (23,051–23,665) | 22,938 (22,599–23,053) |
| volucer spawn_cgi (cold, unix) | off | 743 (720–749) | 666 (657–685) | 692 (690–694) | 757 (739–762) |
| volucer spawn_cgi (cold, unix) | on | 7,574 (7,488–7,610) | 6,764 (6,729–6,827) | 7,648 (7,551–7,695) | 7,253 (7,169–7,320) |
| RoadRunner worker (warm, pipe) | off | 17,936 (17,662–17,966) | 18,947 (18,690–18,993) | 19,459 (19,344–19,619) | 19,179 (18,848–19,234) |
| RoadRunner worker (warm, pipe) | on | 18,190 (18,152–18,524) | 19,437 (19,431–19,780) | 19,750 (19,597–19,819) | 19,864 (19,559–20,058) |
| FrankenPHP worker (warm, embedded) | off | 15,957 (15,790–16,037) | 14,072 (14,004–14,300) | 13,460 (13,452–13,624) | 13,070 (13,070–13,135) |
| FrankenPHP worker (warm, embedded) | on | 16,252 (16,155–16,367) | 14,542 (14,537–14,673) | 13,844 (13,821–13,997) | 13,535 (13,472–13,648) |
| nginx + php-fpm (cold, unix) | off | 799 (792–809) | 810 (801–812) | 801 (801–810) | 806 (801–807) |
| nginx + php-fpm (cold, unix) | on | 7,698 (7,639–7,719) | 8,376 (8,221–8,387) | 8,933 (8,890–9,000) | 9,046 (8,954–9,065) |

## Headline readings

### Best configuration per arm

| arm | rps | workers | opcache | concurrency |
|---|---|---|---|---|
| volucer worker (warm, pipe) | 23,508 | 16 | on | 64 |
| volucer spawn_cgi (cold, unix) | 7,648 | 20 | on | 64 |
| RoadRunner worker (warm, pipe) | 19,897 | 20 | on | 48 |
| FrankenPHP worker (warm, embedded) | 16,257 | 12 | on | 48 |
| nginx + php-fpm (cold, unix) | 9,046 | 24 | on | 64 |

### Does another worker help? (concurrency 64, opcache on)

| arm | w=12 | w=16 | w=20 | w=24 | peak | change from w=12 |
|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | 23,118 | 23,508 | 23,449 | 22,938 | w=16 | +1.7% |
| volucer spawn_cgi (cold, unix) | 7,574 | 6,764 | 7,648 | 7,253 | w=20 | +1.0% |
| RoadRunner worker (warm, pipe) | 18,190 | 19,437 | 19,750 | 19,864 | w=24 | +9.2% |
| FrankenPHP worker (warm, embedded) | 16,252 | 14,542 | 13,844 | 13,535 | w=12 | +0.0% |
| nginx + php-fpm (cold, unix) | 7,698 | 8,376 | 8,933 | 9,046 | w=24 | +17.5% |

## Latency, p50 (ms)

### p50 at concurrency 16

| arm | opcache | w=12 | w=16 | w=20 | w=24 |
|---|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 0.713 (0.704–0.725) | 0.732 (0.731–0.743) | 0.733 (0.721–0.734) | 0.744 (0.729–0.749) |
| volucer worker (warm, pipe) | on | 0.703 (0.703–0.719) | 0.708 (0.702–0.711) | 0.719 (0.701–0.724) | 0.728 (0.700–0.736) |
| volucer spawn_cgi (cold, unix) | off | 16.410 (16.090–16.540) | 20.060 (19.970–20.820) | 18.930 (18.650–18.990) | 18.920 (18.480–19.800) |
| volucer spawn_cgi (cold, unix) | on | 2.000 (1.990–2.030) | 2.190 (2.130–2.190) | 2.180 (2.130–2.180) | 2.280 (2.280–2.310) |
| RoadRunner worker (warm, pipe) | off | 0.720 (0.704–0.727) | 0.781 (0.777–0.796) | 0.809 (0.807–0.810) | 0.838 (0.837–0.839) |
| RoadRunner worker (warm, pipe) | on | 0.701 (0.697–0.709) | 0.767 (0.756–0.774) | 0.792 (0.792–0.798) | 0.819 (0.807–0.820) |
| FrankenPHP worker (warm, embedded) | off | 0.699 (0.696–0.701) | 0.692 (0.686–0.698) | 0.696 (0.690–0.697) | 0.694 (0.693–0.702) |
| FrankenPHP worker (warm, embedded) | on | 0.673 (0.672–0.678) | 0.672 (0.664–0.677) | 0.675 (0.675–0.676) | 0.682 (0.668–0.685) |
| nginx + php-fpm (cold, unix) | off | 14.530 (14.480–14.690) | 16.840 (16.710–16.930) | 17.840 (17.800–17.970) | 18.610 (18.360–18.800) |
| nginx + php-fpm (cold, unix) | on | 1.680 (1.660–1.690) | 1.700 (1.690–1.700) | 1.750 (1.710–1.750) | 1.790 (1.790–1.810) |

### p50 at concurrency 32

| arm | opcache | w=12 | w=16 | w=20 | w=24 |
|---|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 1.020 (1.010–1.020) | 1.070 (1.060–1.070) | 1.130 (1.120–1.140) | 1.170 (1.160–1.180) |
| volucer worker (warm, pipe) | on | 1.000 (1.000–1.020) | 1.030 (1.020–1.050) | 1.100 (1.090–1.110) | 1.170 (1.130–1.170) |
| volucer spawn_cgi (cold, unix) | off | 22.260 (21.910–25.930) | 28.020 (27.110–28.770) | 32.140 (32.010–32.330) | 29.470 (29.360–30.090) |
| volucer spawn_cgi (cold, unix) | on | 2.750 (2.740–2.820) | 2.970 (2.950–2.980) | 2.810 (2.790–2.850) | 3.200 (3.180–3.200) |
| RoadRunner worker (warm, pipe) | off | 1.250 (1.250–1.260) | 1.140 (1.130–1.160) | 1.140 (1.140–1.140) | 1.190 (1.180–1.200) |
| RoadRunner worker (warm, pipe) | on | 1.220 (1.210–1.220) | 1.100 (1.100–1.100) | 1.120 (1.100–1.120) | 1.160 (1.140–1.170) |
| FrankenPHP worker (warm, embedded) | off | 1.410 (1.400–1.420) | 1.520 (1.510–1.540) | 1.660 (1.640–1.670) | 1.770 (1.770–1.790) |
| FrankenPHP worker (warm, embedded) | on | 1.380 (1.360–1.390) | 1.490 (1.460–1.500) | 1.600 (1.600–1.640) | 1.730 (1.710–1.740) |
| nginx + php-fpm (cold, unix) | off | 29.140 (29.110–29.150) | 26.950 (26.940–27.400) | 30.650 (30.630–30.950) | 29.240 (29.020–29.350) |
| nginx + php-fpm (cold, unix) | on | 3.020 (2.960–3.080) | 2.770 (2.760–2.790) | 2.600 (2.530–2.620) | 2.550 (2.480–2.570) |

### p50 at concurrency 48

| arm | opcache | w=12 | w=16 | w=20 | w=24 |
|---|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 2.030 (1.990–2.080) | 1.970 (1.950–1.990) | 1.970 (1.950–1.970) | 2.050 (2.040–2.080) |
| volucer worker (warm, pipe) | on | 2.020 (1.990–2.030) | 1.940 (1.900–1.950) | 1.920 (1.900–1.950) | 2.030 (2.010–2.030) |
| volucer spawn_cgi (cold, unix) | off | 50.030 (48.930–51.150) | 51.240 (48.610–52.400) | 59.600 (58.850–61.190) | 53.330 (51.760–60.380) |
| volucer spawn_cgi (cold, unix) | on | 5.030 (4.930–5.140) | 5.550 (5.410–5.610) | 4.620 (4.450–4.770) | 5.250 (5.140–5.260) |
| RoadRunner worker (warm, pipe) | off | 2.570 (2.550–2.590) | 2.380 (2.360–2.460) | 2.300 (2.280–2.300) | 2.270 (2.250–2.290) |
| RoadRunner worker (warm, pipe) | on | 2.500 (2.490–2.520) | 2.320 (2.300–2.330) | 2.220 (2.220–2.260) | 2.240 (2.240–2.240) |
| FrankenPHP worker (warm, embedded) | off | 2.850 (2.830–2.860) | 3.160 (3.120–3.180) | 3.210 (3.190–3.230) | 3.300 (3.250–3.310) |
| FrankenPHP worker (warm, embedded) | on | 2.800 (2.760–2.810) | 3.040 (3.020–3.050) | 3.140 (3.110–3.150) | 3.200 (3.190–3.230) |
| nginx + php-fpm (cold, unix) | off | 59.770 (59.170–60.320) | 56.090 (55.800–57.860) | 60.310 (60.030–60.640) | 58.400 (57.980–58.910) |
| nginx + php-fpm (cold, unix) | on | 6.100 (6.090–6.270) | 5.650 (5.600–5.700) | 5.210 (5.200–5.280) | 5.170 (5.110–5.260) |

### p50 at concurrency 64

| arm | opcache | w=12 | w=16 | w=20 | w=24 |
|---|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 2.560 (2.540–2.650) | 2.470 (2.470–2.520) | 2.420 (2.420–2.510) | 2.490 (2.480–2.510) |
| volucer worker (warm, pipe) | on | 2.510 (2.510–2.520) | 2.420 (2.400–2.450) | 2.380 (2.370–2.420) | 2.440 (2.430–2.480) |
| volucer spawn_cgi (cold, unix) | off | 65.430 (64.010–65.470) | 60.870 (58.810–65.860) | 70.820 (68.180–72.760) | 67.430 (64.710–70.790) |
| volucer spawn_cgi (cold, unix) | on | 5.890 (5.840–5.890) | 6.370 (6.230–6.400) | 5.580 (5.360–5.640) | 5.900 (5.810–5.950) |
| RoadRunner worker (warm, pipe) | off | 3.210 (3.210–3.230) | 2.970 (2.970–3.020) | 2.890 (2.870–2.900) | 2.900 (2.890–2.960) |
| RoadRunner worker (warm, pipe) | on | 3.140 (3.110–3.150) | 2.890 (2.870–2.900) | 2.830 (2.830–2.850) | 2.780 (2.780–2.850) |
| FrankenPHP worker (warm, embedded) | off | 3.570 (3.560–3.600) | 3.960 (3.910–4.000) | 4.060 (4.060–4.070) | 4.150 (4.140–4.150) |
| FrankenPHP worker (warm, embedded) | on | 3.510 (3.470–3.530) | 3.840 (3.840–3.870) | 3.950 (3.940–3.990) | 4.020 (3.970–4.040) |
| nginx + php-fpm (cold, unix) | off | 73.620 (72.660–73.840) | 71.080 (70.900–71.090) | 74.920 (74.300–75.010) | 73.780 (73.590–73.860) |
| nginx + php-fpm (cold, unix) | on | 7.680 (7.620–7.770) | 7.050 (7.030–7.110) | 6.530 (6.480–6.540) | 6.460 (6.390–6.490) |

## Latency, p99 (ms)

### p99 at concurrency 16

| arm | opcache | w=12 | w=16 | w=20 | w=24 |
|---|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 1.460 (1.440–1.480) | 1.490 (1.490–1.500) | 1.480 (1.460–1.490) | 1.510 (1.480–1.520) |
| volucer worker (warm, pipe) | on | 1.440 (1.410–1.460) | 1.430 (1.430–1.460) | 1.460 (1.430–1.470) | 1.470 (1.400–1.500) |
| volucer spawn_cgi (cold, unix) | off | 51.450 (46.810–54.050) | 37.790 (37.020–41.310) | 34.920 (34.200–35.880) | 36.080 (34.960–37.050) |
| volucer spawn_cgi (cold, unix) | on | 4.800 (4.230–4.840) | 4.940 (4.840–4.990) | 4.940 (4.610–5.110) | 5.020 (5.010–5.450) |
| RoadRunner worker (warm, pipe) | off | 1.800 (1.770–1.810) | 1.930 (1.920–1.960) | 1.990 (1.980–2.000) | 2.050 (2.030–2.060) |
| RoadRunner worker (warm, pipe) | on | 1.760 (1.760–1.810) | 1.870 (1.870–1.910) | 1.960 (1.960–1.990) | 2.020 (1.980–2.050) |
| FrankenPHP worker (warm, embedded) | off | 1.990 (1.970–2.030) | 1.970 (1.920–2.010) | 2.000 (2.000–2.020) | 1.970 (1.960–2.010) |
| FrankenPHP worker (warm, embedded) | on | 1.960 (1.950–1.980) | 1.940 (1.930–1.960) | 1.970 (1.920–1.990) | 1.950 (1.940–1.970) |
| nginx + php-fpm (cold, unix) | off | 22.030 (21.520–22.110) | 31.330 (31.000–32.320) | 34.310 (33.900–34.330) | 35.420 (34.820–35.990) |
| nginx + php-fpm (cold, unix) | on | 3.570 (3.570–3.630) | 3.820 (3.810–4.510) | 4.010 (4.010–4.060) | 4.250 (4.230–4.310) |

### p99 at concurrency 32

| arm | opcache | w=12 | w=16 | w=20 | w=24 |
|---|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 2.310 (2.250–2.340) | 2.260 (2.250–2.270) | 2.420 (2.410–2.470) | 2.530 (2.510–2.620) |
| volucer worker (warm, pipe) | on | 2.270 (2.230–2.270) | 2.200 (2.190–2.310) | 2.400 (2.360–2.450) | 2.510 (2.510–2.690) |
| volucer spawn_cgi (cold, unix) | off | 290.170 (253.010–318.360) | 230.940 (204.640–242.720) | 89.340 (86.180–122.080) | 92.300 (84.190–96.010) |
| volucer spawn_cgi (cold, unix) | on | 18.840 (18.300–19.160) | 19.500 (18.520–21.310) | 16.220 (15.300–17.400) | 9.770 (9.470–10.270) |
| RoadRunner worker (warm, pipe) | off | 2.740 (2.700–2.750) | 3.190 (3.150–3.230) | 3.510 (3.490–3.580) | 3.500 (3.400–3.510) |
| RoadRunner worker (warm, pipe) | on | 2.680 (2.640–2.700) | 3.150 (3.120–3.160) | 3.470 (3.340–3.470) | 3.470 (3.410–3.490) |
| FrankenPHP worker (warm, embedded) | off | 3.630 (3.630–3.690) | 5.750 (5.670–5.900) | 6.620 (6.610–6.670) | 6.640 (6.560–6.900) |
| FrankenPHP worker (warm, embedded) | on | 3.630 (3.620–3.650) | 5.560 (5.560–5.580) | 6.490 (6.430–6.570) | 6.410 (6.400–6.530) |
| nginx + php-fpm (cold, unix) | off | 38.460 (37.250–38.610) | 46.830 (46.170–47.520) | 45.550 (45.540–47.460) | 47.760 (46.690–48.030) |
| nginx + php-fpm (cold, unix) | on | 5.070 (5.000–5.080) | 4.950 (4.890–5.180) | 5.010 (4.810–5.030) | 5.570 (5.360–5.590) |

### p99 at concurrency 48

| arm | opcache | w=12 | w=16 | w=20 | w=24 |
|---|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 6.640 (6.330–6.760) | 5.550 (5.550–5.600) | 4.890 (4.800–4.970) | 4.600 (4.600–4.670) |
| volucer worker (warm, pipe) | on | 6.510 (6.390–6.530) | 5.440 (5.380–5.530) | 4.730 (4.680–4.770) | 4.540 (4.520–4.620) |
| volucer spawn_cgi (cold, unix) | off | 463.720 (462.530–485.110) | 562.810 (531.150–585.040) | 499.500 (482.350–597.420) | 720.990 (359.900–991.500) |
| volucer spawn_cgi (cold, unix) | on | 50.710 (44.170–53.780) | 75.160 (61.050–81.280) | 61.740 (57.430–67.180) | 52.760 (51.420–53.900) |
| RoadRunner worker (warm, pipe) | off | 4.490 (4.490–4.600) | 4.840 (4.800–5.000) | 5.430 (5.280–5.490) | 5.740 (5.680–5.930) |
| RoadRunner worker (warm, pipe) | on | 4.400 (4.380–4.520) | 4.740 (4.740–4.800) | 5.290 (5.150–5.290) | 5.810 (5.710–5.870) |
| FrankenPHP worker (warm, embedded) | off | 5.570 (5.500–5.600) | 7.840 (7.750–7.850) | 9.550 (9.510–9.670) | 11.320 (10.900–11.500) |
| FrankenPHP worker (warm, embedded) | on | 5.440 (5.430–5.540) | 7.600 (7.470–7.700) | 9.240 (9.170–9.350) | 10.940 (10.780–10.940) |
| nginx + php-fpm (cold, unix) | off | 70.810 (70.630–71.090) | 80.890 (76.660–81.290) | 79.690 (79.310–79.850) | 76.650 (74.830–78.470) |
| nginx + php-fpm (cold, unix) | on | 8.280 (8.220–8.460) | 7.940 (7.840–8.050) | 7.620 (7.600–7.800) | 8.270 (8.160–9.070) |

### p99 at concurrency 64

| arm | opcache | w=12 | w=16 | w=20 | w=24 |
|---|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 8.940 (8.830–9.190) | 7.830 (7.760–7.990) | 6.810 (6.770–6.910) | 6.240 (6.110–6.280) |
| volucer worker (warm, pipe) | on | 8.630 (8.530–8.720) | 7.560 (7.540–7.570) | 6.650 (6.630–6.670) | 6.060 (6.000–6.160) |
| volucer spawn_cgi (cold, unix) | off | 471.030 (445.540–684.640) | 728.350 (575.340–793.030) | 530.530 (520.640–677.530) | 782.130 (749.610–882.040) |
| volucer spawn_cgi (cold, unix) | on | 66.170 (66.140–69.160) | 98.360 (86.670–107.460) | 83.700 (74.580–84.950) | 76.660 (67.540–91.320) |
| RoadRunner worker (warm, pipe) | off | 5.390 (5.350–5.550) | 5.600 (5.530–5.750) | 6.100 (5.930–6.120) | 6.630 (6.560–6.880) |
| RoadRunner worker (warm, pipe) | on | 5.320 (5.290–5.340) | 5.480 (5.420–5.510) | 5.960 (5.950–6.020) | 6.530 (6.290–6.550) |
| FrankenPHP worker (warm, embedded) | off | 6.450 (6.360–6.450) | 8.710 (8.510–8.720) | 10.460 (10.290–10.470) | 12.030 (12.010–12.290) |
| FrankenPHP worker (warm, embedded) | on | 6.300 (6.280–6.320) | 8.360 (8.350–8.430) | 10.190 (10.080–10.250) | 11.660 (11.640–11.720) |
| nginx + php-fpm (cold, unix) | off | 83.170 (81.740–86.920) | 94.660 (89.650–94.890) | 91.060 (90.500–92.360) | 91.730 (91.100–92.220) |
| nginx + php-fpm (cold, unix) | on | 9.910 (9.800–10.030) | 9.430 (9.430–9.450) | 9.010 (8.990–9.020) | 9.600 (9.450–10.560) |

## opcache

### opcache effect at concurrency 16 (rps on / rps off)

| arm | w=12 | w=16 | w=20 | w=24 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | 1.01× | 1.03× | 1.02× | 1.02× |
| volucer spawn_cgi (cold, unix) | 8.91× | 9.11× | 8.43× | 8.29× |
| RoadRunner worker (warm, pipe) | 1.02× | 1.02× | 1.03× | 1.03× |
| FrankenPHP worker (warm, embedded) | 1.04× | 1.03× | 1.03× | 1.01× |
| nginx + php-fpm (cold, unix) | 8.41× | 9.71× | 10.00× | 10.02× |

### opcache effect at concurrency 32 (rps on / rps off)

| arm | w=12 | w=16 | w=20 | w=24 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | 1.02× | 1.03× | 1.03× | 1.01× |
| volucer spawn_cgi (cold, unix) | 9.97× | 10.24× | 10.49× | 9.23× |
| RoadRunner worker (warm, pipe) | 1.03× | 1.03× | 1.02× | 1.02× |
| FrankenPHP worker (warm, embedded) | 1.03× | 1.03× | 1.03× | 1.04× |
| nginx + php-fpm (cold, unix) | 9.52× | 10.28× | 10.82× | 10.95× |

### opcache effect at concurrency 48 (rps on / rps off)

| arm | w=12 | w=16 | w=20 | w=24 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | 1.00× | 1.02× | 1.02× | 1.01× |
| volucer spawn_cgi (cold, unix) | 10.13× | 9.95× | 10.87× | 9.50× |
| RoadRunner worker (warm, pipe) | 1.03× | 1.03× | 1.02× | 1.01× |
| FrankenPHP worker (warm, embedded) | 1.01× | 1.04× | 1.03× | 1.04× |
| nginx + php-fpm (cold, unix) | 9.93× | 10.29× | 11.07× | 10.97× |

### opcache effect at concurrency 64 (rps on / rps off)

| arm | w=12 | w=16 | w=20 | w=24 |
|---|---|---|---|---|
| volucer worker (warm, pipe) | 1.02× | 1.02× | 1.02× | 1.02× |
| volucer spawn_cgi (cold, unix) | 10.19× | 10.15× | 11.06× | 9.58× |
| RoadRunner worker (warm, pipe) | 1.01× | 1.03× | 1.01× | 1.04× |
| FrankenPHP worker (warm, embedded) | 1.02× | 1.03× | 1.03× | 1.04× |
| nginx + php-fpm (cold, unix) | 9.64× | 10.34× | 11.15× | 11.23× |

## Memory

### Memory, boot (before any request)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 12 | 13 | 151.8 | 501.2 | 11.7 |
| volucer worker (warm, pipe) | off | 16 | 17 | 192.3 | 664.5 | 11.3 |
| volucer worker (warm, pipe) | off | 20 | 21 | 232.0 | 826.9 | 11.0 |
| volucer worker (warm, pipe) | off | 24 | 25 | 271.9 | 989.9 | 10.9 |
| volucer worker (warm, pipe) | on | 12 | 13 | 187.6 | 538.9 | 14.4 |
| volucer worker (warm, pipe) | on | 16 | 17 | 239.9 | 714.5 | 14.1 |
| volucer worker (warm, pipe) | on | 20 | 21 | 291.6 | 890.1 | 13.9 |
| volucer worker (warm, pipe) | on | 24 | 25 | 343.3 | 1,066.1 | 13.7 |
| volucer spawn_cgi (cold, unix) | off | 12 | 13 | 141.1 | 484.7 | 10.9 |
| volucer spawn_cgi (cold, unix) | off | 16 | 17 | 177.6 | 641.1 | 10.4 |
| volucer spawn_cgi (cold, unix) | off | 20 | 21 | 213.5 | 797.9 | 10.2 |
| volucer spawn_cgi (cold, unix) | off | 24 | 25 | 249.4 | 953.5 | 10.0 |
| volucer spawn_cgi (cold, unix) | on | 12 | 13 | 177.2 | 522.0 | 13.6 |
| volucer spawn_cgi (cold, unix) | on | 16 | 17 | 224.3 | 688.8 | 13.2 |
| volucer spawn_cgi (cold, unix) | on | 20 | 21 | 270.9 | 854.9 | 12.9 |
| volucer spawn_cgi (cold, unix) | on | 24 | 25 | 317.6 | 1,023.9 | 12.7 |
| RoadRunner worker (warm, pipe) | off | 12 | 13 | 189.4 | 535.7 | 14.6 |
| RoadRunner worker (warm, pipe) | off | 16 | 17 | 230.8 | 700.1 | 13.6 |
| RoadRunner worker (warm, pipe) | off | 20 | 21 | 269.5 | 862.3 | 12.8 |
| RoadRunner worker (warm, pipe) | off | 24 | 25 | 309.6 | 1,024.9 | 12.4 |
| RoadRunner worker (warm, pipe) | on | 12 | 13 | 226.0 | 574.3 | 17.4 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 278.7 | 750.3 | 16.4 |
| RoadRunner worker (warm, pipe) | on | 20 | 21 | 331.5 | 927.6 | 15.8 |
| RoadRunner worker (warm, pipe) | on | 24 | 25 | 382.7 | 1,102.3 | 15.3 |
| FrankenPHP worker (warm, embedded) | off | 12 | 1 | 116.5 | 116.6 | 116.5 |
| FrankenPHP worker (warm, embedded) | off | 16 | 1 | 121.8 | 121.8 | 121.8 |
| FrankenPHP worker (warm, embedded) | off | 20 | 1 | 128.8 | 128.8 | 128.8 |
| FrankenPHP worker (warm, embedded) | off | 24 | 1 | 135.8 | 135.8 | 135.8 |
| FrankenPHP worker (warm, embedded) | on | 12 | 1 | 117.5 | 117.5 | 117.5 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 123.0 | 123.1 | 123.0 |
| FrankenPHP worker (warm, embedded) | on | 20 | 1 | 127.6 | 127.7 | 127.6 |
| FrankenPHP worker (warm, embedded) | on | 24 | 1 | 131.2 | 131.2 | 131.2 |
| nginx + php-fpm (cold, unix) | off | 12 | 18 | 38.5 | 224.1 | 2.1 |
| nginx + php-fpm (cold, unix) | off | 16 | 22 | 39.3 | 269.2 | 1.8 |
| nginx + php-fpm (cold, unix) | off | 20 | 26 | 40.0 | 315.3 | 1.5 |
| nginx + php-fpm (cold, unix) | off | 24 | 30 | 40.6 | 360.4 | 1.4 |
| nginx + php-fpm (cold, unix) | on | 12 | 18 | 41.8 | 237.2 | 2.3 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 42.5 | 282.6 | 1.9 |
| nginx + php-fpm (cold, unix) | on | 20 | 26 | 43.2 | 328.0 | 1.7 |
| nginx + php-fpm (cold, unix) | on | 24 | 30 | 43.8 | 374.9 | 1.5 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 12: 151.8 | 24: 271.9 | 120.1 | 12 | 10.0 |
| volucer worker (warm, pipe) | on | 12: 187.6 | 24: 343.3 | 155.7 | 12 | 13.0 |
| volucer spawn_cgi (cold, unix) | off | 12: 141.1 | 24: 249.4 | 108.3 | 12 | 9.0 |
| volucer spawn_cgi (cold, unix) | on | 12: 177.2 | 24: 317.6 | 140.4 | 12 | 11.7 |
| RoadRunner worker (warm, pipe) | off | 12: 189.4 | 24: 309.6 | 120.2 | 12 | 10.0 |
| RoadRunner worker (warm, pipe) | on | 12: 226.0 | 24: 382.7 | 156.7 | 12 | 13.1 |
| FrankenPHP worker (warm, embedded) | off | 12: 116.5 | 24: 135.8 | 19.3 | 12 | 1.6 |
| FrankenPHP worker (warm, embedded) | on | 12: 117.5 | 24: 131.2 | 13.7 | 12 | 1.1 |
| nginx + php-fpm (cold, unix) | off | 12: 38.5 | 24: 40.6 | 2.1 | 12 | 0.2 |
| nginx + php-fpm (cold, unix) | on | 12: 41.8 | 24: 43.8 | 2.0 | 12 | 0.2 |

### Memory, after load (peak concurrency)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 12 | 13 | 190.5 | 553.7 | 14.7 |
| volucer worker (warm, pipe) | off | 16 | 17 | 240.8 | 732.4 | 14.2 |
| volucer worker (warm, pipe) | off | 20 | 21 | 290.9 | 910.1 | 13.9 |
| volucer worker (warm, pipe) | off | 24 | 25 | 341.1 | 1,088.9 | 13.6 |
| volucer worker (warm, pipe) | on | 12 | 13 | 227.5 | 592.8 | 17.5 |
| volucer worker (warm, pipe) | on | 16 | 17 | 291.5 | 784.9 | 17.1 |
| volucer worker (warm, pipe) | on | 20 | 21 | 352.0 | 974.5 | 16.8 |
| volucer worker (warm, pipe) | on | 24 | 25 | 418.5 | 1,170.6 | 16.7 |
| volucer spawn_cgi (cold, unix) | off | 12 | 13 | 186.3 | 548.9 | 14.3 |
| volucer spawn_cgi (cold, unix) | off | 16 | 17 | 235.9 | 725.6 | 13.9 |
| volucer spawn_cgi (cold, unix) | off | 20 | 21 | 285.3 | 903.5 | 13.6 |
| volucer spawn_cgi (cold, unix) | off | 24 | 25 | 334.2 | 1,079.4 | 13.4 |
| volucer spawn_cgi (cold, unix) | on | 12 | 13 | 226.8 | 591.4 | 17.4 |
| volucer spawn_cgi (cold, unix) | on | 16 | 17 | 289.4 | 781.7 | 17.0 |
| volucer spawn_cgi (cold, unix) | on | 20 | 21 | 350.7 | 970.9 | 16.7 |
| volucer spawn_cgi (cold, unix) | on | 24 | 25 | 412.8 | 1,162.7 | 16.5 |
| RoadRunner worker (warm, pipe) | off | 12 | 13 | 248.7 | 608.7 | 19.1 |
| RoadRunner worker (warm, pipe) | off | 16 | 17 | 301.8 | 790.0 | 17.8 |
| RoadRunner worker (warm, pipe) | off | 20 | 21 | 349.6 | 966.5 | 16.6 |
| RoadRunner worker (warm, pipe) | off | 24 | 25 | 401.6 | 1,146.7 | 16.1 |
| RoadRunner worker (warm, pipe) | on | 12 | 13 | 287.7 | 649.3 | 22.1 |
| RoadRunner worker (warm, pipe) | on | 16 | 17 | 349.3 | 839.9 | 20.5 |
| RoadRunner worker (warm, pipe) | on | 20 | 21 | 415.4 | 1,035.6 | 19.8 |
| RoadRunner worker (warm, pipe) | on | 24 | 25 | 476.1 | 1,224.8 | 19.0 |
| FrankenPHP worker (warm, embedded) | off | 12 | 1 | 155.3 | 155.3 | 155.3 |
| FrankenPHP worker (warm, embedded) | off | 16 | 1 | 170.5 | 170.5 | 170.5 |
| FrankenPHP worker (warm, embedded) | off | 20 | 1 | 187.5 | 187.5 | 187.5 |
| FrankenPHP worker (warm, embedded) | off | 24 | 1 | 205.0 | 205.0 | 205.0 |
| FrankenPHP worker (warm, embedded) | on | 12 | 1 | 132.6 | 132.6 | 132.6 |
| FrankenPHP worker (warm, embedded) | on | 16 | 1 | 140.3 | 140.3 | 140.3 |
| FrankenPHP worker (warm, embedded) | on | 20 | 1 | 146.2 | 146.2 | 146.2 |
| FrankenPHP worker (warm, embedded) | on | 24 | 1 | 151.7 | 151.7 | 151.7 |
| nginx + php-fpm (cold, unix) | off | 12 | 18 | 80.5 | 331.4 | 4.5 |
| nginx + php-fpm (cold, unix) | off | 16 | 22 | 96.4 | 417.7 | 4.4 |
| nginx + php-fpm (cold, unix) | off | 20 | 26 | 112.1 | 510.2 | 4.3 |
| nginx + php-fpm (cold, unix) | off | 24 | 30 | 128.1 | 596.1 | 4.3 |
| nginx + php-fpm (cold, unix) | on | 12 | 18 | 53.7 | 351.6 | 3.0 |
| nginx + php-fpm (cold, unix) | on | 16 | 22 | 58.9 | 448.3 | 2.7 |
| nginx + php-fpm (cold, unix) | on | 20 | 26 | 63.7 | 539.9 | 2.5 |
| nginx + php-fpm (cold, unix) | on | 24 | 30 | 68.6 | 631.9 | 2.3 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | off | 12: 190.5 | 24: 341.1 | 150.6 | 12 | 12.6 |
| volucer worker (warm, pipe) | on | 12: 227.5 | 24: 418.5 | 191.0 | 12 | 15.9 |
| volucer spawn_cgi (cold, unix) | off | 12: 186.3 | 24: 334.2 | 147.9 | 12 | 12.3 |
| volucer spawn_cgi (cold, unix) | on | 12: 226.8 | 24: 412.8 | 186.0 | 12 | 15.5 |
| RoadRunner worker (warm, pipe) | off | 12: 248.7 | 24: 401.6 | 152.9 | 12 | 12.7 |
| RoadRunner worker (warm, pipe) | on | 12: 287.7 | 24: 476.1 | 188.4 | 12 | 15.7 |
| FrankenPHP worker (warm, embedded) | off | 12: 155.3 | 24: 205.0 | 49.7 | 12 | 4.1 |
| FrankenPHP worker (warm, embedded) | on | 12: 132.6 | 24: 151.7 | 19.1 | 12 | 1.6 |
| nginx + php-fpm (cold, unix) | off | 12: 80.5 | 24: 128.1 | 47.6 | 12 | 4.0 |
| nginx + php-fpm (cold, unix) | on | 12: 53.7 | 24: 68.6 | 14.9 | 12 | 1.2 |

## Integrity checks

**2 cell(s) reported failures or dropped responses.** A cell with `Non-2xx` responses is a pool shedding load, which is a
throughput number that looks like the fix working; it is listed here rather
than silently averaged in.

| arm | workers | opcache | conc | round | rps | errors |
|---|---|---|---|---|---|---|
| volucer-fastcgi | 16 | off | 64 | 1 | 657.01 | 1 |
| volucer-fastcgi | 24 | off | 48 | 1 | 762.13 | 1 |

