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

Rows: `results/matrix85-volucer-modes/matrix.tsv`. Memory: `results/matrix85-volucer-modes/memory.tsv`.

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
| volucer worker (warm, pipe) | on | 3,434 (3,370–3,527) | 12,895 (12,777–12,897) | 14,752 (14,636–14,810) | 14,594 (14,487–15,082) | 14,123 (14,037–14,659) | 14,456 (14,366–14,499) |
| volucer worker (warm, unix socket) | on | 3,199 (3,147–3,200) | 12,279 (12,252–12,307) | 14,011 (13,867–14,374) | 13,729 (13,513–14,054) | 14,148 (13,948–14,353) | 13,659 (13,241–14,224) |
| volucer attach (warm, unix relay) | on | 3,258 (3,216–3,286) | 12,318 (12,265–12,439) | 14,208 (14,078–14,404) | 14,218 (14,157–14,316) | 14,353 (14,018–14,738) | 14,159 (14,111–14,250) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 802 (794–807) | 3,092 (3,084–3,101) | 5,091 (5,033–5,118) | 4,156 (4,124–4,169) | 3,915 (3,827–3,939) | 3,772 (3,750–3,775) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 793 (776–798) | 3,047 (3,002–3,051) | 5,064 (5,008–5,135) | 4,142 (4,110–4,150) | 3,956 (3,948–3,969) | 3,842 (3,792–3,917) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 3,202 (3,174–3,229) | 4,791 (4,762–4,868) | 4,588 (4,553–4,632) | 4,171 (4,163–4,196) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 5,601 (5,474–5,670) | 4,856 (4,817–4,999) | 4,607 (4,595–4,638) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 5,634 (5,556–5,645) | 4,861 (4,837–4,883) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 5,565 (5,555–5,746) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 5,622 (5,577–5,644) | — | — | — | — | — |

### rps at concurrency 16

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 3,346 (3,316–3,352) | 12,888 (12,754–12,977) | 19,890 (19,417–19,897) | 15,891 (15,683–16,185) | 15,637 (15,511–16,248) | 15,833 (15,800–16,063) |
| volucer worker (warm, unix socket) | on | 3,185 (3,159–3,192) | 12,254 (12,223–12,360) | 18,301 (17,961–18,821) | 15,471 (15,260–15,668) | 15,418 (15,374–15,849) | 15,279 (15,039–15,677) |
| volucer attach (warm, unix relay) | on | 3,184 (3,177–3,238) | 12,229 (12,111–12,277) | 19,101 (19,092–19,648) | 15,923 (15,893–16,118) | 16,079 (16,042–16,301) | 16,087 (15,766–16,233) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 803 (797–804) | 3,062 (3,044–3,089) | 5,613 (5,602–5,618) | 5,233 (5,221–5,329) | 4,933 (4,920–4,954) | 4,659 (4,650–4,685) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 794 (786–797) | 3,083 (3,070–3,100) | 5,594 (5,562–5,714) | 5,304 (5,263–5,352) | 4,939 (4,918–5,051) | 4,720 (4,682–4,778) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 3,153 (3,129–3,171) | 5,644 (5,581–5,677) | 5,437 (5,385–5,442) | 5,195 (5,155–5,281) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 6,208 (6,083–6,235) | 5,644 (5,639–5,670) | 5,453 (5,444–5,455) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 6,037 (5,994–6,054) | 5,637 (5,608–5,717) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 6,031 (5,992–6,123) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 6,045 (6,030–6,098) | — | — | — | — | — |

### rps at concurrency 24

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 3,351 (3,286–3,357) | 12,797 (12,644–13,136) | 21,239 (20,576–21,354) | 22,305 (22,098–22,448) | 20,169 (19,941–20,458) | 20,253 (20,225–20,390) |
| volucer worker (warm, unix socket) | on | 3,212 (3,151–3,218) | 12,298 (12,181–12,411) | 19,510 (19,420–20,255) | 21,478 (21,112–21,537) | 19,746 (19,584–19,763) | 19,576 (19,540–19,960) |
| volucer attach (warm, unix relay) | on | 3,258 (3,226–3,300) | 12,116 (12,054–12,242) | 20,112 (19,710–20,377) | 22,927 (22,803–23,169) | 21,969 (21,675–22,096) | 21,717 (21,630–21,763) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 798 (796–802) | 3,167 (3,107–3,201) | 5,895 (5,781–5,924) | 6,684 (6,662–6,726) | 6,840 (6,829–6,919) | 6,542 (6,469–6,596) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 790 (787–799) | 3,142 (3,053–3,203) | 6,017 (6,015–6,035) | 6,677 (6,586–6,706) | 6,887 (6,882–6,915) | 6,540 (6,500–6,606) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 3,182 (3,151–3,186) | 7,887 (7,719–7,903) | 7,348 (7,293–7,385) | 6,865 (6,853–7,004) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 6,267 (6,241–6,350) | 7,493 (7,470–7,607) | 7,191 (7,187–7,236) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 8,365 (8,308–8,380) | 7,421 (7,352–7,529) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 7,962 (7,892–7,998) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 7,856 (7,779–7,972) | — | — | — | — | — |

