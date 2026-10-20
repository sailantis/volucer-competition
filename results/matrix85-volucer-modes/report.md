# Worker x children x concurrency matrix, PHP 8.5

Five volucer shapes, one server, one page, one host. The point of the run is
that every row is the *same* server with one thing changed, so a difference
between two rows is that thing:

| arm | transport | process model | what it isolates |
|---|---|---|---|
| `volucer-worker` | pipe | one `exec` per worker | the baseline |
| `volucer-unix` | unix socket | one `exec` per worker | the transport |
| `volucer-attach` | unix relay | one boot, `fork()` per connection | the memory model |
| `volucer-fastcgi` | unix socket | one `php-cgi` per slot | the SAPI reset per request |
| `volucer-prefork` | unix socket | `php-cgi` + `children` per slot | fork inside a cold slot |

Rows: `/home/competition/matrix85-volucer-modes/matrix.tsv`. Memory: `/home/competition/matrix85-volucer-modes/memory.tsv`.

Every cell is the **median over the rounds**, with the min–max spread across
rounds in parentheses where there was more than one round. `p50` and `p99` are
each their own median across the rounds of that cell — not the percentile of
whichever round happened to have the median throughput.

`ch=N` marks the `children` axis, which only `volucer-prefork` has: there
`workers` counts listening sockets and `children` counts `php-cgi` processes
behind each, so `w=16 ch=4` is one master, four children, per socket. Every
other arm leaves it empty because it has no such setting.

## Throughput (requests/sec)

### rps at concurrency 8

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 3,360 (3,338–3,373) | 12,941 (12,371–13,060) | 14,449 (14,157–14,813) | 14,102 (13,955–14,199) | 13,979 (13,876–14,398) | 14,438 (14,231–14,510) |
| volucer worker (warm, unix socket) | on | 3,297 (3,205–3,343) | 12,170 (11,972–12,508) | 14,187 (13,800–14,284) | 14,006 (13,922–14,353) | 14,033 (13,874–14,175) | 14,066 (13,721–14,676) |
| volucer attach (warm, unix relay) | on | 3,228 (3,211–3,247) | 12,531 (12,322–12,669) | 14,442 (13,860–14,623) | 14,330 (14,171–14,344) | 14,194 (13,726–14,391) | 13,944 (13,905–14,166) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 799 (792–803) | 3,090 (3,014–3,110) | 5,052 (4,966–5,128) | 4,137 (4,099–4,165) | 3,943 (3,926–3,953) | 3,879 (3,715–3,886) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 802 (794–804) | 3,050 (3,008–3,076) | 5,076 (5,061–5,132) | 4,050 (4,034–4,077) | 3,869 (3,866–3,916) | 3,765 (3,757–3,784) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 3,187 (3,114–3,211) | 4,835 (4,826–4,963) | 4,577 (4,566–4,591) | 4,089 (4,065–4,096) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 5,641 (5,603–5,738) | 4,886 (4,827–4,967) | 4,639 (4,618–4,646) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 5,676 (5,565–5,794) | 4,862 (4,819–4,912) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 5,601 (5,546–5,663) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 5,657 (5,602–5,792) | — | — | — | — | — |

### rps at concurrency 16

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 3,294 (3,240–3,364) | 12,866 (12,710–13,057) | 19,428 (19,122–20,130) | 15,820 (15,682–15,948) | 15,708 (15,701–15,810) | 15,744 (15,583–15,768) |
| volucer worker (warm, unix socket) | on | 3,269 (3,267–3,314) | 12,019 (12,019–12,594) | 18,678 (18,565–18,898) | 15,542 (15,217–15,919) | 15,486 (15,372–15,580) | 15,605 (15,456–15,928) |
| volucer attach (warm, unix relay) | on | 3,244 (3,202–3,300) | 12,428 (12,242–12,621) | 19,009 (18,581–19,394) | 16,216 (16,124–16,294) | 15,903 (15,863–16,244) | 15,737 (15,704–16,109) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 796 (795–806) | 3,100 (3,072–3,122) | 5,721 (5,572–5,787) | 5,313 (5,307–5,333) | 4,921 (4,910–4,977) | 4,729 (4,673–4,777) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 798 (797–807) | 3,111 (3,063–3,166) | 5,612 (5,545–5,729) | 5,232 (5,181–5,248) | 4,834 (4,831–4,911) | 4,605 (4,590–4,636) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 3,222 (3,183–3,236) | 5,671 (5,598–5,736) | 5,394 (5,367–5,424) | 5,100 (5,046–5,169) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 6,307 (6,176–6,425) | 5,709 (5,494–5,753) | 5,378 (5,355–5,473) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 6,070 (6,058–6,117) | 5,634 (5,606–5,708) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 6,103 (6,029–6,110) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 5,996 (5,964–6,222) | — | — | — | — | — |

### rps at concurrency 24

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 3,333 (3,331–3,355) | 12,939 (12,640–12,995) | 20,462 (20,364–20,984) | 22,091 (21,925–22,092) | 20,272 (20,178–20,335) | 20,196 (19,649–20,499) |
| volucer worker (warm, unix socket) | on | 3,259 (3,188–3,273) | 12,015 (11,869–12,258) | 19,670 (19,534–20,164) | 21,642 (21,393–21,892) | 19,984 (19,891–20,053) | 19,871 (19,685–20,195) |
| volucer attach (warm, unix relay) | on | 3,250 (3,201–3,327) | 12,377 (12,375–12,562) | 20,175 (20,163–20,395) | 23,075 (22,717–23,078) | 21,669 (21,610–22,016) | 21,527 (21,339–21,709) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 796 (793–802) | 3,159 (3,138–3,162) | 5,969 (5,856–6,031) | 6,729 (6,609–6,739) | 6,753 (6,739–6,902) | 6,584 (6,445–6,698) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 803 (792–803) | 3,203 (3,135–3,223) | 5,888 (5,840–6,082) | 6,607 (6,543–6,609) | 6,768 (6,709–6,787) | 6,405 (6,382–6,455) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 3,200 (3,188–3,211) | 7,927 (7,862–7,962) | 7,271 (7,245–7,340) | 6,779 (6,740–6,868) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 6,374 (6,258–6,417) | 7,506 (7,400–7,630) | 7,231 (7,195–7,250) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 8,390 (8,338–8,416) | 7,568 (7,523–7,580) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 8,018 (7,959–8,064) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 7,952 (7,938–8,002) | — | — | — | — | — |

