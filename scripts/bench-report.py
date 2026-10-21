#!/usr/bin/env python3
"""Turn a benchmark run into a publishable report: Markdown plus SVG charts.

The pattern is the one ``azera-competition`` established, reimplemented on this
repository's data: a generator that reads the committed result files, prints the
tables a page needs, and draws the charts — so a page is never edited by hand
and never claims a number the data does not contain.

Usage:
    python3 scripts/bench-report.py                      # every view
    python3 scripts/bench-report.py --view=throughput    # one view
    python3 scripts/bench-report.py --list               # list the views
    python3 scripts/bench-report.py --out=<dir>          # somewhere else
    python3 scripts/bench-report.py --publish=volucer    # write into volucer/docs

Output (default ``results/bench-report/``):
    <view>.md              the Markdown fragment, ready to publish
    svg/<view>/*.svg       the charts

**The honesty rules this generator follows**, each one a rule the numbers have
to obey rather than a style:

- **A cell with no successful repeat is printed as ``-``, never as ``0``.** A zero
  reads as "measured, and it was terrible" rather than "not measured".
- **Every chart states the host, the method and the date it was measured.**
- **The median is the median of the repeats, and the spread is printed beside
  it** where there was more than one round — a median with no error bar cannot
  distinguish a 3% effect from a host that drifted while the arms ran.
"""

from __future__ import annotations

import argparse
import os
import statistics
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from svgchart import grouped_bars, range_bars, throughput_dots, write  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "results"

# The arms the five-way comparison uses, in the order a page reads them.
ARMS = {
    "P": ("volucer", "worker (warm, pipe)"),
    "R": ("RoadRunner", "worker (warm, pipe)"),
    "F": ("nginx + php-fpm", "cold, unix socket"),
    "T": ("volucer", "spawn_cgi (cold, TCP)"),
    "U": ("volucer", "spawn_cgi (cold, unix)"),
}

# One colour per server, so an arm is the same colour in every chart on the page.
ARM_COLORS = {
    "P": "#2563eb",
    "R": "#0d9488",
    "F": "#94a3b8",
    "T": "#7c3aed",
    "U": "#c2410c",
}

CONCURRENCIES = [1, 4, 8, 16, 32]


def load_provenance() -> dict:
    """The host and method a run was measured on, read from ``results/report.md``.

    Read from the report rather than kept in a constant here: a constant is a
    second copy of the facts, and the second copy is the one that goes stale.
    Every chart stamps this, because a throughput number with no host beside it
    is not a measurement a reader can weigh.

    The header block wraps across lines, so a value runs until the next
    ``**Marker:**`` or a blank line — reading a single physical line would
    truncate the host halfway through its software list.
    """
    path = RESULTS / "report.md"
    provenance = {"host": "", "method": "", "date": ""}
    if not path.exists():
        return provenance

    lines = path.read_text(encoding="utf-8").splitlines()[:30]
    current: str | None = None
    collected: dict[str, list[str]] = {"host": [], "method": []}

    for line in lines:
        stripped = line.strip()
        if not stripped:
            if current:
                break
            continue
        matched = False
        for key, prefix in (("host", "**Host:**"), ("method", "**Method:**")):
            if stripped.startswith(prefix):
                current = key
                collected[key].append(stripped[len(prefix):].strip())
                matched = True
                break
        if matched:
            continue
        if current and not stripped.startswith("**"):
            collected[current].append(stripped)
        elif current:
            break

    for key, chunks in collected.items():
        text = " ".join(" ".join(chunks).split()).rstrip(".")
        if key == "method":
            # The method line runs to several sentences; the first names the
            # harness and its parameters, which is what a chart caption holds.
            # The endpoint list is dropped there because each chart is about one
            # endpoint and the caption must not claim otherwise.
            text = text.split(". ")[0].split(", endpoints")[0]
        provenance[key] = text
    return provenance


def read_tsv(path: Path) -> list[list[str]]:
    """Read a TSV into a list of rows, skipping the header."""
    rows: list[list[str]] = []
    with path.open(encoding="utf-8") as handle:
        for index, line in enumerate(handle.read().splitlines()):
            if not line.strip():
                continue
            if index == 0 and "\t" in line:
                header = line.split("\t")
                if header and header[0] in ("arm", "shape", "metric"):
                    continue
            rows.append(line.split("\t"))
    return rows


def read_dict_tsv(path: Path) -> list[dict]:
    """Read a *headered* TSV into a list of dicts.

    The matrix files carry a header row, so they are read by name rather than by
    position. Reading a matrix row by position would work right up to the day
    somebody adds a column in the middle, and the reader would keep working
    while reporting a column of the wrong numbers — a silent wrong answer, which
    is the one failure mode this whole repository is written to avoid.
    """
    rows: list[dict] = []
    with path.open(encoding="utf-8") as handle:
        header: list[str] | None = None
        for line in handle.read().splitlines():
            if not line.strip():
                continue
            cells = line.split("\t")
            if header is None:
                header = [cell.strip() for cell in cells]
                continue
            rows.append(dict(zip(header, cells)))
    return rows


def fmt_number(value: float) -> str:
    """A number, with a thousands separator."""
    if value is None:
        return "-"
    if abs(value) >= 100:
        return f"{value:,.0f}"
    if abs(value) >= 1:
        return f"{value:,.2f}".rstrip("0").rstrip(".")
    return f"{value:.3f}".rstrip("0").rstrip(".")


def median_or_none(values: list[float]) -> float | None:
    """The median, or ``None`` when there is nothing to take a median of."""
    if not values:
        return None
    return statistics.median(values)


# --------------------------------------------------------------------------
# The matrix format
# --------------------------------------------------------------------------
#
# `scripts/matrix.sh` writes a different shape of result than `scripts/bench.sh`
# does, and the two are not interchangeable:
#
#   matrix.tsv   one row per (arm, workers, opcache, conc, round, threads)
#   memory.tsv   one row per (arm, workers, opcache, phase, conc)
#   meta.txt     the provenance: host, kernel, interpreter, arms, grid
#
# The matrix is the *newer* measurement, it sweeps the axes an operator turns
# (workers, opcache) rather than one configuration, and it runs every arm
# through one harness — so every ratio it reports is a ratio between two
# measurements made the same way.
#
# It is also the only one of the two that is measured on PHP 8.5, which matters
# because FrankenPHP's release binary embeds 8.5 and no 8.3 build of it exists:
# an 8.3 run compares a 8.5 server against 8.3 servers and the ratio then
# measures the interpreter as much as the server.

MATRIX_DIRS = {
    "servers": "matrix85",
    "servers_root": "matrix85-root",
    "modes": "matrix85-volucer-modes",
    "prefork": "matrix85-prefork",
}

# The arms of the server comparison, in the order a page reads them.
#
# The model string says what the arm *is*, not how it was configured: the
# configuration a cell ran at is read from the data and printed with it, so
# the table cannot claim a shape the run did not measure.
SERVER_ARMS = {
    "volucer-worker": ("volucer", "worker (warm, pipe)"),
    "volucer-unix": ("volucer", "worker (warm, unix socket)"),
    "volucer-attach": ("volucer", "attach (warm, unix relay)"),
    "volucer-fastcgi": ("volucer", "spawn_cgi (cold, unix, 1/slot)"),
    "volucer-prefork": ("volucer", "spawn_cgi (cold, unix, children)"),
    "rr": ("RoadRunner", "worker (warm, pipe)"),
    "frankenphp": ("FrankenPHP", "worker (warm, embedded)"),
    "fpm": ("nginx + php-fpm", "cold, unix socket"),
}

# The arms of the shape comparison: one server, five configurations.
MODE_ARMS = {
    "volucer-worker": "worker (warm, pipe)",
    "volucer-unix": "worker (warm, unix socket)",
    "volucer-attach": "attach (warm, unix relay)",
    "volucer-fastcgi": "spawn_cgi (cold, unix, 1/slot)",
    "volucer-prefork": "spawn_cgi children (cold, unix)",
}

# The arms that measure the *cold* path, against each other.
#
# A tier that holds only these is not a comparison of servers — it is the
# cold path against `nginx + php-fpm`, which is the cold page's subject, in
# the same run and with the same method. The servers page therefore
# publishes only the tiers that put a warm arm beside them, and the cold
# page publishes the cold comparison on its own.
COLD_ARMS = ("volucer-fastcgi", "volucer-prefork", "fpm")

# The short form of each arm's model, for the chart.
#
# The chart's left-hand column has room for a name and a model, not a
# sentence. The full model string is what the *table* prints; a chart that
# repeated it would need a gutter wide enough for "spawn_cgi (cold, unix,
# children), 32 children/slot" and the plot would start halfway across the
# card. So the chart gets the short form and the table keeps the long one,
# and the two are the same fact written twice at two lengths.
SHORT_MODELS = {
    "volucer-worker": "worker, warm",
    "volucer-unix": "worker, warm, unix",
    "volucer-attach": "attach, warm",
    "volucer-fastcgi": "spawn_cgi, cold",
    "volucer-prefork": "spawn_cgi, cold, forked",
    "rr": "worker, warm",
    "frankenphp": "worker, embedded",
    "fpm": "cold, unix",
}

# One colour per server, so an arm keeps its colour across every chart.
SERVER_COLORS = {
    "volucer-worker": "#2563eb",
    "volucer-unix": "#38bdf8",
    "volucer-attach": "#7c3aed",
    "volucer-fastcgi": "#94a3b8",
    "volucer-prefork": "#c2410c",
    "rr": "#0d9488",
    "frankenphp": "#a855f7",
    "fpm": "#64748b",
}

MODE_COLORS = {
    "volucer-worker": "#2563eb",
    "volucer-unix": "#0ea5e9",
    "volucer-attach": "#7c3aed",
    "volucer-fastcgi": "#94a3b8",
    "volucer-prefork": "#c2410c",
}