### rps at concurrency 32

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 3,374 (3,356–3,388) | 12,895 (12,656–12,993) | 21,556 (20,670–21,587) | 22,338 (22,134–22,420) | 20,114 (20,039–20,425) | 20,440 (19,933–20,583) |
| volucer worker (warm, unix socket) | on | 3,178 (3,168–3,259) | 12,400 (12,234–12,475) | 19,454 (19,421–19,946) | 21,598 (21,344–21,698) | 19,913 (19,834–19,937) | 19,768 (19,600–19,830) |
| volucer attach (warm, unix relay) | on | 3,267 (3,214–3,273) | 12,211 (12,097–12,406) | 19,861 (19,759–20,164) | 22,816 (22,517–23,173) | 22,057 (21,897–22,066) | 21,806 (21,759–21,939) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 798 (796–802) | 3,113 (3,101–3,145) | 5,929 (5,847–5,954) | 6,628 (6,455–6,649) | 6,863 (6,838–6,895) | 6,524 (6,469–6,586) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 793 (784–797) | 3,079 (3,042–3,131) | 6,022 (5,884–6,110) | 6,638 (6,627–6,677) | 6,884 (6,782–6,906) | 6,642 (6,563–6,704) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 3,173 (3,147–3,195) | 7,903 (7,729–8,038) | 7,418 (7,353–7,514) | 6,956 (6,954–6,977) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 6,258 (6,197–6,300) | 7,552 (7,439–7,598) | 7,333 (7,327–7,453) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 8,310 (8,294–8,354) | 7,500 (7,496–7,515) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 7,898 (7,885–8,004) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 7,916 (7,861–8,004) | — | — | — | — | — |

### rps at concurrency 64

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 3,349 (3,308–3,438) | 12,883 (12,859–13,045) | 21,098 (20,388–21,376) | 24,234 (24,203–24,461) | 23,584 (23,561–24,060) | 23,424 (23,358–23,559) |
| volucer worker (warm, unix socket) | on | 3,153 (3,149–3,249) | 12,278 (12,215–12,375) | 19,405 (19,232–19,442) | 23,634 (23,617–23,891) | 23,322 (23,020–23,618) | 22,520 (21,972–22,551) |
| volucer attach (warm, unix relay) | on | 3,202 (3,161–3,229) | 12,248 (12,177–12,337) | 19,656 (19,570–19,835) | 25,453 (25,214–26,210) | 26,525 (26,405–26,778) | 26,010 (25,770–26,020) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 790 (787–803) | 3,196 (3,157–3,203) | 6,126 (6,102–6,170) | 6,851 (6,851–6,949) | 7,420 (7,260–7,441) | 7,335 (7,200–7,473) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 789 (784–798) | 3,181 (3,127–3,212) | 6,197 (6,184–6,231) | 6,957 (6,949–7,028) | 7,315 (7,241–7,337) | 7,444 (7,320–7,631) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 3,176 (3,170–3,195) | 7,876 (7,840–8,064) | 8,557 (8,445–8,610) | 7,851 (7,833–8,048) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 6,256 (6,144–6,310) | 8,722 (8,588–8,727) | 8,325 (8,126–8,353) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 8,591 (8,486–8,644) | 8,390 (8,380–8,463) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 8,953 (8,793–8,967) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 9,117 (8,929–9,185) | — | — | — | — | — |

## Headline readings

### Best configuration per arm

| arm | rps | workers | children | opcache | concurrency |
|---|---|---|---|---|---|
| volucer worker (warm, pipe) | 24,234 | 16 | — | on | 64 |
| volucer worker (warm, unix socket) | 23,634 | 16 | — | on | 64 |
| volucer attach (warm, unix relay) | 26,525 | 24 | — | on | 64 |
| volucer spawn_cgi (cold, unix, 1/slot) | 7,420 | 24 | — | on | 64 |
| volucer spawn_cgi children (cold, unix) | 7,444 | 32 | 1 | on | 64 |
| volucer spawn_cgi children (cold, unix) | 8,557 | 8 | 4 | on | 64 |
| volucer spawn_cgi children (cold, unix) | 8,722 | 4 | 8 | on | 64 |
| volucer spawn_cgi children (cold, unix) | 8,591 | 1 | 16 | on | 64 |
| volucer spawn_cgi children (cold, unix) | 8,953 | 1 | 24 | on | 64 |
| volucer spawn_cgi children (cold, unix) | 9,117 | 1 | 32 | on | 64 |

### Does another worker help? (concurrency 64, opcache on)

| arm | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 | peak | change from w=1 |
|---|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | 3,349 | 12,883 | 21,098 | 24,234 | 23,584 | 23,424 | w=16 | +623.6% |
| volucer worker (warm, unix socket) | 3,153 | 12,278 | 19,405 | 23,634 | 23,322 | 22,520 | w=16 | +649.7% |
| volucer attach (warm, unix relay) | 3,202 | 12,248 | 19,656 | 25,453 | 26,525 | 26,010 | w=24 | +728.5% |
| volucer spawn_cgi (cold, unix, 1/slot) | 790 | 3,196 | 6,126 | 6,851 | 7,420 | 7,335 | w=24 | +839.0% |
| volucer spawn_cgi children (cold, unix), ch=1 | 789 | 3,181 | 6,197 | 6,957 | 7,315 | 7,444 | w=32 | +843.2% |
| volucer spawn_cgi children (cold, unix), ch=4 | 3,176 | 7,876 | 8,557 | 7,851 | — | — | w=8 | +169.4% |
| volucer spawn_cgi children (cold, unix), ch=8 | 6,256 | 8,722 | 8,325 | — | — | — | w=4 | +39.4% |
| volucer spawn_cgi children (cold, unix), ch=16 | 8,591 | 8,390 | — | — | — | — | w=1 | +0.0% |

## Latency, p50 (ms)