### rps at concurrency 32

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 3,334 (3,321–3,345) | 12,883 (12,587–12,933) | 21,021 (20,370–21,262) | 22,002 (21,913–22,067) | 20,350 (19,979–20,421) | 20,316 (20,001–20,545) |
| volucer worker (warm, unix socket) | on | 3,285 (3,282–3,290) | 12,149 (11,949–12,282) | 19,747 (19,296–19,940) | 21,895 (21,657–21,969) | 20,055 (19,950–20,156) | 19,994 (19,826–20,148) |
| volucer attach (warm, unix relay) | on | 3,225 (3,193–3,263) | 12,355 (12,309–12,519) | 20,344 (19,925–20,451) | 23,002 (22,926–23,214) | 21,860 (21,717–21,890) | 21,515 (21,490–21,708) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 794 (794–801) | 3,170 (3,169–3,204) | 5,981 (5,824–6,052) | 6,661 (6,591–6,763) | 6,867 (6,831–6,914) | 6,603 (6,548–6,630) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 802 (802–804) | 3,152 (3,083–3,235) | 5,994 (5,884–6,042) | 6,596 (6,434–6,628) | 6,801 (6,778–6,884) | 6,337 (6,310–6,473) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 3,232 (3,216–3,252) | 7,931 (7,756–7,956) | 7,310 (7,304–7,351) | 6,888 (6,875–6,894) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 6,355 (6,343–6,361) | 7,556 (7,507–7,562) | 7,277 (7,231–7,306) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 8,437 (8,285–8,451) | 7,580 (7,573–7,760) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 8,047 (8,041–8,137) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 7,988 (7,879–8,005) | — | — | — | — | — |

### rps at concurrency 64

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 3,326 (3,264–3,366) | 12,810 (12,607–12,981) | 20,654 (20,089–21,264) | 23,851 (23,775–24,090) | 24,091 (23,729–24,216) | 23,957 (23,631–24,043) |
| volucer worker (warm, unix socket) | on | 3,232 (3,225–3,232) | 12,154 (12,081–12,208) | 19,271 (19,013–20,131) | 23,965 (23,660–24,113) | 23,567 (23,527–23,638) | 22,713 (22,696–22,758) |
| volucer attach (warm, unix relay) | on | 3,208 (3,194–3,244) | 12,400 (12,367–12,450) | 20,112 (19,840–20,220) | 26,054 (25,570–26,516) | 26,481 (26,380–26,646) | 25,977 (25,857–26,222) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 785 (783–792) | 3,153 (3,147–3,191) | 6,094 (6,079–6,107) | 6,988 (6,953–7,004) | 7,495 (7,320–7,525) | 7,493 (7,483–7,644) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 798 (795–800) | 3,176 (3,075–3,185) | 6,180 (6,150–6,271) | 6,912 (6,910–6,922) | 7,282 (7,193–7,303) | 7,223 (7,082–7,252) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 3,211 (3,112–3,219) | 7,982 (7,939–8,109) | 8,440 (8,352–8,487) | 7,873 (7,778–8,058) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 6,447 (6,408–6,448) | 8,762 (8,748–8,776) | 8,166 (8,056–8,229) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 8,564 (8,482–8,568) | 8,304 (8,297–8,389) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 9,025 (8,597–9,072) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 9,270 (9,057–9,286) | — | — | — | — | — |

## Headline readings

### Best configuration per arm

| arm | rps | workers | children | opcache | concurrency |
|---|---|---|---|---|---|
| volucer worker (warm, pipe) | 24,091 | 24 | — | on | 64 |
| volucer worker (warm, unix socket) | 23,965 | 16 | — | on | 64 |
| volucer attach (warm, unix relay) | 26,481 | 24 | — | on | 64 |
| volucer spawn_cgi (cold, unix, 1/slot) | 7,495 | 24 | — | on | 64 |
| volucer spawn_cgi children (cold, unix) | 7,282 | 24 | 1 | on | 64 |
| volucer spawn_cgi children (cold, unix) | 8,440 | 8 | 4 | on | 64 |
| volucer spawn_cgi children (cold, unix) | 8,762 | 4 | 8 | on | 64 |
| volucer spawn_cgi children (cold, unix) | 8,564 | 1 | 16 | on | 64 |
| volucer spawn_cgi children (cold, unix) | 9,025 | 1 | 24 | on | 64 |
| volucer spawn_cgi children (cold, unix) | 9,270 | 1 | 32 | on | 64 |

### Does another worker help? (concurrency 64, opcache on)

