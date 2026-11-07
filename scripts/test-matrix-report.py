#!/usr/bin/env python3
"""Sanity-check matrix-report.py's endpoint grouping.

Two claims to prove, because both would fail silently:

1. A multi-path TSV is split into one section per path, and a cell appears in
   exactly one section. The failure this guards against is a report that medians
   `/echo` and `/items` together - which is not an error, it is a number that
   describes no page.
2. A TSV written before the `path` column existed still reports, as one group.
   If the reader demanded the column, every previously published matrix.tsv
   would stop working.
"""

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPORT = os.path.join(HERE, "matrix-report.py")

MTX_HEAD = ["path", "arm", "workers", "opcache", "conc", "round", "threads",
            "rps", "p50", "p99", "errors", "children", "proc_kind"]
MEM_HEAD = ["path", "arm", "workers", "opcache", "phase", "conc",
            "pss_mb", "rss_mb", "pids", "children"]

PATHS = ["/echo", "/", "/api/items", "/items"]
ARMS = ["volucer-attach", "rr", "fpm"]
# A distinct throughput per (path, arm) so a mis-grouped median is visible rather
# than plausible: if two paths were pooled, the cell would show the mean of them.
RPS = {("/echo", "volucer-attach"): 100000, ("/echo", "rr"): 70000, ("/echo", "fpm"): 26000,
       ("/", "volucer-attach"): 80000, ("/", "rr"): 60000, ("/", "fpm"): 22000,
       ("/api/items", "volucer-attach"): 71000, ("/api/items", "rr"): 50000, ("/api/items", "fpm"): 19000,
       ("/items", "volucer-attach"): 66000, ("/items", "rr"): 47000, ("/items", "fpm"): 18000}


def write(path, head, rows):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\t".join(head) + "\n")
        for r in rows:
            fh.write("\t".join(str(c) for c in r) + "\n")


def run(matrix, mem):
    # `--out` rather than stdout: the report contains non-ASCII (a Δ in the
    # percentage columns), and a Windows console is cp1252, which cannot encode
    # it. Writing the file is also what a real run does.
    out_path = os.path.join(tempfile.mkdtemp(prefix="report-out-"), "report.md")
    proc = subprocess.run([sys.executable, REPORT, matrix, mem, "--out", out_path],
                          capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    if proc.returncode != 0:
        print("REPORT FAILED\n" + (proc.stdout or "") + (proc.stderr or ""))
        return None
    with open(out_path, encoding="utf-8") as fh:
        return fh.read()


def main():
    tmp = tempfile.mkdtemp(prefix="report-test-")
    fails = 0

    # --- 1. multi-path -----------------------------------------------------
    mtx_rows, mem_rows = [], []
    for p in PATHS:
        for arm in ARMS:
            for conc in (32, 96):
                for rnd in (1, 2, 3):
                    mtx_rows.append([p, arm, 32, "on", conc, rnd, 12,
                                     RPS[(p, arm)], "1.0ms", "2.0ms", 0, "", "process"])
            mem_rows.append([p, arm, 32, "on", "boot", 0, 100.0, 120.0, 32, ""])
            mem_rows.append([p, arm, 32, "on", "post", 96, 300.0, 340.0, 32, ""])

    mpath = os.path.join(tmp, "matrix.tsv")
    mempath = os.path.join(tmp, "memory.tsv")
    write(mpath, MTX_HEAD, mtx_rows)
    write(mempath, MEM_HEAD, mem_rows)

    out = run(mpath, mempath)
    if out is None:
        return 1

    for p in PATHS:
        if f"## `{p}`" not in out:
            print(f"FAIL no section heading for {p}")
            fails += 1
        # Exactly one heading per path, not one per table.
        n = out.count(f"## `{p}`")
        if n != 1:
            print(f"FAIL {p} has {n} section headings, want 1")
            fails += 1

    # Each arm's throughput for a path must appear in that path's section, and
    # the *other* paths' values must not. Rendered as the report renders it —
    # `fmt()` inserts thousands separators, so the raw integer never matches.
    def rendered(v):
        return f"{v:,}"

    for p in PATHS:
        start = out.index(f"## `{p}`")
        nxt = [out.index(f"## `{q}`") for q in PATHS if q != p and f"## `{q}`" in out]
        end = min([x for x in nxt if x > start], default=len(out))
        section = out[start:end]
        for arm in ARMS:
            want = rendered(RPS[(p, arm)])
            if want not in section:
                print(f"FAIL {p} section missing {arm} rps {want}")
                fails += 1
            for q in PATHS:
                if q == p:
                    continue
                other = rendered(RPS[(q, arm)])
                if other != want and other in section:
                    print(f"FAIL {p} section leaked {q}'s {arm} rps {other}")
                    fails += 1

    # `*` memory rows must not create a phantom endpoint.
    if "<unrecorded>" in out:
        print("FAIL memory '*' produced a phantom endpoint section")
        fails += 1

    # --- 2. legacy TSV with no path column ---------------------------------
    old_mtx = [r[1:] for r in mtx_rows if r[0] == "/items"]
    old_mem = [r[1:] for r in mem_rows if r[0] == "/items"]
    om = os.path.join(tmp, "old-matrix.tsv")
    omm = os.path.join(tmp, "old-memory.tsv")
    write(om, MTX_HEAD[1:], old_mtx)
    write(omm, MEM_HEAD[1:], old_mem)

    out2 = run(om, omm)
    if out2 is None:
        return 1
    if out2.count("## `") > 1:
        print("FAIL legacy TSV was split into several endpoint sections")
        fails += 1
    if f"{RPS[('/items', 'volucer-attach')]:,}" not in out2:
        print("FAIL legacy TSV lost its throughput")
        fails += 1

    print("report grouping OK" if fails == 0 else f"report grouping FAILED ({fails})")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