### p50 at concurrency 8

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 2.270 (2.200–2.300) | 0.591 (0.590–0.595) | 0.512 (0.512–0.516) | 0.516 (0.502–0.520) | 0.536 (0.517–0.541) | 0.525 (0.522–0.527) |
| volucer worker (warm, unix socket) | on | 2.420 (2.420–2.460) | 0.622 (0.617–0.623) | 0.537 (0.526–0.546) | 0.553 (0.538–0.558) | 0.533 (0.529–0.542) | 0.552 (0.529–0.569) |
| volucer attach (warm, unix relay) | on | 2.380 (2.370–2.420) | 0.619 (0.614–0.622) | 0.534 (0.527–0.536) | 0.536 (0.528–0.537) | 0.527 (0.516–0.541) | 0.532 (0.532–0.539) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 9.840 (9.790–9.840) | 2.330 (2.320–2.350) | 1.380 (1.380–1.390) | 1.730 (1.720–1.750) | 1.850 (1.840–1.900) | 1.930 (1.930–1.930) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 9.950 (9.830–10.010) | 2.340 (2.310–2.340) | 1.390 (1.370–1.390) | 1.750 (1.730–1.760) | 1.840 (1.820–1.840) | 1.900 (1.850–1.930) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 2.390 (2.380–2.410) | 1.480 (1.470–1.480) | 1.530 (1.520–1.560) | 1.740 (1.710–1.740) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1.340 (1.320–1.360) | 1.480 (1.430–1.480) | 1.510 (1.510–1.540) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1.330 (1.330–1.330) | 1.470 (1.450–1.480) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 1.330 (1.300–1.340) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1.330 (1.330–1.330) | — | — | — | — | — |

### p50 at concurrency 16

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 3.500 (3.480–3.500) | 0.890 (0.890–0.900) | 0.566 (0.566–0.580) | 0.711 (0.694–0.717) | 0.715 (0.692–0.723) | 0.709 (0.699–0.710) |
| volucer worker (warm, unix socket) | on | 3.680 (3.640–3.680) | 0.940 (0.930–0.950) | 0.616 (0.597–0.626) | 0.720 (0.715–0.729) | 0.723 (0.705–0.726) | 0.728 (0.712–0.742) |
| volucer attach (warm, unix relay) | on | 3.650 (3.610–3.680) | 0.940 (0.940–0.960) | 0.592 (0.575–0.593) | 0.700 (0.691–0.704) | 0.693 (0.685–0.700) | 0.693 (0.685–0.711) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 14.750 (14.740–14.760) | 3.240 (3.080–3.370) | 1.480 (1.480–1.510) | 2.110 (2.080–2.110) | 2.250 (2.240–2.250) | 2.370 (2.360–2.380) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 14.890 (14.880–15.040) | 3.240 (3.050–3.320) | 1.510 (1.470–1.510) | 2.080 (2.070–2.100) | 2.240 (2.190–2.240) | 2.330 (2.310–2.340) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 3.630 (3.610–3.640) | 1.910 (1.890–1.930) | 2.030 (2.020–2.050) | 2.150 (2.120–2.170) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1.870 (1.860–1.910) | 1.910 (1.870–1.920) | 2.020 (2.010–2.030) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1.790 (1.780–1.800) | 1.920 (1.880–1.930) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 1.810 (1.770–1.820) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1.800 (1.790–1.810) | — | — | — | — | — |

### p50 at concurrency 24

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 7.000 (6.980–7.120) | 1.840 (1.800–1.860) | 1.080 (1.060–1.100) | 1.020 (1.010–1.020) | 1.120 (1.120–1.120) | 1.110 (1.100–1.110) |
| volucer worker (warm, unix socket) | on | 7.330 (7.320–7.460) | 1.910 (1.910–1.930) | 1.160 (1.120–1.180) | 1.050 (1.040–1.070) | 1.130 (1.130–1.140) | 1.140 (1.120–1.150) |
| volucer attach (warm, unix relay) | on | 7.210 (7.070–7.290) | 1.970 (1.940–1.970) | 1.130 (1.120–1.150) | 0.980 (0.970–0.980) | 1.030 (1.020–1.030) | 1.040 (1.030–1.040) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 29.830 (29.580–29.830) | 7.330 (7.010–7.460) | 3.210 (3.090–3.250) | 3.040 (3.040–3.080) | 3.210 (3.170–3.260) | 3.400 (3.370–3.440) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 29.960 (29.850–29.970) | 7.330 (6.400–7.400) | 3.330 (3.280–3.360) | 3.050 (3.030–3.070) | 3.210 (3.190–3.240) | 3.430 (3.360–3.430) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 7.380 (7.320–7.390) | 2.780 (2.760–2.820) | 3.080 (3.070–3.110) | 3.280 (3.220–3.290) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 3.720 (3.690–3.800) | 3.020 (2.980–3.020) | 3.140 (3.120–3.140) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 2.760 (2.740–2.770) | 3.030 (3.000–3.050) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 2.850 (2.840–2.880) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 2.890 (2.840–2.900) | — | — | — | — | — |

### p50 at concurrency 32

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 6.990 (6.970–7.010) | 1.820 (1.810–1.840) | 1.030 (1.030–1.080) | 1.010 (1.000–1.010) | 1.120 (1.100–1.120) | 1.100 (1.100–1.120) |
| volucer worker (warm, unix socket) | on | 7.380 (7.200–7.440) | 1.880 (1.880–1.900) | 1.140 (1.110–1.150) | 1.030 (1.030–1.050) | 1.120 (1.120–1.130) | 1.130 (1.120–1.140) |
| volucer attach (warm, unix relay) | on | 7.210 (7.180–7.290) | 1.940 (1.890–1.950) | 1.130 (1.110–1.130) | 0.980 (0.970–1.000) | 1.010 (1.000–1.020) | 1.020 (1.020–1.020) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 29.670 (29.610–29.710) | 6.760 (6.160–7.070) | 2.640 (2.600–2.740) | 2.890 (2.870–2.930) | 3.180 (3.170–3.200) | 3.350 (3.340–3.390) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 29.990 (29.840–30.050) | 6.260 (5.490–6.930) | 2.720 (2.590–2.880) | 2.890 (2.880–2.910) | 3.160 (3.140–3.250) | 3.290 (3.260–3.340) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 7.390 (7.350–7.400) | 2.760 (2.730–2.780) | 3.020 (2.980–3.050) | 3.210 (3.190–3.210) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 3.760 (3.700–3.790) | 2.980 (2.960–3.000) | 3.060 (3.010–3.060) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 2.750 (2.730–2.770) | 2.980 (2.970–3.000) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 2.860 (2.820–2.870) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 2.860 (2.830–2.870) | — | — | — | — | — |

