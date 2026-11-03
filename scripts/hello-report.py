#!/usr/bin/env python3
"""Summarise a `hello-bench.sh` run.

The run produces one row per (generator, arm, process count, concurrency, round):

    generator  arm  procs  conc  round  status  rps  p50  p99

`hello.tsv` is written by the shell; this script only reads it. The two things it must
never do are the two ways a benchmark like this goes wrong:

  * **Average a rate across rounds.** A host that drifts over twenty minutes makes every
    arm's absolute rate a function of when it ran. What is comparable between arms is a
    ratio measured *inside* one round, and what is reported is that ratio's median over
    rounds with its observed spread. The absolute rates are shown as context, never as
    the claim.

  * **Mix generators.** `wrk` and `autocannon` answer different questions (see the
    header of `hello-bench.sh`), so their rows are summarised separately and never
    averaged into one rate.

Usage:
    python3 scripts/hello-report.py ~/hello-bench-run/hello.tsv
    python3 scripts/hello-report.py ~/hello-bench-run/hello.tsv --baseline volucer+attach
    python3 scripts/hello-report.py ~/hello-bench-run/hello.tsv --markdown
"""

from __future__ import annotations

import argparse
import statistics
import sys
from collections import defaultdict
from pathlib import Path

COLUMNS = ["generator", "arm", "procs", "conc", "round", "status", "rps", "p50", "p99"]


def load(path: Path) -> list[dict]:
    rows: list[dict] = []
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        parts = line.split("\t")
        # A row that does not have the full width is a broken write, and a broken write
        # that is silently skipped turns into an arm missing from the comparison rather
        # than into an error. `bench.sh` has the same guard for the same reason.
        if len(parts) != len(COLUMNS):
            print(
                f"warning: {path.name}:{lineno}: {len(parts)} columns, expected "
                f"{len(COLUMNS)}; skipping: {line[:120]!r}",
                file=sys.stderr,
            )
            continue
        row = dict(zip(COLUMNS, parts))
        row["procs"] = int(row["procs"]) if row["procs"].isdigit() else None
        row["conc"] = int(row["conc"]) if row["conc"].isdigit() else None
        row["round"] = int(row["round"]) if row["round"].isdigit() else None
        row["ok"] = row["status"] == "OK"
        # Only the rate is parsed here. Latencies keep their unit on the wire
        # (`2.17ms`, `1.02s`) because `wrk` and `autocannon` print different ones, so
        # they are parsed per instrument by `parse_ms` rather than assumed to be
        # milliseconds.
        try:
            row["rps"] = float(row["rps"])
        except ValueError:
            row["rps"] = None
        rows.append(row)
    return rows


def parse_ms(value: str) -> float:
    """`wrk` writes latencies as `2.17ms` / `1.02s`; the row keeps its own unit."""
    value = value.strip()
    if value.endswith("ms"):
        return float(value[:-2])
    if value.endswith("us"):
        return float(value[:-2]) / 1000.0
    if value.endswith("s"):
        return float(value[:-1]) * 1000.0
    # autocannon prints a bare number, which is milliseconds.
    return float(value)


def ratio_spread(values: list[float]) -> tuple[float, float, float]:
    """Median and observed min/max of a list of ratios.

    The spread rather than a confidence interval, because the rounds are the sample and
    a benchmark host does not meet the independence assumption an interval would need.
    A range that contains 1.0 is reported as a tie — the same rule the published
    benchmark document uses, and for the same reason: a comparison whose rounds include
    equal throughput is not evidence of a difference.
    """
    values = [v for v in values if v is not None]
    if not values:
        return (float("nan"), float("nan"), float("nan"))
    return (statistics.median(values), min(values), max(values))


def group_key(row: dict) -> tuple:
    return (row["generator"], row["arm"], row["procs"], row["conc"])


def cells(rows: list[dict]) -> dict[tuple, list[dict]]:
    grouped: dict[tuple, list[dict]] = defaultdict(list)
    for row in rows:
        if row["ok"]:
            grouped[group_key(row)].append(row)
    return grouped


def rate_table(grouped: dict[tuple, list[dict]]) -> str:
    """Absolute rates, as context. Not the claim — see the module docstring."""
    lines = [
        "| generator | arm | procs | conc | rps (median of rounds) | p50 | p99 | rounds |",
        "|---|---|---:|---:|---:|---:|---:|---:|",
    ]
    for key in sorted(grouped, key=lambda k: (k[0], k[2] or 0, k[3] or 0, k[1])):
        generator, arm, procs, conc = key
        values = grouped[key]
        rps = statistics.median(v["rps"] for v in values if v["rps"] is not None)
        p50s = [parse_ms(v["p50"]) for v in values if v["p50"] is not None]
        p99s = [parse_ms(v["p99"]) for v in values if v["p99"] is not None]
        lines.append(
            f"| {generator} | {arm} | {procs} | {conc} | {rps:,.0f} | "
            f"{statistics.median(p50s):.2f} ms | {statistics.median(p99s):.2f} ms | {len(values)} |"
        )
    return "\n".join(lines)