| arm | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 | peak | change from w=1 |
|---|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | 3,326 | 12,810 | 20,654 | 23,851 | 24,091 | 23,957 | w=24 | +624.3% |
| volucer worker (warm, unix socket) | 3,232 | 12,154 | 19,271 | 23,965 | 23,567 | 22,713 | w=16 | +641.6% |
| volucer attach (warm, unix relay) | 3,208 | 12,400 | 20,112 | 26,054 | 26,481 | 25,977 | w=24 | +725.4% |
| volucer spawn_cgi (cold, unix, 1/slot) | 785 | 3,153 | 6,094 | 6,988 | 7,495 | 7,493 | w=24 | +854.6% |
| volucer spawn_cgi children (cold, unix), ch=1 | 798 | 3,176 | 6,180 | 6,912 | 7,282 | 7,223 | w=24 | +812.0% |
| volucer spawn_cgi children (cold, unix), ch=4 | 3,211 | 7,982 | 8,440 | 7,873 | — | — | w=8 | +162.9% |
| volucer spawn_cgi children (cold, unix), ch=8 | 6,447 | 8,762 | 8,166 | — | — | — | w=4 | +35.9% |
| volucer spawn_cgi children (cold, unix), ch=16 | 8,564 | 8,304 | — | — | — | — | w=1 | +0.0% |

## Latency, p50 (ms)

### p50 at concurrency 8

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 2.310 (2.310–2.320) | 0.587 (0.583–0.613) | 0.520 (0.514–0.533) | 0.538 (0.534–0.542) | 0.543 (0.525–0.543) | 0.522 (0.521–0.530) |
| volucer worker (warm, unix socket) | on | 2.370 (2.360–2.420) | 0.625 (0.616–0.633) | 0.533 (0.530–0.547) | 0.538 (0.529–0.540) | 0.538 (0.533–0.542) | 0.537 (0.512–0.551) |
| volucer attach (warm, unix relay) | on | 2.410 (2.400–2.430) | 0.610 (0.603–0.618) | 0.526 (0.514–0.538) | 0.529 (0.526–0.534) | 0.536 (0.527–0.546) | 0.542 (0.531–0.544) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 9.850 (9.810–9.860) | 2.310 (2.300–2.310) | 1.380 (1.380–1.410) | 1.750 (1.740–1.750) | 1.840 (1.830–1.840) | 1.880 (1.850–1.970) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 9.830 (9.780–9.890) | 2.300 (2.280–2.320) | 1.390 (1.380–1.400) | 1.780 (1.780–1.800) | 1.880 (1.860–1.890) | 1.950 (1.930–1.960) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 2.400 (2.370–2.400) | 1.480 (1.440–1.480) | 1.540 (1.540–1.550) | 1.780 (1.760–1.790) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1.310 (1.300–1.320) | 1.460 (1.440–1.470) | 1.520 (1.500–1.530) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1.320 (1.300–1.320) | 1.480 (1.460–1.480) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 1.330 (1.300–1.340) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1.320 (1.300–1.330) | — | — | — | — | — |

### p50 at concurrency 16

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 3.520 (3.490–3.580) | 0.890 (0.880–0.900) | 0.581 (0.562–0.591) | 0.712 (0.709–0.720) | 0.717 (0.711–0.717) | 0.715 (0.712–0.719) |
| volucer worker (warm, unix socket) | on | 3.570 (3.540–3.600) | 0.960 (0.920–0.960) | 0.603 (0.595–0.604) | 0.722 (0.701–0.728) | 0.720 (0.715–0.723) | 0.715 (0.697–0.723) |
| volucer attach (warm, unix relay) | on | 3.600 (3.530–3.650) | 0.930 (0.920–0.940) | 0.592 (0.580–0.605) | 0.691 (0.683–0.692) | 0.702 (0.688–0.704) | 0.708 (0.692–0.709) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 14.820 (14.720–14.840) | 3.400 (3.160–3.510) | 1.510 (1.510–1.520) | 2.070 (2.070–2.100) | 2.240 (2.220–2.250) | 2.330 (2.330–2.370) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 14.780 (14.740–14.880) | 3.350 (3.240–3.380) | 1.510 (1.490–1.520) | 2.120 (2.110–2.130) | 2.290 (2.260–2.300) | 2.410 (2.380–2.410) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 3.600 (3.590–3.620) | 1.910 (1.890–1.930) | 2.030 (2.030–2.050) | 2.180 (2.150–2.200) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1.850 (1.840–1.860) | 1.890 (1.880–1.940) | 2.040 (2.010–2.060) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1.790 (1.780–1.800) | 1.910 (1.900–1.940) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 1.780 (1.770–1.820) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1.810 (1.740–1.830) | — | — | — | — | — |

### p50 at concurrency 24

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 7.030 (7.010–7.070) | 1.820 (1.820–1.860) | 1.110 (1.080–1.120) | 1.020 (1.020–1.030) | 1.110 (1.100–1.110) | 1.120 (1.090–1.130) |
| volucer worker (warm, unix socket) | on | 7.230 (7.180–7.360) | 1.940 (1.930–1.980) | 1.160 (1.120–1.170) | 1.040 (1.020–1.050) | 1.120 (1.120–1.120) | 1.120 (1.110–1.140) |
| volucer attach (warm, unix relay) | on | 7.220 (7.130–7.300) | 1.920 (1.900–1.920) | 1.130 (1.110–1.130) | 0.980 (0.980–0.980) | 1.030 (1.020–1.040) | 1.040 (1.040–1.050) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 29.870 (29.620–30.000) | 7.200 (6.960–7.390) | 3.300 (3.220–3.400) | 3.030 (3.010–3.050) | 3.300 (3.170–3.300) | 3.360 (3.330–3.440) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 29.580 (29.550–29.930) | 7.200 (7.080–7.360) | 3.320 (3.260–3.360) | 3.070 (3.060–3.080) | 3.280 (3.260–3.310) | 3.470 (3.470–3.480) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 7.320 (7.300–7.320) | 2.780 (2.760–2.810) | 3.120 (3.100–3.130) | 3.340 (3.290–3.340) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 3.720 (3.690–3.770) | 3.030 (2.960–3.060) | 3.110 (3.110–3.150) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 2.760 (2.750–2.770) | 2.990 (2.980–3.010) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 2.830 (2.820–2.860) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 2.850 (2.840–2.860) | — | — | — | — | — |