### p50 at concurrency 64

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 17.740 (17.210–17.930) | 4.620 (4.540–4.620) | 2.800 (2.750–2.900) | 2.330 (2.330–2.350) | 2.360 (2.330–2.380) | 2.400 (2.400–2.420) |
| volucer worker (warm, unix socket) | on | 18.760 (18.190–18.770) | 4.820 (4.770–4.860) | 3.050 (3.040–3.070) | 2.390 (2.380–2.390) | 2.410 (2.380–2.430) | 2.540 (2.510–2.580) |
| volucer attach (warm, unix relay) | on | 18.400 (18.320–18.680) | 4.860 (4.820–4.870) | 3.000 (2.980–3.020) | 2.220 (2.150–2.240) | 2.110 (2.090–2.120) | 2.170 (2.170–2.170) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 74.360 (74.340–75.760) | 18.010 (16.640–19.990) | 8.560 (8.130–8.660) | 6.120 (6.070–6.460) | 5.860 (5.710–6.110) | 5.920 (5.900–6.000) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 74.930 (74.560–75.190) | 18.140 (17.780–20.090) | 8.640 (8.620–8.880) | 6.160 (6.030–6.170) | 6.090 (6.040–6.230) | 5.870 (5.860–6.280) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 18.680 (18.520–18.700) | 4.090 (3.680–5.080) | 5.800 (5.670–5.890) | 7.280 (7.110–7.290) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 9.490 (9.430–9.580) | 5.950 (5.930–5.960) | 6.910 (6.890–7.040) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 6.840 (6.820–6.840) | 6.860 (6.820–6.880) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 6.540 (6.530–6.580) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 6.400 (6.330–6.420) | — | — | — | — | — |

## Latency, p99 (ms)

### p99 at concurrency 8

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 3.190 (3.090–3.220) | 1.190 (1.180–1.200) | 0.990 (0.990–1.000) | 0.990 (0.960–1.010) | 1.050 (1.010–1.050) | 1.020 (1.000–1.020) |
| volucer worker (warm, unix socket) | on | 3.450 (3.400–3.510) | 1.230 (1.200–1.260) | 1.040 (1.010–1.060) | 1.080 (1.060–1.090) | 1.040 (1.020–1.070) | 1.090 (1.030–1.110) |
| volucer attach (warm, unix relay) | on | 3.340 (3.260–3.380) | 1.230 (1.200–1.250) | 1.030 (1.020–1.030) | 1.020 (1.010–1.020) | 1.020 (0.990–1.050) | 1.040 (1.030–1.040) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 12.070 (11.930–12.840) | 6.780 (6.560–6.930) | 3.300 (3.240–3.420) | 3.800 (3.740–3.820) | 4.010 (3.890–4.200) | 4.560 (4.260–5.700) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 12.770 (12.490–16.140) | 7.230 (6.940–7.740) | 3.300 (3.170–5.920) | 3.850 (3.790–4.270) | 3.950 (3.920–3.960) | 3.980 (3.880–4.110) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 4.180 (4.090–4.320) | 3.240 (3.130–3.590) | 3.770 (3.520–3.930) | 3.750 (3.740–3.760) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 2.650 (2.610–2.800) | 3.200 (3.110–3.220) | 3.510 (3.480–5.090) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 2.540 (2.520–2.610) | 3.230 (3.160–3.710) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 2.530 (2.450–2.860) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 2.520 (2.510–2.590) | — | — | — | — | — |

### p99 at concurrency 16

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 4.730 (4.630–4.790) | 2.150 (2.110–2.180) | 1.160 (1.150–1.180) | 1.440 (1.400–1.440) | 1.460 (1.400–1.460) | 1.420 (1.410–1.430) |
| volucer worker (warm, unix socket) | on | 5.090 (4.970–5.200) | 2.210 (2.200–2.250) | 1.260 (1.210–1.260) | 1.500 (1.470–1.510) | 1.500 (1.480–1.510) | 1.530 (1.490–1.550) |
| volucer attach (warm, unix relay) | on | 4.920 (4.900–4.940) | 2.210 (2.180–2.260) | 1.180 (1.160–1.200) | 1.460 (1.420–1.460) | 1.440 (1.420–1.440) | 1.450 (1.430–1.470) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16.940 (16.700–17.610) | 11.690 (11.280–12.280) | 6.890 (6.660–6.930) | 4.780 (4.570–4.880) | 4.950 (4.910–5.030) | 5.290 (5.280–5.340) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 17.830 (17.310–17.850) | 13.010 (11.940–13.200) | 6.860 (6.680–7.050) | 4.590 (4.590–4.640) | 4.990 (4.900–5.000) | 5.300 (5.230–5.570) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 6.700 (6.620–6.750) | 4.390 (4.380–4.550) | 4.530 (4.530–4.590) | 4.730 (4.590–4.940) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 3.190 (3.150–3.230) | 4.390 (4.310–4.450) | 4.520 (4.460–4.550) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 3.930 (3.910–4.080) | 4.430 (4.420–4.450) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 3.860 (3.850–4.180) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 3.850 (3.850–3.910) | — | — | — | — | — |

