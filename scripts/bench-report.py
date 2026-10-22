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
    "servers": "run85-scale-items-2",
    "servers_root": "run85-scale-root",
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

# The arms the one page compares, in the order a reader meets them.
#
# `volucer-fastcgi` is measured but is NOT published in the throughput
# comparison: it is `spawn_cgi` with one process per slot, and the page's
# prefork arm is `spawn_cgi` with `children` — the same cold path, arranged
# so that one slot serves many requests. It is still measured, because it is
# the other side of the memory comparison, which is where the difference
# between the two arrangements shows up.
COMPARISON_ARMS = (
    "volucer-attach",
    "volucer-worker",
    "volucer-unix",
    "rr",
    "frankenphp",
    "volucer-prefork",
    "fpm",
)

# The process tiers the page publishes.
#
# The 16-process tier carries every arm, so it is the comparison of servers.
# The 32-process tier carries the two cold deployments, and it is where the
# cold path is still gaining from more processes: `spawn_cgi` with `children`
# and `nginx + php-fpm` both get faster, while the warm arms get slower.
#
# The 64-process tier is measured and is not published. It is the tier where
# the cold path has stopped gaining for volucer — `spawn_cgi` with `children`
# is slower there than at 32 — so it says nothing about a volucer deployment.
# What it does say is that `nginx + php-fpm` keeps improving, which is a fact
# about php-fpm rather than about volucer, and a fact about another server's
# ceiling is not a reason for a reader to run more volucer processes. The
# rows are in the repository, and the page says where they are.
PUBLISHED_TIERS = (16, 32)

# The process tiers the run measured. The memory section publishes all of
# them, because memory is a cost argument rather than a throughput claim:
# what a deployment holds while it serves is a fact about the deployment at
# every size, and the forked pool's advantage grows with the process count.
MEASURED_TIERS = (16, 32, 64)

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


# --------------------------------------------------------------------------
# View: versions — what was measured, exactly
# --------------------------------------------------------------------------

# The version line of each participant, in the order the page lists them.
#
# Read out of `meta.txt`, not written here: a version written into the
# generator is a second copy of a fact that the run recorded, and the second
# copy is the one that goes stale. The run's own header block is the record,
# and the page quotes it.
#
# The key is the `meta.txt` key, the value is the label the page shows.
VERSION_SOURCES = (
    ("php", "PHP (CLI)"),
    ("php-cgi", "PHP (CGI)"),
    ("php-fpm", "PHP (FPM)"),
    ("volucer", "Volucer"),
    ("volucer ref", "Volucer commit"),
    ("roadrunner", "RoadRunner"),
    ("frankenphp", "FrankenPHP"),
    ("nginx", "nginx"),
    ("app ref", "Bench app commit"),
)


def shorten_version(value: str) -> str:
    """One version number out of a full version string.

    `PHP 8.5.11 (cli) (built: Sep 24 2026 13:49:29) (NTS)` is what the run
    recorded, and it is more than a table cell wants: the build date and the
    SAPI are the run's own business, and a reader comparing two runs wants
    the number. The full string stays in the run's `meta.txt`, which the
    table links to.
    """
    # The build stamp and the SAPI are both parenthesised, and dropping them
    # is what leaves `PHP 8.5.11 (cli)`.
    text = value.split(" (built:")[0].strip()
    return text


def shorten_tool_version(value: str, label: str) -> str:
    """The version number of a tool, without the rest of its version line.

    `rr version 2025.1.15 (build time: ..., go1.26.4), OS: linux, arch:
    amd64` names the build and the platform as well as the version. The
    platform is the host's, and the build time is not a property of the
    version — so what is left is the number a reader compares against the
    release they would install.
    """
    if value.startswith("rr version "):
        rest = value[len("rr version "):]
        return rest.split(",")[0].split(" (")[0].strip()

    if value.startswith("FrankenPHP v"):
        # `FrankenPHP v1.13.0 PHP 8.5.11 Caddy v2.11.7 h1:...` — the
        # FrankenPHP version, then the PHP it embeds, then the Caddy under
        # it. The first is the version being compared; the PHP is already a
        # row of its own, so it is dropped here rather than repeated.
        parts = value.split()
        if len(parts) >= 2:
            return parts[1]
        return value

    if value.startswith("nginx version: "):
        return value[len("nginx version: "):].strip()

    return value


# The version of the *program* each arm runs.
#
# The arms are the measurement; the program behind them is what a reader has to
# install to reproduce it, and the same program backs several arms — four of
# them are volucer in four shapes. So the chart's version line names volucer
# once rather than once per arm.
ARM_VERSIONS = {
    "volucer-worker": "volucer",
    "volucer-unix": "volucer",
    "volucer-attach": "volucer",
    "volucer-fastcgi": "volucer",
    "volucer-prefork": "volucer",
    "rr": "roadrunner",
    "frankenphp": "frankenphp",
    "fpm": "nginx",
}

# The order the version line names the programs: the server under test, then
# what it is measured against, then the interpreter they all run on.
VERSION_ORDER = ("volucer", "roadrunner", "frankenphp", "nginx")

VERSION_LABELS = dict(VERSION_SOURCES)


def version_value(meta: dict, key: str) -> str:
    """The version of one participant, as a table cell or a chart line prints it."""
    value = meta.get(key, "").strip()
    if not value:
        return ""
    if key in ("roadrunner", "frankenphp", "nginx"):
        return shorten_tool_version(value, VERSION_LABELS.get(key, key))
    return shorten_version(value)