### p50 at concurrency 32

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 7.020 (7.000–7.100) | 1.810 (1.810–1.880) | 1.060 (1.050–1.090) | 1.020 (1.020–1.020) | 1.100 (1.100–1.120) | 1.100 (1.090–1.120) |
| volucer worker (warm, unix socket) | on | 7.160 (7.130–7.190) | 1.940 (1.910–1.960) | 1.130 (1.120–1.160) | 1.020 (1.010–1.040) | 1.110 (1.110–1.110) | 1.120 (1.100–1.120) |
| volucer attach (warm, unix relay) | on | 7.290 (7.190–7.370) | 1.900 (1.870–1.910) | 1.090 (1.090–1.120) | 0.970 (0.970–0.980) | 1.020 (1.020–1.020) | 1.030 (1.020–1.040) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 29.820 (29.480–29.950) | 6.860 (6.530–7.140) | 2.910 (2.760–2.970) | 2.870 (2.860–2.870) | 3.190 (3.150–3.220) | 3.320 (3.290–3.320) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 29.740 (29.700–29.740) | 7.000 (6.260–7.000) | 2.770 (2.750–2.820) | 2.910 (2.900–2.960) | 3.220 (3.150–3.230) | 3.470 (3.400–3.480) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 7.280 (7.220–7.290) | 2.730 (2.700–2.770) | 3.080 (3.060–3.080) | 3.230 (3.230–3.250) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 3.690 (3.670–3.720) | 2.960 (2.960–2.990) | 3.070 (3.040–3.080) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 2.740 (2.740–2.780) | 2.950 (2.900–2.960) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 2.800 (2.770–2.810) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 2.820 (2.820–2.870) | — | — | — | — | — |

### p50 at concurrency 64

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 17.680 (17.580–18.030) | 4.630 (4.580–4.730) | 2.860 (2.770–2.940) | 2.380 (2.360–2.390) | 2.340 (2.300–2.350) | 2.380 (2.360–2.390) |
| volucer worker (warm, unix socket) | on | 18.390 (18.170–18.430) | 4.870 (4.850–4.900) | 3.060 (2.940–3.110) | 2.370 (2.350–2.380) | 2.380 (2.380–2.380) | 2.490 (2.480–2.500) |
| volucer attach (warm, unix relay) | on | 18.520 (18.260–18.600) | 4.810 (4.780–4.820) | 2.940 (2.920–2.970) | 2.170 (2.130–2.200) | 2.120 (2.100–2.120) | 2.170 (2.150–2.170) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 74.740 (74.370–75.750) | 18.500 (18.440–18.940) | 8.390 (8.300–8.420) | 6.040 (5.940–6.210) | 5.660 (5.530–5.850) | 5.860 (5.830–5.920) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 74.540 (74.320–74.830) | 18.140 (15.360–18.150) | 8.310 (8.110–8.800) | 6.460 (6.310–6.610) | 6.010 (5.960–6.060) | 6.150 (5.970–6.160) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 18.510 (18.490–18.780) | 4.350 (4.300–4.360) | 5.850 (5.740–5.890) | 7.310 (7.120–7.360) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 9.280 (9.260–9.320) | 5.990 (5.860–6.030) | 7.040 (6.970–7.120) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 6.890 (6.860–6.920) | 6.820 (6.800–6.890) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 6.450 (6.440–6.700) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 6.310 (6.290–6.450) | — | — | — | — | — |

## Latency, p99 (ms)

### p99 at concurrency 8

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 3.270 (3.160–3.490) | 1.170 (1.160–1.230) | 1.010 (0.990–1.030) | 1.050 (1.020–1.060) | 1.050 (1.020–1.050) | 1.010 (1.000–1.040) |
| volucer worker (warm, unix socket) | on | 3.340 (3.310–3.350) | 1.240 (1.200–1.260) | 1.040 (1.040–1.070) | 1.070 (1.010–1.070) | 1.060 (1.050–1.060) | 1.060 (1.000–1.080) |
| volucer attach (warm, unix relay) | on | 3.330 (3.330–3.350) | 1.210 (1.180–1.230) | 1.020 (0.990–1.030) | 1.030 (1.030–1.040) | 1.040 (1.010–1.060) | 1.050 (1.030–1.060) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 12.150 (11.950–12.320) | 6.830 (6.760–6.910) | 3.310 (3.210–3.540) | 3.770 (3.770–4.140) | 4.040 (3.920–4.040) | 4.370 (3.860–4.540) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 12.580 (12.120–12.840) | 6.960 (6.940–7.090) | 3.410 (3.390–4.190) | 3.860 (3.820–5.570) | 4.020 (3.990–4.040) | 4.010 (3.960–4.020) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 4.350 (4.270–4.550) | 3.160 (3.100–3.190) | 3.540 (3.490–3.570) | 4.080 (3.780–4.290) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 2.580 (2.510–2.830) | 3.160 (3.050–3.210) | 3.470 (3.430–4.760) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 2.480 (2.400–2.790) | 3.180 (3.120–3.190) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 2.820 (2.460–3.680) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 2.500 (2.450–2.530) | — | — | — | — | — |