### p99 at concurrency 24

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 9.150 (9.070–10.010) | 5.250 (5.190–5.270) | 3.210 (3.160–3.280) | 2.160 (2.130–2.210) | 2.380 (2.370–2.930) | 2.360 (2.350–2.660) |
| volucer worker (warm, unix socket) | on | 9.520 (9.440–9.670) | 5.410 (5.340–5.460) | 3.440 (3.350–3.530) | 2.300 (2.270–2.330) | 2.500 (2.480–2.860) | 2.510 (2.510–2.880) |
| volucer attach (warm, unix relay) | on | 9.430 (9.410–9.660) | 5.400 (5.330–5.600) | 3.350 (3.270–3.360) | 2.150 (2.100–2.160) | 2.260 (2.250–2.300) | 2.280 (2.280–2.300) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 33.550 (33.410–34.900) | 23.480 (22.390–24.920) | 18.550 (17.000–19.970) | 13.360 (12.340–13.700) | 9.520 (9.060–9.600) | 9.090 (9.020–9.100) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 34.450 (33.710–35.870) | 23.780 (22.980–33.910) | 16.670 (15.770–20.620) | 13.320 (13.170–15.290) | 9.190 (8.850–9.330) | 8.880 (8.750–9.150) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 14.680 (14.460–14.860) | 7.900 (7.860–7.940) | 7.060 (6.970–7.150) | 7.620 (7.610–8.550) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 7.940 (7.930–8.070) | 6.930 (6.790–6.950) | 7.310 (7.190–7.350) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 5.530 (5.480–5.970) | 6.970 (6.850–7.040) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 6.230 (6.210–6.280) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 6.320 (6.200–7.010) | — | — | — | — | — |

### p99 at concurrency 32

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 9.020 (8.630–9.160) | 5.150 (5.120–5.200) | 3.140 (3.100–3.260) | 2.140 (2.140–2.140) | 2.370 (2.360–2.380) | 2.380 (2.350–2.380) |
| volucer worker (warm, unix socket) | on | 9.810 (9.530–9.990) | 5.280 (5.250–5.300) | 3.410 (3.360–3.430) | 2.240 (2.220–2.250) | 2.480 (2.450–2.500) | 2.490 (2.470–2.500) |
| volucer attach (warm, unix relay) | on | 9.370 (9.320–9.470) | 5.400 (5.390–5.470) | 3.370 (3.360–3.400) | 2.140 (2.130–2.210) | 2.250 (2.240–2.270) | 2.270 (2.240–2.280) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 33.950 (32.790–34.430) | 25.440 (24.570–25.670) | 16.900 (16.680–17.720) | 14.910 (13.150–16.500) | 8.940 (8.640–9.160) | 9.530 (8.950–9.860) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 34.130 (33.710–34.460) | 25.120 (25.030–31.690) | 18.380 (15.490–19.010) | 13.300 (12.920–14.000) | 9.010 (8.880–9.280) | 8.950 (8.920–9.090) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 14.650 (14.490–14.720) | 8.390 (6.950–8.650) | 6.970 (6.830–7.030) | 7.600 (7.530–7.980) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 8.010 (7.830–8.140) | 6.800 (6.760–7.610) | 7.040 (6.940–7.060) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 5.460 (5.340–5.770) | 6.930 (6.920–6.930) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 6.260 (6.220–6.300) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 6.250 (6.120–6.280) | — | — | — | — | — |

### p99 at concurrency 64

| arm | opcache | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 21.250 (20.850–21.810) | 14.550 (14.530–15.200) | 11.030 (10.520–11.080) | 7.220 (7.210–7.250) | 5.820 (5.700–5.860) | 5.340 (5.300–5.710) |
| volucer worker (warm, unix socket) | on | 23.060 (22.340–23.450) | 14.930 (14.810–15.150) | 11.790 (11.610–11.890) | 7.320 (7.200–7.490) | 5.990 (5.840–6.020) | 5.680 (5.670–5.940) |
| volucer attach (warm, unix relay) | on | 22.980 (22.540–23.080) | 14.900 (14.770–15.140) | 11.450 (11.360–11.540) | 6.730 (6.640–6.820) | 5.240 (5.110–5.260) | 4.920 (4.880–5.040) |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 81.200 (79.200–84.670) | 52.660 (48.570–63.290) | 48.450 (46.120–50.510) | 63.890 (60.230–66.440) | 42.420 (39.300–45.290) | 47.260 (46.000–49.420) |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 87.330 (81.360–102.190) | 47.510 (42.650–56.980) | 46.220 (39.620–50.860) | 56.830 (53.760–73.440) | 41.530 (36.240–47.460) | 44.020 (38.870–50.110) |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 38.580 (38.520–38.900) | 46.040 (41.990–46.210) | 28.610 (27.640–31.570) | 16.960 (16.600–17.110) | — | — |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 24.900 (24.320–26.910) | 24.450 (23.370–26.110) | 15.690 (15.580–16.150) | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 16.810 (16.560–17.650) | 15.330 (15.230–15.470) | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 14.530 (14.450–14.760) | — | — | — | — | — |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 12.690 (12.530–12.930) | — | — | — | — | — |

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