def versions_line(meta: dict, arms) -> str:
    """The one-line build stamp of every program in a chart.

    A chart is embedded as an image and gets copied or linked on its own, so it
    has to name the builds it measured without relying on the table beside it —
    the table is where a reader checks the versions, and the chart is where they
    read the numbers. Both come from the run's own ``meta.txt``, so neither can
    drift from the other.

    Only the programs the chart actually measured are named: a version line that
    listed RoadRunner under a chart of volucer alone would describe a run that
    is not the one on the card. A program the run measured but did not record a
    version for is printed as ``unknown`` rather than dropped — an absent name
    reads as "not in this chart", while "unknown" states honestly that the
    chart measured it and cannot name its build.
    """
    parts: list[str] = []
    for key in VERSION_ORDER:
        if not any(ARM_VERSIONS.get(arm) == key for arm in arms):
            continue
        label = VERSION_LABELS.get(key, key)
        value = version_value(meta, key)
        if not value:
            parts.append(f"{label} unknown")
            continue

        if key == "volucer":
            # `volucer 0.1.0` repeats the label; the number is what is left.
            number = value[len("volucer "):] if value.startswith("volucer ") else value
            text = f"{label} {number}"
            # A version number does not say which source produced the binary,
            # so the commit is what makes the row reproducible.
            ref = meta.get("volucer ref", "").strip()
            if ref and not ref.startswith("("):
                text += f" ({ref})"
            parts.append(text)
        elif key == "nginx":
            # `nginx/1.24.0 (Ubuntu)`: the label names the program already, and
            # the distribution suffix is the host's, not the build's.
            number = value[len("nginx/"):] if value.startswith("nginx/") else value
            parts.append(f"{label} {number.split(' (')[0]}")
        else:
            parts.append(f"{label} {value}")

    php = meta.get("php", "").strip()
    if php:
        # `PHP 8.5.11 (cli) (built: ...) (NTS)`: the number is what a reader
        # compares against the build they would install.
        words = php.split()
        parts.append(" ".join(words[:2]) if len(words) >= 2 else php)

    return " · ".join(parts)


def view_versions(meta: dict) -> list[str]:
    """The versions the run was measured with, as a table.

    A throughput number is a fact about a *version* of a program, and a
    reader who cannot see which version cannot tell whether the number
    applies to the one they would install. The charts carry a short stamp for
    that reason; this is the long form of the same fact, in one place, for
    every participant in the comparison.

    The rows come from the run's own `meta.txt`, so they are the versions the
    run recorded rather than the versions a later release happens to be.
    """
    lines: list[str] = []
    rows: list[tuple[str, str]] = []

    for key, label in VERSION_SOURCES:
        value = meta.get(key, "")
        if not value:
            continue
        if key == "volucer ref":
            # The commit is already in the `volucer` row's version string
            # only as a version number; the commit is what says which source
            # produced the binary, so it is a row of its own.
            value = value.strip()
        elif key == "app ref":
            value = value.strip()
        elif key in ("roadrunner", "frankenphp", "nginx"):
            value = shorten_tool_version(value, label)
        else:
            value = shorten_version(value)
        rows.append((label, value))

    if not rows:
        return lines

    lines.append("## What was measured")
    lines.append("")
    lines.append(
        "**Every number on this page belongs to these versions.** A "
        "throughput figure is a fact about a version of a program, not about "
        "the program in general: the same measurement on another build is "
        "another number. These are the versions this run used, read from the "
        "run's own record, and the raw rows are in "
        "[`volucer-competition`](https://github.com/sailantis/volucer-competition)."
    )
    lines.append("")
    lines.append("| what | version |")
    lines.append("|---|---|")
    for label, value in rows:
        lines.append(f"| {label} | {value} |")
    lines.append("")
    lines.append(
        "The **host** is the machine all of them ran on, the **method** is the "
        "harness that drove them, and the **builds** are the versions of the "
        "programs compared — all three are printed on every chart above, so a "
        "reader who has only the image still knows what it measured. One host, "
        "one harness, one interpreter, one pass: that is what makes a ratio "
        "between two arms a ratio between two measurements made the same way."
    )
    lines.append("")
    return lines


def meta_stamp(meta: dict) -> str:
    """The conditions a chart's numbers were measured under.

    The host, the kernel and the method — the three facts that make a number
    comparable with another one. They are stamped on every chart because a
    throughput figure with no host beside it is not a measurement a reader can
    weigh: the same number on another host, or with another client, is another
    number.

    The builds are the other half of that provenance and they are drawn as a
    line of their own (see :func:`versions_line`): a reader scanning a chart
    looks for "which version", and a version buried in a sentence about the
    host is a version they have to hunt for.
    """
    parts: list[str] = []

    host = meta.get("host", "").strip()
    if host:
        parts.append(host)

    kernel = meta.get("kernel", "").strip()
    if kernel:
        parts.append(kernel)

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


