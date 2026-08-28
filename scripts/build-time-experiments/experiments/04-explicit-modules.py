#!/usr/bin/env python3
"""Experiment 04: enable Explicitly Built Modules (Xcode 16+) for debug builds."""
from pathlib import Path

XCCONFIG = Path(__file__).resolve().parents[3] / "firefox-ios/Client/Configuration/Debug.xcconfig"


def main() -> None:
    text = XCCONFIG.read_text()
    if "SWIFT_ENABLE_EXPLICIT_MODULES" in text:
        print("04-explicit-modules: already applied")
        return
    XCCONFIG.write_text(
        text.rstrip("\n")
        + "\nSWIFT_ENABLE_EXPLICIT_MODULES = YES\n_EXPERIMENTAL_CLANG_EXPLICIT_MODULES = YES\n"
    )
    print("04-explicit-modules: applied")


if __name__ == "__main__":
    main()
