#!/usr/bin/env python3
"""Experiment 02: use plain DWARF (no dSYM) for Fennec / Fennec_Testing configurations.

Only rewrites DEBUG_INFORMATION_FORMAT inside XCBuildConfiguration blocks whose
name is Fennec or Fennec_Testing; release-facing configs keep their dSYMs.
"""
import re
from pathlib import Path

PBXPROJ = Path(__file__).resolve().parents[3] / "firefox-ios/Client.xcodeproj/project.pbxproj"
DEV_CONFIGS = {"Fennec", "Fennec_Testing"}


def main() -> None:
    src = PBXPROJ.read_text()
    changed = 0

    def rewrite(match: re.Match) -> str:
        nonlocal changed
        block = match.group(0)
        name = match.group(1)
        if name in DEV_CONFIGS and 'DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";' in block:
            changed += 1
            return block.replace(
                'DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";',
                "DEBUG_INFORMATION_FORMAT = dwarf;",
            )
        return block

    src = re.sub(
        r"\{\n\t\t\tisa = XCBuildConfiguration;.*?name = (\w+);\n\t\t\}",
        rewrite,
        src,
        flags=re.S,
    )
    PBXPROJ.write_text(src)
    print(f"02-no-dsym-dev: rewrote {changed} configuration(s)")


if __name__ == "__main__":
    main()
