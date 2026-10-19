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


ARM_ORDER = ["volucer-worker", "volucer-fastcgi", "rr", "frankenphp", "fpm"]
ARM_NAME = {
    "volucer-worker": "volucer worker (warm, pipe)",
    "volucer-fastcgi": "volucer spawn_cgi (cold, unix)",
    "rr": "RoadRunner worker (warm, pipe)",
    "frankenphp": "FrankenPHP worker (warm, embedded)",
    "fpm": "nginx + php-fpm (cold, unix)",
}


def arm_sort(arms):
    return sorted(arms, key=lambda a: (ARM_ORDER.index(a) if a in ARM_ORDER else 99, a))


def table_throughput(rows, metric, digits, concurrency, transform=None):
    transform = transform or num
    cells = defaultdict(list)
    spread_cells = defaultdict(list)
    arms, workers, modes = set(), set(), set()
    for r in rows:
        if r["conc"] != concurrency or r["rps"] == "FAIL":
            continue
        key = (r["arm"], r["opcache"], r["workers"])
        cells[key].append(transform(r[metric]))
        spread_cells[key].append(transform(r[metric]))
        arms.add(r["arm"])
        workers.add(r["workers"])
        modes.add(r["opcache"])

    out = []
    out.append(f"### {metric} at concurrency {concurrency}")
    out.append("")
    head = "| arm | opcache | " + " | ".join(f"w={w}" for w in ordered(workers)) + " |"
    out.append(head)
    out.append("|" + "---|" * (2 + len(workers)))
    for arm in arm_sort(arms):
        for mode in sorted(modes):
            line = [ARM_NAME.get(arm, arm), mode]
            for w in ordered(workers):
                vals = cells.get((arm, mode, w))
                if not vals:
                    line.append("—")
                    continue
                value = med(vals)
                sp = spread(spread_cells[(arm, mode, w)])
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
        key = (r["arm"], r["opcache"], r["workers"])
        # Several post-load samples per configuration (one per round); the median
        # describes the steady state rather than whichever round was busiest.
        cells.setdefault(key, {"pss": [], "rss": [], "pids": []})
        cells[key]["pss"].append(num(r["pss_mb"]))
        cells[key]["rss"].append(num(r["rss_mb"]))
        cells[key]["pids"].append(num(r["pids"]))
        arms.add(r["arm"])
        workers.add(r["workers"])
        modes.add(r["opcache"])

    label = "boot (before any request)" if phase == "boot" else "after load (peak concurrency)"
    out = [f"### Memory, {label}", ""]
    out.append("| arm | opcache | workers | processes | PSS MB | RSS MB | PSS/process |")
    out.append("|---|---|---|---|---|---|---|")
    for arm in arm_sort(arms):
        for mode in sorted(modes):
            for w in ordered(workers):
                c = cells.get((arm, mode, w))
                if not c:
                    continue
                pss = med(c["pss"])
                rss = med(c["rss"])
                pids = med(c["pids"])
                per = (pss / pids) if (pss and pids) else None
                out.append(
                    "| " + " | ".join(
                        [
                            ARM_NAME.get(arm, arm),
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
        for mode in sorted(modes):
            ws = [w for w in ordered(workers) if (arm, mode, w) in cells]
            if len(ws) < 2:
                continue
            lo, hi = ws[0], ws[-1]
            p_lo = med(cells[(arm, mode, lo)]["pss"])
            p_hi = med(cells[(arm, mode, hi)]["pss"])
            d_w = int(hi) - int(lo)
            if p_lo is None or p_hi is None or d_w <= 0:
                continue
            out.append(
                "| " + " | ".join(
                    [
                        ARM_NAME.get(arm, arm),
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
        cells[(r["arm"], r["workers"])].setdefault(r["opcache"], []).append(num(r["rps"]))
        arms.add(r["arm"])
        workers.add(r["workers"])

    out = [f"### opcache effect at concurrency {concurrency} (rps on / rps off)", ""]
    out.append("| arm | " + " | ".join(f"w={w}" for w in ordered(workers)) + " |")
    out.append("|" + "---|" * (1 + len(workers)))
    for arm in arm_sort(arms):
        line = [ARM_NAME.get(arm, arm)]
        for w in ordered(workers):
            on = med(cells.get((arm, w), {}).get("on", []))
            off = med(cells.get((arm, w), {}).get("off", []))
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
        cells[(r["arm"], r["workers"], r["opcache"], r["conc"])].append(num(r["rps"]))

    arms = arm_sort({r["arm"] for r in rows})
    workers = ordered({r["workers"] for r in rows})
    concs = ordered({r["conc"] for r in rows})
    modes = sorted({r["opcache"] for r in rows})

    out = ["## Headline readings", ""]
    out.append("### Best configuration per arm")
    out.append("")
    out.append("| arm | rps | workers | opcache | concurrency |")
    out.append("|---|---|---|---|---|")
    for arm in arms:
        best = None
        for w in workers:
            for mode in modes:
                for c in concs:
                    v = med(cells.get((arm, w, mode, c), []))
                    if v is not None and (best is None or v > best[0]):
                        best = (v, w, mode, c)
        if best:
            out.append(f"| {ARM_NAME.get(arm, arm)} | {fmt(best[0])} | {best[1]} | "
                       f"{best[2]} | {best[3]} |")
    out.append("")

    if len(workers) > 1 and concs:
        top = concs[-1]
        out.append(f"### Does another worker help? (concurrency {top}, opcache on)")
        out.append("")
        out.append("| arm | " + " | ".join(f"w={w}" for w in workers) + " | peak | change from w=%s |"
                   % workers[0])
        out.append("|" + "---|" * (3 + len(workers)))
        for arm in arms:
            vals = [(w, med(cells.get((arm, w, "on", top), []))) for w in workers]
            vals = [(w, v) for w, v in vals if v is not None]
            if len(vals) < 2:
                continue
            peak_w, peak_v = max(vals, key=lambda t: t[1])
            first = dict(vals)[workers[0]] if workers[0] in dict(vals) else None
            change = f"{(peak_v / first - 1) * 100:+.1f}%" if first else "—"
            line = [ARM_NAME.get(arm, arm)]
            line += [fmt(v) for _, v in vals]
            line += [f"w={peak_w}", change]
            out.append("| " + " | ".join(line) + " |")
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
    out.append("# Worker / opcache / concurrency matrix")
    out.append("")
    out.append(f"Rows: `{matrix_path}`. Memory: `{mem_path}`.")
    out.append("")
    out.append("Every cell is the **median over the rounds**, with the min–max spread across")
    out.append("rounds in parentheses where there was more than one round. `p50` and `p99` are")
    out.append("each their own median across the rounds of that cell — not the percentile of")
    out.append("whichever round happened to have the median throughput.")
    out.append("")

    out.append("## Throughput (requests/sec)")
    out.append("")
    for c in concs:
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

    out.append("## opcache")
    out.append("")
    for c in concs:
        out += table_opcache(rows, c)

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