| comparison | metric | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| transport: unix vs pipe | rps | -6.9% | -4.8% | -5.0% | -5.9% | +0.2% | -5.5% |
|  | PSS | +0.2% | +0.3% | +0.2% | +0.1% | -0.0% | +0.3% |
| memory model: attach vs pipe | rps | -5.1% | -4.5% | -3.7% | -2.6% | +1.6% | -2.1% |
|  | PSS | +1.5% | -49.0% | -67.2% | -77.9% | -82.6% | -85.2% |
| control: children=1 vs plain spawn_cgi | rps | -1.2% | -1.5% | -0.5% | -0.3% | +1.0% | +1.9% |
|  | PSS | +0.5% | -0.9% | +1.2% | -1.0% | -0.1% | -0.3% |
| prefork: children=4 vs children=1 | rps | +303.9% | +57.3% | -9.4% | +0.7% | — | — |
|  | PSS | +14.7% | +25.1% | +21.5% | +24.2% | — | — |
| prefork: children=8 vs children=1 | rps | +606.4% | +59.4% | -9.0% | — | — | — |
|  | PSS | +30.9% | +49.5% | +45.4% | — | — | — |
| prefork: children=16 vs children=1 | rps | +610.7% | +59.5% | — | — | — | — |
|  | PSS | +59.4% | +83.7% | — | — | — | — |
| prefork: children=24 vs children=1 | rps | +601.9% | — | — | — | — | — |
|  | PSS | +86.7% | — | — | — | — | — |
| prefork: children=32 vs children=1 | rps | +609.1% | — | — | — | — | — |
|  | PSS | +102.7% | — | — | — | — | — |

### Shape comparisons at concurrency 16

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| transport: unix vs pipe | rps | -4.8% | -4.9% | -8.0% | -2.6% | -1.4% | -3.5% |
|  | PSS | +0.2% | +0.3% | +0.2% | +0.1% | -0.0% | +0.3% |
| memory model: attach vs pipe | rps | -4.8% | -5.1% | -4.0% | +0.2% | +2.8% | +1.6% |
|  | PSS | +1.5% | -49.0% | -67.2% | -77.9% | -82.6% | -85.2% |
| control: children=1 vs plain spawn_cgi | rps | -1.2% | +0.7% | -0.3% | +1.4% | +0.1% | +1.3% |
|  | PSS | +0.5% | -0.9% | +1.2% | -1.0% | -0.1% | -0.3% |
| prefork: children=4 vs children=1 | rps | +297.2% | +83.0% | -2.8% | -2.1% | — | — |
|  | PSS | +14.7% | +25.1% | +21.5% | +24.2% | — | — |
| prefork: children=8 vs children=1 | rps | +682.2% | +83.0% | -2.5% | — | — | — |
|  | PSS | +30.9% | +49.5% | +45.4% | — | — | — |
| prefork: children=16 vs children=1 | rps | +660.7% | +82.8% | — | — | — | — |
|  | PSS | +59.4% | +83.7% | — | — | — | — |
| prefork: children=24 vs children=1 | rps | +659.9% | — | — | — | — | — |
|  | PSS | +86.7% | — | — | — | — | — |
| prefork: children=32 vs children=1 | rps | +661.7% | — | — | — | — | — |
|  | PSS | +102.7% | — | — | — | — | — |

### Shape comparisons at concurrency 24

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| transport: unix vs pipe | rps | -4.2% | -3.9% | -8.1% | -3.7% | -2.1% | -3.3% |
|  | PSS | +0.2% | +0.3% | +0.2% | +0.1% | -0.0% | +0.3% |
| memory model: attach vs pipe | rps | -2.8% | -5.3% | -5.3% | +2.8% | +8.9% | +7.2% |
|  | PSS | +1.5% | -49.0% | -67.2% | -77.9% | -82.6% | -85.2% |
| control: children=1 vs plain spawn_cgi | rps | -1.0% | -0.8% | +2.1% | -0.1% | +0.7% | -0.0% |
|  | PSS | +0.5% | -0.9% | +1.2% | -1.0% | -0.1% | -0.3% |
| prefork: children=4 vs children=1 | rps | +302.9% | +151.0% | +22.1% | +2.8% | — | — |
|  | PSS | +14.7% | +25.1% | +21.5% | +24.2% | — | — |
| prefork: children=8 vs children=1 | rps | +693.6% | +138.5% | +19.5% | — | — | — |
|  | PSS | +30.9% | +49.5% | +45.4% | — | — | — |
| prefork: children=16 vs children=1 | rps | +959.3% | +136.2% | — | — | — | — |
|  | PSS | +59.4% | +83.7% | — | — | — | — |
| prefork: children=24 vs children=1 | rps | +908.3% | — | — | — | — | — |
|  | PSS | +86.7% | — | — | — | — | — |
| prefork: children=32 vs children=1 | rps | +894.8% | — | — | — | — | — |
|  | PSS | +102.7% | — | — | — | — | — |

### Shape comparisons at concurrency 32

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| transport: unix vs pipe | rps | -5.8% | -3.8% | -9.8% | -3.3% | -1.0% | -3.3% |
|  | PSS | +0.2% | +0.3% | +0.2% | +0.1% | -0.0% | +0.3% |
| memory model: attach vs pipe | rps | -3.2% | -5.3% | -7.9% | +2.1% | +9.7% | +6.7% |
|  | PSS | +1.5% | -49.0% | -67.2% | -77.9% | -82.6% | -85.2% |
| control: children=1 vs plain spawn_cgi | rps | -0.6% | -1.1% | +1.6% | +0.2% | +0.3% | +1.8% |
|  | PSS | +0.5% | -0.9% | +1.2% | -1.0% | -0.1% | -0.3% |
| prefork: children=4 vs children=1 | rps | +300.0% | +156.7% | +23.2% | +4.8% | — | — |
|  | PSS | +14.7% | +25.1% | +21.5% | +24.2% | — | — |
| prefork: children=8 vs children=1 | rps | +688.8% | +145.3% | +21.8% | — | — | — |
|  | PSS | +30.9% | +49.5% | +45.4% | — | — | — |
| prefork: children=16 vs children=1 | rps | +947.5% | +143.6% | — | — | — | — |
|  | PSS | +59.4% | +83.7% | — | — | — | — |
| prefork: children=24 vs children=1 | rps | +895.5% | — | — | — | — | — |
|  | PSS | +86.7% | — | — | — | — | — |
| prefork: children=32 vs children=1 | rps | +897.9% | — | — | — | — | — |
|  | PSS | +102.7% | — | — | — | — | — |