def load_meta(directory: str) -> dict:
    """Read a matrix run's ``meta.txt`` into a flat dict.

    The file is a list of ``key: value`` lines indented under a header, plus
    free text further down (the skipped cells, the teardown count). Only the
    ``key: value`` lines are read; the free text is left where it is, because
    it belongs to the report, not to a machine-readable summary.

    A key is everything before the first colon, and it may contain spaces
    (``opcache on``, ``ini scan``). The value is everything after it, so a
    line that carries several facts — ``concurrency: 16,32,48,64   wrk threads:
    tc t12   duration: 5s   rounds: 3`` — keeps all of them.
    """
    path = RESULTS / directory / "meta.txt"
    meta: dict[str, str] = {}
    if not path.exists():
        return meta

    for line in path.read_text(encoding="utf-8").splitlines():
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip()
        value = value.strip()
        if not key or not value:
            continue
        # `setdefault`, so the first occurrence of a key wins: the file states
        # the versions in a header block, and a later line that happens to
        # repeat a key should not overwrite it.
        meta.setdefault(key, value)
    return meta


def meta_stamp(meta: dict) -> str:
    """The one-line provenance stamp a chart carries.

    Host, kernel, interpreter, the commit the server was built from, and the
    method. A throughput figure with no host beside it is not a measurement a
    reader can weigh — the same number on a different host, or with a different
    interpreter, is a different number. And a version number does not say which
    source produced it, so the commit is printed too.
    """
    parts: list[str] = []

    host = meta.get("host", "")
    if host:
        parts.append(host)

    kernel = meta.get("kernel", "")
    if kernel:
        parts.append(kernel)

    php = meta.get("php", "")
    if php:
        # `PHP 8.5.11 (cli) (built: ...) (NTS)` is more than a chart caption
        # wants; the version and the SAPI are what a reader needs.
        parts.append(" ".join(php.split(" (built:")[0].split()))

    ref = meta.get("volucer ref", "")
    if ref and not ref.startswith("("):
        parts.append(f"volucer {ref}")

    # The arms the run measured. Two pages can compare the same two
    # deployments and report different numbers, because they come from
    # different runs; the number of arms is what tells a reader that the two
    # charts came from passes of different scope rather than from one pass
    # that disagrees with itself.
    arms = meta.get("arms", "")
    if arms:
        count = len([a for a in arms.split(",") if a.strip()])
        parts.append(f"{count} arms")

    method = meta_method(meta)
    if method:
        parts.append(method)

    return " · ".join(parts)


def meta_method(meta: dict) -> str:
    """The measurement method in one clause: the grid, the client and the repeats.

    The `concurrency` line carries several facts at once
    (``16,32,48,64   wrk threads: tc t12   duration: 5s   rounds: 3``), so it
    is read out piece by piece rather than printed whole.
    """
    line = meta.get("concurrency", "")
    pieces: list[str] = []

    levels = line.split("   ")[0].strip()
    if levels:
        pieces.append(f"c={levels}")

    for needle, label in (("duration:", "per cell"), ("rounds:", "repeats")):
        if needle in line:
            value = line.split(needle, 1)[1].split("   ")[0].strip()
            if value:
                pieces.append(f"{value} {label}")

    threads = meta.get("wrk threads", "")
    if threads:
        pieces.append(f"wrk threads {threads}")

    return ", ".join(pieces)



def matrix_rows(directory: str) -> list[dict]:
    """The matrix rows of one run, or an empty list."""
    path = RESULTS / directory / "matrix.tsv"
    if not path.exists():
        return []
    return read_dict_tsv(path)


def matrix_memory(directory: str) -> list[dict]:
    """The memory samples of one run, or an empty list."""
    path = RESULTS / directory / "memory.tsv"
    if not path.exists():
        return []
    return read_dict_tsv(path)


def cell_median(rows: list[dict], key_fields: dict, field: str,
                transform=None) -> float | None:
    """The median of ``field`` over the rows matching ``key_fields``.

    A row whose value cannot be read is dropped rather than counted as zero.
    """
    transform = transform or (lambda value: float(value))
    values: list[float] = []
    for row in rows:
        if any(row.get(name) != value for name, value in key_fields.items()):
            continue
        raw = row.get(field, "")
        if raw in ("", "FAIL", "?"):
            continue
        try:
            values.append(transform(raw))
        except (TypeError, ValueError):
            continue
    return median_or_none(values)


def php_process_count(arm: str, workers: int, children: int) -> int:
    """The number of PHP processes that execute the application.

    The same rule `scripts/matrix.sh` applies when it decides whether a cell
    fits the host's process cap, restated here so the published page and the
    harness agree on what a configuration costs — with one difference, and the
    difference is the whole point of the comparison.

    The harness counts *every* PHP process, which for a forked slot includes
    the master that supervises the children. The master does not serve
    requests; the children do. So the harness's number is the cost and this
    one is the work: `workers × children` for a forked slot, against `workers`
    for one process per slot.

    The `pids` column of `memory.tsv` cannot be used for either: it counts
    every process in the tree, the server and the supervisor included.
    """
    if arm == "volucer-prefork" and children > 1:
        return workers * children
    return workers


def same_process_count_comparison(post_rows: list[dict]) -> list[dict]:
    """The memory of two arrangements that hold the PHP process count equal.

    The `children` shape exists to answer one question: for the same number of
    PHP processes, is a forked slot cheaper than one process per slot? The
    comparison has to hold the process count equal, or it is comparing two
    different amounts of server — and a page that reported "the forked shape
    uses less memory" without saying "for the same 16 processes" would be
    claiming something the data does not support.

    Only pairs whose PHP process counts are equal are returned, so the
    comparison is between like and like.
    """
    # Group the samples by (arm, workers, children) and keep the PHP process
    # count, which is the quantity the comparison has to hold equal.
    groups: dict[tuple[str, str, str], list[float]] = defaultdict(list)

    for row in post_rows:
        key = (row.get("arm", ""), row.get("workers", ""), (row.get("children") or "").strip())
        pss = row.get("pss_mb", "")
        if pss in ("", "?"):
            continue
        try:
            groups[key].append(float(pss))
        except ValueError:
            continue

    # The candidate pairs, keyed by the number of serving processes.
    one_per_slot: dict[int, tuple[str, str, str]] = {}
    forked: dict[int, list[tuple[str, str, str]]] = defaultdict(list)

    for key in groups:
        arm, workers, children = key
        if not workers.isdigit():
            continue
        count = php_process_count(
            arm, int(workers), int(children) if children.isdigit() else 0
        )
        if count <= 0:
            continue
        if arm == "volucer-fastcgi":
            one_per_slot.setdefault(count, key)
        elif arm == "volucer-prefork" and children not in ("", "1"):
            # `children = 1` is the same thing as one process per slot, so it
            # is not a member of this side of the comparison.
            forked[count].append(key)

    entries: list[dict] = []
    for count in sorted(set(one_per_slot) & set(forked)):
        slot_key = one_per_slot[count]
        slot_values = groups[slot_key]
        entries.append({
            "label": f"{count} separate slots",
            "processes": count,
            "median": statistics.median(slot_values),
            "min": min(slot_values),
            "max": max(slot_values),
        })

        # Every forked arrangement that reaches the same serving count, not
        # just the most favourable one. The arrangements differ in how many
        # masters they carry, and picking one of several would be a cherry-pick.
        for fork_key in sorted(forked[count], key=lambda k: (int(k[1]), int(k[2]))):
            fork_values = groups[fork_key]
            workers = int(fork_key[1])
            children = int(fork_key[2])
            entries.append({
                "label": f"{workers} slot{'s' if workers > 1 else ''} × {children} children",
                "processes": count,
                "median": statistics.median(fork_values),
                "min": min(fork_values),
                "max": max(fork_values),
            })

    return entries


def best_configuration(rows: list[dict], arm: str, conc: int, mode: str | None = None,
                       threads: str | None = None) -> dict:
    """The best-measured configuration of one arm at one concurrency.

    An arm can have more than one axis: `workers` for every shape, and
    `children` for `volucer-prefork`, where it is the number of PHP processes
    behind each listening socket. The best configuration is therefore a
    (workers, children) pair, and searching only `workers` would report the
    prefork shape's best as `children = 1` — which is the `spawn_cgi` shape
    under a different name, and would quietly throw away the finding the shape
    exists to show.

    `mode` and `threads` narrow the search to one opcache mode and one client
    thread count, so the best is taken within the same conditions as the rest
    of the comparison rather than across them.

    A cell with no successful repeat is skipped rather than counted as zero.
    """
    best: dict = {"rps": None, "workers": None, "children": ""}

    configs: set[tuple[str, str]] = set()
    for row in rows:
        if row.get("arm") != arm or row.get("conc") != str(conc):
            continue
        if mode is not None and row.get("opcache") != mode:
            continue
        if threads is not None and row.get("threads") != threads:
            continue
        worker = row.get("workers", "")
        children = (row.get("children") or "").strip()
        configs.add((worker, children))

    for worker, children in configs:
        key = {"arm": arm, "workers": worker, "conc": str(conc)}
        if mode is not None:
            key["opcache"] = mode
        if threads is not None:
            key["threads"] = threads
        if children:
            key["children"] = children
        rps = cell_median(rows, key, "rps")
        if rps is None:
            continue
        if best["rps"] is None or rps > best["rps"]:
            best = {
                "rps": rps,
                "workers": int(worker) if worker.isdigit() else worker,
                "children": children,
            }
    return best


def configuration_at_process_count(rows: list[dict], arm: str, procs: int,
                                   conc: int, mode: str | None = None,
                                   threads: str | None = None) -> dict:
    """The configuration of one arm that serves with exactly ``procs`` processes.

    The comparison on the servers page is only fair between arms that serve
    with the same number of PHP processes, because that is what the host pays
    for. `volucer-fastcgi` serves with one process per slot, so its process
    count is its worker count; `volucer-prefork` serves with `children`
    processes behind each socket, so its count is the product; and `fpm` runs
    one child per worker. They are different expressions of the same idea, and
    this function is the one place that knows the difference.

    Where an arm has more than one configuration at the same process count —
    `1 slot x 16 children` and `4 slots x 4 children` both serve 16 — the one
    with the higher throughput is returned. That is the configuration an
    operator would choose, and choosing the *worst* of them would understate
    the arm for no reason.

    A configuration with no successful repeat is skipped rather than counted
    as zero.
    """
    best: dict = {"rps": None, "workers": None, "children": ""}

    configs: set[tuple[str, str]] = set()
    for row in rows:
        if row.get("arm") != arm or row.get("conc") != str(conc):
            continue
        if mode is not None and row.get("opcache") != mode:
            continue
        if threads is not None and row.get("threads") != threads:
            continue
        configs.add((row.get("workers", ""), (row.get("children") or "").strip()))

    for worker, children in configs:
        count = php_process_count(
            arm,
            int(worker) if worker.isdigit() else 0,
            int(children) if children.isdigit() else 0,
        )
        if count != procs:
            continue
        key = {"arm": arm, "workers": worker, "conc": str(conc)}
        if mode is not None:
            key["opcache"] = mode
        if threads is not None:
            key["threads"] = threads
        if children:
            key["children"] = children
        rps = cell_median(rows, key, "rps")
        if rps is None:
            continue
        if best["rps"] is None or rps > best["rps"]:
            best = {
                "rps": rps,
                "workers": int(worker) if worker.isdigit() else worker,
                "children": children,
            }
    return best