def by_round(rows: list[dict], key: dict, field: str = "rps") -> dict[str, float]:
    """The value of one field for one configuration, keyed by the round.

    The round is the unit of simultaneity in an interleaved run: both arms
    were measured once per round, so a round holds a ratio of the two taken
    under the same conditions rather than tens of minutes apart.

    A row whose value cannot be read is dropped rather than counted as zero,
    and a configuration that was measured in no round at all is an empty
    mapping.
    """
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
    values_a = by_round(rows, key_a, field)
    values_b = by_round(rows, key_b, field)
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
# View: benchmarks — the one page: the servers side by side, and their cost
# --------------------------------------------------------------------------

def view_benchmarks(out_dir: Path) -> dict:
    """The whole benchmark: the servers side by side, and what they cost.

    One page, one run, one data source.

    The run is `results/run85-scale-items-2`: every arm, at 16, 32 and 64
    serving PHP processes, at c=8, 16, 32 and 64, in one interleaved pass
    over one host. Every ratio the page prints is therefore a ratio between
    two measurements made the same way, in the same round, on the same host
    — which is the property the page's factor column depends on, and the
    reason the page reads from this run alone rather than from the earlier
    16-process run, which was measured on a smaller host.

    This is the *second* pass of that grid, and it is the one the page
    publishes because the first pass carried an artefact the second does
    not: in `run85-scale-items` the `volucer-worker` arm lost about 6% of
    its throughput from the first round to the third, in every cell, while
    every other arm held. The re-measurement repeated the same grid on the
    same host, with the same binary and the same application, and that
    decline did not reproduce — the arm's mean change from round 1 to
    round 3 is -0.02% against -5.92%. A published number that moves by
    12% with the order of the run, and does not move at all when the run
    is repeated, is measuring the run rather than the server, so the
    cleaner pass is the one the page is built from. Both passes are in
    the repository.

    The page has two parts. The first is the comparison: the servers, side by
    side, at the number of PHP processes each of them is given. The second is
    the cost: the resident memory of the same deployments, because throughput
    alone is half the answer to "which server should I run".
    """
    svg_dir = out_dir / "svg" / "benchmarks"
    svg_dir.mkdir(parents=True, exist_ok=True)
    files: list[str] = []
    lines: list[str] = []

    directory = MATRIX_DIRS["servers"]
    rows = matrix_rows(directory)
    if not rows:
        return {"pages": 0, "files": []}

    meta = load_meta(directory)
    # The conditions every chart was measured under: the host, the kernel and
    # the method. The builds are a line of their own, because they differ per
    # chart - a chart of two servers must not name a third.
    stamp = meta_stamp(meta)

    arms = [arm for arm in COMPARISON_ARMS
            if any(r.get("arm") == arm for r in rows)]
    if not arms:
        return {"pages": 0, "files": []}

    # The opcache axis. A run with both modes compares them; a run with one
    # mode has no axis to compare, and printing an empty table of both would
    # read like a failed measurement.
    modes = sorted({r.get("opcache", "") for r in rows})
    opcache_modes = modes if len(modes) > 1 else [modes[0]] if modes else ["on"]

    concurrencies = sorted({int(r["conc"]) for r in rows if r.get("conc", "").isdigit()})

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
    # for the whole run. Resolving it once - which is what this did before -
    # finds no single count that covers every row, falls back to "the most
    # common", and then every row whose thread count differs is invisible:
    # the c=8 cells were measured, and the page printed none of them. A
    # level that is missing from the page because of a bookkeeping detail in
    # the report is indistinguishable from a level that was never measured,
    # and the second is a claim while the first is a bug.
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

    # The serving-process count each arm was measured at.
    #
    # `spawn_cgi` with `children` puts several processes behind one listening
    # socket, so its process count is not its worker count. Fixing the
    # serving-process count is what makes two rows comparable, and the
    # function that knows the difference is `php_process_count`.
    def tiers_of(arm: str) -> list[int]:
        found: set[int] = set()
        for row in rows:
            if row.get("arm") != arm:
                continue
            workers = row.get("workers", "")
            children = (row.get("children") or "").strip()
            if not workers.isdigit():
                continue
            count = php_process_count(
                arm, int(workers), int(children) if children.isdigit() else 0)
            if count > 0:
                found.add(count)
        return sorted(found)

    # The process tiers the page publishes.
    #
    # A tier is published when it says something about the deployment a
    # reader would actually run. The 16-process tier carries every arm, so it
    # is the comparison of servers. The 32-process tier carries the two cold
    # deployments, and it is the tier where the cold path is still gaining:
    # `spawn_cgi` with `children` and `nginx + php-fpm` both get faster with
    # more processes, while the warm arms get slower.
    #
    # The 64-process tier is measured and is not published. It is the tier
    # where the cold path has stopped gaining - `spawn_cgi` with `children`
    # is slower there than at 32 - so it says nothing about a Volucer
    # deployment, and what it does say is that `nginx + php-fpm` keeps
    # improving, which is a fact about php-fpm rather than about volucer.
    # The rows are in the repository, and the page says where.
    published_tiers = [tier for tier in PUBLISHED_TIERS
                       if any(tier in tiers_of(arm) for arm in arms)]
    if not published_tiers:
        return {"pages": 0, "files": []}

    endpoint = meta.get("endpoint", "/") or "/"
    endpoint_name = "the landing page" if endpoint == "/" else "the ORM page"
    lines.append(f"## `GET {endpoint}` — {endpoint_name}")
    lines.append("")

    # What the run is, stated before the numbers rather than after them.
    lines.append(
        "Every row below was measured in **one interleaved pass** — every arm, "
        "at every process count, at every load, in one round-robin over one "
        "host, with the order rotating so that no cell is always first and no "
        "cell is always last. The **PHP procs** column is the cost side of "
        "the comparison: it says how many PHP processes serve the requests, "
        "and it is what the host pays for."
    )
    lines.append("")
    lines.append(
        "The `spawn_cgi` arm with `children` puts several processes behind one "
        "listening socket, so it reaches a given throughput with a different "
        "amount of server than the arms beside it. That is why the process "
        "count is a column and not a footnote: a row with more processes is "
        "not a better row, it is a row that bought its throughput with more "
        "server."
    )
    lines.append("")

    # How to read the charts, stated once, because a chart that needs a
    # paragraph in the reader's head to be read is a chart that will be
    # misread. These paragraphs explain the ENCODING only: which mark is which
    # number, and what a range on a bar means. No figure from this run appears
    # in them, so a re-measurement cannot leave a sentence behind claiming the
    # previous run's result.
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
        "that chart*, not a fixed server: a cold deployment can overtake a warm "
        "one as the host saturates, so the fastest server is not necessarily "
        "the same one at every load — and naming it per chart is more honest "
        "than a fixed reference that would read as a claim about the same "
        "winner every time."
    )
    lines.append("")
    lines.append(
        "**The range on each bar is the spread of the comparison, not of the "
        "server.** Both servers were measured once per round, interleaved, so "
        "each round holds a ratio of the two. The range is the smallest and "
        "largest of those round-paired ratios, scaled back into requests per "
        "second. Pairing by round is what makes that range honest: a host that "
        "drifts over the run moves both servers in the same round, so the ratio "
        "within a round is steadier than either server's own spread. A range "
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

        for conc in concurrencies:
            threads = threads_for(conc)

            # The rows of this chart: one per (arm, process tier) that was
            # measured at this concurrency.
            #
            # An arm can be measured at more than one process count, and the
            # process count is what the rows are compared on, so a row is an
            # (arm, tier) pair and not an arm.
            entries: list[dict] = []
            for arm in arms:
                for tier in published_tiers:
                    if tier not in tiers_of(arm):
                        continue
                    best = configuration_at_process_count(
                        rows, arm, tier, conc, mode=mode, threads=threads)
                    if best["rps"] is None:
                        continue
                    entries.append({"arm": arm, "tier": tier, "best": best})

            if len(entries) < 2:
                continue

            # The baseline: the fastest row in the chart.
            #
            # The baseline is the **fastest row**, not a fixed arm. A fixed
            # reference would put a label on every bar that means something
            # different in every chart, and the reader would have to look it
            # up. The fastest server in the group is the natural yardstick:
            # it is 1.0x, and every other bar is labelled with its share of it.
            #
            # It is found from the data, per concurrency. It is not assumed to
            # be the same arm at every load, because it is not: a cold
            # deployment overtakes a warm one as the host saturates, and a
            # chart that kept naming the same baseline would be claiming a
            # winner the measurement does not have.
            reference = max(entries, key=lambda e: e["best"]["rps"])
            reference_best = reference["best"]
            reference_key = {
                "arm": reference["arm"],
                "workers": str(reference_best["workers"]),
                "opcache": mode,
                "conc": str(conc),
                "threads": threads,
            }
            if reference_best["children"]:
                reference_key["children"] = reference_best["children"]

            chart_rows: list[dict] = []
            ratios: dict[tuple[str, int], dict] = {}

            for entry in entries:
                arm = entry["arm"]
                tier = entry["tier"]
                best = entry["best"]
                server, model = SERVER_ARMS[arm]
                short = SHORT_MODELS.get(arm, model)

                # The chart's left-hand column has room for a name and a
                # model, not a sentence. The model carries the process count
                # here, because the chart has no column for it and two rows of
                # the same arm at different process counts would otherwise be
                # two identical labels.
                chart_model = f"{short} · {tier} procs"

                row = {
                    "name": server,
                    "model": chart_model,
                    "color": SERVER_COLORS.get(arm, "#94a3b8"),
                    "rps": best["rps"],
                    "low": None,
                    "high": None,
                    "factor": None,
                    "reference": entry is reference,
                }

                key = {"arm": arm, "workers": str(best["workers"]),
                       "opcache": mode, "conc": str(conc), "threads": threads}
                if best["children"]:
                    key["children"] = best["children"]

                if entry is reference:
                    # The baseline against itself is 1.0 by definition, and it
                    # has no range: it is the yardstick, and a yardstick with a
                    # range on it is not a yardstick.
                    spread = {"centre": 1.0, "low": 1.0, "high": 1.0,
                              "rounds": 0}
                else:
                    # How many times slower this row is than the baseline: the
                    # baseline divided by the row. It is the reciprocal of the
                    # share, because "twice as slow" is how a reader thinks
                    # about the result - and the same number describes a
                    # comparison of times rather than rates.
                    spread = ratio_with_spread(rows, reference_key, key)
                ratios[(arm, tier)] = spread

                row["factor"] = spread["centre"]
                if spread["low"] is not None and spread["high"] is not None:
                    # The range in requests per second: the reference's rate
                    # divided by the factor, and by the factor's extremes. The
                    # row's own rate sits inside it, because the factor is
                    # measured from it.
                    row["low"] = reference_best["rps"] / spread["high"]
                    row["high"] = reference_best["rps"] / spread["low"]

                chart_rows.append(row)

            slug = "root" if endpoint == "/" else endpoint.strip("/").replace("/", "-")
            chart = f"benchmarks-{slug}-{mode}-c{conc}.svg"

            write(svg_dir / chart, throughput_dots(
                rows=chart_rows,
                title=f"GET {endpoint} — {mode_title} at c={conc}",
                note="The bar is the request rate. The label behind it is how "
                     "many times slower that server is than the fastest server "
                     "in this chart, which is the dashed line. The range on "
                     "each bar is the spread of the round-paired comparison: "
                     "both servers were measured in the same round, so the "
                     "range is the spread of the comparison rather than the "
                     "drift of the host.",
                stamp=stamp,
                versions=versions_line(meta, [entry["arm"] for entry in entries]),
                reference_label="fastest here",
            ))
            files.append(chart)

            lines.append(f"![{mode_title} at c={conc}](svg/benchmarks/{chart})")

            # The table belongs to the highest concurrency the run was
            # measured at, which is the load the comparison is about: the
            # numbers above are the ones the table prints, and a table that
            # reported a different concurrency's numbers would contradict the
            # chart above it.
            if conc != concurrencies[-1]:
                continue

            lines.append("")
            lines.append(
                "The **factor** column is measured against **the fastest server "
                "in the table**, which is the row marked `x1.0`. It states how "
                "many times slower each server is, so `x1.0` is the fastest and "
                "`x2.5` is a quarter of its rate. The column carries the range "
                "of the round-paired ratios beside it, and a row marked **tie** "
                "is one whose range reaches across 1.0 — the two servers could "
                "not be told apart in this run."
            )
            lines.append("")
            lines.append("| server | model | PHP procs | rps | p50 | p99 | factor (range) |")
            lines.append("|---|---|---:|---:|---:|---:|---:|")
            # The rows are ordered by throughput, fastest first - the same
            # order as the chart above them. A table whose rows are in a
            # different order from the chart beside it is a table the reader
            # has to re-sort in their head.
            for entry in sorted(entries, key=lambda e: -(e["best"]["rps"] or 0.0)):
                arm = entry["arm"]
                tier = entry["tier"]
                best = entry["best"]
                rps = best["rps"]
                server, model = SERVER_ARMS[arm]
                key = {"arm": arm, "workers": str(best["workers"]),
                       "opcache": mode, "conc": str(conc), "threads": threads}
                if best["children"]:
                    key["children"] = best["children"]
                p50 = cell_median(rows, key, "p50", parse_latency)
                p99 = cell_median(rows, key, "p99", parse_latency)
                spread = ratios[(arm, tier)]
                if entry is reference or not spread.get("centre"):
                    # The reference is 1.0 by definition. It is printed
                    # rather than left blank, because a blank cell in this
                    # column would read as "not measured" — and it is the one
                    # cell in the column that was measured beyond doubt.
                    factor = "x1.0"
                else:
                    factor = f"x{spread['centre']:.1f}"
                    # The range is printed beside the factor because the
                    # chart beside the table draws it, and a chart that shows
                    # a number the table does not is a number the reader has
                    # to trust rather than check. It is the range of the
                    # round-paired ratios - the spread of the comparison, not
                    # the spread of the server.
                    #
                    # Two decimals, while the factor itself has one. The
                    # factor is read as a scale - x1.1, x2.5 - and one decimal
                    # is enough for that. The range is read as evidence, and
                    # one decimal would round a range of 0.99 to 1.01 into
                    # "1.0 - 1.0": a range that visibly does not cross 1.0
                    # beside a row marked **tie**, which is exactly the
                    # contradiction the range exists to prevent.
                    low = spread.get("low")
                    high = spread.get("high")
                    if low is not None and high is not None:
                        factor += f" ({low:.2f}–{high:.2f})"
                    # A factor whose range reaches across 1.0 is not a
                    # difference - the two servers could not be told apart in
                    # this run. Printing it as a plain factor would claim a
                    # result the measurement does not support, and would
                    # contradict the chart beside it, which says so.
                    if low is not None and high is not None and low <= 1.0 <= high:
                        factor += " — tie"
                lines.append(
                    f"| {server} | {model} | {tier} | "
                    f"**{fmt_number(rps)}** | "
                    f"{fmt_number(p50) if p50 is not None else '-'} ms | "
                    f"{fmt_number(p99) if p99 is not None else '-'} ms | {factor} |"
                )
            lines.append("")

        # The tier story, told once the numbers are on the page.
        lines.extend(tier_notes(rows, arms, published_tiers, modes[0] if modes else "on"))

    # --- The cost: what the same deployments hold in memory. ---
    #
    # The memory section publishes every tier the run measured, including the
    # 64-process one the throughput comparison stops before. Memory is a cost
    # argument rather than a throughput claim: what a deployment holds while it
    # serves is a fact about the deployment at every size, and the forked
    # pool's advantage grows with the process count — which is the whole
    # argument for it. A section that stopped at 32 would show the advantage
    # at its smallest.
    memory = view_memory(rows, meta, stamp, arms, MEASURED_TIERS, svg_dir, files)
    lines.extend(memory["lines"])
    files.extend(memory["files"])

    # --- What was measured: the versions, in one place. ---
    #
    # The charts carry a one-line stamp for the same reason. This is the long
    # form, and it is last on the page because it is the answer to "what do
    # I have to install to get these numbers" rather than part of the
    # comparison itself.
    lines.extend(view_versions(meta))

    return {"pages": 1, "files": files, "body": "\n".join(lines)}


def tier_notes(rows: list[dict], arms: list[str], tiers: list[int],
               mode: str) -> list[str]:
    """The two tables that read the process tiers against each other.

    Both are comparisons of the same run's cells, paired by the round they
    were measured in: the two cold deployments against each other with the
    process count held equal, and each arm's larger tier against its smaller
    one. The prose around them only says what a column or a ratio means; the
    numbers stay in the cells, so a re-measured run needs no rewritten
    sentence here.
    """
    notes: list[str] = []

    def key_for(arm: str, tier: int, conc: str) -> dict:
        if arm == "volucer-prefork":
            return {"arm": arm, "workers": "1", "children": str(tier),
                    "opcache": mode, "conc": conc, "threads": "12"}
        return {"arm": arm, "workers": str(tier), "opcache": mode,
                "conc": conc, "threads": "12"}

    conc = "64"

    # The cold pair, head to head, at each tier.
    if "volucer-prefork" in arms and "fpm" in arms:
        lines: list[str] = []
        pairs: list[tuple[int, float, float, float]] = []
        for tier in tiers:
            prefork_key = key_for("volucer-prefork", tier, conc)
            fpm_key = key_for("fpm", tier, conc)
            prefork_rps = cell_median(rows, prefork_key, "rps")
            fpm_rps = cell_median(rows, fpm_key, "rps")
            if prefork_rps is None or fpm_rps is None:
                continue
            spread = ratio_with_spread(rows, prefork_key, fpm_key)
            if spread["centre"] is None:
                continue
            pairs.append((tier, prefork_rps, fpm_rps, spread["centre"]))

        if pairs:
            lines.append(
                "**The two cold deployments, head to head.** `spawn_cgi` with "
                "`children` and `nginx + php-fpm` are the same idea reached two "
                "ways — a forked pool of `php-cgi` children behind one socket, "
                "or a pool of `php-fpm` children behind another. The table below "
                "holds the pair at each process count the run covered, so the "
                "two are compared with the amount of server held equal:"
            )
            lines.append("")
            lines.append("| PHP procs | server | model | rps | spawn_cgi ÷ php-fpm |")
            lines.append("|---:|---|---|---:|---:|")
            for tier, prefork_rps, fpm_rps, factor in pairs:
                lines.append(
                    f"| {tier} | volucer | spawn_cgi (cold, unix, children) | "
                    f"**{fmt_number(prefork_rps)}** | x{factor:.2f} |"
                )
                lines.append(
                    f"| {tier} | nginx + php-fpm | cold, unix socket | "
                    f"**{fmt_number(fpm_rps)}** | — |"
                )
            lines.append("")
            lines.append(
                "The factor is `spawn_cgi`'s rate divided by php-fpm's at the "
                "same process count, so `x1.0` is level and a factor above 1.0 "
                "means the forked pool served more requests with the same "
                "number of PHP processes."
            )
            lines.append("")
            notes.extend(lines)

    # What more processes buy, per arm, paired by round.
    gains: list[str] = []
    for arm in arms:
        if len(tiers) < 2:
            break
        base = tiers[0]
        for tier in tiers[1:]:
            base_key = key_for(arm, base, conc)
            tier_key = key_for(arm, tier, conc)
            base_rps = cell_median(rows, base_key, "rps")
            tier_rps = cell_median(rows, tier_key, "rps")
            if base_rps is None or tier_rps is None:
                continue
            spread = ratio_with_spread(rows, tier_key, base_key)
            if spread["centre"] is None:
                continue
            server, model = SERVER_ARMS[arm]
            gains.append(
                f"| {server} | {model} | {fmt_number(base_rps)} | "
                f"{fmt_number(tier_rps)} | x{spread['centre']:.2f} "
                f"({spread['low']:.2f}–{spread['high']:.2f}) |"
            )

    if gains:
        notes.append(
            "**What the extra processes buy.** The table below is each arm at "
            "the smallest and the largest serving-process count this comparison "
            "publishes, paired by the round each was measured in, with the ratio "
            "of the two and its range. A ratio above 1.0 means the arm served "
            "more requests with the larger process count; a ratio below 1.0 "
            "means it served fewer; and a range that reaches across 1.0 means "
            "the two tiers could not be told apart in this run:"
        )
        notes.append("")
        notes.append(
            f"| server | model | {tiers[0]} procs | {tiers[-1]} procs | "
            f"{tiers[-1]}/{tiers[0]} (range) |"
        )
        notes.append("|---|---|---:|---:|---:|")
        notes.extend(gains)
        notes.append("")

    # The tier that is measured but not published, said out loud.
    #
    # A page that stops at the last tier without saying why looks like a page
    # that ran out of measurements. The run measured more than the throughput
    # table prints, the rows are in the repository, and the memory section
    # below publishes every tier - so the omission is a scope decision about
    # the throughput comparison, not a missing measurement. Which tier says
    # what is a result, so it is left to the tables rather than asserted here.
    unpublished = [tier for tier in MEASURED_TIERS if tier not in tiers]
    if unpublished:
        notes.append(
            f"**The {', '.join(str(t) for t in unpublished)}-process tier is "
            f"measured and is not in the throughput table above.** The rows are "
            f"in the repository, and the memory section below publishes every "
            f"tier the run covered — memory is a cost of a deployment rather "
            f"than a claim about who is faster, so it has no reason to stop "
            f"where the throughput comparison does."
        )
        notes.append("")

    return notes


def view_memory(rows: list[dict], meta: dict, stamp: str, arms: list[str],
                tiers: list[int], svg_dir: Path, files: list[str]) -> dict:
    """The cost of the same deployments: the memory they hold.

    Throughput alone is half the answer to "which server should I run". The
    other half is what it holds in memory while it does it, and the two cold
    deployments are where that half is interesting: the same number of PHP
    processes, arranged two different ways, and the two arrangements do not
    cost the same.
    """
    lines: list[str] = []
    charts: list[str] = []

    mem_rows = matrix_memory(MATRIX_DIRS["servers"])
    post = [r for r in mem_rows if r.get("phase") == "post"]
    if not post:
        return {"lines": lines, "files": charts}

    def memory_of(arm: str, tier: int) -> tuple[float | None, float | None]:
        """The median PSS and RSS of one arm at one process count."""
        key = {"arm": arm, "phase": "post"}
        if arm == "volucer-prefork":
            key["workers"] = "1"
            key["children"] = str(tier)
        else:
            key["workers"] = str(tier)
        pss = cell_median(post, key, "pss_mb")
        rss = cell_median(post, key, "rss_mb")
        return pss, rss

    lines.append("## What it costs in memory")
    lines.append("")
    lines.append(
        "**Proportional set size (PSS)**, of the whole process tree, after the "
        "run. PSS divides every shared page by the number of processes that map "
        "it, which is what makes it the figure that can be compared across "
        "process models: a page that thirty-two `php-fpm` children share "
        "counts once, and a page that thirty-two separate processes each hold "
        "counts thirty-two times."
    )
    lines.append("")
    lines.append(
        "**Resident set size (RSS)** is printed beside it in brackets, "
        "because it is the number `htop` shows and the number most people "
        "quote — and it counts a shared page once per process that maps it, so "
        "it reports a cost that the host does not pay. Both are given, so "
        "nothing is hidden and neither is mistaken for the other."
    )
    lines.append("")

    # --- Chart one: the memory of each deployment, against its process count. ---
    series: dict[str, list[float | None]] = {}
    labels: dict[str, str] = {}
    for arm in arms:
        values: list[float | None] = []
        for tier in tiers:
            pss, _ = memory_of(arm, tier)
            values.append(pss)
        if all(value is None for value in values):
            continue
        server, model = SERVER_ARMS[arm]
        series[arm] = values
        labels[arm] = f"{server} — {model}"

    if series:
        chart = "benchmarks-memory.svg"
        write(svg_dir / chart, grouped_bars(
            categories=[f"{tier} processes" for tier in tiers],
            series=series,
            colors={arm: SERVER_COLORS.get(arm, "#94a3b8") for arm in series},
            labels=labels,
            title="Resident memory against the number of PHP processes",
            value_suffix="MiB",
            note="Proportional set size of the whole process tree, after the "
                 "run: each shared page is divided by the number of processes "
                 "that map it, so a page the children share counts once.",
            stamp=stamp,
            versions=versions_line(meta, list(series)),
            height=420,
        ))
        charts.append(chart)
        lines.append(f"![Resident memory against the number of PHP processes](svg/benchmarks/{chart})")
        lines.append("")
        lines.append("| server | model | " + " | ".join(
            f"{tier} procs" for tier in tiers) + " |")
        lines.append("|---|---|" + "---:|" * len(tiers))
        for arm in arms:
            if arm not in series:
                continue
            server, model = SERVER_ARMS[arm]
            cells: list[str] = []
            for tier in tiers:
                pss, rss = memory_of(arm, tier)
                if pss is None:
                    cells.append("-")
                    continue
                if rss is None:
                    cells.append(f"{pss:.1f}")
                    continue
                cells.append(f"{pss:.1f} ({rss:,.0f})")
            lines.append(f"| {server} | {model} | " + " | ".join(cells) + " |")
        lines.append("")
        lines.append(
            "Each cell is the **PSS** of the deployment, with its **RSS** in "
            "brackets — the same number `htop` shows, which counts a shared "
            "page once per process that maps it."
        )
        lines.append("")

    # --- Chart two: the same PHP processes, arranged two ways. ---
    #
    # The `children` key exists to answer one question: for the same number of
    # PHP processes, is a forked slot cheaper than one process per slot? The
    # comparison has to hold the process count equal, or it is comparing two
    # different amounts of server.
    same_processes = same_process_count_comparison(post)
    if len(same_processes) >= 2:
        by_count: dict[int, list[dict]] = defaultdict(list)
        for entry in same_processes:
            by_count[entry["processes"]].append(entry)

        counts = [tier for tier in tiers if tier in by_count]
        if counts:
            one_per_slot: list[float | None] = []
            forked: list[float | None] = []
            for tier in counts:
                entries = by_count[tier]
                slot = next((e for e in entries if "separate slots" in e["label"]), None)
                fork = next((e for e in entries if "separate slots" not in e["label"]), None)
                one_per_slot.append(slot["median"] if slot else None)
                forked.append(fork["median"] if fork else None)

            if any(v is not None for v in one_per_slot) and any(v is not None for v in forked):
                chart = "benchmarks-memory-same-processes.svg"
                write(svg_dir / chart, grouped_bars(
                    categories=[f"{tier} processes" for tier in counts],
                    series={
                        "one per slot": one_per_slot,
                        "one slot × N children": forked,
                    },
                    colors={"one per slot": "#94a3b8", "one slot × N children": "#c2410c"},
                    labels={
                        "one per slot": "spawn_cgi — one process per slot",
                        "one slot × N children": "spawn_cgi — one slot × N children",
                    },
                    title="The same PHP processes, arranged two ways",
                    value_suffix="MiB",
                    note="Proportional set size of the whole process tree, after "
                         "the run: each shared page is divided by the number of "
                         "processes that map it, so a page the children share "
                         "counts once. The same number of PHP processes, serving "
                         "the same requests: once as separate slots, once as the "
                         "children of a single slot.",
                    stamp=stamp,
                    # Only the two spawn_cgi shapes are on this card, so only
                    # volucer is named: a version line that listed RoadRunner
                    # under a chart of one server's shapes would describe a
                    # chart that is not the one on the card.
                    versions=versions_line(meta, ["volucer-fastcgi", "volucer-prefork"]),
                    height=340,
                ))
                charts.append(chart)
                lines.append("### The same PHP processes, arranged two ways")
                lines.append("")
                lines.append(
                    "The `children` key exists to answer one question: for the "
                    "same number of PHP processes, is a forked slot cheaper "
                    "than one process per slot? The comparison has to hold the "
                    "process count equal, or it is comparing two different "
                    "amounts of server."
                )
                lines.append("")
                lines.append(
                    f"![The same PHP processes, arranged two ways](svg/benchmarks/{chart})"
                )
                lines.append("")
                lines.append("| shape | PHP processes | median PSS (MiB) | min | max | vs one per slot |")
                lines.append("|---|---:|---:|---:|---:|---:|")
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
                lines.append(
                    "The **vs one per slot** column is the row's own median "
                    "divided by the one-process-per-slot row at the same "
                    "process count, so it states how much less memory the "
                    "forked pool holds for the same amount of server. Read it "
                    "across a row of the table, not between two rows: the "
                    "comparison holds the process count equal, and comparing "
                    "two different counts would compare two different amounts "
                    "of server."
                )
                lines.append("")
                lines.append(
                    "The reason the two arrangements differ is that the "
                    "children inherit the master's pages instead of each "
                    "mapping its own copy, so a page the pool shares is paid "
                    "for once rather than once per process. That is the "
                    "argument for the `children` key, and it is why the "
                    "`spawn_cgi` arm with `children` is the shape that "
                    "appears in the throughput comparison above: it is the "
                    "same cold path as one process per slot, at a fraction of "
                    "the memory."
                )
                lines.append("")

    return {"lines": lines, "files": charts}


# --------------------------------------------------------------------------
# The manifest
# --------------------------------------------------------------------------

VIEWS = {
    "benchmarks": {
        "title": "Benchmarks",
        "description": "Volucer against RoadRunner, FrankenPHP and nginx + php-fpm, "
                       "every arm through one harness on one interpreter - and what "
                       "each of them costs in memory.",
        "build": view_benchmarks,
        "page": "12-BENCHMARKS.md",
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
# The four pages this list holds were one comparison split four ways: the
# servers side by side, the same server in five shapes, the cold path against
# php-fpm, and what the preforked slot is worth. Every number in them is
# either in the one page now or was a re-statement of a number in it, and
# four pages that said the same thing four ways was four places for a reader
# to find an answer that disagreed with the others.
RETIRED_VIEWS: tuple[str, ...] = ("servers", "modes", "cold", "prefork")

PREAMBLE = """**Measured, not estimated.** Every number on this page comes from one committed
result file in
[`volucer-competition`](https://github.com/sailantis/volucer-competition), and the
charts are generated from that same file — so a chart cannot disagree with the table
beside it. A cell with no successful repeat is printed as `-`, never as `0`: a zero reads
as "measured, and it was terrible" rather than "not measured". The method, the raw rows
and the controls live in that repository.

**One host, one harness, one interpreter, one pass.** Every figure below was measured on
the same machine, through the same script, against the same PHP build, in one
interleaved pass — so a ratio between two arms is a ratio between two measurements made
the same way. **Each chart names the host and the method it was measured on, and the
build of every program it measured**, so the image is readable on its own and a figure
is never a fact about a version no one can identify.
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
            "page": view.get("page"),
            "markdown": target,
            "charts": result.get("files", []),
        })

    return built


def publish(built: list[dict], target: str) -> list[str]:
    """Copy a built view into the volucer repository's documentation.

    The page's name comes from the view, not from its key. The one page is
    `12-BENCHMARKS.md`, and it is the section's entry point as well as its
    content — there is no separate index page, because with a single page an
    index that links to it would be a page that links to a page.
    """
    if target != "volucer":
        return [f"unknown publish target: {target}"]

    docs = ROOT.parent / "volucer" / "docs"
    if not docs.is_dir():
        return [f"volucer docs not found at {docs}"]

    log: list[str] = []

    for view in built:
        page = view.get("page") or f"12-BENCHMARKS-{view['key'].upper()}.md"
        destination = docs / page
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
