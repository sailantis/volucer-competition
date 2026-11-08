#!/usr/bin/env python3
"""Group matrix.tsv rows into cells without silently merging two configurations.

`matrix.tsv` identifies a cell by `(path, arm, workers, opcache, children,
conc)`. For seven of the eight arms `children` is empty, so `(arm, workers)`
happens to be unique and it is tempting to group on that alone. For
`volucer-prefork` it is not: `workers` is the number of *listening sockets* and
`children` is the number of processes behind each, so `w=1` names three
different cells (ch=8, ch=16, ch=32).

Grouping on `(arm, workers)` therefore averages those three into one number that
describes no configuration. It does not raise, and the result is plausible --
for `/items-fast` the blend is 9,000 rps against true values of 7,076 / 9,099 /
10,825 -- which is exactly why it needs a guard rather than a comment.

Use this module instead of hand-rolling a dict key:

    from matrix_cells import read_rows, cell_key, cell_mean

    rows = read_rows("results/matrix-final/matrix.tsv")
    cells = cell_mean(rows, arm="volucer-prefork", path="/items-fast", workers="1")
    for (kids, mean), ... in cells.items():   # one entry per children count

The guard refuses the ambiguous case rather than guessing:

    cell_key({"arm": "volucer-prefork", "workers": "1"})
    # -> MatrixCellError: volucer-prefork needs `children`; w=1 names 3 cells

Run this file directly to audit a TSV for cells that a `(arm, workers)` grouping
would have merged:

    python3 scripts/matrix_cells.py results/matrix-final/matrix.tsv
"""

import argparse
import sys
from collections import defaultdict

# The only arm whose `workers` is not a complete cell identity. Kept as data
# rather than a special case in each function so a second such arm is one edit.
AXIS_ARMS = frozenset({"volucer-prefork"})


class MatrixCellError(ValueError):
    """Raised when a grouping would merge two distinct configurations."""


def read_rows(path):
    """Read matrix.tsv into a list of dicts, parsing the unit-suffixed columns.

    `rps` is a plain float; `p50`/`p99` arrive as `5.98ms`, `840us` or `0.00us`,
    so `num()` normalises them to milliseconds. Blank fields stay `None` instead
    of becoming 0.0, because a missing measurement and a measured zero are
    different facts.
    """
    import csv

    def num(value):
        text = str(value or "").strip()
        if not text:
            return None
        try:
            return float(text)
        except ValueError:
            pass
        for suffix, scale in (("ms", 1.0), ("us", 0.001), ("ns", 0.000001), ("s", 1000.0)):
            if text.endswith(suffix):
                return float(text[: -len(suffix)]) * scale
        return None

    with open(path, newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh, delimiter="\t"))
    for row in rows:
        row["rps"] = num(row.get("rps"))
        row["p50"] = num(row.get("p50"))
        row["p99"] = num(row.get("p99"))
        row["errors"] = num(row.get("errors")) or 0
    return rows


def children_of(row):
    """The row's `children` as a string, or "" where the arm has no such axis."""
    return str(row.get("children", "") or "").strip()


def cell_key(row, part=None):
    """The identity of the cell a row belongs to.

    Returns `(path, arm, workers, opcache, children, conc)`, or the requested
    `part` of it. `children` is included for every arm -- empty for the seven
    that have no axis -- so one key shape works everywhere.

    Raises MatrixCellError when an arm in AXIS_ARMS arrives without `children`,
    because the key would then be ambiguous rather than merely incomplete.
    """
    arm = str(row.get("arm", "")).strip()
    kids = children_of(row)
    if arm in AXIS_ARMS and not kids:
        raise MatrixCellError(
            f"{arm} needs `children` to identify a cell: its `workers` counts "
            f"listening sockets, so w={row.get('workers')} is one of several "
            f"configurations. Read it with children_of() or group via group_cells()."
        )
    key = (
        str(row.get("path", "") or "").strip(),
        arm,
        str(row.get("workers", "") or "").strip(),
        str(row.get("opcache", "") or "").strip(),
        kids,
        str(row.get("conc", "") or "").strip(),
    )
    if part is None:
        return key
    names = ("path", "arm", "workers", "opcache", "children", "conc")
    return key[names.index(part)]


