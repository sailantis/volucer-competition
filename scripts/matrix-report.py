#!/usr/bin/env python3
"""Turn matrix.tsv + memory.tsv into the tables the matrix exists to produce.

The raw rows are one per (arm, workers, opcache, conc, round) and one per
(arm, workers, opcache, phase, conc). Nothing here re-measures or smooths:
each cell is the MEDIAN over rounds, and the spread across rounds is printed
beside it, because a median with no error bar cannot distinguish a 3% effect
from a host that drifted while the arms ran.

Three tables are the point of the run:

  throughput   one table per concurrency: rows are (arm, opcache), columns are
               the worker counts. This is the answer to "how many workers".
  memory       PSS and RSS of the whole process tree, boot and after load.
               Both, because RSS charges a shared page once per process and so
               penalises 24 spawned PHP processes against an embedded runtime;
               PSS is the honest cross-model figure and the difference between
               the two is itself a finding about the process model.
  opcache      the ON/OFF ratio at each configuration, which is the other axis:
               what compiled-script reuse is worth when the framework boots per
               request (cold arms) versus once (warm arms).

Usage:
  python3 scripts/matrix-report.py [matrix.tsv] [memory.tsv] [--out report.md]
"""

import argparse
import os
import statistics
import sys
from collections import defaultdict


def read_tsv(path):
    rows = []
    with open(path, encoding="utf-8") as fh:
        header = None
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            cells = line.split("\t")
            if header is None:
                header = cells
                continue
            rows.append(dict(zip(header, cells)))
    return rows


