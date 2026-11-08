#!/usr/bin/env python3
"""Prove matrix_cells.py refuses to merge an axis arm, rather than averaging it.

The failure being guarded against is silent: grouping on `(arm, workers)` for
`volucer-prefork` pools children 8/16/32 into one plausible number. Each test
below fails against a grouping helper that does not carry `children`.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from matrix_cells import (  # noqa: E402
    MatrixCellError,
    cell_key,
    cell_mean,
    children_of,
    group_cells,
    merge_audit,
)


def row(arm, workers, children="", path="/items-fast", conc="96", rps=1000.0, round_="1"):
    return {
        "path": path,
        "arm": arm,
        "workers": workers,
        "opcache": "on",
        "conc": conc,
        "round": round_,
        "rps": rps,
        "p50": 1.0,
        "p99": 2.0,
        "errors": 0,
        "children": children,
    }


# The three real cells, with the values the run actually produced. If a helper
# averaged them the result would be 9,000 -- a number no configuration has.
PREFORK_CH32 = [row("volucer-prefork", "1", "32", rps=r) for r in (10685.41, 10985.85, 10802.99)]
PREFORK_CH16 = [row("volucer-prefork", "1", "16", rps=r) for r in (9101.23, 9093.37, 9103.38)]
PREFORK_CH8 = [row("volucer-prefork", "1", "8", rps=r) for r in (7056.31, 7099.65, 7070.56)]
ATTACH = [row("volucer-attach", "32", "", rps=r) for r in (51042.0, 51100.0, 50900.0)]


class CellKeyTest(unittest.TestCase):
    def test_axis_arm_without_children_is_refused(self):
        with self.assertRaises(MatrixCellError) as caught:
            cell_key(row("volucer-prefork", "1"))
        self.assertIn("children", str(caught.exception))
        self.assertIn("listening sockets", str(caught.exception))

    def test_axis_arm_with_children_is_accepted(self):
        key = cell_key(row("volucer-prefork", "1", "32"))
        self.assertEqual(key[1], "volucer-prefork")
        self.assertEqual(key[4], "32")

    def test_arm_without_the_axis_needs_no_children(self):
        key = cell_key(row("volucer-attach", "32"))
        self.assertEqual(key[4], "")

    def test_part_selector_returns_one_field(self):
        self.assertEqual(cell_key(row("volucer-attach", "32"), part="workers"), "32")


class GroupCellsTest(unittest.TestCase):
    def test_prefork_children_are_three_cells_not_one(self):
        groups, names = group_cells(PREFORK_CH32 + PREFORK_CH16 + PREFORK_CH8)
        self.assertIn("children", names)
        self.assertEqual(len(groups), 3, "ch=8/16/32 must remain separate cells")

    def test_children_is_added_even_when_not_requested(self):
        _, names = group_cells(PREFORK_CH32 + PREFORK_CH16, by=("arm", "workers"))
        self.assertIn("children", names, "the guard must append the axis, not trust the caller")

    def test_a_childrenless_axis_row_still_raises_through_grouping(self):
        with self.assertRaises(MatrixCellError):
            group_cells([row("volucer-prefork", "1")])


class CellMeanTest(unittest.TestCase):
    def test_each_children_count_keeps_its_own_mean(self):
        picked = cell_mean(
            PREFORK_CH32 + PREFORK_CH16 + PREFORK_CH8,
            arm="volucer-prefork",
            workers="1",
            path="/items-fast",
        )
        self.assertEqual(sorted(picked), ["16", "32", "8"])
        self.assertAlmostEqual(picked["32"][0], 10824.75, places=2)
        self.assertAlmostEqual(picked["8"][0], 7075.51, places=2)
        self.assertEqual(picked["32"][1], 3, "n is the round count")

    def test_the_blend_is_not_reachable(self):
        picked = cell_mean(
            PREFORK_CH32 + PREFORK_CH16 + PREFORK_CH8, arm="volucer-prefork", workers="1"
        )
        means = sorted(m for m, _ in picked.values())
        self.assertEqual(len(means), 3, "three configurations must stay three entries")
        # The point is not that the mean equals 9,000 to some tolerance -- ch=16
        # happens to sit near it. It is that one number cannot describe all three:
        # the fastest config is ~53% above the slowest, so any single value
        # misstates at least one of them by ~25%.
        self.assertGreater(means[2] / means[0], 1.45)


class MergeAuditTest(unittest.TestCase):
    def test_reports_the_axis_arm(self):
        found = merge_audit(PREFORK_CH32 + PREFORK_CH16 + PREFORK_CH8 + ATTACH)
        self.assertEqual(len(found), 1)
        arm, workers, kids, spread = found[0]
        self.assertEqual(arm, "volucer-prefork")
        self.assertEqual(workers, "1")
        self.assertEqual(kids, ["16", "32", "8"])
        self.assertGreater(spread, 40)

    def test_quiet_when_there_is_no_axis(self):
        self.assertEqual(merge_audit(ATTACH), [])


class ChildrenOfTest(unittest.TestCase):
    def test_missing_and_blank_are_both_empty(self):
        self.assertEqual(children_of({}), "")
        self.assertEqual(children_of({"children": None}), "")
        self.assertEqual(children_of({"children": "  "}), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