def group_cells(rows, by=("path", "arm", "workers", "children")):
    """Group rows into cells keyed by `by`, never merging an axis arm.

    `by` names cell_key parts; the default is the grouping most analyses want
    (one entry per configuration and path, rounds pooled). `children` is always
    appended if absent when an axis arm is present, so the merge cannot happen by
    forgetting it.
    """
    names = ("path", "arm", "workers", "opcache", "children", "conc")
    wanted = [n for n in by if n in names]
    if not wanted:
        raise ValueError(f"no usable grouping names in {by!r}; expected from {names}")

    has_axis = any(str(r.get("arm", "")).strip() in AXIS_ARMS for r in rows)
    if has_axis and "children" not in wanted:
        wanted.append("children")

    out = defaultdict(list)
    for row in rows:
        key = cell_key(row)
        out[tuple(key[names.index(n)] for n in wanted)].append(row)
    return dict(out), tuple(wanted)


def cell_mean(rows, **match):
    """Mean rps per `children` value, after filtering on any cell_key part.

    Keyed by `children` (empty string where the arm has no axis) so a caller who
    filters on `arm="volucer-prefork", workers="1"` still gets three entries
    instead of their average. Each value is `(mean_rps, n_rounds)`.
    """
    groups, _ = group_cells(rows, by=("children",))
    picked = {}
    for key, bucket in groups.items():
        (kids,) = key
        sample = [r for r in bucket if all(str(r.get(k, "") or "") == str(v) for k, v in match.items())]
        if not sample:
            continue
        values = [r["rps"] for r in sample if r.get("rps") is not None]
        if values:
            picked[kids] = (sum(values) / len(values), len(values))
    return picked


def merge_audit(rows):
    """Every `(arm, workers)` key that a naive grouping would have merged.

    Returns a list of `(arm, workers, children_counts, spread_pct)`, worst first.
    An empty list means the TSV has no arm where that mistake was possible.
    """
    seen = defaultdict(lambda: defaultdict(list))
    for row in rows:
        arm = str(row.get("arm", "")).strip()
        if arm not in AXIS_ARMS:
            continue
        seen[(arm, str(row.get("workers", "")).strip())][children_of(row)].append(row.get("rps"))

    out = []
    for (arm, workers), by_kids in seen.items():
        if len(by_kids) < 2:
            continue
        means = [sum(v) / len(v) for v in by_kids.values() if v]
        if len(means) < 2:
            continue
        lo, hi = min(means), max(means)
        spread = (hi - lo) / lo * 100 if lo else 0.0
        out.append((arm, workers, sorted(by_kids), spread))
    return sorted(out, key=lambda t: -t[3])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tsv", help="path to a matrix.tsv")
    args = parser.parse_args(argv)

    rows = read_rows(args.tsv)
    print(f"{args.tsv}: {len(rows)} rows")

    groups, names = group_cells(rows)
    print(f"cells grouped by {', '.join(names)}: {len(groups)}")

    merged = merge_audit(rows)
    if not merged:
        print("no arm has a second axis in this file -- (arm, workers) is safe here")
        return 0

    print("\n(arm, workers) keys that a naive grouping would have merged:")
    print(f"  {'arm':20}{'workers':>8}{'children':>22}{'spread':>9}")
    print("  " + "-" * 57)
    for arm, workers, kids, spread in merged:
        print(f"  {arm:20}{workers:>8}{','.join(kids):>22}{spread:>8.0f}%")
    print(
        "\nGrouping on (arm, workers) alone averages these into one number that "
        "describes\nno configuration. Cell identity needs `children` -- the spread "
        "above is what the\nmerge would have hidden."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
