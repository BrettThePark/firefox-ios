#!/usr/bin/env python3
"""Experiment 03: skip the SwiftLint build phase entirely.

Measures the ceiling of what gating/removing the in-build lint would save.
(SwiftLint still runs via the repo's push hooks.)
"""
from pathlib import Path

PBXPROJ = Path(__file__).resolve().parents[3] / "firefox-ios/Client.xcodeproj/project.pbxproj"
PHASE_ID = "C874A4E327F62C5B006F54E5"


def main() -> None:
    src = PBXPROJ.read_text()
    start = src.find(PHASE_ID + " /* Swiftlint */ = {")
    if start == -1:
        raise SystemExit("SwiftLint phase definition not found")
    marker = "shellScript = \""
    idx = src.find(marker, start)
    if idx == -1:
        raise SystemExit("SwiftLint shellScript not found")
    insert_at = idx + len(marker)
    src = src[:insert_at] + "exit 0 # experiment 03: swiftlint skipped\\n" + src[insert_at:]
    PBXPROJ.write_text(src)
    print("03-skip-swiftlint: applied")


if __name__ == "__main__":
    main()