def parse_latency(value: str) -> float | None:
    """A wrk latency in milliseconds.

    wrk writes ``689.00us``, ``1.40ms`` or ``1.10s``. They are compared across
    arms, so everything is normalised to milliseconds: a raw float would make
    ``1.40ms`` and ``689us`` look like 1.4 and 689 of the same thing, which is
    a 1000x error in the direction of whichever arm happened to land either
    side of the unit boundary.
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
    try:
        return float(text)
    except ValueError:
        return None


def round_paired_ratios(rows: list[dict], key_a: dict, key_b: dict,
                         field: str = "rps") -> list[float]:
    """The ratios of one field between two configurations, paired by round.

    Each configuration is measured once per round, and the rounds are
    interleaved across the arms — so a round is the smallest unit in which
    two arms were measured under the same conditions, minutes apart rather
    than tens of minutes apart.

    Pairing by round is what makes a range worth drawing. A host that drifts
    over the run moves *every* arm in the same direction within a round, so
    the ratio inside a round is far steadier than either arm's own spread.
    The alternative — a range from one arm's minimum to its maximum — charges
    the whole of the host's drift to one arm, and produces a whisker that is
    wide for the wrong reason.

    A configuration with no successful repeat contributes nothing rather than
    a zero, and a round in which only one of the two was measured is not
    paired at all: there is no ratio in it.
    """
    def by_round(key: dict) -> dict[str, float]:
        found: dict[str, float] = {}
        for row in rows:
            if any(row.get(name) != value for name, value in key.items()):
                continue
            raw = row.get(field, "")
            if raw in ("", "FAIL", "?"):
                continue
            try:
                found[row.get("round", "")] = float(raw)
            except (TypeError, ValueError):
                continue
        return found

    values_a = by_round(key_a)
    values_b = by_round(key_b)
    if not values_a or not values_b:
        return []

    ratios: list[float] = []
    for round_id in sorted(set(values_a) & set(values_b)):
        denominator = values_b[round_id]
        if denominator <= 0:
            continue
        ratios.append(values_a[round_id] / denominator)
    return ratios


def ratio_with_spread(rows: list[dict], key_a: dict, key_b: dict,
                      field: str = "rps") -> dict:
    """A ratio of two configurations, with the spread of the paired rounds.

    The centre is the ratio of the two medians — the same number the table
    beside the chart prints, so a reader can check the arithmetic. The low and
    high are the extremes of the round-paired ratios.

    The whisker is widened to contain the centre. A whisker that did not
    contain the dot would be a chart contradicting its own table, and the
    honest response to that is to widen the whisker, not to move the dot. On
    the committed data the widening never fires, and the test suite pins
    that: the whisker is the measurement, and the dot is the summary of it.
    """
    centre = cell_median(rows, key_a, field)
    baseline = cell_median(rows, key_b, field)
    if centre is None or baseline is None or baseline <= 0:
        return {"centre": None, "low": None, "high": None, "rounds": 0}

    ratio = centre / baseline
    paired = round_paired_ratios(rows, key_a, key_b, field)
    if not paired:
        return {"centre": ratio, "low": ratio, "high": ratio, "rounds": 0}

    low = min(min(paired), ratio)
    high = max(max(paired), ratio)
    return {"centre": ratio, "low": low, "high": high, "rounds": len(paired)}



# --------------------------------------------------------------------------
# View: prefork — what `children` is worth
# --------------------------------------------------------------------------

def prefork_provenance() -> str:
    """The host and method of the prefork comparison, read from its report.

    The prefork run was measured by hand rather than by `matrix.sh`, so its
    provenance lives in the prose of `results/prefork-vs-slots.md` rather than
    in a `meta.txt`. It is read from there rather than kept as a constant
    here, for the same reason the other views read theirs: a constant is a
    second copy of the facts, and the second copy is the one that goes stale.
    """
    path = RESULTS / "prefork-vs-slots.md"
    if not path.exists():
        return ""

    text = path.read_text(encoding="utf-8")
    for line in text.splitlines():
        if "cores" in line and "PHP" in line:
            # The line reads like "WSL2, 12 cores, PHP 8.3.35 (cgi-fcgi),
            # `/items`, `wrk -t4`, 8 s per point, 2 interleaved rounds."
            parts = [part.strip() for part in line.split(",")]
            kept = []
            for part in parts:
                # The endpoint and the client command are backticked, and the
                # rounds clause is cut at the comma — "2 interleaved rounds"
                # is the whole phrase, not "2 interleaved".
                if not part or part.startswith("`"):
                    continue
                if part.startswith("2 interleaved"):
                    part = "2 rounds"
                kept.append(part)
            if kept:
                return " · ".join(kept)
    return ""


def view_prefork(out_dir: Path) -> dict:
    """The prefork-versus-slots comparison, as a memory chart."""
    path = RESULTS / "prefork-vs-slots.tsv"
    if not path.exists():
        return {"pages": 0, "files": []}

    rows = read_tsv(path)
    # Keyed by (shape, concurrency): pooling every concurrency level into one
    # range mixes load levels, and a range that spans "idle" to "saturated"
    # says nothing about either.
    cells: dict[tuple[str, int], list[float]] = defaultdict(list)
    for parts in rows:
        if len(parts) < 8:
            continue
        try:
            shape, conc = parts[0], int(parts[2])
            pss_kb = int(parts[7])  # PSS after load, KiB
        except (ValueError, IndexError):
            continue
        cells[(shape, conc)].append(pss_kb / 1024)

    if not cells:
        return {"pages": 0, "files": []}

    shape_names = {
        "S": "16 separate slots",
        "C16": "1 master × 16 children",
    }
    prefork_stamp = prefork_provenance()
    shapes_present = [s for s in ("S", "C16") if any(k[0] == s for k in cells)]
    concurrencies = sorted({k[1] for k in cells})

    svg_dir = out_dir / "svg" / "prefork"
    svg_dir.mkdir(parents=True, exist_ok=True)
    files: list[str] = []
    lines: list[str] = ["## Memory for the same 16 PHP processes", ""]

    # --- Chart one: memory against load, one line per shape. ---
    series = {
        shape: [statistics.median(cells[(shape, c)]) if (shape, c) in cells else None
                for c in concurrencies]
        for shape in shapes_present
    }
    colors = {"S": "#94a3b8", "C16": "#2563eb"}
    labels = {shape: shape_names.get(shape, shape) for shape in shapes_present}
    load_chart = "prefork-memory-by-load.svg"
    write(svg_dir / load_chart, grouped_bars(
        categories=[f"c={c}" for c in concurrencies],
        series=series,
        colors=colors,
        labels=labels,
        title="Resident memory against load — 16 PHP processes",
        value_suffix="MiB",
        note=prefork_stamp,
    ))
    files.append(load_chart)

    lines += [
        f"![Memory against load](svg/prefork/{load_chart})",
        "",
        "Proportional set size (PSS) after the run, summed over the 16 PHP processes.",
        "PSS divides each shared page by the number of processes mapping it, which is",
        "why it is the figure that shows copy-on-write sharing: a preforked child that",
        "has not yet written to a page costs its siblings nothing.",
        "",
        "| shape | " + " | ".join(f"c={c}" for c in concurrencies) + " |",
        "|---|" + "---:|" * len(concurrencies),
    ]
    for shape in shapes_present:
        row = []
        for c in concurrencies:
            values = cells.get((shape, c))
            row.append(f"{statistics.median(values):.1f}" if values else "-")
        lines.append(f"| {shape_names.get(shape, shape)} | " + " | ".join(row) + " |")
    lines.append("")

    # --- Chart two: the peak-load comparison, which is the finding. ---
    peak = concurrencies[-1]
    peak_labels: list[str] = []
    peak_low: list[float] = []
    peak_high: list[float] = []
    peak_mid: list[float] = []
    for shape in shapes_present:
        values = cells.get((shape, peak))
        if not values:
            continue
        peak_labels.append(shape_names.get(shape, shape))
        peak_mid.append(statistics.median(values))
        peak_low.append(min(values))
        peak_high.append(max(values))

    if len(peak_labels) >= 2:
        peak_chart = "prefork-memory.svg"
        write(svg_dir / peak_chart, range_bars(
            categories=peak_labels,
            low=peak_low,
            high=peak_high,
            centre=peak_mid,
            colour="#2563eb",
            title=f"Memory at c={peak} — the same 16 PHP processes",
            value_suffix="MiB",
            note="The bar spans the measured range across the rounds; the dot is "
                 "the median. PSS divides shared pages between the processes that "
                 "map them, so a page the children share counts once. " + prefork_stamp,
            show_factor=True,
            factor_note="The multiplier compares a row's median with the lightest "
                        "median on the chart.",
        ))
        files.append(peak_chart)

        lines += [
            f"## At c={peak}",
            "",
            f"![Memory at c={peak}](svg/prefork/{peak_chart})",
            "",
            "| shape | median PSS (MiB) | min (MiB) | max (MiB) | multiplier |",
            "|---|---:|---:|---:|---:|",
        ]
        lightest = min(peak_mid) if peak_mid else 0.0
        for index, label in enumerate(peak_labels):
            ratio = peak_mid[index] / lightest if lightest > 0 else 0.0
            # The lightest row is the reference and carries no factor of its
            # own, for the same reason the servers chart leaves the fastest
            # server unlabelled: a yardstick does not measure itself.
            factor = "x1.0" if abs(ratio - 1.0) < 1e-9 else f"x{ratio:.1f}"
            lines.append(
                f"| {label} | **{peak_mid[index]:.1f}** | {peak_low[index]:.1f} | "
                f"{peak_high[index]:.1f} | {factor} |"
            )
        lines.append("")
        if lightest > 0 and len(peak_mid) >= 2:
            heaviest = max(peak_mid)
            lines += [
                f"At c={peak} the preforked pool holds "
                f"**{heaviest / lightest:.1f}× less** resident memory than one",
                "process per slot, for the same 16 PHP processes serving the same",
                "requests.",
                "",
            ]

    return {"pages": 1, "files": files, "body": "\n".join(lines)}


# --------------------------------------------------------------------------
# View: servers — the five servers, one harness, one interpreter
# --------------------------------------------------------------------------

def view_servers(out_dir: Path) -> dict:
    """The server comparison: volucer against four alternatives, on one harness.

    Every arm here went through the same script, the same interpreter and the
    same load generator, so a ratio between two arms is a ratio between two
    measurements made the same way. That is the property the older
    `bench.sh` run does not have, because it measured the arms in separate
    passes and configured the `php-fpm` arm through the host's systemd service
    while the volucer arms ran their own private servers.

    The harness measures one endpoint per run, so a second endpoint is a
    second run and a second directory. The endpoints are discovered rather
    than hard-coded, and a run that is absent is simply not published.
    """
    svg_dir = out_dir / "svg" / "servers"
    svg_dir.mkdir(parents=True, exist_ok=True)
    files: list[str] = []
    lines: list[str] = []

    endpoints: list[tuple[str, str]] = []
    for key in ("servers", "servers_root"):
        directory = MATRIX_DIRS[key]
        if not (RESULTS / directory / "matrix.tsv").exists():
            continue
        endpoint = ""
        meta = load_meta(directory)
        endpoint = meta.get("endpoint", "")
        endpoints.append((key, endpoint or "/"))

    if not endpoints:
        return {"pages": 0, "files": []}

    for directory_key, endpoint in endpoints:
        rows = matrix_rows(MATRIX_DIRS[directory_key])
        if not rows:
            continue
        meta = load_meta(MATRIX_DIRS[directory_key])
        stamp = meta_stamp(meta)

        arms = [arm for arm in SERVER_ARMS if any(r.get("arm") == arm for r in rows)]
        if not arms:
            continue

        # The worker count the grid was run at, and the concurrency levels it
        # covered. Both come from the data rather than from a constant, so a run
        # with a different grid publishes its own grid.
        workers = sorted({r.get("workers", "") for r in rows if r.get("arm") == arms[0]},
                         key=lambda v: int(v) if v.isdigit() else 0)
        concurrencies = sorted({int(r["conc"]) for r in rows if r.get("conc", "").isdigit()})

        # The opcache axis. A run with both modes compares them; a run with one
        # mode has no axis to compare, and printing an empty table of both would
        # read like a failed measurement.
        modes = sorted({r.get("opcache", "") for r in rows})
        opcache_modes = modes if len(modes) > 1 else [modes[0]] if modes else ["on"]

        # The client thread count. The grid measured `-t$conc` and a fixed `-t12`
        # in the same cells, and the fixed one is the one a cross-arm comparison
        # uses: it keeps the load generator's own cost constant, so the difference
        # between two arms is the server rather than the client.
        #
        # The thread count is a property of the CELL, not of the run: `wrk`
        # refuses `-c` below `-t`, so the harness clamps the thread count to the
        # concurrency level whenever the level is below the requested one. A run
        # that measures c=8 therefore has c=8 rows at `-t8` and c=16/32/64 rows
        # at `-t12`.
        #
        # So the thread count to use is resolved PER CONCURRENCY LEVEL, not once
        # for the whole run. Resolving it once - which is what this did before
        # - finds no single count that covers every row, falls back to "the most
        # common", and then every row whose thread count differs is invisible:
        # the c=8 cells were measured, and the page printed none of them. A
        # level that is missing from the page because of a bookkeeping detail
        # in the report is indistinguishable from a level that was never
        # measured, and the second is a claim while the first is a bug.
        def threads_for(conc: int) -> str:
            """The client thread count the run used at this concurrency level."""
            candidates = {r.get("threads", "") for r in rows
                          if r.get("conc") == str(conc)}
            # The most common one at this level. A level measured once per
            # configuration has exactly one; a level measured twice (the
            # `-t$conc` and the fixed `-t12` convention) has two, and the
            # fixed one is the comparable one - the same reason the run-wide
            # fallback preferred it.
            fixed = [c for c in candidates
                     if sum(1 for r in rows if r.get("threads") == c) == len(rows)]
            if fixed:
                return sorted(fixed, key=lambda v: int(v) if v.isdigit() else 0)[-1]
            if not candidates:
                return ""
            return max(candidates,
                       key=lambda v: sum(1 for r in rows if r.get("threads") == v))

        # The process counts the run measured, per arm.
        #
        # The comparison is only fair between arms that serve with the same
        # number of PHP processes, so the page is organised by process count
        # rather than by arm. A run that measured every arm at 16 processes
        # publishes one table; a run that also measured fpm at 32 publishes a
        # second one, and the arms that were not measured at that count are
        # absent from it rather than silently carrying a number from another
        # tier.
        arm_process_counts: dict[str, set[int]] = defaultdict(set)
        for arm in arms:
            for worker in {r.get("workers", "") for r in rows if r.get("arm") == arm}:
                for children in {((r.get("children") or "").strip())
                                 for r in rows if r.get("arm") == arm}:
                    count = php_process_count(
                        arm,
                        int(worker) if worker.isdigit() else 0,
                        int(children) if children.isdigit() else 0,
                    )
                    if count > 0:
                        arm_process_counts[arm].add(count)

        # The tiers the run covers, smallest first.
        #
        # A tier is published when it is a *server comparison* — that is, when
        # it measures at least one warm arm beside the cold ones. The 32-process
        # tier measures only `spawn_cgi` and `nginx + php-fpm`, and a table of
        # those two is not a comparison of servers: it is the cold path
        # against php-fpm, which is what the cold page is for, in the same
        # run and with the same method. Publishing it here as well would put
        # the same comparison on two pages against two different baselines,
        # and a reader would have to work out which one to believe.
        all_counts = sorted({c for counts in arm_process_counts.values() for c in counts})
        tiers = [c for c in all_counts
                 if any(c in arm_process_counts[arm] for arm in arms
                        if arm not in COLD_ARMS)]

        endpoint_name = "the landing page" if endpoint == "/" else "the ORM page"
        lines.append(f"## `GET {endpoint}` — {endpoint_name}")
        lines.append("")

        # The process count is the cost side of the comparison, and it decides
        # which arms may be compared with which. `spawn_cgi` with `children`
        # puts several processes behind one listening socket, so it reaches a
        # given throughput with a different number of processes than the arms
        # beside it — and a reader who cannot see that would read the rows as
        # comparable when they are not.
        #
        # The cold path against `nginx + php-fpm` is compared on the cold
        # page, where the process count is held equal on purpose. Here every
        # row serves with the same number of processes, so the comparison is
        # a comparison of servers.
        if len(tiers) > 1:
            lines.append(
                "The tables below are grouped by **PHP procs** — the number of PHP "
                "processes serving the requests. That is what the host pays for, and "
                "it is the number that decides which rows may be compared with which. "
                "The `spawn_cgi` arm with `children` puts several processes behind one "
                "listening socket, so it reaches a given throughput with a different "
                "number of processes than the arms beside it. A row with more "
                "processes is not a better row — it is a row that bought its "
                "throughput with more server."
            )
        else:
            lines.append(
                "Every row below serves with the same number of PHP processes — the "
                "**PHP procs** column says how many, and that is what the host pays "
                "for. The `spawn_cgi` arm with `children` puts several processes "
                "behind one listening socket, so its throughput is produced by a "
                "different amount of server than the arms beside it, and the count "
                "is what makes the rows comparable."
            )
        lines.append("")

        # How to read the charts, stated once, because a chart that needs a
        # paragraph in the reader's head to be read is a chart that will be
        # misread.
        lines.append(
            "Each chart is a bar per server, and the bar is the **request rate** — "
            "the number the page is about. The bars start at zero, so their lengths "
            "can be compared directly."
        )
        lines.append("")
        lines.append(
            "**The label behind each bar is how many times slower that server is "
            "than the fastest server in the same chart.** The fastest server is the "
            "dashed vertical line, and it carries no label of its own; every other "
            "bar states its factor — `x2.5` for a server that did 40% of the "
            "leader's requests per second. The baseline is the fastest server *in "
            "that chart*, not a fixed server: a cold deployment overtakes a warm one "
            "once the host saturates, so the fastest server is not the same one at "
            "every load — and naming it per chart is more honest than a fixed "
            "reference that would read as a claim about the same winner every time."
        )
        lines.append("")
        lines.append(
            "**The range on each bar is the spread of the comparison, not of the "
            "server.** Both servers were measured once per round, interleaved, so "
            "each round holds a ratio of the two. The range is the smallest and "
            "largest of those round-paired ratios, scaled back into requests per "
            "second. Pairing by round is what makes that range honest: a host that "
            "drifts over the run moves both servers in the same round, so the ratio "
            "within a round is far steadier than either server's own spread. A range "
            "drawn from one server's minimum and maximum would instead charge the "
            "whole of the host's drift to that one server, and would be wide for the "
            "wrong reason."
        )
        lines.append("")
        lines.append(
            "A range that reaches across the 1.0 line means the two servers could "
            "not be told apart in this run. The table marks those rows **tie**: a "
            "difference inside the measurement's own spread is not a difference, and "
            "the factor there is the best estimate rather than a claim that one "
            "server is faster."
        )
        lines.append("")

        for mode in opcache_modes:
            mode_title = ("OPcache on" if mode == "on"
                          else "OPcache off" if mode == "off"
                          else f"OPcache {mode}")
            lines.append(f"### {mode_title}")
            lines.append("")

            for tier in tiers:
                # The arms measured at this process count. An arm that was not
                # measured here is absent from this tier rather than carrying
                # a number from another tier.
                tier_arms = [arm for arm in arms if tier in arm_process_counts[arm]]

                # The arm the ratio column is measured against.
                #
                # The baseline is the **fastest arm in the group**, not a fixed
                # arm. A fixed reference would put a label on every bar that
                # means something different in every chart, and the reader
                # would have to look it up. The fastest server in the group is
                # the natural yardstick: it is 1.00x, and every other bar is
                # labelled with its share of it.
                #
                # The fastest arm is found from the data, per concurrency. It
                # is not assumed to be the same arm at every load, because it
                # is not: a cold deployment overtakes a warm one as the host
                # saturates, and a chart that kept naming the same baseline
                # would be claiming a winner the measurement does not have.
                for conc in concurrencies:
                    # The configuration of each arm at this process count and
                    # this concurrency.
                    #
                    # An arm can have more than one axis: `workers` for every
                    # arm, and `children` for `volucer-prefork`, where it is
                    # the number of PHP processes behind each listening socket.
                    # Fixing the process count is what makes the rows
                    # comparable, so the search is over the configurations that
                    # reach it.
                    best_of: dict[str, dict] = {}
                    for arm in tier_arms:
                        best_of[arm] = configuration_at_process_count(
                            rows, arm, tier, conc, mode=mode,
                            threads=threads_for(conc))

                    measured = {arm: best for arm, best in best_of.items()
                                if best["rps"] is not None}
                    if not measured:
                        continue

                    # The baseline: the fastest arm measured at this tier and
                    # this concurrency.
                    reference = max(measured, key=lambda arm: measured[arm]["rps"])
                    reference_best = measured[reference]
                    reference_key = {
                        "arm": reference,
                        "workers": str(reference_best["workers"]),
                        "opcache": mode,
                        "conc": str(conc),
                        "threads": threads_for(conc),
                    }
                    if reference_best["children"]:
                        reference_key["children"] = reference_best["children"]

                    # The chart rows: the rate, the range around it, and the
                    # share of the baseline.
                    #
                    # The range is the range of the *round-paired* ratios,
                    # scaled back into requests per second. Pairing by round
                    # is what makes it honest: a host that drifts over the run
                    # moves both arms in the same round, so the ratio inside
                    # a round is far steadier than either arm's own spread. A
                    # range drawn from an arm's own minimum and maximum would
                    # instead charge the whole of the host's drift to that
                    # one arm, and would be wide for the wrong reason.
                    chart_rows: list[dict] = []
                    ratios: dict[str, dict] = {}

                    for arm in tier_arms:
                        best = best_of[arm]
                        server, model = SERVER_ARMS[arm]
                        short = SHORT_MODELS.get(arm, model)
                        if best["children"]:
                            short = f"{short} \u00b7 {best['children']}/slot"

                        entry = {
                            "name": server,
                            "model": short,
                            "color": SERVER_COLORS.get(arm, "#94a3b8"),
                            "rps": best["rps"],
                            "low": None,
                            "high": None,
                            "factor": None,
                            "reference": arm == reference,
                        }

                        if best["rps"] is None:
                            chart_rows.append(entry)
                            ratios[arm] = {"centre": None, "low": None, "high": None}
                            continue

                        key = {"arm": arm, "workers": str(best["workers"]),
                               "opcache": mode, "conc": str(conc),
                               "threads": threads_for(conc)}
                        if best["children"]:
                            key["children"] = best["children"]

                        if arm == reference:
                            # The baseline against itself is 1.0 by
                            # definition, and it has no range: it is the
                            # yardstick, and a yardstick with a range on it is
                            # not a yardstick.
                            spread = {"centre": 1.0, "low": 1.0, "high": 1.0,
                                      "rounds": 0}
                        else:
                            # How many times slower this arm is than the
                            # baseline: the baseline divided by the arm. It is
                            # the reciprocal of the share, because "twice as
                            # slow" is how a reader thinks about the result -
                            # and the same number describes a comparison of
                            # times rather than rates.
                            spread = ratio_with_spread(rows, reference_key, key)
                        ratios[arm] = spread

                        entry["factor"] = spread["centre"]
                        if spread["low"] is not None and spread["high"] is not None:
                            # The range in requests per second: the
                            # reference's rate divided by the factor, and by
                            # the factor's extremes. The arm's own rate sits
                            # inside it, because the factor is measured
                            # from it.
                            entry["low"] = reference_best["rps"] / spread["high"]
                            entry["high"] = reference_best["rps"] / spread["low"]

                        chart_rows.append(entry)

                    if not any(row["rps"] is not None for row in chart_rows):
                        continue

                    slug = "root" if endpoint == "/" else endpoint.strip("/").replace("/", "-")
                    # The tier is part of the file name. Two tiers publish two
                    # charts of the same endpoint, mode and concurrency, and a
                    # shared name would let the second overwrite the first -
                    # a chart that is silently replaced by a different one is
                    # worse than a chart that is missing.
                    chart = f"servers-{slug}-{mode}-p{tier}-c{conc}.svg"
                    reference_server, reference_model = SERVER_ARMS[reference]
                    reference_label = f"{reference_server} \u2014 {reference_model}"
                    if reference_best["children"]:
                        reference_label += f", {reference_best['children']} children/slot"

                    write(svg_dir / chart, throughput_dots(
                        rows=chart_rows,
                        title=f"GET {endpoint} \u2014 {mode_title} at c={conc}",
                        note="The bar is the request rate. The label behind it is how "
                             "many times slower that server is than the fastest server "
                             "in this chart, which is the dashed line. The range on "
                             "each bar is the spread of the round-paired comparison: "
                             "both servers were measured in the same round, so the "
                             "range is the spread of the comparison, not the drift of "
                             "the host. " + stamp,
                        reference_label="fastest here",
                    ))
                    files.append(chart)

                    lines.append(f"![{mode_title} at c={conc}](svg/servers/{chart})")

                    # The table belongs to the highest concurrency the tier
                    # was measured at, which is the load the comparison is
                    # about: the numbers above are the ones the table
                    # prints, and a table that reported a different
                    # concurrency's numbers would contradict the chart
                    # above it.
                    if conc != concurrencies[-1]:
                        continue

                    lines.append("")
                    lines.append(f"#### {tier} PHP processes")
                    lines.append("")
                    # Which arm the factor is measured against, stated per
                    # tier: it is the fastest server in the table. The
                    # reference is named here because a factor without its
                    # reference is a number with no meaning, and because the
                    # fastest server is not the same arm in every tier - the
                    # cold deployments overtake the warm ones once the host
                    # saturates.
                    reference_server, reference_model = SERVER_ARMS[reference]
                    reference_label = f"{reference_server} \u2014 {reference_model}"
                    if reference_best["children"]:
                        reference_label += f", {reference_best['children']} children/slot"
                    lines.append(
                        f"The **factor** column is measured against **{reference_label}** "
                        "\u2014 the fastest server in this table. It states how many "
                        "times slower each server is, so `x1.0` is the fastest and "
                        "`x2.5` is a quarter of its rate. The column carries the "
                        "range of the round-paired ratios beside it, and a row marked "
                        "**tie** is one whose range reaches across 1.0 \u2014 the two "
                        "servers could not be told apart in this run."
                    )
                    lines.append("")
                    lines.append("| server | model | PHP procs | rps | p50 | p99 | factor (range) |")
                    lines.append("|---|---|---:|---:|---:|---:|---:|")
                    # The rows are ordered by throughput, fastest first - the
                    # same order as the chart above them. A table whose rows
                    # are in a different order from the chart beside it is a
                    # table the reader has to re-sort in their head.
                    for arm in sorted(tier_arms,
                                      key=lambda a: -(best_of[a]["rps"] or 0.0)):
                        best = best_of[arm]
                        rps = best["rps"]
                        server, model = SERVER_ARMS[arm]
                        if rps is None:
                            lines.append(f"| {server} | {model} | - | - | - | - | - |")
                            continue
                        key = {"arm": arm, "workers": str(best["workers"]),
                               "opcache": mode, "conc": str(conc),
                               "threads": threads_for(conc)}
                        if best["children"]:
                            key["children"] = best["children"]
                        p50 = cell_median(rows, key, "p50", parse_latency)
                        p99 = cell_median(rows, key, "p99", parse_latency)
                        spread = ratios[arm]
                        if arm == reference or not spread.get("centre"):
                            # The reference is 1.0 by definition. It is
                            # printed rather than left blank, because a blank
                            # cell in this column would read as "not
                            # measured" — and it is the one cell in the
                            # column that was measured beyond doubt.
                            factor = "x1.0"
                        else:
                            factor = f"x{spread['centre']:.1f}"
                            # The range is printed beside the factor because
                            # the chart beside the table draws it, and a chart
                            # that shows a number the table does not is a
                            # number the reader has to trust rather than
                            # check. It is the range of the round-paired
                            # ratios - the spread of the comparison, not the
                            # spread of the server.
                            #
                            # Two decimals, while the factor itself has one.
                            # The factor is read as a scale - x1.1, x2.5 - and
                            # one decimal is enough for that. The range is
                            # read as evidence, and one decimal would round
                            # a range of 0.99 to 1.01 into "1.0 - 1.0": a
                            # range that visibly does not cross 1.0 beside a
                            # row marked **tie**, which is exactly the
                            # contradiction the range exists to prevent.
                            low = spread.get("low")
                            high = spread.get("high")
                            if low is not None and high is not None:
                                factor += f" ({low:.2f}\u2013{high:.2f})"
                            # A factor whose range reaches across 1.0 is not a
                            # difference - the two servers could not be told
                            # apart in this run. Printing it as a plain factor
                            # would claim a result the measurement does not
                            # support, and would contradict the chart beside
                            # it, which says so.
                            if low is not None and high is not None and low <= 1.0 <= high:
                                factor += " \u2014 tie"
                        lines.append(
                            f"| {server} | {model} | {tier} | "
                            f"**{fmt_number(rps)}** | "
                            f"{fmt_number(p50) if p50 is not None else '-'} ms | "
                            f"{fmt_number(p99) if p99 is not None else '-'} ms | {factor} |"
                        )
                    lines.append("")


    return {"pages": 1, "files": files, "body": "\n".join(lines)}

# --------------------------------------------------------------------------
# View: cold — volucer's cold path against php-fpm, at equal process count
# --------------------------------------------------------------------------

def view_cold(out_dir: Path) -> dict:
    """Volucer's cold path against `nginx + php-fpm`, at equal process count.

    The two deployments are compared at the *same number of serving PHP
    processes*, because that is what the host pays for. `php-fpm` runs one
    child per worker; volucer's `spawn_cgi` with `children` runs several
    children behind each listening socket. Comparing one preforked pool of 32
    children against a php-fpm pool of 16 would be a comparison of two
    different amounts of server, and it would flatter whichever side happened
    to have more processes.

    Every arm here was measured in one interleaved pass, so the ratio between
    two of them is a ratio between measurements taken minutes apart from one
    another rather than tens of minutes apart.

    The reference is the **16-child** php-fpm pool, not the fastest
    deployment in the chart. The page is about the cold path against
    php-fpm, so php-fpm is the thing everything else is measured against -
    and a page that re-anchored its baseline on whichever deployment
    happened to win at the current load would be a page about a different
    question every time the load changed.
    """
    rows = matrix_rows(MATRIX_DIRS["prefork"])
    if not rows:
        return {"pages": 0, "files": []}

    meta = load_meta(MATRIX_DIRS["prefork"])
    stamp = meta_stamp(meta)

    concurrencies = sorted({int(r["conc"]) for r in rows if r.get("conc", "").isdigit()})
    if not concurrencies:
        return {"pages": 0, "files": []}

    # The php-fpm pools that were measured, and the prefork shapes that reach
    # the same number of serving processes.
    fpm_workers = sorted({int(r["workers"]) for r in rows
                           if r["arm"] == "fpm" and r.get("workers", "").isdigit()})
    prefork_shapes: dict[int, tuple[int, int]] = {}
    for row in rows:
        if row["arm"] != "volucer-prefork" or not row.get("workers", "").isdigit():
            continue
        workers = int(row["workers"])
        children = int((row.get("children") or "1"))
        serving = workers * children
        # The first shape found for a process count is kept: the grid is
        # measured in a defined order, so this is deterministic rather than
        # whichever shape happened to be read last.
        prefork_shapes.setdefault(serving, (workers, children))

    svg_dir = out_dir / "svg" / "cold"
    svg_dir.mkdir(parents=True, exist_ok=True)
    files: list[str] = []
    lines: list[str] = []

    # The reference is the php-fpm pool with the most children, because
    # that is the pool a reader would put in front of this: a one-child
    # pool is a deliberately undersized server, and a comparison against it
    # would read as a headline number. It is read here rather than inside
    # the loop, because the prose that explains the table names it.
    reference_workers = max(fpm_workers) if fpm_workers else None
    if reference_workers is None:
        return {"pages": 0, "files": []}

    lines.append("## The same number of PHP processes")
    lines.append("")
    lines.append("`nginx + php-fpm` runs one child per worker. Volucer's `spawn_cgi` with")
    lines.append("`children` runs several children behind each listening socket. The")
    lines.append("comparison below holds the number of *serving* processes equal, because that")
    lines.append("is what the host pays for — a preforked pool of 32 children against a")
    lines.append("php-fpm pool of 16 would be a comparison of two different amounts of server.")
    lines.append("")
    lines.append(
        "Each chart is a bar per deployment, and the bar is the **request rate**. "
        "The label behind each bar states how many times slower that deployment "
        "is than php-fpm, which is the dashed vertical line. The range on each bar "
        "is the spread of the round-paired comparison: both deployments were "
        "measured once per round, interleaved, so the range is the spread of the "
        "comparison rather than the drift of the host. A range that reaches across "
        "the 1.0 line means the two could not be told apart, and the row in the "
        "table is marked **tie**."
    )
    lines.append("")
    lines.append(
        "The reference is the "
        f"**{reference_workers}-child** php-fpm pool, which is the pool a reader "
        "would put in front of this: a one-child pool is a deliberately undersized "
        "server, and a comparison against it would read as a headline number. The "
        "**factor** column in the table is measured against the same pool, so the "
        "chart and the table beside it cannot disagree."
    )
    lines.append("")

    for conc in concurrencies:
        reference_key = {"arm": "fpm", "workers": str(reference_workers),
                         "opcache": "on", "conc": str(conc), "threads": "12"}
        reference_rps = cell_median(rows, reference_key, "rps")
        if reference_rps is None:
            continue

        # The chart rows. The name and the model are stacked, because the
        # chart's left-hand column has room for a name and a model, not a
        # sentence: the table below keeps the full description.
        chart_rows: list[dict] = []
        ratios: dict[str, dict] = {}

        # The php-fpm pools, each against the reference pool.
        #
        # Only the reference pool goes into the *chart*. A smaller pool is a
        # deliberately undersized server, and at a tenth of the reference's
        # rate it would squash the bars that are level with php-fpm down to
        # a few pixels. The smaller pools stay in the table, and the prose
        # below says so, because a row that quietly disappears from a chart
        # is a row a reader cannot account for.
        for workers in fpm_workers:
            key = {"arm": "fpm", "workers": str(workers), "opcache": "on",
                   "conc": str(conc), "threads": "12"}
            rps = cell_median(rows, key, "rps")
            if rps is None:
                continue
            if workers == reference_workers:
                label = f"nginx + php-fpm, {workers} child{'ren' if workers > 1 else ''}"
                chart_rows.append({
                    "name": label,
                    "model": "cold, one child per worker",
                    "color": "#64748b",
                    "rps": rps,
                    "low": rps,
                    "high": rps,
                    "factor": None,
                    "reference": True,
                })
                ratios[label] = {"centre": 1.0, "low": 1.0, "high": 1.0}
                continue
            # A smaller pool is in the table but not in the chart.
            label = f"nginx + php-fpm, {workers} child{'ren' if workers > 1 else ''}"
            spread = ratio_with_spread(rows, reference_key, key)
            ratios[label] = spread

        # The prefork shapes. Every one of them is compared with the same
        # reference pool, and the serving-process count travels with the row
        # so a reader can see that a shape which reaches php-fpm's throughput
        # with 32 processes is not the same result as one that reaches it
        # with 16.
        for serving, (pworkers, pchildren) in sorted(prefork_shapes.items()):
            key = {"arm": "volucer-prefork", "workers": str(pworkers),
                   "children": str(pchildren), "opcache": "on",
                   "conc": str(conc), "threads": "12"}
            rps = cell_median(rows, key, "rps")
            if rps is None:
                continue
            label = (f"volucer spawn_cgi, {pchildren} child"
                     f"{'ren' if pchildren > 1 else ''} in 1 slot")
            spread = ratio_with_spread(rows, reference_key, key)
            ratios[label] = spread
            entry = {
                "name": label,
                "model": f"cold, {serving} serving processes",
                "color": "#c2410c" if serving == reference_workers else "#f97316",
                "rps": rps,
                "low": None,
                "high": None,
                "factor": spread["centre"],
                "reference": False,
            }
            if spread["low"] is not None and spread["high"] is not None:
                # The range in requests per second: the reference's rate
                # divided by the factor, and by the factor's extremes. The
                # deployment's own rate sits inside it, because the factor
                # is measured from it.
                entry["low"] = reference_rps / spread["high"]
                entry["high"] = reference_rps / spread["low"]
            chart_rows.append(entry)

        if len(chart_rows) < 2 or not any(row["rps"] is not None for row in chart_rows):
            continue

        chart = f"cold-c{conc}.svg"
        write(svg_dir / chart, throughput_dots(
            rows=chart_rows,
            title=f"The same number of PHP processes at c={conc}",
            note="The bar is the request rate. The label behind it states how "
                 "many times slower that deployment is than php-fpm, which is the "
                 "dashed line. The range on each bar is the spread of the "
                 "round-paired comparison: both deployments were measured in the "
                 "same round, so the range is the spread of the comparison, not "
                 "the drift of the host. " + stamp,
            reference_label=f"php-fpm, {reference_workers} children",
        ))
        files.append(chart)

        lines.append(f"### At c={conc}")
        lines.append("")
        lines.append(f"![The same number of PHP processes at c={conc}](svg/cold/{chart})")
        lines.append("")
        lines.append("| deployment | serving processes | rps | p50 | p99 | factor against php-fpm (range) |")
        lines.append("|---|---:|---:|---:|---:|---:|")
        smaller_pools = [w for w in fpm_workers if w != reference_workers]

        # The rows are collected first and ordered by throughput, fastest
        # first - the same order as the chart above them. A table whose rows
        # are in a different order from the chart beside it is a table the
        # reader has to re-sort in their head.
        table_rows: list[tuple[float, str]] = []

        for workers in fpm_workers:
            key = {"arm": "fpm", "workers": str(workers), "opcache": "on",
                   "conc": str(conc), "threads": "12"}
            fpm = cell_median(rows, key, "rps")
            if fpm is None:
                continue
            label = f"nginx + php-fpm, {workers} child{'ren' if workers > 1 else ''}"
            if workers == reference_workers:
                table_rows.append((fpm, f"| {label} | {workers} | "
                                       f"**{fmt_number(fpm)}** | - | - | x1.0 |"))
                continue
            spread = ratio_with_spread(rows, reference_key, key)
            factor = f"x{spread['centre']:.1f} ({spread['low']:.2f}–{spread['high']:.2f})"
            if spread["low"] <= 1.0 <= spread["high"]:
                factor += " — tie"
            table_rows.append((fpm, f"| {label} | {workers} | "
                                   f"**{fmt_number(fpm)}** | - | - | {factor} |"))

        for serving, (pworkers, pchildren) in sorted(prefork_shapes.items()):
            key = {"arm": "volucer-prefork", "workers": str(pworkers),
                   "children": str(pchildren), "opcache": "on",
                   "conc": str(conc), "threads": "12"}
            prefork = cell_median(rows, key, "rps")
            if prefork is None:
                continue
            p50 = cell_median(rows, key, "p50", parse_latency)
            p99 = cell_median(rows, key, "p99", parse_latency)
            spread = ratio_with_spread(rows, reference_key, key)
            factor = f"x{spread['centre']:.1f} ({spread['low']:.2f}–{spread['high']:.2f})"
            if spread["low"] <= 1.0 <= spread["high"]:
                factor += " — tie"
            table_rows.append((prefork, (
                f"| volucer spawn_cgi, {pchildren} child"
                f"{'ren' if pchildren > 1 else ''} in 1 slot | {serving} | "
                f"**{fmt_number(prefork)}** | "
                f"{fmt_number(p50) if p50 is not None else '-'} ms | "
                f"{fmt_number(p99) if p99 is not None else '-'} ms | "
                f"{factor} |")))

        for _, line in sorted(table_rows, key=lambda item: -item[0]):
            lines.append(line)
        if smaller_pools:
            listed = ", ".join(
                f"{w} child{'ren' if w > 1 else ''}" for w in smaller_pools
            )
            lines.append("")
            lines.append(
                f"The chart shows the **{reference_workers}-child** pool and the "
                f"preforked shapes. The {listed} pool is in the table but not in "
                "the chart: it is a deliberately undersized server, and at ten "
                "times the rate of the others it would compress the bars that are "
                "level with php-fpm down to a few pixels."
            )
        lines.append("")

    # --- Memory: the argument the `children` key actually makes. ---
    #
    # The throughput above says the two deployments are level at the same
    # number of processes. The memory below says the other half: what the
    # same throughput costs in resident memory.
    mem_rows = matrix_memory(MATRIX_DIRS["prefork"])
    if mem_rows:
        post = [r for r in mem_rows if r.get("phase") == "post"]
        if post:
            lines.append("## What the same throughput costs in memory")
            lines.append("")
            lines.append("Proportional set size (PSS) of the whole process tree, after the run.")
            lines.append("PSS divides each shared page by the number of processes mapping it, so")
            lines.append("a page the forked children share counts once — which is the whole point")
            lines.append("of the `children` key.")
            lines.append("")
            lines.append("| deployment | serving processes | PSS (MB) |")
            lines.append("|---|---:|---:|")

            def pss_of(arm, workers, children=None):
                subset = [r for r in post
                          if r.get("arm") == arm and r.get("workers") == str(workers)
                          and (r.get("children") or "").strip() == (children or "")]
                values = []
                for row in subset:
                    try:
                        values.append(float(row["pss_mb"]))
                    except (TypeError, ValueError):
                        continue
                return statistics.median(values) if values else None

            for workers in fpm_workers:
                value = pss_of("fpm", workers)
                if value is None:
                    continue
                lines.append(
                    f"| nginx + php-fpm, {workers} child{'ren' if workers > 1 else ''} | "
                    f"{workers} | {value:.1f} |"
                )
                shape = prefork_shapes.get(workers)
                if not shape:
                    continue
                pworkers, pchildren = shape
                pvalue = pss_of("volucer-prefork", pworkers, str(pchildren))
                if pvalue is None:
                    continue
                lines.append(
                    f"| volucer spawn_cgi, {pchildren} child"
                    f"{'ren' if pchildren > 1 else ''} in 1 slot | {workers} | {pvalue:.1f} |"
                )
            lines.append("")

    return {"pages": 1, "files": files, "body": "\n".join(lines)}



# --------------------------------------------------------------------------
# View: modes — one server, five shapes
# --------------------------------------------------------------------------

def view_modes(out_dir: Path) -> dict:
    """The shape comparison: the same server in five configurations.

    Every arm is volucer, so a difference between two rows is that shape and
    nothing else — the transport, the process model, the SAPI reset, or the
    `children` fork inside a cold slot.
    """
    rows = matrix_rows(MATRIX_DIRS["modes"])
    if not rows:
        return {"pages": 0, "files": []}

    meta = load_meta(MATRIX_DIRS["modes"])
    stamp = meta_stamp(meta)

    arms = [arm for arm in MODE_ARMS if any(r.get("arm") == arm for r in rows)]
    if not arms:
        return {"pages": 0, "files": []}

    concurrencies = sorted({int(r["conc"]) for r in rows if r.get("conc", "").isdigit()})
    workers = sorted({int(r["workers"]) for r in rows if r.get("workers", "").isdigit()})

    svg_dir = out_dir / "svg" / "modes"
    svg_dir.mkdir(parents=True, exist_ok=True)
    files: list[str] = []
    lines: list[str] = []

    # --- Chart: the best configuration of each shape, across concurrency. ---
    #
    # The `volucer-prefork` arm has a *second* axis: `children`, the number of
    # PHP processes behind each listening socket. Its best configuration is
    # therefore a (workers, children) pair, and a view that looked only at
    # `workers` would report the prefork shape's best as `children = 1` — which
    # is just the `spawn_cgi` shape with a different name.
    for conc in concurrencies:
        series: dict[str, list[float | None]] = {}
        labels: dict[str, str] = {}
        for arm in arms:
            best = best_configuration(rows, arm, conc)
            series[arm] = [best["rps"]]
            label = MODE_ARMS[arm]
            if best["children"]:
                label = f"{label}, {best['children']} children/slot"
            labels[arm] = label

        if not any(any(v is not None for v in row) for row in series.values()):
            continue

        chart = f"modes-c{conc}.svg"
        write(svg_dir / chart, grouped_bars(
            categories=[f"c={conc}"],
            series=series,
            colors={arm: MODE_COLORS.get(arm, "#94a3b8") for arm in arms},
            labels=labels,
            title=f"Best configuration of each shape at c={conc} — requests per second",
            value_suffix="rps",
            note=stamp,
            height=300,
        ))
        files.append(chart)

        lines.append(f"## At c={conc}")
        lines.append("")
        lines.append(f"![Best configuration of each shape at c={conc}](svg/modes/{chart})")
        lines.append("")
        lines.append("| shape | best rps | workers | children/slot | p50 | p99 |")
        lines.append("|---|---:|---:|---:|---:|---:|")
        for arm in arms:
            best = best_configuration(rows, arm, conc)
            if best["rps"] is None:
                lines.append(f"| {MODE_ARMS[arm]} | - | - | - | - | - |")
                continue
            key = {"arm": arm, "workers": str(best["workers"]), "conc": str(conc)}
            if best["children"]:
                key["children"] = best["children"]
            p50 = cell_median(rows, key, "p50", parse_latency)
            p99 = cell_median(rows, key, "p99", parse_latency)
            lines.append(
                f"| {MODE_ARMS[arm]} | **{fmt_number(best['rps'])}** | {best['workers']} | "
                f"{best['children'] or '—'} | "
                f"{fmt_number(p50) if p50 is not None else '-'} ms | "
                f"{fmt_number(p99) if p99 is not None else '-'} ms |"
            )
        lines.append("")

    # --- The memory table, which is where the shapes differ in kind. ---
    #
    # The full grid is 40+ rows, which is a data dump rather than a page. Two
    # readings are worth publishing: the cost of the shape at a fixed worker
    # count, and the same number of PHP processes arranged two different ways.
    mem_rows = matrix_memory(MATRIX_DIRS["modes"])
    if mem_rows:
        post = [r for r in mem_rows if r.get("phase") == "post"]
        if post:
            lines.append("## Memory")
            lines.append("")
            lines.append("Proportional set size (PSS) of the whole process tree, after the run.")
            lines.append("PSS divides each shared page by the number of processes mapping it, so a")
            lines.append("page the forked children share counts once — which is exactly the effect")
            lines.append("the `children` shape is claiming.")
            lines.append("")

            # --- Chart one: PSS against the worker count, one line per shape. ---
            #
            # The `volucer-prefork` arm is drawn at `children = 1`, because that
            # is the configuration that is comparable with one process per slot.
            # Its other `children` values are a different shape and are in the
            # second chart, where the process count is held equal instead.
            chart_shapes: list[str] = []
            for arm in arms:
                if arm == "volucer-prefork":
                    continue
                if any(r.get("arm") == arm for r in post):
                    chart_shapes.append(arm)
            if "volucer-prefork" in arms and any(
                r.get("arm") == "volucer-prefork" and (r.get("children") or "").strip() == "1"
                for r in post
            ):
                chart_shapes.append("volucer-prefork")

            worker_levels = sorted({int(r["workers"]) for r in post if r.get("workers", "").isdigit()})
            series: dict[str, list[float | None]] = {}
            labels: dict[str, str] = {}
            colors: dict[str, str] = {}
            for arm in chart_shapes:
                values: list[float | None] = []
                for worker in worker_levels:
                    key = {"arm": arm, "workers": str(worker), "phase": "post"}
                    if arm == "volucer-prefork":
                        key["children"] = "1"
                    values.append(cell_median(post, key, "pss_mb"))
                series[arm] = values
                label = MODE_ARMS[arm]
                if arm == "volucer-prefork":
                    label = f"{label}, 1 child/slot"
                labels[arm] = label
                colors[arm] = MODE_COLORS.get(arm, "#94a3b8")

            if series:
                mem_chart = "modes-memory.svg"
                write(svg_dir / mem_chart, grouped_bars(
                    categories=[f"w={w}" for w in worker_levels],
                    series=series,
                    colors=colors,
                    labels=labels,
                    title="Resident memory against the worker count",
                    value_suffix="MiB",
                    note=stamp,
                    height=420,
                ))
                files.append(mem_chart)
                lines.append(f"![Resident memory against the worker count](svg/modes/{mem_chart})")
                lines.append("")
                lines.append("| shape | " + " | ".join(f"w={w}" for w in worker_levels) + " |")
                lines.append("|---|" + "---:|" * len(worker_levels))
                for arm in chart_shapes:
                    row = []
                    for index in range(len(worker_levels)):
                        value = series[arm][index]
                        row.append(f"{value:.1f}" if value is not None else "-")
                    lines.append(f"| {labels[arm]} | " + " | ".join(row) + " |")
                lines.append("")

            # --- Chart two: the same PHP processes, arranged two ways. ---
            #
            # The `children` shape exists to answer one question: for the same
            # number of PHP processes, is a forked slot cheaper than one
            # process per slot? The comparison has to hold the process count
            # equal, or it is comparing two different amounts of server.
            same_processes = same_process_count_comparison(post)
            if len(same_processes) >= 2:
                rows_out: list[str] = []
                low: list[float] = []
                high: list[float] = []
                centre: list[float] = []
                for entry in same_processes:
                    rows_out.append(entry["label"])
                    low.append(entry["min"])
                    high.append(entry["max"])
                    centre.append(entry["median"])

                proc_chart = "modes-same-processes.svg"
                write(svg_dir / proc_chart, range_bars(
                    categories=rows_out,
                    low=low,
                    high=high,
                    centre=centre,
                    colour="#2563eb",
                    title="The same number of PHP processes, arranged two ways",
                    value_suffix="MiB",
                    note="The bar spans the measured range across the rounds; the dot is "
                         "the median. PSS divides shared pages between the processes "
                         "that map them, so a page the forked children share counts once. "
                         + stamp,
                ))
                files.append(proc_chart)
                lines.append("### The same number of PHP processes, two ways")
                lines.append("")
                lines.append(f"![The same number of PHP processes, arranged two ways](svg/modes/{proc_chart})")
                lines.append("")
                lines.append("| shape | PHP processes | median PSS (MiB) | min | max | vs separate slots |")
                lines.append("|---|---:|---:|---:|---:|---:|")
                # The multiplier is against the *separate slots* row with the
                # same process count, not against the lightest row on the
                # chart. A chart holds several process counts, and comparing
                # across them would state a ratio between two different
                # amounts of server.
                baseline: dict[int, float] = {}
                for entry in same_processes:
                    if "separate slots" in entry["label"]:
                        baseline[entry["processes"]] = entry["median"]

                for entry in same_processes:
                    base = baseline.get(entry["processes"])
                    if base and "separate slots" not in entry["label"]:
                        ratio = f"{base / entry['median']:.1f}× less"
                    else:
                        ratio = "—"
                    lines.append(
                        f"| {entry['label']} | {entry['processes']} | "
                        f"**{entry['median']:.1f}** | {entry['min']:.1f} | "
                        f"{entry['max']:.1f} | {ratio} |"
                    )
                lines.append("")
                # Every forked arrangement is compared against the separate
                # slots with the same serving count, and the range across all
                # of them is reported. A single number chosen from several
                # ways to reach the same process count would be a cherry-pick:
                # the arrangements differ in how many masters they carry, and
                # the honest statement is the range.
                pairs: list[tuple[int, str, float]] = []
                for entry in same_processes:
                    base = baseline.get(entry["processes"])
                    if base and "separate slots" not in entry["label"]:
                        pairs.append((entry["processes"], entry["label"], base / entry["median"]))

                if pairs:
                    lightest_pair = min(pairs, key=lambda p: p[2])
                    heaviest_pair = max(pairs, key=lambda p: p[2])
                    lines += [
                        "Across every arrangement the run measured, the forked pool holds",
                        f"**{lightest_pair[2]:.1f}× to {heaviest_pair[2]:.1f}× less** resident",
                        "memory than one process per slot, for the same number of serving",
                        "processes:",
                        "",
                        f"- **{heaviest_pair[1]}** — {heaviest_pair[2]:.1f}× less, at "
                        f"{heaviest_pair[0]} processes",
                        f"- **{lightest_pair[1]}** — {lightest_pair[2]:.1f}× less, at "
                        f"{lightest_pair[0]} processes",
                        "",
                        "The forked arrangement is lighter in every case. The spread is the",
                        "number of master processes the arrangement carries: one master for one",
                        "slot serving every child, or one master per slot.",
                        "",
                    ]

    return {"pages": 1, "files": files, "body": "\n".join(lines)}



# --------------------------------------------------------------------------
# The manifest
# --------------------------------------------------------------------------

VIEWS = {
    "servers": {
        "title": "The servers, side by side",
        "description": "Volucer against RoadRunner, FrankenPHP and nginx + php-fpm, "
                       "every arm through one harness on one interpreter.",
        "build": view_servers,
    },
    "modes": {
        "title": "One server, five shapes",
        "description": "The same server in five configurations: the transport, the "
                       "process model, the SAPI reset, and the forked slot.",
        "build": view_modes,
    },
    "cold": {
        "title": "The cold path against php-fpm",
        "description": "Volucer's spawn_cgi against nginx + php-fpm, at the same "
                       "number of serving PHP processes, in one run.",
        "build": view_cold,
    },
    "prefork": {
        "title": "Prefork versus one process per slot",
        "description": "What spawn_cgi's `children` key is worth.",
        "build": view_prefork,
    },
}

# The views that used to be published and are not any more.
#
# A published page that is no longer generated is worse than a page that was
# never written: it is still served, still indexed by the homepage's search,
# and still carrying a comparison the rest of the documentation no longer
# makes. So a retired view is named here, and publishing removes its page
# and its charts.
#
# The list is empty at the moment. The mechanism stays, because the day a
# view is retired is exactly the day somebody would forget to remove its
# page.
RETIRED_VIEWS: tuple[str, ...] = ()

PREAMBLE = """The charts on this page are generated from the committed result files in
[`volucer-competition`](https://github.com/sailantis/volucer-competition) by
`scripts/bench-report.py`, so a chart cannot disagree with the table beside it. A cell
with no successful repeat is printed as `-`, never as `0` — a zero reads as "measured,
and it was terrible" rather than "not measured". The method, the raw rows and the
controls live in that repository.

Every figure here was measured on one host, with one harness and one interpreter, so a
ratio between two arms is a ratio between two measurements made the same way. The host,
the kernel, the PHP version and the method are printed on every chart.
"""


def build(out_dir: Path, only: str | None) -> list[dict]:
    """Build every view (or one) and write the markdown plus the charts."""
    out_dir.mkdir(parents=True, exist_ok=True)
    built = []

    for key, view in VIEWS.items():
        if only and key != only:
            continue
        result = view["build"](out_dir)
        if not result.get("pages"):
            continue

        body = result.get("body", "")
        markdown = f"# {view['title']}\n\n{view['description']}\n\n{PREAMBLE}\n{body}"
        target = out_dir / f"{key}.md"
        with target.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write(markdown)

        built.append({
            "key": key,
            "title": view["title"],
            "description": view["description"],
            "markdown": target,
            "charts": result.get("files", []),
        })

    return built


def publish(built: list[dict], target: str) -> list[str]:
    """Copy a built view into the volucer repository's documentation.

    Also writes ``12-BENCHMARKS.md`` as the section index, so the docs tree has
    one entry point that links every generated page. The index is generated
    rather than hand-written for the same reason the pages are: a link written
    by hand is a link that goes stale the moment a view is renamed.
    """
    if target != "volucer":
        return [f"unknown publish target: {target}"]

    docs = ROOT.parent / "volucer" / "docs"
    if not docs.is_dir():
        return [f"volucer docs not found at {docs}"]

    log: list[str] = []
    index_lines = [
        "# Benchmarks",
        "",
        "**Measured, not estimated.** Every number in this section comes from a committed",
        "result file in",
        "[`volucer-competition`](https://github.com/sailantis/volucer-competition), and the",
        "charts are generated from those same files — so a chart cannot disagree with the",
        "table beside it.",
        "",
        "**A cell with no successful repeat is printed as `-`, never as `0`.** A zero reads",
        'as "measured, and it was terrible" rather than "not measured".',
        "",
        "**One host, one harness, one interpreter.** Every figure below was measured on the",
        "same machine, through the same script, against the same PHP build — so a ratio",
        "between two arms is a ratio between two measurements made the same way. The host,",
        "the kernel, the PHP version and the method are printed on every chart.",
        "",
        "Each page below is written by `scripts/bench-report.py` in the competition",
        "repository. None of them is edited by hand. The complete method, the raw rows and",
        "the controls live in that repository.",
        "",
    ]

    for view in built:
        destination = docs / f"12-BENCHMARKS-{view['key'].upper()}.md"
        # The Markdown is written against the build tree's layout, which puts
        # the charts in a sibling `svg/` directory. Publishing moves them under
        # `images/`, so the link the reader follows has to move with them — a
        # page whose images all 404 is a page that looks broken rather than one
        # that looks empty.
        published = view["markdown"].read_text(encoding="utf-8").replace(
            f"](svg/{view['key']}/",
            f"](images/benchmarks/{view['key']}/",
        )
        with destination.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write(published)
        log.append(f"wrote docs/{destination.name}")

        index_lines.append(f"- **[{view['title']}]({destination.name})** — {view.get('description', '')}")

        images = docs / "images" / "benchmarks" / view["key"]
        images.mkdir(parents=True, exist_ok=True)
        source_dir = ROOT / "results" / "bench-report" / "svg" / view["key"]
        for chart in view["charts"]:
            source = source_dir / chart
            if source.exists():
                (images / chart).write_bytes(source.read_bytes())
                log.append(f"wrote docs/images/benchmarks/{view['key']}/{chart}")

        # The charts this view no longer draws are removed. A stale SVG in the
        # published tree is a file nothing links to any more, and it looks
        # exactly like a chart the page forgot to include.
        current = set(view["charts"])
        for stale in images.glob("*.svg"):
            if stale.name not in current:
                stale.unlink()
                log.append(f"removed docs/images/benchmarks/{view['key']}/{stale.name}")

    index = docs / "12-BENCHMARKS.md"
    with index.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(index_lines).rstrip("\n") + "\n")
    log.append("wrote docs/12-BENCHMARKS.md")

    # A view that is no longer generated loses its published page and its
    # charts. A page left behind would still be served, and would still be
    # linked from the homepage's search index, and would carry a comparison
    # the rest of the documentation no longer makes.
    published_keys = {view["key"] for view in built}
    for retired in RETIRED_VIEWS:
        if retired in published_keys:
            continue
        page = docs / f"12-BENCHMARKS-{retired.upper()}.md"
        if page.exists():
            page.unlink()
            log.append(f"removed docs/{page.name}")
        images = docs / "images" / "benchmarks" / retired
        if images.is_dir():
            for chart in sorted(images.glob("*.svg")):
                chart.unlink()
                log.append(f"removed docs/images/benchmarks/{retired}/{chart.name}")
            images.rmdir()
            log.append(f"removed docs/images/benchmarks/{retired}/")

    return log


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate the volucer benchmark report.")
    parser.add_argument("--out", default=str(RESULTS / "bench-report"))
    parser.add_argument("--view", default=None)
    parser.add_argument("--publish", default=None)
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()

    if args.list:
        print("Views:")
        for key, view in VIEWS.items():
            print(f"  {key:<12} {view['description']}")
        return 0

    out_dir = Path(args.out).resolve()
    built = build(out_dir, args.view)
    if not built:
        print("nothing to build: no result files found")
        return 1

    for view in built:
        print(f"wrote {view['markdown']} ({len(view['charts'])} chart(s))")

    if args.publish:
        for line in publish(built, args.publish):
            print(line)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