### p99 at concurrency 16

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 4.790 (4.730–5.110) | 2.130 (2.130–2.140) | 1.180 (1.120–1.200) | 1.450 (1.440–1.460) | 1.440 (1.440–1.450) | 1.450 (1.440–1.450) |
| volucer worker (warm, unix socket) | on | 4.850 (4.790–4.890) | 2.270 (2.210–2.290) | 1.230 (1.210–1.240) | 1.480 (1.470–1.520) | 1.490 (1.480–1.530) | 1.490 (1.460–1.500) |
| volucer attach (warm, unix relay) | on | 4.890 (4.850–5.260) | 2.210 (2.160–2.220) | 1.190 (1.180–1.220) | 1.440 (1.420–1.440) | 1.440 (1.430–1.460) | 1.470 (1.430–1.470) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 19.230 (17.500–20.630) | 11.480 (10.960–11.500) | 6.910 (6.440–7.020) | 4.630 (4.570–4.660) | 5.060 (4.950–5.260) | 5.280 (5.230–5.310) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 17.510 (17.360–17.860) | 11.460 (10.790–11.750) | 6.830 (6.350–7.280) | 4.650 (4.610–4.990) | 5.090 (5.040–5.230) | 5.440 (5.380–5.710) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 7.120 (6.670–7.150) | 4.380 (4.330–4.410) | 4.610 (4.560–4.630) | 4.990 (4.880–5.080) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 3.140 (3.130–3.620) | 4.370 (4.330–4.490) | 4.610 (4.570–4.990) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 3.850 (3.830–3.860) | 4.410 (4.350–4.820) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 3.900 (3.870–4.070) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 4.110 (3.820–4.500) | — | — | — | — | — |

### p99 at concurrency 24

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 9.230 (9.200–9.390) | 5.280 (5.220–5.320) | 3.290 (3.230–3.330) | 2.170 (2.150–2.240) | 2.380 (2.360–2.720) | 2.380 (2.330–2.840) |
| volucer worker (warm, unix socket) | on | 9.520 (9.340–9.810) | 5.520 (5.500–5.520) | 3.440 (3.380–3.530) | 2.300 (2.230–2.310) | 2.470 (2.460–2.810) | 2.520 (2.480–2.850) |
| volucer attach (warm, unix relay) | on | 9.520 (9.250–9.940) | 5.350 (5.340–5.410) | 3.380 (3.340–3.390) | 2.160 (2.130–2.160) | 2.270 (2.250–2.280) | 2.310 (2.290–2.330) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 34.200 (34.030–34.660) | 25.940 (20.880–27.010) | 18.120 (16.670–19.980) | 14.010 (13.010–14.450) | 9.460 (9.370–9.820) | 10.400 (8.480–21.940) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 32.910 (32.650–34.450) | 24.480 (22.370–27.010) | 16.480 (15.670–20.520) | 13.160 (12.880–13.900) | 9.190 (8.920–9.480) | 8.990 (8.940–11.940) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 16.330 (14.670–18.380) | 8.100 (7.700–8.280) | 7.080 (7.010–7.080) | 7.770 (7.580–7.880) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 7.800 (7.770–8.610) | 6.890 (6.840–7.030) | 7.430 (7.330–7.880) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 5.500 (5.380–7.330) | 7.330 (7.080–7.370) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 6.230 (6.130–6.340) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 6.270 (6.240–6.410) | — | — | — | — | — |

### p99 at concurrency 32

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 9.520 (9.330–9.820) | 5.240 (5.220–5.340) | 3.190 (3.130–3.320) | 2.160 (2.160–2.160) | 2.370 (2.350–2.400) | 2.370 (2.330–2.390) |
| volucer worker (warm, unix socket) | on | 9.170 (9.160–9.280) | 5.430 (5.370–5.460) | 3.430 (3.410–3.490) | 2.230 (2.220–2.270) | 2.450 (2.440–2.460) | 2.460 (2.440–2.470) |
| volucer attach (warm, unix relay) | on | 9.350 (9.260–9.580) | 5.250 (5.230–5.360) | 3.310 (3.300–3.360) | 2.150 (2.130–2.190) | 2.270 (2.260–2.280) | 2.290 (2.260–2.300) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 34.120 (33.940–36.020) | 21.880 (17.640–22.680) | 15.310 (15.260–16.870) | 13.440 (12.630–15.540) | 8.850 (8.450–9.160) | 9.290 (8.650–9.810) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 33.300 (33.020–33.630) | 20.680 (19.660–24.950) | 16.790 (15.720–18.790) | 13.220 (12.200–16.280) | 9.370 (8.820–9.410) | 8.970 (8.920–9.180) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 14.400 (14.390–17.470) | 8.010 (7.140–8.360) | 6.990 (6.970–7.000) | 7.680 (7.620–7.690) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 7.890 (7.820–8.420) | 6.840 (6.830–7.450) | 7.640 (7.210–7.970) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 5.750 (5.380–6.270) | 7.070 (6.530–7.360) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 6.140 (6.130–6.190) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 6.230 (6.200–6.240) | — | — | — | — | — |

### p99 at concurrency 64

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 21.510 (20.960–24.070) | 14.690 (14.500–14.730) | 11.050 (10.700–11.460) | 7.400 (7.340–7.450) | 5.740 (5.720–5.780) | 5.270 (5.240–5.440) |
| volucer worker (warm, unix socket) | on | 22.630 (22.040–26.340) | 15.150 (14.950–15.230) | 11.800 (11.410–11.840) | 7.340 (7.300–7.390) | 5.860 (5.860–5.860) | 5.540 (5.510–5.900) |
| volucer attach (warm, unix relay) | on | 22.720 (22.140–22.780) | 14.700 (14.540–14.740) | 11.350 (11.190–11.580) | 6.780 (6.760–6.790) | 5.240 (5.200–5.290) | 4.990 (4.950–4.990) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 88.760 (80.420–93.780) | 58.590 (53.550–61.530) | 38.050 (37.630–42.950) | 56.220 (55.410–67.730) | 46.020 (45.620–48.690) | 48.960 (45.600–54.370) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 80.540 (79.610–85.290) | 58.390 (56.550–69.730) | 53.330 (44.310–57.050) | 50.900 (44.100–52.830) | 41.330 (40.580–44.890) | 44.850 (40.740–46.000) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 38.620 (37.860–49.630) | 43.400 (43.320–44.290) | 31.590 (27.200–35.800) | 16.690 (16.590–17.150) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 24.360 (24.110–24.450) | 22.080 (21.690–23.890) | 16.130 (16.060–17.460) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 16.810 (16.740–16.840) | 15.900 (15.790–16.810) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 15.350 (14.110–16.120) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 12.330 (12.310–13.000) | — | — | — | — | — |