def comparison(
    rows: list[dict], baseline: str | None, generator: str
) -> tuple[str, list[str]]:
    """Per-round ratios against the baseline, grouped by (procs, conc).

    Pairing inside a round is the whole estimator: two arms measured back to back on the
    same host share whatever the host was doing, and the ratio between them survives a
    drift that the absolute rates do not. The rotation makes the *order* of the two a
    fair coin, so a monotonic drift lands on both arms equally often.
    """
    by_round: dict[int, dict[tuple, float]] = defaultdict(dict)
    for row in rows:
        if not row["ok"] or row["generator"] != generator:
            continue
        by_round[row["round"]][(row["arm"], row["procs"], row["conc"])] = row["rps"]

    arms = sorted({row["arm"] for row in rows if row["ok"] and row["generator"] == generator})
    if baseline is None:
        baseline = arms[0] if arms else ""

    lines = [
        f"| procs | conc | arm | ratio vs `{baseline}` (median) | observed range | rounds | verdict |",
        "|---:|---:|---|---:|---|---:|---|",
    ]
    notes: list[str] = []

    keys = sorted({(row["procs"], row["conc"]) for row in rows if row["ok"] and row["generator"] == generator})
    for procs, conc in keys:
        base_arm_key = (baseline, procs, conc)
        for arm in arms:
            arm_key = (arm, procs, conc)
            ratios = []
            for round_index, measured in by_round.items():
                a = measured.get(base_arm_key)
                b = measured.get(arm_key)
                if a and b:
                    ratios.append(b / a)
            if not ratios:
                continue
            median, low, high = ratio_spread(ratios)
            # A verdict needs at least two paired rounds. One round is a point, not a
            # range, and reporting it as "faster" or "slower" is the mistake this whole
            # estimator exists to avoid: a single cell on this host is only good to
            # about ±2%, so a 3% difference from one round is indistinguishable from
            # drift.
            if len(ratios) < 2:
                verdict = "inconclusive (1 round)"
            elif low <= 1.0 <= high:
                verdict = "tie"
            elif median < 1.0:
                verdict = "slower"
            else:
                verdict = "faster"
            if arm == baseline:
                lines.append(f"| {procs} | {conc} | {arm} | — | — | {len(ratios)} | reference |")
                continue
            range_text = "—" if len(ratios) < 2 else f"{low:.3f}–{high:.3f}"
            ratio_text = "—" if len(ratios) < 2 else f"x{median:.3f}"
            lines.append(
                f"| {procs} | {conc} | {arm} | {ratio_text} | {range_text} | "
                f"{len(ratios)} | {verdict} |"
            )
            if len(ratios) < 3:
                notes.append(
                    f"`{arm}` at {procs} procs / c{conc}: only {len(ratios)} paired round(s), so "
                    "the range is what it is — two rounds cannot show a drift, only a difference."
                )
    return "\n".join(lines), notes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("table", type=Path, help="the hello.tsv written by hello-bench.sh")
    parser.add_argument(
        "--baseline",
        default=None,
        help="the arm every ratio is taken against (default: alphabetically first)",
    )
    parser.add_argument(
        "--generator",
        default="wrk",
        choices=["wrk", "autocannon"],
        help="which instrument's rows to summarise (default: wrk, the primary)",
    )
    args = parser.parse_args()

    if not args.table.is_file():
        print(f"no such file: {args.table}", file=sys.stderr)
        return 1

    rows = load(args.table)
    if not rows:
        print(f"{args.table} has no rows", file=sys.stderr)
        return 1

    grouped = cells(rows)
    failures = [row for row in rows if not row["ok"]]
    if failures:
        print(f"## {len(failures)} failed cells\n", file=sys.stderr)
        for row in failures:
            print(
                f"  {row['generator']} {row['arm']} procs={row['procs']} conc={row['conc']} "
                f"round={row['round']}: {row['status']}",
                file=sys.stderr,
            )
        print(file=sys.stderr)

    print("## Rates (context, not the claim)\n")
    print(rate_table(grouped))
    print()

    print(f"## Paired comparison — {args.generator}\n")
    table, notes = comparison(rows, args.baseline, args.generator)
    print(table)
    if notes:
        print()
        for note in notes:
            print(f"- {note}")

    if args.generator == "wrk":
        other = [row for row in rows if row["ok"] and row["generator"] != "wrk"]
        if other:
            print("\n## Cross-check — autocannon at the reference settings\n")
            print("A single-threaded generator with ten requests pipelined per connection.")
            print("Beside the wrk rows, never averaged with them.\n")
            other_grouped = cells(other)
            ac_table, _ = comparison(other, args.baseline, "autocannon")
            print(ac_table)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