### Shape comparisons at concurrency 64

Each row is one arm divided by another at the same worker count, so the ratio
is the single thing that differs between them. `PSS` is the same ratio for
summed PSS after load.

| comparison | metric | w=1 | w=4 | w=8 | w=16 | w=24 | w=32 |
|---|---|---|---|---|---|---|---|
| transport: unix vs pipe | rps | -5.9% | -4.7% | -8.0% | -2.5% | -1.1% | -3.9% |
|  | PSS | +0.2% | +0.3% | +0.2% | +0.1% | -0.0% | +0.3% |
| memory model: attach vs pipe | rps | -4.4% | -4.9% | -6.8% | +5.0% | +12.5% | +11.0% |
|  | PSS | +1.5% | -49.0% | -67.2% | -77.9% | -82.6% | -85.2% |
| control: children=1 vs plain spawn_cgi | rps | -0.1% | -0.5% | +1.1% | +1.5% | -1.4% | +1.5% |
|  | PSS | +0.5% | -0.9% | +1.2% | -1.0% | -0.1% | -0.3% |
| prefork: children=4 vs children=1 | rps | +302.4% | +147.5% | +38.1% | +12.8% | — | — |
|  | PSS | +14.7% | +25.1% | +21.5% | +24.2% | — | — |
| prefork: children=8 vs children=1 | rps | +692.7% | +174.1% | +34.4% | — | — | — |
|  | PSS | +30.9% | +49.5% | +45.4% | — | — | — |
| prefork: children=16 vs children=1 | rps | +988.5% | +163.7% | — | — | — | — |
|  | PSS | +59.4% | +83.7% | — | — | — | — |
| prefork: children=24 vs children=1 | rps | +1034.3% | — | — | — | — | — |
|  | PSS | +86.7% | — | — | — | — | — |
| prefork: children=32 vs children=1 | rps | +1055.2% | — | — | — | — | — |
|  | PSS | +102.7% | — | — | — | — | — |

## Memory

### Memory, boot (before any request)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 1 | 2 | 37.1 | 59.3 | 18.6 |
| volucer worker (warm, pipe) | on | 4 | 5 | 86.9 | 198.7 | 17.4 |
| volucer worker (warm, pipe) | on | 8 | 9 | 147.5 | 385.3 | 16.4 |
| volucer worker (warm, pipe) | on | 16 | 17 | 264.0 | 757.7 | 15.5 |
| volucer worker (warm, pipe) | on | 24 | 25 | 378.7 | 1,130.5 | 15.1 |
| volucer worker (warm, pipe) | on | 32 | 33 | 492.9 | 1,502.5 | 14.9 |
| volucer worker (warm, unix socket) | on | 1 | 2 | 37.0 | 59.2 | 18.5 |
| volucer worker (warm, unix socket) | on | 4 | 5 | 87.2 | 198.9 | 17.4 |
| volucer worker (warm, unix socket) | on | 8 | 9 | 147.5 | 385.2 | 16.4 |
| volucer worker (warm, unix socket) | on | 16 | 17 | 264.0 | 758.0 | 15.5 |
| volucer worker (warm, unix socket) | on | 24 | 25 | 379.0 | 1,130.6 | 15.2 |
| volucer worker (warm, unix socket) | on | 32 | 33 | 493.5 | 1,503.3 | 15.0 |
| volucer attach (warm, unix relay) | on | 1 | 3 | 38.8 | 80.2 | 12.9 |
| volucer attach (warm, unix relay) | on | 4 | 6 | 40.8 | 127.4 | 6.8 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 43.2 | 191.0 | 4.3 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 48.3 | 316.7 | 2.7 |
| volucer attach (warm, unix relay) | on | 24 | 26 | 53.2 | 441.0 | 2.0 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 58.3 | 566.7 | 1.7 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 1 | 2 | 37.0 | 58.7 | 18.5 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 4 | 5 | 86.0 | 197.1 | 17.2 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 140.1 | 373.3 | 15.6 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 243.8 | 727.6 | 14.3 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 24 | 25 | 345.7 | 1,080.2 | 13.8 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 447.0 | 1,435.0 | 13.5 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 1 | 2 | 37.0 | 58.8 | 18.5 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 4 | 5 | 86.1 | 197.3 | 17.2 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 8 | 9 | 140.2 | 374.1 | 15.6 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 16 | 17 | 243.7 | 727.6 | 14.3 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 24 | 25 | 345.7 | 1,080.5 | 13.8 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 32 | 33 | 447.1 | 1,432.8 | 13.5 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 1 | 6 | 38.7 | 114.5 | 6.5 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 4 | 21 | 88.8 | 395.9 | 4.2 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 8 | 41 | 144.3 | 749.2 | 3.5 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 16 | 81 | 250.2 | 1,451.1 | 3.1 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 39.1 | 158.5 | 3.9 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 4 | 37 | 90.5 | 571.0 | 2.4 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 8 | 73 | 146.7 | 1,099.2 | 2.0 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 39.8 | 246.4 | 2.2 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 4 | 69 | 92.9 | 921.5 | 1.3 |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 1 | 26 | 40.2 | 332.6 | 1.5 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 41.1 | 420.4 | 1.2 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 1: 37.1 | 32: 492.9 | 455.8 | 31 | 14.7 |
| volucer worker (warm, unix socket) | on | 1: 37.0 | 32: 493.5 | 456.5 | 31 | 14.7 |
| volucer attach (warm, unix relay) | on | 1: 38.8 | 32: 58.3 | 19.5 | 31 | 0.6 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 1: 37.0 | 32: 447.0 | 410.0 | 31 | 13.2 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 1: 37.0 | 32: 447.1 | 410.1 | 31 | 13.2 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 1: 38.7 | 16: 250.2 | 211.5 | 15 | 14.1 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1: 39.1 | 8: 146.7 | 107.6 | 7 | 15.4 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1: 39.8 | 4: 92.9 | 53.1 | 3 | 17.7 |

