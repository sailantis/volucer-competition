# Prefork versus one-process-per-slot: what `children` is worth

Raw rows: [`results/prefork-vs-slots.tsv`](../results/prefork-vs-slots.tsv).

The question the `children` key in the volucer repository answers: `spawn_cgi` could
set `PHP_FCGI_CHILDREN`, and forked children share the OPcache segment — is that worth a
new configuration key and a pool that admits more than one request per slot?

It was measured **before any of it was written**, because `external` already attaches to a
preforking `php-cgi -b`, so the comparison needs no code. Two shapes, PHP process count
held equal at **16**, opcache **on** (the production case, and the only case in which
shared compiled scripts exist — [matrix85-opcache](matrix85-opcache/report.md) records
opcache at ~10× for this arm, so measuring with it off would measure the wrong thing):

| shape   | config                                     | PHP processes          |
| ------- | ------------------------------------------ | ---------------------- |
| **S**   | `spawn_cgi`, `workers = 16`, no `children` | 16 separate slots      |
| **C16** | `external` → `PHP_FCGI_CHILDREN=16`        | 1 master + 16 children |

WSL2, 12 cores, PHP 8.3.35 (cgi-fcgi), `/items`, `wrk -t4`, 8 s per point, 2 interleaved
rounds. PSS is `smaps_rollup` summed over the server and every PHP process; **PSS rather
than RSS** because forked children share the inherited anonymous pages, so summing RSS would
count the OPcache segment once per child and report a saving that does not exist.

## Result

| shape                        | PSS after load   | rps @ c=64  | distinct pids serving |
| ---------------------------- | ---------------- | ----------- | --------------------- |
| S — 16 slots                 | **300 – 313 MB** | 3668 / 3850 | 16                    |
| C16 — 1 master × 16 children | **68 – 70 MB**   | 4543 / 4170 | 16                    |

**4.5–4.7× less memory for the same 16 PHP processes**, and throughput is within noise —
C16 slightly ahead at every concurrency in both rounds.

A third shape, 1 master × 4 children against a 4-way S, was measured in a separate run and is
in the volucer plan's hazard 86 rather than here: four processes cannot fill twelve cores, and
its measurement was there to confirm the C16 row is not a lucky one. An earlier run of the S-vs-C16
comparison, at 10 s per point over 3 rounds, measured **311–314 MB against 44 MB** — the same
conclusion with a larger gap. Neither of those is in the TSV below, which records the 8 s / 2-round
run whose numbers this table quotes.

`distinct pids` is the check that the children are real rather than a number in a config:
each shape reports exactly its process count, sampled from a probe that returns
`getmypid()`. **The probe has to be concurrent and has to write one file per response** —
`external` retains one idle connection, so twenty sequential probes are all answered by the
same warm child and report "1 pid" for a 16-child master. See hazard 86 for that defect and
for the other three the measurement corrected.

## What this does not decide

Throughput and memory are both measurable from `external`, and the existing numbers say the
two are comparable: `external` → prefork measured 8,202 rps against `spawn_cgi`'s 8,292 at
the same concurrency, 1% apart. What `external` **cannot** show is whether `max_requests`
recycling, per-slot restart and the lifecycle teardown still work with children present —
it has no slots. Those belong to the pool's own tests, not to this one:

- `children_lets_one_slot_serve_several_requests_at_once` — four requests in flight against
  one slot, with a `children = 0` control that must be slower.
- The teardown gate, measured separately: `SIGKILL` to a preforked master leaves every child
  alive (`php-cgi` installs its group-signalling handler for `SIGTERM` only), but **`killpg`
  reaches all of them** — 16 before, 0 after — because `setsid()` fails with `EPERM` on the
  process-group leader `process_group(0)` already made, and `cgi_main.c:2001` ignores the
  return value.