## opcache

Every cell in this run was measured with opcache **on**, which is the
production case and the only one where a shared OPcache segment can exist —
so the ON/OFF ratio is not a column here. The committed 8.5 matrix measures
that axis for the same arms (`results/matrix85/report.md`).

## Shape comparisons

### Shape comparisons at concurrency 8

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| transport: unix vs pipe | rps | -1.9% | -6.0% | -1.8% | -0.7% | +0.4% | -2.6% |
|  | PSS | +0.0% | -0.5% | +2.3% | +0.4% | -0.0% | +0.1% |
| memory model: attach vs pipe | rps | -3.9% | -3.2% | -0.1% | +1.6% | +1.5% | -3.4% |
|  | PSS | +3.1% | -49.7% | -66.5% | -78.2% | -82.6% | -85.3% |
| control: children=1 vs plain spawn_cgi | rps | +0.4% | -1.3% | +0.5% | -2.1% | -1.9% | -2.9% |
|  | PSS | +0.2% | -0.6% | -0.5% | +0.8% | +0.2% | -0.2% |
| prefork: children=4 vs children=1 | rps | +297.2% | +58.5% | -9.8% | +1.0% | — | — |
|  | PSS | +17.4% | +28.3% | +24.0% | +21.0% | — | — |
| prefork: children=8 vs children=1 | rps | +603.0% | +60.2% | -8.6% | — | — | — |
|  | PSS | +35.1% | +47.0% | +42.0% | — | — | — |
| prefork: children=16 vs children=1 | rps | +607.4% | +59.4% | — | — | — | — |
|  | PSS | +58.1% | +82.8% | — | — | — | — |
| prefork: children=24 vs children=1 | rps | +598.1% | — | — | — | — | — |
|  | PSS | +82.8% | — | — | — | — | — |
| prefork: children=32 vs children=1 | rps | +605.0% | — | — | — | — | — |
|  | PSS | +102.7% | — | — | — | — | — |

### Shape comparisons at concurrency 16

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| transport: unix vs pipe | rps | -0.7% | -6.6% | -3.9% | -1.8% | -1.4% | -0.9% |
|  | PSS | +0.0% | -0.5% | +2.3% | +0.4% | -0.0% | +0.1% |
| memory model: attach vs pipe | rps | -1.5% | -3.4% | -2.2% | +2.5% | +1.2% | -0.0% |
|  | PSS | +3.1% | -49.7% | -66.5% | -78.2% | -82.6% | -85.3% |
| control: children=1 vs plain spawn_cgi | rps | +0.3% | +0.4% | -1.9% | -1.5% | -1.8% | -2.6% |
|  | PSS | +0.2% | -0.6% | -0.5% | +0.8% | +0.2% | -0.2% |
| prefork: children=4 vs children=1 | rps | +303.6% | +82.3% | -3.9% | -2.5% | — | — |
|  | PSS | +17.4% | +28.3% | +24.0% | +21.0% | — | — |
| prefork: children=8 vs children=1 | rps | +690.1% | +83.5% | -4.2% | — | — | — |
|  | PSS | +35.1% | +47.0% | +42.0% | — | — | — |
| prefork: children=16 vs children=1 | rps | +660.4% | +81.1% | — | — | — | — |
|  | PSS | +58.1% | +82.8% | — | — | — | — |
| prefork: children=24 vs children=1 | rps | +664.5% | — | — | — | — | — |
|  | PSS | +82.8% | — | — | — | — | — |
| prefork: children=32 vs children=1 | rps | +651.1% | — | — | — | — | — |
|  | PSS | +102.7% | — | — | — | — | — |

### Shape comparisons at concurrency 24

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| transport: unix vs pipe | rps | -2.2% | -7.1% | -3.9% | -2.0% | -1.4% | -1.6% |
|  | PSS | +0.0% | -0.5% | +2.3% | +0.4% | -0.0% | +0.1% |
| memory model: attach vs pipe | rps | -2.5% | -4.3% | -1.4% | +4.5% | +6.9% | +6.6% |
|  | PSS | +3.1% | -49.7% | -66.5% | -78.2% | -82.6% | -85.3% |
| control: children=1 vs plain spawn_cgi | rps | +0.9% | +1.4% | -1.4% | -1.8% | +0.2% | -2.7% |
|  | PSS | +0.2% | -0.6% | -0.5% | +0.8% | +0.2% | -0.2% |
| prefork: children=4 vs children=1 | rps | +298.6% | +147.5% | +23.5% | +2.6% | — | — |
|  | PSS | +17.4% | +28.3% | +24.0% | +21.0% | — | — |
| prefork: children=8 vs children=1 | rps | +693.9% | +134.3% | +22.8% | — | — | — |
|  | PSS | +35.1% | +47.0% | +42.0% | — | — | — |
| prefork: children=16 vs children=1 | rps | +944.9% | +136.3% | — | — | — | — |
|  | PSS | +58.1% | +82.8% | — | — | — | — |
| prefork: children=24 vs children=1 | rps | +898.6% | — | — | — | — | — |
|  | PSS | +82.8% | — | — | — | — | — |
| prefork: children=32 vs children=1 | rps | +890.3% | — | — | — | — | — |
|  | PSS | +102.7% | — | — | — | — | — |

