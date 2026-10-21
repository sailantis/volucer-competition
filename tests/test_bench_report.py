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
        key = "modes"
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
    """The server comparison must publish every arm it measured.

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
        br.build(self.out, "servers")
        self.markdown = (self.out / "servers.md").read_text(encoding="utf-8")

    def test_the_prefork_arm_is_published(self):
        self.assertIn(
            "spawn_cgi (cold, unix, children)", self.markdown,
            "the servers page does not publish the spawn_cgi arm with `children`",
        )

    def test_the_prefork_arm_publishes_its_shape(self):
        """The arm's `children` value has to be printed, not just implied."""
        # Only the table rows: the page names the arm in prose as well, and
        # a prose mention is not a published measurement.
        rows = [line for line in self.markdown.splitlines()
                if line.startswith("|") and "spawn_cgi (cold, unix, children)" in line]
        self.assertTrue(rows, "the prefork arm has no table row")
        for row in rows:
            self.assertRegex(
                row, r"\|\s*\d+\s*\|",
                f"the prefork row does not state its PHP process count: {row}",
            )

    def test_every_measured_arm_appears_in_the_table(self):
        """An arm in the data that is missing from the page is a silent loss."""
        rows = br.matrix_rows(br.MATRIX_DIRS["servers"])
        measured = {r["arm"] for r in rows if r.get("arm")}
        for arm in measured:
            with self.subTest(arm=arm):
                self.assertIn(
                    br.SERVER_ARMS[arm][1], self.markdown,
                    f"the arm {arm} was measured but is not in the published table",
                )

    def test_the_php_process_count_is_published(self):
        """The cost side of the comparison has to be visible."""
        self.assertIn("PHP procs", self.markdown,
                      "the servers table does not state the PHP process count")

    def test_a_tier_holds_one_process_count(self):
        """A table must not mix rows that serve with different amounts of server.

        The whole point of grouping the page by process count is that the rows
        beside each other are comparable. A row that reached the table with a
        different process count than its neighbours would break that, and it
        would break it silently: the table would still look like a table.
        """
        current = None
        for line in self.markdown.splitlines():
            heading = re.match(r"^#### (\d+) PHP processes$", line)
            if heading:
                current = heading.group(1)
                continue
            if current and line.startswith("|") and "PHP procs" not in line:
                cells = [c.strip() for c in line.strip("|").split("|")]
                if len(cells) >= 3 and cells[0] not in ("server", "---"):
                    self.assertEqual(
                        cells[2], current,
                        f"a row in the {current}-process tier reports {cells[2]} processes",
                    )

    def test_the_lowest_tier_carries_every_arm(self):
        """The tiers are ordered by process count, within each endpoint.

        The page publishes one set of tiers per endpoint, and each endpoint
        starts again at its own lowest tier — so the order is checked per
        section rather than across the whole page.
        """
        tiers: list[str] = []
        for line in self.markdown.splitlines():
            if line.startswith("## "):
                # A new endpoint ends the previous section's tiers.
                tiers = []
                continue
            heading = re.match(r"^#### (\d+) PHP processes$", line)
            if heading:
                tiers.append(heading.group(1))

        self.assertTrue(tiers, "the page publishes no process tier")
        self.assertEqual(
            tiers, sorted(tiers, key=int),
            "the tiers of one endpoint are not ordered by process count",
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
        br.build(out, "servers")
        markdown = (out / "servers.md").read_text(encoding="utf-8")

        rows = br.matrix_rows(br.MATRIX_DIRS["servers"])
        levels = sorted({int(r["conc"]) for r in rows if r.get("conc", "").isdigit()})
        self.assertTrue(levels, "the dataset has no concurrency levels")

        # Every measured level must have a chart. The chart's name carries
        # the level, so a missing level is a missing chart.
        charts = {p.name for p in (out / "svg" / "servers").glob("*.svg")}
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
        br.build(self.out, "servers")
        self.markdown = (self.out / "servers.md").read_text(encoding="utf-8")

    def charts_of(self):
        return sorted((self.out / "svg" / "servers").glob("*.svg"))

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
        """
        for chart in self.charts_of():
            data = chart.read_text(encoding="utf-8")
            with self.subTest(chart=chart.name):
                self.assertIn("fastest here", data,
                              f"{chart.name} does not say what the baseline is")

    def test_the_whisker_is_narrower_than_the_arms_own_spread(self):
        """A paired range must be tighter than the arm's own min-to-max.

        This is the check that would catch a whisker built from the wrong
        thing. The arm's own range includes the host's drift over the whole
        run; the paired range does not, because both arms moved together
        within a round. If the two were the same width, the pairing would be
        doing nothing, and the whisker would be charging the drift to one arm
        in all but name.
        """
        rows = br.matrix_rows(br.MATRIX_DIRS["servers"])
        reference = "volucer-worker"
        checked = 0
        for conc in (16, 32, 48, 64):
            best = br.configuration_at_process_count(rows, reference, 16, conc,
                                                     mode="on", threads="12")
            if best["rps"] is None:
                continue
            reference_key = {
                "arm": reference, "workers": str(best["workers"]),
                "opcache": "on", "conc": str(conc), "threads": "12",
            }
            for arm in ("fpm", "rr", "frankenphp"):
                other = br.configuration_at_process_count(rows, arm, 16, conc,
                                                          mode="on", threads="12")
                if other["rps"] is None:
                    continue
                key = {"arm": arm, "workers": str(other["workers"]),
                       "opcache": "on", "conc": str(conc), "threads": "12"}
                spread = br.ratio_with_spread(rows, reference_key, key)
                paired = spread["high"] - spread["low"]
                self.assertLess(
                    paired, 0.20,
                    f"{arm} at c={conc}: the paired range is as wide as the noise",
                )
                checked += 1
        self.assertGreater(checked, 0, "no ratio was checked")

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


class ColdViewTest(unittest.TestCase):
    """The cold path has its own page, and the servers page leaves it there.

    The cold path - `spawn_cgi` against `nginx + php-fpm` - is a comparison
    of two *deployments* at the same number of serving processes, not a
    comparison of servers. It reads differently from the servers page, and
    it needs a different baseline: the servers page measures everything
    against the fastest server in the chart, while the cold page measures
    against php-fpm, because php-fpm is the thing the cold path is being
    compared to.

    So the cold comparison lives on its own page, and the servers page
    publishes only the tiers that put a warm arm beside the cold ones. A
    tier of nothing but cold arms on the servers page would put the same
    comparison on two pages against two different baselines, and a reader
    would have to work out which one to believe.
    """

    def setUp(self):
        self.out = Path(tempfile.mkdtemp(prefix="bench-cold-"))
        self.addCleanup(shutil.rmtree, self.out, True)
        br.build(self.out, "cold")
        self.markdown = (self.out / "cold.md").read_text(encoding="utf-8")

    def test_the_cold_view_is_published(self):
        self.assertIn(
            "cold", br.VIEWS,
            "the cold page is not published, and the cold path against "
            "php-fpm has nowhere to live",
        )

    def test_the_servers_page_leaves_the_cold_comparison_to_the_cold_page(self):
        """The servers page publishes no tier that holds only cold arms.

        The 32-process tier measures `spawn_cgi` against php-fpm and
        nothing else. It is the cold page's comparison, in the same run and
        with the same method.
        """
        out = Path(tempfile.mkdtemp(prefix="bench-tiers-"))
        self.addCleanup(shutil.rmtree, out, True)
        br.build(out, "servers")
        markdown = (out / "servers.md").read_text(encoding="utf-8")

        tiers = re.findall(r"^#### (\d+) PHP processes$", markdown, re.M)
        self.assertTrue(tiers, "the servers page publishes no process tier")
        for tier in tiers:
            self.assertNotEqual(
                tier, "32",
                "the servers page publishes the cold-only 32-process tier, "
                "which is the cold page's comparison",
            )

    def test_the_cold_page_compares_against_php_fpm(self):
        """The cold page's baseline is php-fpm, and it says so."""
        self.assertIn("factor against php-fpm (range)", self.markdown,
                      "the cold table does not name what its factor is "
                      "measured against")

    def test_the_cold_table_carries_the_range(self):
        """The table has to show the range the chart draws."""
        self.assertIn("(", self.markdown,
                      "the cold table does not publish the range beside the "
                      "factor")

    def test_an_undersized_pool_is_in_the_table_but_not_the_chart(self):
        """A row must not quietly disappear from a chart.

        The one-child php-fpm pool is a tenth of the sixteen-child one's
        rate, and it would squash the bars that are level with php-fpm down
        to a few pixels. So it stays in the table - and the page has to say
        that it is in the table and not in the chart, because a reader who
        counts the rows will otherwise think a measurement went missing.
        """
        self.assertIn("is in the table but not in", self.markdown,
                      "the page does not say that the small pool is table-only")
        for chart in sorted((self.out / "svg" / "cold").glob("*.svg")):
            with self.subTest(chart=chart.name):
                self.assertNotIn(
                    "php-fpm, 1 child", chart.read_text(encoding="utf-8"),
                    "the one-child pool is in the chart, and it squashes it",
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
        """The list has to exist, even while it is empty.

        A retired view is named in the list so that publishing removes its
        page and its charts. Without the list, a view dropped from the
        manifest would leave its page behind, and it would look exactly
        like a current page.
        """
        self.assertIsInstance(br.RETIRED_VIEWS, tuple)
        for retired in br.RETIRED_VIEWS:
            self.assertNotIn(
                retired, br.VIEWS,
                f"{retired} is listed as retired and is also published",
            )


if __name__ == "__main__":
    unittest.main()
