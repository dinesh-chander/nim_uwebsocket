#!/usr/bin/env python3
"""Write ci/coverage-baseline.json from a fresh coverage/summary.md run.

Usage: python3 scripts/update_coverage_baseline.py coverage/summary.md [baseline.json]
"""
import datetime
import json
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: update_coverage_baseline.py <summary.md> [baseline.json]", file=sys.stderr)
        return 2
    summary_path = sys.argv[1]
    baseline_path = sys.argv[2] if len(sys.argv) > 2 else "ci/coverage-baseline.json"

    packages = {}
    in_section = False
    total_lines = 0
    total_missed = 0
    with open(summary_path, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("## "):
                in_section = line.strip() == "## Line coverage per package"
                continue
            if not in_section or not line.startswith("|"):
                continue
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) < 4 or cells[0] in ("Package", "") or cells[0].strip("*") == "Total" or set(cells[0]) <= {"-"}:
                continue
            try:
                lines, missed = int(cells[1]), int(cells[2])
            except ValueError:
                continue
            pct = round((lines - missed) * 100.0 / lines, 2) if lines else 0.0
            packages[cells[0]] = {"lines": lines, "missed": missed, "coverage_pct": pct}
            total_lines += lines
            total_missed += missed

    if not packages:
        print("no package table found in " + summary_path, file=sys.stderr)
        return 1

    total_pct = round((total_lines - total_missed) * 100.0 / total_lines, 2)
    data = {
        "coverage_pct": total_pct,
        "total_lines": total_lines,
        "total_missed": total_missed,
        "tolerance_pp": 0.25,
        "updated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "packages": packages,
        "note": "Full-suite LLVM line coverage over scripts/test_all.sh discovery. "
        "Raise only after a green `bash scripts/coverage.sh` run; the CI gate "
        "(scripts/coverage_gate.sh) fails when coverage drops more than "
        "tolerance_pp below this baseline.",
    }
    import os
    parent = os.path.dirname(baseline_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(baseline_path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    print("wrote " + baseline_path + " — total " + str(total_pct) + "% ("
          + str(total_lines) + " lines, " + str(total_missed) + " missed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