### Shape comparisons at concurrency 32

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| transport: unix vs pipe | rps | -1.5% | -5.7% | -6.1% | -0.5% | -1.5% | -1.6% |
|  | PSS | +0.0% | -0.5% | +2.3% | +0.4% | -0.0% | +0.1% |
| memory model: attach vs pipe | rps | -3.3% | -4.1% | -3.2% | +4.5% | +7.4% | +5.9% |
|  | PSS | +3.1% | -49.7% | -66.5% | -78.2% | -82.6% | -85.3% |
| control: children=1 vs plain spawn_cgi | rps | +0.9% | -0.6% | +0.2% | -1.0% | -1.0% | -4.0% |
|  | PSS | +0.2% | -0.6% | -0.5% | +0.8% | +0.2% | -0.2% |
| prefork: children=4 vs children=1 | rps | +303.1% | +151.7% | +22.0% | +4.4% | — | — |
|  | PSS | +17.4% | +28.3% | +24.0% | +21.0% | — | — |
| prefork: children=8 vs children=1 | rps | +692.6% | +139.8% | +21.4% | — | — | — |
|  | PSS | +35.1% | +47.0% | +42.0% | — | — | — |
| prefork: children=16 vs children=1 | rps | +952.4% | +140.5% | — | — | — | — |
|  | PSS | +58.1% | +82.8% | — | — | — | — |
| prefork: children=24 vs children=1 | rps | +903.8% | — | — | — | — | — |
|  | PSS | +82.8% | — | — | — | — | — |
| prefork: children=32 vs children=1 | rps | +896.4% | — | — | — | — | — |
|  | PSS | +102.7% | — | — | — | — | — |

### Shape comparisons at concurrency 64

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| transport: unix vs pipe | rps | -2.8% | -5.1% | -6.7% | +0.5% | -2.2% | -5.2% |
|  | PSS | +0.0% | -0.5% | +2.3% | +0.4% | -0.0% | +0.1% |
| memory model: attach vs pipe | rps | -3.5% | -3.2% | -2.6% | +9.2% | +9.9% | +8.4% |
|  | PSS | +3.1% | -49.7% | -66.5% | -78.2% | -82.6% | -85.3% |
| control: children=1 vs plain spawn_cgi | rps | +1.7% | +0.7% | +1.4% | -1.1% | -2.8% | -3.6% |
|  | PSS | +0.2% | -0.6% | -0.5% | +0.8% | +0.2% | -0.2% |
| prefork: children=4 vs children=1 | rps | +302.1% | +151.3% | +36.6% | +13.9% | — | — |
|  | PSS | +17.4% | +28.3% | +24.0% | +21.0% | — | — |
| prefork: children=8 vs children=1 | rps | +707.4% | +175.9% | +32.1% | — | — | — |
|  | PSS | +35.1% | +47.0% | +42.0% | — | — | — |
| prefork: children=16 vs children=1 | rps | +972.5% | +161.4% | — | — | — | — |
|  | PSS | +58.1% | +82.8% | — | — | — | — |
| prefork: children=24 vs children=1 | rps | +1030.4% | — | — | — | — | — |
|  | PSS | +82.8% | — | — | — | — | — |
| prefork: children=32 vs children=1 | rps | +1061.0% | — | — | — | — | — |
|  | PSS | +102.7% | — | — | — | — | — |

## Memory

### Memory, boot (before any request)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 1 | 2 | 37.2 | 59.1 | 18.6 |
| volucer worker (warm, pipe) | on | 4 | 5 | 87.5 | 199.0 | 17.5 |
| volucer worker (warm, pipe) | on | 8 | 9 | 148.1 | 386.1 | 16.5 |
| volucer worker (warm, pipe) | on | 16 | 17 | 265.0 | 757.9 | 15.6 |
| volucer worker (warm, pipe) | on | 24 | 25 | 380.2 | 1,131.8 | 15.2 |
| volucer worker (warm, pipe) | on | 32 | 33 | 494.5 | 1,504.6 | 15.0 |
| volucer worker (warm, unix socket) | on | 1 | 2 | 37.3 | 59.1 | 18.6 |
| volucer worker (warm, unix socket) | on | 4 | 5 | 87.7 | 199.4 | 17.5 |
| volucer worker (warm, unix socket) | on | 8 | 9 | 148.3 | 385.4 | 16.5 |
| volucer worker (warm, unix socket) | on | 16 | 17 | 265.2 | 758.3 | 15.6 |
| volucer worker (warm, unix socket) | on | 24 | 25 | 380.3 | 1,132.6 | 15.2 |
| volucer worker (warm, unix socket) | on | 32 | 33 | 494.9 | 1,503.8 | 15.0 |
| volucer attach (warm, unix relay) | on | 1 | 3 | 38.8 | 80.1 | 12.9 |
| volucer attach (warm, unix relay) | on | 4 | 6 | 40.8 | 127.5 | 6.8 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 43.3 | 190.8 | 4.3 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 48.5 | 316.1 | 2.7 |
| volucer attach (warm, unix relay) | on | 24 | 26 | 53.4 | 444.0 | 2.1 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 58.2 | 570.3 | 1.7 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 1 | 2 | 36.9 | 58.8 | 18.4 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 4 | 5 | 86.1 | 197.4 | 17.2 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 140.2 | 373.7 | 15.6 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 243.7 | 728.1 | 14.3 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 24 | 25 | 345.6 | 1,081.0 | 13.8 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 447.1 | 1,434.8 | 13.5 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 1 | 2 | 36.9 | 58.7 | 18.4 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 4 | 5 | 86.1 | 197.3 | 17.2 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 8 | 9 | 140.3 | 373.8 | 15.6 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 16 | 17 | 243.8 | 727.7 | 14.3 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 24 | 25 | 345.7 | 1,081.0 | 13.8 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 32 | 33 | 447.0 | 1,433.8 | 13.5 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 1 | 6 | 38.7 | 114.5 | 6.5 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 4 | 21 | 89.0 | 396.5 | 4.2 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 8 | 41 | 144.1 | 748.3 | 3.5 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 16 | 81 | 250.4 | 1,453.6 | 3.1 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 38.8 | 157.8 | 3.9 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 4 | 37 | 90.3 | 570.9 | 2.4 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 8 | 73 | 146.7 | 1,098.7 | 2.0 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 39.7 | 246.1 | 2.2 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 4 | 69 | 92.9 | 921.2 | 1.3 |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 1 | 26 | 40.4 | 332.3 | 1.6 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 41.0 | 420.2 | 1.2 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 1: 37.2 | 32: 494.5 | 457.3 | 31 | 14.8 |
| volucer worker (warm, unix socket) | on | 1: 37.3 | 32: 494.9 | 457.6 | 31 | 14.8 |
| volucer attach (warm, unix relay) | on | 1: 38.8 | 32: 58.2 | 19.4 | 31 | 0.6 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 1: 36.9 | 32: 447.1 | 410.2 | 31 | 13.2 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 1: 36.9 | 32: 447.0 | 410.1 | 31 | 13.2 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 1: 38.7 | 16: 250.4 | 211.7 | 15 | 14.1 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1: 38.8 | 8: 146.7 | 107.9 | 7 | 15.4 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1: 39.7 | 4: 92.9 | 53.2 | 3 | 17.7 |

