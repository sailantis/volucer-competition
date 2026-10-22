#!/usr/bin/env python3
"""The generator must not be able to publish a chart it did not draw.

Run with:  python3 -m unittest discover -s tests -v

The failure this pins is the one the sibling `azera-competition` repository
found and fixed: a chart directory survives between runs, so a chart a view has
stopped drawing keeps sitting in it. A generator that *lists* the directory
picks the orphan up again as if it were current, and a stale chart goes back
into a published page.

These assertions are structural rather than byte-comparisons against committed
output, so they keep holding as the datasets are re-measured: whatever the
renderer reports writing are the only charts that may appear.
"""

import importlib.util
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))


def load_module():
    """Load `bench-report.py`, whose name is not a valid module name."""
    spec = importlib.util.spec_from_file_location(
        "bench_report", ROOT / "scripts" / "bench-report.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


br = load_module()


class ChartManifestTest(unittest.TestCase):
    """A view's Markdown must reference exactly the charts it drew."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="bench-manifest-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def build_view(self, key, out_name):
        """Build one view into a scratch directory."""
        out = self.tmp / out_name
        result = br.VIEWS[key]["build"](out)
        self.assertTrue(result.get("pages"), f"view {key} produced no pages")
        return out, result

    def test_every_reported_chart_is_on_disk(self):
        for key in br.VIEWS:
            with self.subTest(view=key):
                out, result = self.build_view(key, f"on-disk-{key}")
                chart_dir = out / "svg" / key
                self.assertTrue(chart_dir.is_dir(), f"{key} wrote no chart directory")
                self.assertTrue(result["files"], f"{key} must write charts")
                for chart in result["files"]:
                    self.assertTrue(
                        (chart_dir / chart).exists(),
                        f"{key} reported {chart} as written but it is not on disk",
                    )

    def test_reported_charts_match_the_svgs_on_disk(self):
        """Equality both ways.

        Nothing on disk is unreported — which would mean a write that bypassed
        `write()` and could therefore go stale unnoticed — and nothing reported
        is missing.
        """
        for key in br.VIEWS:
            with self.subTest(view=key):
                out, result = self.build_view(key, f"funnel-{key}")
                chart_dir = out / "svg" / key
                on_disk = sorted(p.name for p in chart_dir.glob("*.svg"))
                reported = sorted(result["files"])
                self.assertEqual(
                    on_disk, reported,
                    f"{key}: the reported charts must match the SVGs actually produced",
                )

    def test_a_stale_svg_in_the_directory_is_not_reported(self):
        """The regression itself: an orphan must not come back as a chart.

        The orphan is planted before the build, exactly as it survives in a real
        `results/bench-report/svg/<view>/` tree between regenerations.
        """
        key = "benchmarks"
        out = self.tmp / "stale"
        out.mkdir(parents=True, exist_ok=True)
        chart_dir = out / "svg" / key
        chart_dir.mkdir(parents=True, exist_ok=True)
        orphan = chart_dir / "orphan-from-an-older-run.svg"
        orphan.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg"><!-- orphan --></svg>',
            encoding="utf-8",
        )

        result = br.VIEWS[key]["build"](out)
        self.assertNotIn(
            "orphan-from-an-older-run.svg",
            result["files"],
            "a stale SVG in the directory must not be reported as a chart",
        )

    def test_the_markdown_references_only_charts_that_exist(self):
        """Every image link in a published page must resolve.

        A page whose images all 404 looks broken rather than empty, so this is
        checked rather than assumed.
        """
        for key in br.VIEWS:
            with self.subTest(view=key):
                # `build()` is what writes the Markdown, so the full path is
                # used here: a view function alone draws charts but writes no
                # page.
                out = self.tmp / f"links-{key}"
                built = br.build(out, key)
                self.assertTrue(built, f"{key} built nothing")
                markdown = (out / f"{key}.md").read_text(encoding="utf-8")
                links = re.findall(r"!\[[^\]]*\]\(([^)]+)\)", markdown)
                self.assertTrue(links, f"{key} must reference at least one chart")
                for link in links:
                    path = out / link
                    self.assertTrue(
                        path.exists(),
                        f"{key}.md references {link}, which does not exist",
                    )


class ChartGeometryTest(unittest.TestCase):
    """A chart has to fit the card it is drawn on."""

    def approx_width(self, text, size):
        """An approximation of the rendered width of a string.

        The same estimate the geometry check has always used: a system font's
        average advance is about 0.56 em. It over-estimates slightly, which is
        the safe direction — a chart that passes here has room.
        """
        return len(text) * size * 0.56

    def charts_of(self, key):
        out = Path(tempfile.mkdtemp(prefix="bench-geometry-"))
        self.addCleanup(shutil.rmtree, out, True)
        br.VIEWS[key]["build"](out)
        return sorted((out / "svg" / key).glob("*.svg"))

    def test_no_text_overflows_the_canvas(self):
        for key in br.VIEWS:
            for chart in self.charts_of(key):
                with self.subTest(view=key, chart=chart.name):
                    data = chart.read_text(encoding="utf-8")
                    match = re.search(r'viewBox="0 0 (\d+) (\d+)"', data)
                    self.assertIsNotNone(match, f"{chart.name} has no viewBox")
                    width, height = int(match.group(1)), int(match.group(2))

                    for text in re.finditer(
                        r'<text x="([\d.]+)" y="([\d.]+)"[^>]*font-size="([\d.]+)"[^>]*>(.*?)</text>',
                        data,
                    ):
                        x = float(text.group(1))
                        y = float(text.group(2))
                        size = float(text.group(3))
                        content = text.group(4)

                        anchor = re.search(r'text-anchor="(\w+)"', text.group(0))
                        anchor = anchor.group(1) if anchor else "start"
                        text_width = self.approx_width(content, size)
                        if anchor == "middle":
                            left = x - text_width / 2
                        elif anchor == "end":
                            left = x - text_width
                        else:
                            left = x

                        self.assertGreaterEqual(
                            left, -1,
                            f"{chart.name}: text {content!r} starts left of the canvas",
                        )
                        self.assertLessEqual(
                            left + text_width, width + 1,
                            f"{chart.name}: text {content!r} overflows the canvas",
                        )
                        self.assertLessEqual(
                            y, height + 1,
                            f"{chart.name}: text {content!r} is below the canvas",
                        )

    def test_no_mark_is_drawn_outside_the_canvas(self):
        for key in br.VIEWS:
            for chart in self.charts_of(key):
                with self.subTest(view=key, chart=chart.name):
                    data = chart.read_text(encoding="utf-8")
                    match = re.search(r'viewBox="0 0 (\d+) (\d+)"', data)
                    width, height = int(match.group(1)), int(match.group(2))

                    for rect in re.finditer(
                        r'<rect x="([\d.]+)" y="([\d.]+)" width="([\d.]+)" height="([\d.]+)"',
                        data,
                    ):
                        x, y, w, h = (float(value) for value in rect.groups())
                        self.assertGreaterEqual(x, 0, f"{chart.name}: a mark starts left of the canvas")
                        self.assertLessEqual(
                            x + w, width + 1, f"{chart.name}: a mark overflows the canvas"
                        )
                        self.assertLessEqual(
                            y + h, height + 1, f"{chart.name}: a mark overflows the canvas"
                        )

    def test_no_chart_uses_a_style_block_or_a_class(self):
        """A Markdown renderer that sanitises HTML strips `<style>` and classes.

        The charts are published as images through the homepage's docs pipeline,
        so a chart that lost its styling would render as unstyled shapes. The
        styling is therefore expressed with presentation attributes only.
        """
        for key in br.VIEWS:
            for chart in self.charts_of(key):
                with self.subTest(view=key, chart=chart.name):
                    data = chart.read_text(encoding="utf-8")
                    self.assertNotIn("<style", data, f"{chart.name} uses a <style> block")
                    self.assertNotIn("class=", data, f"{chart.name} uses a CSS class")


class HonestyRuleTest(unittest.TestCase):
    """The rules the numbers have to obey, rather than a style."""

    def charts_of(self, key):
        out = Path(tempfile.mkdtemp(prefix="bench-honesty-"))
        self.addCleanup(shutil.rmtree, out, True)
        br.build(out, key)
        return out

    def test_a_cell_with_no_successful_repeat_is_never_a_zero(self):
        """A zero reads as "measured, and it was terrible".

        The cell with no successful repeat has to be absent, or printed as `-`.
        """
        for key in br.VIEWS:
            with self.subTest(view=key):
                out = self.charts_of(key)
                markdown = (out / f"{key}.md").read_text(encoding="utf-8")
                # A zero in a numeric cell. The header separators are `---`, and
                # the em dash is a non-numeric placeholder, so `| 0 |` is a zero
                # reading rather than formatting.
                self.assertNotRegex(
                    markdown, r"\|\s*0(\.0+)?\s*(?:rps|ms|MiB|MB)?\s*\|",
                    f"{key}.md prints a zero, which claims a measurement that was not made",
                )

    def test_every_chart_carries_its_provenance(self):
        """A figure with no host beside it is not a measurement a reader can weigh."""
        for key in br.VIEWS:
            out = self.charts_of(key)
            for chart in sorted((out / "svg" / key).glob("*.svg")):
                with self.subTest(view=key, chart=chart.name):
                    data = chart.read_text(encoding="utf-8")
                    self.assertIn("cores", data, f"{chart.name} does not name the host")
                    self.assertIn("PHP", data, f"{chart.name} does not name the interpreter")


class ServersArmTest(unittest.TestCase):
    """The comparison must publish every arm it measured.

    The failure this pins is an arm that quietly disappears from the table.
    `spawn_cgi` with `children` is the arm that answers "can the cold path
    reach php-fpm's throughput", and it is measured on a *second* axis
    (`children`, the processes behind each listening socket) rather than on
    `workers`. A view that searched only `workers` would report the prefork
    shape's best as `children = 1` - which is the `spawn_cgi` shape under a
    different name - and the arm would still be in the table, just measured
    as something it is not.

    So the assertion is on the arm's *shape*, not only on its presence.
    """

    def setUp(self):
        self.out = Path(tempfile.mkdtemp(prefix="bench-arms-"))
        self.addCleanup(shutil.rmtree, self.out, True)
        br.build(self.out, "benchmarks")
        self.markdown = (self.out / "benchmarks.md").read_text(encoding="utf-8")

    def test_the_prefork_arm_is_published(self):
        self.assertIn(
            "spawn_cgi (cold, unix, children)", self.markdown,
            "the servers page does not publish the spawn_cgi arm with `children`",
        )

    def test_the_prefork_arm_publishes_its_shape(self):
        """The arm's `children` value has to be printed, not just implied."""
        # Only the throughput table: the page names the arm in prose and in
        # the memory table as well, and a prose mention is not a published
        # measurement.
        rows = [line for line in self.markdown.splitlines()
                if line.startswith("| volucer | spawn_cgi (cold, unix, children) |")
                and "**" in line]
        self.assertTrue(rows, "the prefork arm has no throughput row")
        for row in rows:
            self.assertRegex(
                row, r"\|\s*\d+\s*\|",
                f"the prefork row does not state its PHP process count: {row}",
            )

    def test_every_comparison_arm_appears_in_the_table(self):
        """An arm in the data that is missing from the page is a silent loss."""
        rows = br.matrix_rows(br.MATRIX_DIRS["servers"])
        measured = {r["arm"] for r in rows if r.get("arm")}
        for arm in measured & set(br.COMPARISON_ARMS):
            with self.subTest(arm=arm):
                self.assertIn(
                    br.SERVER_ARMS[arm][1], self.markdown,
                    f"the arm {arm} was measured but is not in the published table",
                )

    def test_the_one_process_per_slot_arm_is_not_in_the_throughput_table(self):
        """`spawn_cgi` with one process per slot is measured, not published.

        The `children` arm is the one the comparison publishes: it is the same
        cold path arranged so that one slot serves many requests, and the
        memory section shows that it costs a fraction of the memory for the
        same throughput. The one-process-per-slot shape is the other side of
        that memory comparison, and publishing it in the throughput table as
        well would put the same argument on the page twice, against a
        different baseline.
        """
        rows = [line for line in self.markdown.splitlines()
                if line.startswith("|") and "1/slot" in line]
        self.assertFalse(
            rows,
            "the one-process-per-slot arm is in the throughput table, which "
            "is the comparison the `children` arm already makes",
        )

    def test_the_php_process_count_is_published(self):
        """The cost side of the comparison has to be visible."""
        self.assertIn("PHP procs", self.markdown,
                      "the servers table does not state the PHP process count")

    def test_every_row_states_the_process_count_it_was_measured_at(self):
        """A row must say how much server it is asking the host for.

        The whole point of the `PHP procs` column is that the rows beside
        each other are comparable: a row that reached the table without its
        process count would let a reader compare a 16-process deployment with
        a 32-process one and read the second as the better server, when it
        is the same server given twice the host.
        """
        measured: set[int] = set()
        for arm in br.COMPARISON_ARMS:
            for row in br.matrix_rows(br.MATRIX_DIRS["servers"]):
                if row.get("arm") != arm:
                    continue
                workers = row.get("workers", "")
                children = (row.get("children") or "").strip()
                if not workers.isdigit():
                    continue
                count = br.php_process_count(
                    arm, int(workers), int(children) if children.isdigit() else 0)
                if count > 0:
                    measured.add(count)

        # The throughput table: a server, a model, a process count, a rate.
        rows = [line for line in self.markdown.splitlines()
                if line.startswith("| ") and "**" in line
                and "PHP procs" not in line
                and "median PSS" not in line
                and "16 procs" not in line]
        self.assertTrue(rows, "the page publishes no measured row")
        for row in rows:
            cells = [c.strip() for c in row.strip("|").split("|")]
            if len(cells) < 3 or not cells[2].isdigit():
                continue
            self.assertIn(
                cells[2], {str(count) for count in measured},
                f"a row states a process count the run never measured: {row}",
            )

    def test_the_page_publishes_both_the_16_and_the_32_process_rows(self):
        """The two tiers the page is about are both in the table.

        The 16-process tier is the comparison of servers. The 32-process tier
        is the one where the cold path is still gaining, and it is the tier
        that shows `nginx + php-fpm` and `spawn_cgi` with `children` are
        level. A page that published only the first would leave the cold
        path's ceiling unstated.
        """
        rows = [line for line in self.markdown.splitlines()
                if line.startswith("| ") and "**" in line
                and "PHP procs" not in line
                and "median PSS" not in line
                and "16 procs" not in line]
        counts = set()
        for row in rows:
            cells = [c.strip() for c in row.strip("|").split("|")]
            if len(cells) >= 3 and cells[2].isdigit():
                counts.add(int(cells[2]))
        for tier in br.PUBLISHED_TIERS:
            self.assertIn(
                tier, counts,
                f"the table publishes no {tier}-process row",
            )


class ClampedThreadTest(unittest.TestCase):
    """A concurrency level below the client's thread count must still publish.

    `wrk` refuses `-c` below `-t`, so the harness clamps the thread count to
    the concurrency level whenever the level is below the requested one. A
    run that measures c=8 therefore has c=8 rows at `-t8` and c=16/32/64 rows
    at `-t12`.

    The report used to resolve the thread count ONCE for the whole run. No
    single count covered every row, so it fell back to "the most common" -
    and every row whose thread count differed became invisible. The c=8
    cells were measured, and the page printed none of them: a level missing
    from the page because of a bookkeeping detail in the report is
    indistinguishable from a level that was never measured, and the second
    is a claim while the first is a bug.

    The test builds the page from a dataset that has the clamp in it, so
    the failure is reproduced rather than described.
    """

    def setUp(self):
        self.out = Path(tempfile.mkdtemp(prefix="bench-clamp-"))
        self.addCleanup(shutil.rmtree, self.out, True)

    def test_a_level_whose_thread_count_was_clamped_is_published(self):
        """A row set that differs only in its thread count still publishes."""
        rows = [
            # c=8, clamped to -t8: the shape the harness produces.
            {"arm": "rr", "workers": "16", "opcache": "on", "conc": "8",
             "round": "1", "threads": "8", "rps": "100.0", "p50": "1.00ms",
             "p99": "2.00ms", "errors": "0", "children": ""},
            # c=16 at the fixed -t12.
            {"arm": "rr", "workers": "16", "opcache": "on", "conc": "16",
             "round": "1", "threads": "12", "rps": "200.0", "p50": "1.00ms",
             "p99": "2.00ms", "errors": "0", "children": ""},
        ]

        # The two levels differ in their thread count, so a run-wide
        # resolution cannot cover both.
        self.assertNotEqual(
            rows[0]["threads"], rows[1]["threads"],
            "the fixture no longer has two different thread counts",
        )

        # What the report does with the rows, for one level.
        best = br.configuration_at_process_count(
            rows, "rr", 16, 8, mode="on", threads="8")
        self.assertIsNotNone(
            best["rps"],
            "the c=8 cell was measured but the report cannot find it, "
            "because it looked for it under the wrong thread count",
        )

    def test_the_run_wide_thread_count_does_not_hide_a_level(self):
        """A run with two thread counts must publish both levels.

        The run-wide resolution is what hid the level. This asserts on the
        published page: the level with the clamped thread count has a chart,
        and the level with the fixed one has a chart too.
        """
        out = self.out
        br.build(out, "benchmarks")
        markdown = (out / "benchmarks.md").read_text(encoding="utf-8")

        rows = br.matrix_rows(br.MATRIX_DIRS["servers"])
        levels = sorted({int(r["conc"]) for r in rows if r.get("conc", "").isdigit()})
        self.assertTrue(levels, "the dataset has no concurrency levels")

        # Every measured level must have a chart. The chart's name carries
        # the level, so a missing level is a missing chart.
        charts = {p.name for p in (out / "svg" / "benchmarks").glob("*.svg")}
        for level in levels:
            with self.subTest(conc=level):
                self.assertTrue(
                    any(name.endswith(f"-c{level}.svg") for name in charts),
                    f"c={level} was measured but no chart was published for it",
                )


class RatioChartTest(unittest.TestCase):
    """The chart must not claim more than the measurement supports.

    The chart is a bar per server, at the request rate, with the server's
    factor against the fastest one floating behind it. That is a chart with
    a failure mode the plain bar chart did not have: a range that reaches
    across the 1.0 line says "these two cannot be told apart", and if the
    range were drawn from the arm's own minimum and maximum it would say
    that far too often, because the host's drift over the run would be
    charged to one arm.

    So the range has to be the range of the *round-paired* ratios, and the
    factor has to be the number the table prints.

    The factor is the **reciprocal** of the share: it states how many times
    slower a server is than the reference, not what fraction of the
    reference it reached. Both describe the same measurement, but the
    reciprocal is the one a reader thinks in - "twice as slow" is a thing
    people say, "half the share" is not - and it is the same number whether
    the axis carries rates or times.
    """

    def setUp(self):
        self.out = Path(tempfile.mkdtemp(prefix="bench-ratio-"))
        self.addCleanup(shutil.rmtree, self.out, True)
        br.build(self.out, "benchmarks")
        self.markdown = (self.out / "benchmarks.md").read_text(encoding="utf-8")

    def charts_of(self):
        return sorted((self.out / "svg" / "benchmarks").glob("*.svg"))

    def test_the_label_is_the_factor_the_table_prints(self):
        """The chart and the table must not disagree about the same number.

        The floating label is the factor the `factor` column prints. A
        chart that showed a different number from the table beside it
        would be the one thing a reader cannot check.

        The factor is the baseline divided by the arm - how many times
        slower. A generator that inverted it would print a number below
        1.0 for a slower server, and the page would read as a claim about
        speed that is exactly backwards.
        """
        rows = br.matrix_rows(br.MATRIX_DIRS["servers"])
        for conc in (16, 32, 48, 64):
            best_of = {
                arm: br.configuration_at_process_count(rows, arm, 16, conc,
                                                       mode="on", threads="12")
                for arm in br.SERVER_ARMS
            }
            measured = {arm: b for arm, b in best_of.items() if b["rps"] is not None}
            if len(measured) < 2:
                continue
            baseline = max(measured, key=lambda arm: measured[arm]["rps"])
            base_rps = measured[baseline]["rps"]

            for arm, best in measured.items():
                if arm == baseline:
                    continue
                key = {"arm": arm, "workers": str(best["workers"]),
                       "opcache": "on", "conc": str(conc), "threads": "12"}
                if best["children"]:
                    key["children"] = best["children"]
                base_key = {"arm": baseline,
                            "workers": str(measured[baseline]["workers"]),
                            "opcache": "on", "conc": str(conc), "threads": "12"}
                if measured[baseline]["children"]:
                    base_key["children"] = measured[baseline]["children"]
                spread = br.ratio_with_spread(rows, base_key, key)
                with self.subTest(arm=arm, conc=conc):
                    self.assertIsNotNone(spread["centre"])
                    # The factor is at least 1.0 by construction - the
                    # baseline is the fastest arm - and it is the same
                    # number as the baseline's rate over the arm's.
                    self.assertGreaterEqual(spread["centre"], 1.0 - 1e-9)
                    self.assertAlmostEqual(
                        spread["centre"], base_rps / best["rps"], places=9,
                    )

    def test_the_range_is_the_factor_the_table_prints(self):
        """The range on the bar has to contain the arm's own rate.

        The bar's end is the arm's rate; the range is the range of the
        round-paired factors, scaled back into requests per second. A range
        that did not contain the number beside it would contradict the
        table, so the code widens it - and the widening must not be what
        makes the test pass. On the committed data the range already
        contains the rate, and this pins that.
        """
        rows = br.matrix_rows(br.MATRIX_DIRS["servers"])
        for conc in (16, 32, 48, 64):
            best_of = {
                arm: br.configuration_at_process_count(rows, arm, 16, conc,
                                                       mode="on", threads="12")
                for arm in br.SERVER_ARMS
            }
            measured = {arm: b for arm, b in best_of.items() if b["rps"] is not None}
            if len(measured) < 2:
                continue
            baseline = max(measured, key=lambda arm: measured[arm]["rps"])
            base_rps = measured[baseline]["rps"]
            base_key = {"arm": baseline,
                        "workers": str(measured[baseline]["workers"]),
                        "opcache": "on", "conc": str(conc), "threads": "12"}
            if measured[baseline]["children"]:
                base_key["children"] = measured[baseline]["children"]

            for arm, best in measured.items():
                if arm == baseline:
                    continue
                key = {"arm": arm, "workers": str(best["workers"]),
                       "opcache": "on", "conc": str(conc), "threads": "12"}
                if best["children"]:
                    key["children"] = best["children"]
                spread = br.ratio_with_spread(rows, base_key, key)
                if spread["low"] is None or spread["high"] is None:
                    continue
                with self.subTest(arm=arm, conc=conc):
                    self.assertLessEqual(spread["low"], spread["centre"])
                    self.assertGreaterEqual(spread["high"], spread["centre"])
                    # The range in requests per second brackets the rate.
                    self.assertLessEqual(base_rps / spread["high"], best["rps"] + 1e-6)
                    self.assertGreaterEqual(base_rps / spread["low"], best["rps"] - 1e-6)

    def test_the_baseline_is_the_fastest_server(self):
        """The reference bar has to be the fastest one in the chart.

        A reference that is not the fastest makes every other label mean
        something the reader cannot check - and a server that did more
        requests per second than the one the others are measured against
        would be a contradiction visible in the chart itself.

        The memory charts are a different kind of chart - they plot a cost
        against a size, and have no fastest server to name - so the check is
        on the throughput charts.
        """
        for chart in self.charts_of():
            if "memory" in chart.name:
                continue
            data = chart.read_text(encoding="utf-8")
            with self.subTest(chart=chart.name):
                self.assertIn("fastest here", data,
                              f"{chart.name} does not say what the baseline is")

    def test_the_paired_range_is_tighter_than_the_unpaired_one(self):
        """The claim the page's prose makes, checked on the data.

        The page says a range drawn from one server's minimum and maximum
        "would charge the whole of the host's drift to that one server, and
        would be wide for the wrong reason". That is a claim about two ways
        of building a range from the same three rounds:

          paired   - the ratio inside each round, then the extremes
          unpaired - A's min against B's max, and A's max against B's min

        Both are ranges of the comparison. The paired one is the honest
        one, and this checks that it is the tighter one for most pairs -
        which is the claim, and is what the prose says.

        It is deliberately "most pairs" and not "every pair": a run in
        which both arms are stable has nothing for the pairing to fix, and
        the two ranges come out the same width. The page says "in most of
        the pairs", and the test asserts exactly that - a stronger
        assertion would fail on a run that was steadier than this one, and
        a steadier run is not a worse run.
        """
        rows = br.matrix_rows(br.MATRIX_DIRS["servers"])
        tighter = 0
        total = 0
        for conc, threads in ((8, "8"), (16, "12"), (32, "12"), (64, "12")):
            for tier in br.PUBLISHED_TIERS:
                for arm in br.COMPARISON_ARMS:
                    reference_key = {
                        "arm": "volucer-attach", "workers": str(tier),
                        "opcache": "on", "conc": str(conc), "threads": threads,
                    }
                    if arm == "volucer-attach":
                        continue
                    key = {"arm": arm, "workers": str(tier), "opcache": "on",
                           "conc": str(conc), "threads": threads}
                    if arm == "volucer-prefork":
                        key = {"arm": arm, "workers": "1",
                               "children": str(tier), "opcache": "on",
                               "conc": str(conc), "threads": threads}
                    a = br.by_round(rows, reference_key)
                    b = br.by_round(rows, key)
                    shared = sorted(set(a) & set(b))
                    if len(shared) < 2:
                        continue
                    centre = (br.cell_median(rows, reference_key, "rps")
                             / br.cell_median(rows, key, "rps"))
                    paired = [a[r] / b[r] for r in shared if b[r] > 0]
                    paired_width = (max(paired) - min(paired)) / centre
                    unpaired = [min(a.values()) / max(b.values()),
                                max(a.values()) / min(b.values())]
                    unpaired_width = (max(unpaired) - min(unpaired)) / centre
                    total += 1
                    if paired_width <= unpaired_width:
                        tighter += 1
        self.assertGreater(total, 0, "no ratio was checked")
        self.assertGreater(
            tighter * 2, total,
            f"the paired range was tighter in only {tighter} of {total} pairs, "
            f"so the page's claim about it does not hold on this run",
        )

    def test_a_factor_of_one_is_a_tie(self):
        """A range that crosses 1.0 must be reported as a tie.

        The 16-process tier on the landing page measures `attach` against
        `worker`, and the two are within a percent of each other. The table
        has to say so in words, because a reader looking at a bar that
        reaches across the 1.0 line needs to be told that the line is the
        answer rather than a decoration.
        """
        self.assertIn(
            "\u2014 tie", self.markdown,
            "a tier reports two servers within a percent of each other, and "
            "no row says so",
        )

    def test_the_chart_does_not_label_a_tie(self):
        """The chart leaves the tie to the table.

        The chart already draws the range, and a range that reaches across
        the reference says it in the reader's own terms. A word beside it
        would be a second copy of the same statement, and the two copies
        are the kind that drifts apart. The table keeps the marker, because
        the table is where the range is printed as numbers.
        """
        for chart in self.charts_of():
            data = chart.read_text(encoding="utf-8")
            with self.subTest(chart=chart.name):
                self.assertNotIn(">tie<", data,
                                 f"{chart.name} labels a tie on the chart")

    def test_the_chart_never_labels_a_factor_of_one(self):
        """A factor of one is a label that says nothing.

        The reference is 1.0 by definition, and any other bar whose factor
        rounds to 1.0 is level with the reference. Printing "x1.0" beside
        it spends a word on saying nothing, and the reference row would be
        the one bar on the chart that labels itself.
        """
        for chart in self.charts_of():
            data = chart.read_text(encoding="utf-8")
            with self.subTest(chart=chart.name):
                self.assertNotIn(">x1.0<", data,
                                 f"{chart.name} labels a factor of one")

    def test_a_factor_is_printed_with_one_decimal(self):
        """A factor is read as a scale, so it keeps one decimal place.

        A column of factors has to scan: x1.1, x2.5, x3.0. Mixed precision
        - x1.0, x2.53, x3 - is the same number set with the reading
        burden moved onto the reader.

        A chart with no factor at all is allowed: the 32-process tier
        measures two servers within a percent of each other, so every
        factor there rounds to x1.0 and every label is skipped. The check
        is therefore on the charts that do carry a factor, plus a count
        that the rest of the suite would miss if they all stopped.
        """
        labelled = 0
        for chart in self.charts_of():
            data = chart.read_text(encoding="utf-8")
            labels = re.findall(r">x([\d.]+)<", data)
            labelled += len(labels)
            with self.subTest(chart=chart.name):
                for label in labels:
                    self.assertRegex(
                        label, r"^\d+\.\d$",
                        f"{chart.name} prints the factor {label!r} with the "
                        f"wrong precision",
                    )
        self.assertGreater(
            labelled, 0,
            "no chart prints a factor at all, which is not what the chart "
            "is for",
        )

    def test_every_chart_states_how_to_read_its_bars(self):
        """A chart that needs a paragraph in the reader's head gets misread.

        The range on a bar means "the spread of the comparison", which is not
        the obvious thing it looks like, so the note has to say so on the
        chart itself - a reader who lands on the chart from a search does not
        read the page's prose first.

        The check is against the chart's *text*, joined: the note is wrapped
        across several `<text>` elements, so a phrase that spans a line break
        is not a contiguous string in the markup. A reader does not see line
        breaks, and neither should the test.
        """
        for chart in self.charts_of():
            if "memory" in chart.name:
                # The memory charts plot a cost, not a rate, and the thing
                # a reader has to be told about *them* is what the measure
                # is: PSS divides a shared page between the processes that
                # map it, and RSS does not.
                with self.subTest(chart=chart.name):
                    data = chart.read_text(encoding="utf-8")
                    text = " ".join(re.findall(r"<text[^>]*>(.*?)</text>", data))
                    self.assertIn(
                        "Proportional set size", text,
                        f"{chart.name} does not say what it measures",
                    )
                    self.assertIn(
                        "shared page", text,
                        f"{chart.name} does not say what its measure means",
                    )
                continue
            with self.subTest(chart=chart.name):
                data = chart.read_text(encoding="utf-8")
                text = " ".join(re.findall(r"<text[^>]*>(.*?)</text>", data))
                self.assertIn(
                    "round-paired", text,
                    f"{chart.name} does not say what its bars mean",
                )
                self.assertIn(
                    "spread of the comparison", text,
                    f"{chart.name} does not say what its bars mean",
                )

    def test_every_chart_publishes_the_request_rate(self):
        """The chart is a chart of throughput, so it has to say so.

        The rate is the number the page is about, and a chart that plots
        ratios without printing the rate has put the answer in a table.
        """
        for chart in self.charts_of():
            if "memory" in chart.name:
                with self.subTest(chart=chart.name):
                    data = chart.read_text(encoding="utf-8")
                    self.assertIn(
                        "MiB", data,
                        f"{chart.name} does not name its unit",
                    )
                continue
            with self.subTest(chart=chart.name):
                data = chart.read_text(encoding="utf-8")
                self.assertIn("requests per second", data,
                              f"{chart.name} does not name its unit")

    def test_the_chart_does_not_say_more_than_the_page_measures(self):
        """The published factor must be the one the chart draws.

        The table's `factor` column and the chart's floating label are two
        renderings of the same number. A generator that computed them
        differently would produce a page whose chart and table disagree,
        which is the failure this whole repository is written to prevent.
        """
        rows = br.matrix_rows(br.MATRIX_DIRS["servers"])
        best = br.configuration_at_process_count(rows, "volucer-worker", 16, 64,
                                                 mode="on", threads="12")
        reference_key = {
            "arm": "volucer-worker", "workers": str(best["workers"]),
            "opcache": "on", "conc": "64", "threads": "12",
        }
        other = br.configuration_at_process_count(rows, "fpm", 16, 64,
                                                  mode="on", threads="12")
        key = {"arm": "fpm", "workers": str(other["workers"]),
               "opcache": "on", "conc": "64", "threads": "12"}
        spread = br.ratio_with_spread(rows, reference_key, key)
        self.assertAlmostEqual(
            spread["centre"], best["rps"] / other["rps"], places=9,
        )


class ColdPathTest(unittest.TestCase):
    """The cold path is compared on the one page, against php-fpm.

    The cold path - `spawn_cgi` against `nginx + php-fpm` - is a comparison
    of two *deployments* at the same number of serving processes, not a
    comparison of servers. It needs a different baseline from the servers
    comparison: the servers comparison measures everything against the
    fastest server in the chart, while the cold comparison measures against
    php-fpm, because php-fpm is the thing the cold path is being compared
    to.

    It used to have its own page for that reason. It does not any more,
    because a page that exists to answer one question and answers it with
    one table is a page that could have been a section - and the four pages
    the documentation had were four places for a reader to find the same
    comparison stated against a different baseline.
    """

    def setUp(self):
        self.out = Path(tempfile.mkdtemp(prefix="bench-cold-"))
        self.addCleanup(shutil.rmtree, self.out, True)
        br.build(self.out, "benchmarks")
        self.markdown = (self.out / "benchmarks.md").read_text(encoding="utf-8")

    def test_the_cold_path_is_compared_on_the_page(self):
        """The two cold deployments are compared with each other.

        The comparison has to hold the number of serving processes equal, or
        it is comparing two different amounts of server.
        """
        self.assertIn(
            "head to head", self.markdown,
            "the page does not compare the two cold deployments with each other",
        )
        for tier in br.PUBLISHED_TIERS:
            self.assertIn(
                f"- **{tier} processes**",
                self.markdown,
                f"the page does not compare the cold deployments at {tier} processes",
            )

    def test_the_cold_comparison_carries_the_range(self):
        """The table has to show the range the chart draws."""
        self.assertIn(
            "spawn_cgi", self.markdown,
            "the page does not publish the spawn_cgi arm",
        )


class MemorySectionTest(unittest.TestCase):
    """The page has to carry the memory of the same deployments.

    Throughput alone is half the answer to "which server should I run". The
    other half is what it holds in memory while it does it, and the two cold
    deployments are where that half is interesting: the same number of PHP
    processes, arranged two different ways, and the two arrangements do not
    cost the same.
    """

    def setUp(self):
        self.out = Path(tempfile.mkdtemp(prefix="bench-memory-"))
        self.addCleanup(shutil.rmtree, self.out, True)
        br.build(self.out, "benchmarks")
        self.markdown = (self.out / "benchmarks.md").read_text(encoding="utf-8")
        self.charts = sorted((self.out / "svg" / "benchmarks").glob("*.svg"))

    def test_the_memory_section_is_published(self):
        self.assertIn(
            "What it costs in memory", self.markdown,
            "the page has no memory section",
        )

    def test_the_memory_is_reported_as_pss(self):
        """PSS, not RSS.

        RSS counts a shared page once per process that maps it, so it
        reports a cost the host does not pay - and a page that compared two
        process models on RSS would be comparing the wrong thing. PSS
        divides each shared page by the number of processes mapping it.
        """
        self.assertIn(
            "Proportional set size (PSS)", self.markdown,
            "the memory section does not say which measure it is",
        )

    def test_every_process_count_is_published_in_the_memory_table(self):
        """The memory table covers every tier the run measured.

        The forked pool's advantage grows with the process count, so a
        memory table that stopped at 32 would show the argument at its
        smallest.
        """
        for tier in br.MEASURED_TIERS:
            self.assertIn(
                f"{tier} procs", self.markdown,
                f"the memory table does not publish the {tier}-process column",
            )

    def test_the_same_processes_arranged_two_ways_is_published(self):
        """The prefork argument, with the process count held equal.

        The comparison has to hold the process count equal, or it is
        comparing two different amounts of server - which is the whole
        reason the `children` key exists.
        """
        self.assertIn(
            "arranged two ways", self.markdown,
            "the page does not compare the same PHP processes arranged two ways",
        )
        for tier in br.MEASURED_TIERS:
            self.assertIn(
                f"1 slot × {tier} children", self.markdown,
                f"the two-ways table does not publish the {tier}-child row",
            )

    def test_the_memory_section_has_a_chart(self):
        """A memory section without a chart is a table of numbers.

        The chart is what makes the shape of the argument visible: the
        forked pool's bar stays flat while the one-per-slot bar grows with
        the process count, and a reader sees that before reading a word.
        """
        names = [chart.name for chart in self.charts]
        self.assertTrue(
            any("memory" in name for name in names),
            f"the page publishes no memory chart: {names}",
        )


class RetiredViewTest(unittest.TestCase):
    """A view that is retired must leave nothing behind.

    A published page that is no longer generated is worse than a page that
    was never written: it is still served, still indexed by the homepage's
    search, and still carrying a comparison the rest of the documentation
    no longer makes. So the removal is part of the generator's job, and the
    mechanism that does it is pinned here — the list is empty at the
    moment, and the day a view is retired is exactly the day somebody would
    forget to remove its page.
    """

    def test_the_retired_list_exists(self):
        """The list has to exist, and every name in it has to be retired.

        A retired view is named in the list so that publishing removes its
        page and its charts. Without the list, a view dropped from the
        manifest would leave its page behind, and it would look exactly
        like a current page.
        """
        self.assertIsInstance(br.RETIRED_VIEWS, tuple)
        self.assertTrue(
            br.RETIRED_VIEWS,
            "no view is retired, but the four pages this page replaces are "
            "still published",
        )
        for retired in br.RETIRED_VIEWS:
            self.assertNotIn(
                retired, br.VIEWS,
                f"{retired} is listed as retired and is also published",
            )

    def test_the_four_replaced_pages_are_retired(self):
        """The pages the one page replaces are on the list.

        They are removed by the *publish* step, which is the only step that
        writes into the documentation tree. A retired view that is not on the
        list would leave its page behind - still served, still indexed - and
        it would carry a comparison against a baseline the new page does not
        use.
        """
        for retired in ("servers", "modes", "cold", "prefork"):
            self.assertIn(
                retired, br.RETIRED_VIEWS,
                f"the {retired} page is retired but is not on the list, so "
                f"publishing would leave it behind",
            )

    def test_the_one_page_is_the_sections_entry_point(self):
        """The single page is `12-BENCHMARKS.md`, and it is the only one.

        With one page there is no room for a separate index: an index that
        links to a single page is a page that links to a page, and the
        reader would have to click twice to reach the numbers.
        """
        page = br.VIEWS["benchmarks"].get("page")
        self.assertEqual(
            page, "12-BENCHMARKS.md",
            "the one page is not the section's entry point",
        )


if __name__ == "__main__":
    unittest.main()
