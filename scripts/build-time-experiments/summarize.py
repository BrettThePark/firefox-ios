#!/usr/bin/env python3
"""Turns results/timings.csv into results/SUMMARY.md (median per label/case)."""
import csv
import statistics
from pathlib import Path

RESULTS = Path(__file__).resolve().parent / "results"
CASES = ["cold", "noop", "op"]


def main() -> None:
    rows = list(csv.DictReader((RESULTS / "timings.csv").open()))
    labels = list(dict.fromkeys(r["label"] for r in rows))
    data = {}
    for r in rows:
        data.setdefault((r["label"], r["case"]), []).append(float(r["seconds"]))

    def cell(label: str, case: str) -> str:
        values = data.get((label, case))
        if not values:
            return "—"
        median = statistics.median(values)
        base = data.get(("baseline", case))
        if base and label != "baseline":
            delta = median - statistics.median(base)
            return f"{median:.1f}s ({delta:+.1f}s)"
        return f"{median:.1f}s"

    lines = [
        "# Build-time experiment results",
        "",
        "Median wall time per case; delta vs. baseline in parentheses.",
        "",
        "| Experiment | Cold | No-op | Incremental (op) |",
        "| --- | --- | --- | --- |",
    ]
    for label in labels:
        lines.append(
            f"| {label} | " + " | ".join(cell(label, c) for c in CASES) + " |"
        )
    standalone = RESULTS / "05-swift-syntax-cost.txt"
    if standalone.exists():
        lines += ["", "## swift-syntax isolation (experiment 05)", "", "```",
                  standalone.read_text().strip(), "```"]
    (RESULTS / "SUMMARY.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