### Memory, after load (peak concurrency)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 1 | 2 | 45.0 | 66.9 | 22.5 |
| volucer worker (warm, pipe) | on | 4 | 5 | 105.2 | 220.4 | 21.0 |
| volucer worker (warm, pipe) | on | 8 | 9 | 175.7 | 422.4 | 19.5 |
| volucer worker (warm, pipe) | on | 16 | 17 | 312.0 | 824.0 | 18.4 |
| volucer worker (warm, pipe) | on | 24 | 25 | 447.8 | 1,228.6 | 17.9 |
| volucer worker (warm, pipe) | on | 32 | 33 | 580.4 | 1,629.8 | 17.6 |
| volucer worker (warm, unix socket) | on | 1 | 2 | 45.0 | 66.9 | 22.5 |
| volucer worker (warm, unix socket) | on | 4 | 5 | 104.7 | 220.2 | 20.9 |
| volucer worker (warm, unix socket) | on | 8 | 9 | 179.7 | 425.5 | 20.0 |
| volucer worker (warm, unix socket) | on | 16 | 17 | 313.1 | 825.5 | 18.4 |
| volucer worker (warm, unix socket) | on | 24 | 25 | 447.6 | 1,228.9 | 17.9 |
| volucer worker (warm, unix socket) | on | 32 | 33 | 581.0 | 1,629.8 | 17.6 |
| volucer attach (warm, unix relay) | on | 1 | 3 | 46.4 | 87.8 | 15.5 |
| volucer attach (warm, unix relay) | on | 4 | 6 | 52.9 | 155.8 | 8.8 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 58.9 | 242.6 | 5.9 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 67.9 | 417.4 | 3.8 |
| volucer attach (warm, unix relay) | on | 24 | 26 | 77.7 | 591.3 | 3.0 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 85.5 | 761.4 | 2.5 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 1 | 2 | 44.1 | 66.1 | 22.1 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 4 | 5 | 103.1 | 218.5 | 20.6 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 176.2 | 421.9 | 19.6 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 309.8 | 822.5 | 18.2 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 24 | 25 | 448.3 | 1,229.3 | 17.9 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 576.9 | 1,625.7 | 17.5 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 1 | 2 | 44.2 | 66.0 | 22.1 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 4 | 5 | 102.5 | 217.8 | 20.5 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 8 | 9 | 175.3 | 421.2 | 19.5 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 16 | 17 | 312.4 | 825.1 | 18.4 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 24 | 25 | 449.3 | 1,230.2 | 18.0 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 32 | 33 | 575.8 | 1,624.5 | 17.4 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 1 | 6 | 51.9 | 170.3 | 8.7 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 4 | 21 | 131.5 | 645.8 | 6.3 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 8 | 41 | 217.3 | 1,260.6 | 5.3 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 16 | 81 | 378.0 | 2,476.0 | 4.7 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 59.7 | 278.1 | 6.0 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 4 | 37 | 150.7 | 1,077.1 | 4.1 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 8 | 73 | 249.0 | 2,106.8 | 3.4 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 69.9 | 491.5 | 3.9 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 4 | 69 | 187.4 | 1,927.1 | 2.7 |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 1 | 26 | 80.8 | 708.9 | 3.1 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 89.6 | 920.1 | 2.6 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 1: 45.0 | 32: 580.4 | 535.4 | 31 | 17.3 |
| volucer worker (warm, unix socket) | on | 1: 45.0 | 32: 581.0 | 536.0 | 31 | 17.3 |
| volucer attach (warm, unix relay) | on | 1: 46.4 | 32: 85.5 | 39.1 | 31 | 1.3 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 1: 44.1 | 32: 576.9 | 532.8 | 31 | 17.2 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 1: 44.2 | 32: 575.8 | 531.6 | 31 | 17.1 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 1: 51.9 | 16: 378.0 | 326.1 | 15 | 21.7 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1: 59.7 | 8: 249.0 | 189.3 | 7 | 27.0 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1: 69.9 | 4: 187.4 | 117.5 | 3 | 39.2 |

## Integrity checks

No failed cells and no dropped responses in any measured cell.