def num(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def ms(value):
    """wrk writes latencies with a unit suffix (`689.00us`, `1.40ms`, `1.10s`).

    They are compared across arms, so everything is normalised to milliseconds;
    a raw float would make `1.40ms` and `689us` look like 1.4 and 689 of the same
    thing, which is a 1000x error in the direction of whichever arm happened to
    land either side of the unit boundary.
    """
    if value is None:
        return None
    text = str(value).strip()
    if not text or text == "?":
        return None
    for suffix, scale in (("us", 0.001), ("ms", 1.0), ("s", 1000.0)):
        if text.endswith(suffix):
            try:
                return float(text[: -len(suffix)]) * scale
            except ValueError:
                return None
    return num(text)


def med(values):
    vals = [v for v in values if v is not None]
    return statistics.median(vals) if vals else None


def spread(values):
    vals = [v for v in values if v is not None]
    if len(vals) < 2:
        return None
    return min(vals), max(vals)


def fmt(value, digits=0):
    if value is None:
        return "—"
    if digits == 0:
        return f"{value:,.0f}"
    return f"{value:,.{digits}f}"


def ordered(values):
    """Worker counts / concurrencies in numeric order, regardless of input order."""
    seen = []
    for v in values:
        if v not in seen:
            seen.append(v)
    return sorted(seen, key=lambda x: int(x))


ARM_ORDER = [
    "volucer-worker",
    "volucer-unix",
    "volucer-attach",
    "volucer-fastcgi",
    "volucer-prefork",
    "rr",
    "frankenphp",
    "fpm",
]
ARM_NAME = {
    "volucer-worker": "volucer worker (warm, pipe)",
    "volucer-unix": "volucer worker (warm, unix socket)",
    "volucer-attach": "volucer attach (warm, unix relay)",
    "volucer-fastcgi": "volucer spawn_cgi (cold, unix, 1/slot)",
    "volucer-prefork": "volucer spawn_cgi children (cold, unix)",
    "rr": "RoadRunner worker (warm, pipe)",
    "frankenphp": "FrankenPHP worker (warm, embedded)",
    "fpm": "nginx + php-fpm (cold, unix)",
}


def arm_sort(arms):
    return sorted(arms, key=lambda a: (ARM_ORDER.index(a) if a in ARM_ORDER else 99, a))


def child_of(row):
    """The `children` a row was measured at, as a string, or "".

    Only `volucer-prefork` has the axis. Older runs have no column at all, and the
    other arms genuinely have no setting, so "" is the truthful value rather than a
    default that would imply they were configured at one child.
    """
    return str(row.get("children", "") or "").strip()


def arm_label(arm, children):
    """The row label, with the second axis only where it exists.

    A `volucer-prefork` run at `workers = 16` is a different cell depending on
    whether four processes sit behind each listening socket or one, so the number
    belongs in the label rather than in a column that would be empty for seven of
    the eight arms.
    """
    name = ARM_NAME.get(arm, arm)
    return f"{name}, ch={children}" if children else name


def child_groups(rows):
    """`children` values per arm, in numeric order, as strings."""
    out = defaultdict(set)
    for r in rows:
        out[r["arm"]].add(child_of(r))
    return {arm: sorted(vals, key=lambda x: int(x) if x.isdigit() else -1)
            for arm, vals in out.items()}


def table_throughput(rows, metric, digits, concurrency, transform=None):
    transform = transform or num
    cells = defaultdict(list)
    arms, workers, modes = set(), set(), set()
    for r in rows:
        if r["conc"] != concurrency or r["rps"] == "FAIL":
            continue
        key = (r["arm"], child_of(r), r["opcache"], r["workers"])
        cells[key].append(transform(r[metric]))
        arms.add(r["arm"])
        workers.add(r["workers"])
        modes.add(r["opcache"])

    groups = child_groups(rows)
    out = []
    out.append(f"### {metric} at concurrency {concurrency}")
    out.append("")
    head = "| arm | opcache | " + " | ".join(f"w={w}" for w in ordered(workers)) + " |"
    out.append(head)
    out.append("|" + "---|" * (2 + len(workers)))
    for arm in arm_sort(arms):
        for children in groups.get(arm, [""]):
            for mode in sorted(modes):
                line = [arm_label(arm, children), mode]
                for w in ordered(workers):
                    vals = cells.get((arm, children, mode, w))
                    if not vals:
                        line.append("—")
                        continue
                    value = med(vals)
                    sp = spread(vals)
                    if sp and len(vals) > 1:
                        line.append(f"{fmt(value, digits)} ({fmt(sp[0], digits)}–{fmt(sp[1], digits)})")
                    else:
                        line.append(fmt(value, digits))
                out.append("| " + " | ".join(line) + " |")
    out.append("")
    return out


def table_memory(mem_rows, phase):
    cells = {}
    arms, workers, modes = set(), set(), set()
    for r in mem_rows:
        if r["phase"] != phase:
            continue
        key = (r["arm"], child_of(r), r["opcache"], r["workers"])
        # Several post-load samples per configuration (one per round); the median
        # describes the steady state rather than whichever round was busiest.
        cells.setdefault(key, {"pss": [], "rss": [], "pids": []})
        cells[key]["pss"].append(num(r["pss_mb"]))
        cells[key]["rss"].append(num(r["rss_mb"]))
        cells[key]["pids"].append(num(r["pids"]))
        arms.add(r["arm"])
        workers.add(r["workers"])
        modes.add(r["opcache"])

    groups = child_groups(mem_rows)
    label = "boot (before any request)" if phase == "boot" else "after load (peak concurrency)"
    out = [f"### Memory, {label}", ""]
    out.append("| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |")
    out.append("|---|---|---|---|---|---|---|")
    for arm in arm_sort(arms):
        for children in groups.get(arm, [""]):
            for mode in sorted(modes):
                for w in ordered(workers):
                    c = cells.get((arm, children, mode, w))
                    if not c:
                        continue
                    pss = med(c["pss"])
                    rss = med(c["rss"])
                    pids = med(c["pids"])
                    per = (pss / pids) if (pss and pids) else None
                    out.append(
                        "| " + " | ".join(
                            [
                                arm_label(arm, children),
                                mode,
                                str(w),
                                fmt(pids),
                                fmt(pss, 1),
                                fmt(rss, 1),
                                fmt(per, 1),
                            ]
                        ) + " |"
                    )
    out.append("")

    # The marginal cost of one more worker is the number that generalises: the
    # totals carry a fixed base (the server binary, the master process), which a
    # deployment at a different worker count does not pay again.
    out.append("### Marginal PSS per worker")
    out.append("")
    out.append("| arm | opcache | PSS at min workers | PSS at max workers | Δ PSS MB | Δ workers | MB per worker |")
    out.append("|---|---|---|---|---|---|---|")
    for arm in arm_sort(arms):
        for children in groups.get(arm, [""]):
            for mode in sorted(modes):
                ws = [w for w in ordered(workers) if (arm, children, mode, w) in cells]
                if len(ws) < 2:
                    continue
                lo, hi = ws[0], ws[-1]
                p_lo = med(cells[(arm, children, mode, lo)]["pss"])
                p_hi = med(cells[(arm, children, mode, hi)]["pss"])
                d_w = int(hi) - int(lo)
                if p_lo is None or p_hi is None or d_w <= 0:
                    continue
                out.append(
                    "| " + " | ".join(
                        [
                            arm_label(arm, children),
                            mode,
                            f"{lo}: {fmt(p_lo, 1)}",
                            f"{hi}: {fmt(p_hi, 1)}",
                            fmt(p_hi - p_lo, 1),
                            str(d_w),
                            fmt((p_hi - p_lo) / d_w, 1),
                        ]
                    ) + " |"
                )
    out.append("")
    return out


def table_opcache(rows, concurrency):
    """ON/OFF ratio per (arm, workers) at one concurrency — the axis's answer."""
    cells = defaultdict(dict)
    arms, workers = set(), set()
    for r in rows:
        if r["conc"] != concurrency or r["rps"] == "FAIL":
            continue
        key = (r["arm"], child_of(r), r["workers"])
        cells[key].setdefault(r["opcache"], []).append(num(r["rps"]))
        arms.add(r["arm"])
        workers.add(r["workers"])

    groups = child_groups(rows)
    out = [f"### opcache effect at concurrency {concurrency} (rps on / rps off)", ""]
    out.append("| arm | " + " | ".join(f"w={w}" for w in ordered(workers)) + " |")
    out.append("|" + "---|" * (1 + len(workers)))
    for arm in arm_sort(arms):
        for children in groups.get(arm, [""]):
            line = [arm_label(arm, children)]
            for w in ordered(workers):
                on = med(cells.get((arm, children, w), {}).get("on", []))
                off = med(cells.get((arm, children, w), {}).get("off", []))
                if on is None or off is None or off == 0:
                    line.append("—")
                    continue
                line.append(f"{on / off:.2f}×")
            out.append("| " + " | ".join(line) + " |")
    out.append("")
    return out


def table_headlines(rows):
    """Best cell per arm, and the per-worker scaling at the top concurrency.

    The tables above answer "what happened in each cell". These two answer the
    questions the matrix was run to settle — how many workers to configure, and
    what the best configuration is per server — so a reader does not have to scan
    a 10x4 grid to find the maximum.
    """
    cells = defaultdict(list)
    for r in rows:
        if r["rps"] == "FAIL":
            continue
        cells[(r["arm"], child_of(r), r["workers"], r["opcache"], r["conc"])].append(num(r["rps"]))

    arms = arm_sort({r["arm"] for r in rows})
    groups = child_groups(rows)
    workers = ordered({r["workers"] for r in rows})
    concs = ordered({r["conc"] for r in rows})
    modes = sorted({r["opcache"] for r in rows})

    out = ["## Headline readings", ""]
    out.append("### Best configuration per arm")
    out.append("")
    out.append("| arm | rps | workers | children | opcache | concurrency |")
    out.append("|---|---|---|---|---|---|")
    for arm in arms:
        for children in groups.get(arm, [""]):
            best = None
            for w in workers:
                for mode in modes:
                    for c in concs:
                        v = med(cells.get((arm, children, w, mode, c), []))
                        if v is not None and (best is None or v > best[0]):
                            best = (v, w, mode, c)
            if best:
                out.append(f"| {ARM_NAME.get(arm, arm)} | {fmt(best[0])} | {best[1]} | "
                           f"{children or '—'} | {best[2]} | {best[3]} |")
    out.append("")

    if len(workers) > 1 and concs:
        top = concs[-1]
        out.append(f"### Does another worker help? (concurrency {top}, opcache on)")
        out.append("")
        out.append("| arm | " + " | ".join(f"w={w}" for w in workers) + " | peak | change from w=%s |"
                   % workers[0])
        out.append("|" + "---|" * (3 + len(workers)))
        for arm in arms:
            for children in groups.get(arm, [""]):
                vals = [(w, med(cells.get((arm, children, w, "on", top), []))) for w in workers]
                present = {w: v for w, v in vals if v is not None}
                if len(present) < 2:
                    continue
                peak_w, peak_v = max(present.items(), key=lambda t: t[1])
                first = present.get(workers[0])
                change = f"{(peak_v / first - 1) * 100:+.1f}%" if first else "—"
                line = [arm_label(arm, children)]
                # A missing level is printed as a gap rather than skipped: these
                # rows have different measured ranges (`children` trades sockets
                # for processes, and the process cap ends some ladders early), and
                # a row that shifts left would line its numbers up under the wrong
                # worker count.
                line += [fmt(present[w]) if w in present else "—" for w in workers]
                line += [f"w={peak_w}", change]
                out.append("| " + " | ".join(line) + " |")
        out.append("")
    return out


def thread_values(rows):
    """Distinct `threads` values, in numeric order.

    Older runs have no such column: they are the fixed-thread runs, and a single
    "all cells" group is the right reading for them.
    """
    vals = {r.get("threads", "") for r in rows if r.get("threads", "")}
    return sorted(vals, key=lambda x: int(x) if str(x).isdigit() else 0)


def table_threads(rows, concurrency):
    """Is the p99 the server's, or the load generator's?

    `wrk -t$conc` gives every concurrent request its own client thread, so nothing
    queues in the client. At c=64 on a 12-core host that is also 64 busy threads
    competing for the cores the server is being measured on, so the tail may be
    the client's. Holding `-t12` makes the client cost constant and moves the
    question to the server. Both are measured; this is the table that says whether
    the choice mattered.
    """
    cells = defaultdict(list)
    arms, workers, modes, tvals = set(), set(), set(), set()
    for r in rows:
        if r["conc"] != concurrency or r["rps"] == "FAIL":
            continue
        cells[(r["arm"], child_of(r), r["opcache"], r["workers"], r["threads"])].append(r)
        arms.add(r["arm"])
        workers.add(r["workers"])
        modes.add(r["opcache"])
        tvals.add(r["threads"])

    groups = child_groups(rows)
    out = [
        f"### wrk thread count at concurrency {concurrency} "
        f"(rps | p50 ms | p99 ms)",
        "",
    ]
    out.append("| arm | opcache | workers | " + " | ".join(f"t={t}" for t in thread_values(rows)) + " |")
    out.append("|" + "---|" * (3 + len(tvals)))
    for arm in arm_sort(arms):
        for children in groups.get(arm, [""]):
            for mode in sorted(modes):
                for w in ordered(workers):
                    line = [arm_label(arm, children), mode, str(w)]
                    for t in thread_values(rows):
                        got = cells.get((arm, children, mode, w, t))
                        if not got:
                            line.append("—")
                            continue
                        rps = med([num(x["rps"]) for x in got])
                        p50 = med([ms(x["p50"]) for x in got])
                        p99 = med([ms(x["p99"]) for x in got])
                        line.append(f"{fmt(rps)} ({fmt(p50, 2)} / {fmt(p99, 2)})")
                    out.append("| " + " | ".join(line) + " |")
    out.append("")
    out.append("Each cell is `rps (p50 / p99)`. Where the columns differ, the choice of")
    out.append("thread count was a variable and not a constant.")
    out.append("")
    return out


def fmt_pct(value):
    return "—" if value is None else f"{value:+.1f}%"


def table_shape_pairs(rows, mem_rows, concurrency):
    """The questions the run exists to answer, as ratios between matched rows.

    Each pair differs in exactly one thing, and the ratio is taken at the same
    worker count and the same concurrency, so the number is that thing:

      unix / worker        the transport, with the process model held constant
      attach / worker      the memory model: fork() shares one OPcache segment
      prefork ch=1 / fastcgi   the control: the same config expressed through the
                           new key must measure the same, or `children = 1` is a
                           silent behaviour change rather than an alias
      prefork ch=N / prefork ch=1   what prefork itself buys inside a slot

    A ratio is only printed where both cells exist; the process cap ends the
    prefork ladders early, and inventing a comparison against a missing cell
    would be the one number in this file that is not measured.
    """
    by = {}
    for r in rows:
        if r["conc"] != concurrency or r["rps"] == "FAIL":
            continue
        key = (r["arm"], child_of(r), r["workers"], r["opcache"])
        by.setdefault(key, []).append(num(r["rps"]))
    rps = {k: med(v) for k, v in by.items()}

    mem = {}
    for r in mem_rows:
        if r["phase"] != "post":
            continue
        mem.setdefault((r["arm"], child_of(r), r["workers"], r["opcache"]), []).append(num(r["pss_mb"]))
    pss = {k: med(v) for k, v in mem.items()}

    workers = ordered({r["workers"] for r in rows})
    pairs = [
        ("transport: unix vs pipe", "volucer-unix", "", "volucer-worker", ""),
        ("memory model: attach vs pipe", "volucer-attach", "", "volucer-worker", ""),
        ("control: children=1 vs plain spawn_cgi", "volucer-prefork", "1", "volucer-fastcgi", ""),
    ]
    for ch in sorted({child_of(r) for r in rows
                      if r["arm"] == "volucer-prefork" and child_of(r)},
                     key=lambda x: int(x) if x.isdigit() else 0):
        if ch != "1":
            pairs.append((f"prefork: children={ch} vs children=1", "volucer-prefork", ch,
                          "volucer-prefork", "1"))

    out = [
        f"### Shape comparisons at concurrency {concurrency}",
        "",
        "Each row is one arm divided by another at the same worker count, so the ratio",
        "is the single thing that differs between them. `PSS` is the same ratio for",
        "summed PSS after load.",
        "",
    ]
    out.append("| comparison | metric | " + " | ".join(f"w={w}" for w in workers) + " |")
    out.append("|" + "---|" * (2 + len(workers)))
    for label, a_arm, a_ch, b_arm, b_ch in pairs:
        cells, memcells = [], []
        for w in workers:
            a = rps.get((a_arm, a_ch, w, "on"))
            b = rps.get((b_arm, b_ch, w, "on"))
            cells.append(fmt_pct((a / b - 1) * 100) if a and b else "—")
            am = pss.get((a_arm, a_ch, w, "on"))
            bm = pss.get((b_arm, b_ch, w, "on"))
            memcells.append(fmt_pct((am / bm - 1) * 100) if am and bm else "—")
        out.append("| " + " | ".join([label, "rps"] + cells) + " |")
        out.append("| " + " | ".join(["", "PSS"] + memcells) + " |")
    out.append("")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("matrix", nargs="?", default=None)
    ap.add_argument("memory", nargs="?", default=None)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    run = os.environ.get("RUNDIR", os.path.expanduser("~/matrix-run"))
    matrix_path = args.matrix or os.path.join(run, "matrix.tsv")
    mem_path = args.memory or os.path.join(run, "memory.tsv")
    if not os.path.isfile(matrix_path):
        sys.exit(f"no matrix rows at {matrix_path} (pass the path, or set RUNDIR)")

    rows = [r for r in read_tsv(matrix_path)]
    mem_rows = read_tsv(mem_path) if os.path.isfile(mem_path) else []
    concs = ordered({r["conc"] for r in rows if r["rps"] != "FAIL"})

    out = []
    out.append("# Worker x children x concurrency matrix, PHP 8.5")
    out.append("")
    out.append("Five volucer shapes, one server, one page, one host. The point of the run is")
    out.append("that every row is the *same* server with one thing changed, so a difference")
    out.append("between two rows is that thing:")
    out.append("")
    out.append("| arm | transport | process model | what it isolates |")
    out.append("|---|---|---|---|")
    out.append("| `volucer-worker` | pipe | one `exec` per worker | the baseline |")
    out.append("| `volucer-unix` | unix socket | one `exec` per worker | the transport |")
    out.append("| `volucer-attach` | unix relay | one boot, `fork()` per connection | the memory model |")
    out.append("| `volucer-fastcgi` | unix socket | one `php-cgi` per slot | the SAPI reset per request |")
    out.append("| `volucer-prefork` | unix socket | `php-cgi` + `children` per slot | fork inside a cold slot |")
    out.append("")
    out.append(f"Rows: `{matrix_path}`. Memory: `{mem_path}`.")
    out.append("")
    out.append("Every cell is the **median over the rounds**, with the min–max spread across")
    out.append("rounds in parentheses where there was more than one round. `p50` and `p99` are")
    out.append("each their own median across the rounds of that cell — not the percentile of")
    out.append("whichever round happened to have the median throughput.")
    out.append("")
    if any(child_of(r) for r in rows):
        out.append("`ch=N` marks the `children` axis, which only `volucer-prefork` has: there")
        out.append("`workers` counts listening sockets and `children` counts `php-cgi` processes")
        out.append("behind each, so `w=16 ch=4` is one master, four children, per socket. Every")
        out.append("other arm leaves it empty because it has no such setting.")
        out.append("")

    out.append("## Throughput (requests/sec)")
    out.append("")
    tvals = thread_values(rows)
    for c in concs:
        # `wrk` refuses `-c` below `-t`, so a concurrency level under the fixed
        # thread count is measured at `-t{conc}` instead. That is a real variable,
        # but only at *that* level: splitting every table on it would add a mostly
        # empty column to five levels that were measured at one thread count. So
        # the split happens per level, where the variation exists.
        per_level = {r["threads"] for r in rows
                     if r["conc"] == c and r["rps"] != "FAIL"}
        if len(per_level) > 1:
            out += table_threads(rows, c)
        else:
            out += table_throughput(rows, "rps", 0, c)

    out += table_headlines(rows)

    out.append("## Latency, p50 (ms)")
    out.append("")
    for c in concs:
        out += table_throughput(rows, "p50", 3, c, transform=ms)

    out.append("## Latency, p99 (ms)")
    out.append("")
    for c in concs:
        out += table_throughput(rows, "p99", 3, c, transform=ms)

    # The opcache axis only exists when both modes were measured. A run that pins
    # `OPCACHE_MODES=on` — which is the right choice when the question is the
    # process model rather than the compiler — would otherwise print a table of
    # dashes that reads like a failed measurement.
    if len({r["opcache"] for r in rows}) > 1:
        out.append("## opcache")
        out.append("")
        for c in concs:
            out += table_opcache(rows, c)
    else:
        out.append("## opcache")
        out.append("")
        mode = sorted({r["opcache"] for r in rows})[0]
        out.append(f"Every cell in this run was measured with opcache **{mode}**, which is the")
        out.append("production case and the only one where a shared OPcache segment can exist —")
        out.append("so the ON/OFF ratio is not a column here. The committed 8.5 matrix measures")
        out.append("that axis for the same arms (`results/matrix85/report.md`).")
        out.append("")

    out.append("## Shape comparisons")
    out.append("")
    for c in concs:
        out += table_shape_pairs(rows, mem_rows, c)

    out.append("## Memory")
    out.append("")
    if mem_rows:
        out += table_memory(mem_rows, "boot")
        out += table_memory(mem_rows, "post")
    else:
        out.append("_no memory samples recorded_")
        out.append("")

    errors = [r for r in rows if r["rps"] == "FAIL" or (num(r["errors"]) or 0) > 0]
    out.append("## Integrity checks")
    out.append("")
    if errors:
        out.append(f"**{len(errors)} cell(s) reported failures or dropped responses.** "
                   "A cell with `Non-2xx` responses is a pool shedding load, which is a")
        out.append("throughput number that looks like the fix working; it is listed here rather")
        out.append("than silently averaged in.")
        out.append("")
        out.append("| arm | workers | opcache | conc | round | rps | errors |")
        out.append("|---|---|---|---|---|---|---|")
        for r in sorted(errors, key=lambda r: (r["arm"], int(r["workers"]), r["opcache"],
                                               int(r["conc"]), int(r["round"]))):
            out.append(f"| {r['arm']} | {r['workers']} | {r['opcache']} | {r['conc']} | "
                       f"{r['round']} | {r['rps']} | {r['errors']} |")
    else:
        out.append("No failed cells and no dropped responses in any measured cell.")
    out.append("")

    text = "\n".join(out)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
        print(f"wrote {args.out}")
    else:
        print(text)


if __name__ == "__main__":
    main()