### Memory, after load (peak concurrency)

| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |
|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 1 | 2 | 45.4 | 67.6 | 22.7 |
| volucer worker (warm, pipe) | on | 4 | 5 | 105.3 | 220.7 | 21.1 |
| volucer worker (warm, pipe) | on | 8 | 9 | 175.2 | 421.6 | 19.5 |
| volucer worker (warm, pipe) | on | 16 | 17 | 312.0 | 824.7 | 18.4 |
| volucer worker (warm, pipe) | on | 24 | 25 | 446.9 | 1,227.5 | 17.9 |
| volucer worker (warm, pipe) | on | 32 | 33 | 579.7 | 1,628.6 | 17.6 |
| volucer worker (warm, unix socket) | on | 1 | 2 | 45.5 | 67.8 | 22.8 |
| volucer worker (warm, unix socket) | on | 4 | 5 | 105.6 | 221.1 | 21.1 |
| volucer worker (warm, unix socket) | on | 8 | 9 | 175.5 | 422.0 | 19.5 |
| volucer worker (warm, unix socket) | on | 16 | 17 | 312.3 | 825.3 | 18.4 |
| volucer worker (warm, unix socket) | on | 24 | 25 | 446.8 | 1,227.3 | 17.9 |
| volucer worker (warm, unix socket) | on | 32 | 33 | 581.5 | 1,630.4 | 17.6 |
| volucer attach (warm, unix relay) | on | 1 | 3 | 46.1 | 87.5 | 15.4 |
| volucer attach (warm, unix relay) | on | 4 | 6 | 53.7 | 156.2 | 9.0 |
| volucer attach (warm, unix relay) | on | 8 | 10 | 57.5 | 241.6 | 5.8 |
| volucer attach (warm, unix relay) | on | 16 | 18 | 68.8 | 415.5 | 3.8 |
| volucer attach (warm, unix relay) | on | 24 | 26 | 77.7 | 588.2 | 3.0 |
| volucer attach (warm, unix relay) | on | 32 | 34 | 85.9 | 762.5 | 2.5 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 1 | 2 | 44.1 | 65.9 | 22.1 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 4 | 5 | 104.3 | 219.5 | 20.9 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 8 | 9 | 174.3 | 419.8 | 19.4 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 16 | 17 | 312.4 | 825.0 | 18.4 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 24 | 25 | 444.9 | 1,224.9 | 17.8 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 32 | 33 | 580.1 | 1,630.2 | 17.6 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 1 | 2 | 44.3 | 66.2 | 22.1 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 4 | 5 | 103.4 | 218.6 | 20.7 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 8 | 9 | 176.4 | 422.8 | 19.6 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 16 | 17 | 309.4 | 821.9 | 18.2 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 24 | 25 | 444.5 | 1,224.4 | 17.8 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 32 | 33 | 578.1 | 1,626.2 | 17.5 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 1 | 6 | 50.8 | 169.1 | 8.5 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 4 | 21 | 129.4 | 644.2 | 6.2 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 8 | 41 | 214.4 | 1,258.7 | 5.2 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 16 | 81 | 384.2 | 2,488.1 | 4.7 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1 | 10 | 58.0 | 278.3 | 5.8 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 4 | 37 | 154.6 | 1,080.9 | 4.2 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 8 | 73 | 256.4 | 2,115.8 | 3.5 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1 | 18 | 70.6 | 493.2 | 3.9 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 4 | 69 | 189.9 | 1,932.0 | 2.8 |
| volucer spawn_cgi children (cold, unix), ch=24 | on | 1 | 26 | 82.7 | 712.0 | 3.2 |
| volucer spawn_cgi children (cold, unix), ch=32 | on | 1 | 34 | 89.8 | 916.6 | 2.6 |

### Marginal PSS per worker

| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |
|---|---|---|---|---|---|---|
| volucer worker (warm, pipe) | on | 1: 45.4 | 32: 579.7 | 534.3 | 31 | 17.2 |
| volucer worker (warm, unix socket) | on | 1: 45.5 | 32: 581.5 | 536.0 | 31 | 17.3 |
| volucer attach (warm, unix relay) | on | 1: 46.1 | 32: 85.9 | 39.8 | 31 | 1.3 |
| volucer spawn_cgi (cold, unix, 1/slot) | on | 1: 44.1 | 32: 580.1 | 536.0 | 31 | 17.3 |
| volucer spawn_cgi children (cold, unix), ch=1 | on | 1: 44.3 | 32: 578.1 | 533.8 | 31 | 17.2 |
| volucer spawn_cgi children (cold, unix), ch=4 | on | 1: 50.8 | 16: 384.2 | 333.4 | 15 | 22.2 |
| volucer spawn_cgi children (cold, unix), ch=8 | on | 1: 58.0 | 8: 256.4 | 198.4 | 7 | 28.3 |
| volucer spawn_cgi children (cold, unix), ch=16 | on | 1: 70.6 | 4: 189.9 | 119.3 | 3 | 39.8 |

## Integrity checks

No failed cells and no dropped responses in any measured cell.

