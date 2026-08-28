#!/usr/bin/env python3
"""Experiment 01: let Xcode skip run-script phases that declare their inputs/outputs.

- Nimbus FML phase: already declares inputs/outputs but is alwaysOutOfDate — drop the
  flag and add nimbus-features/ as an input so edits there still regenerate.
- test-fixtures / reader-mode rsync phases: declare source dir input + destination output,
  drop alwaysOutOfDate.
- "Conditionally Add Optional Resources": declare Settings.bundle + Debug assets as
  inputs, Settings.bundle in the app as output, drop alwaysOutOfDate.

SwiftLint is intentionally untouched here (see experiment 03).
"""
import re
import sys
from pathlib import Path

PBXPROJ = Path(__file__).resolve().parents[3] / "firefox-ios/Client.xcodeproj/project.pbxproj"

EDITS = {
    # Nimbus Feature Manifest Generator Script
    "5FA2232C27F6FA69005B3D87": {
        "inputs": ['"$(SOURCE_ROOT)/nimbus-features"'],
        "outputs": [],
    },
    # Populate test-fixtures script
    "D48146712E26CB3300231244": {
        "inputs": ['"$(SRCROOT)/../test-fixtures"'],
        "outputs": ['"$(TARGET_BUILD_DIR)/Client.app/test-fixtures"'],
    },
    # Populate reader-mode script
    "EEB971C22FC0FCB200D6C232": {
        "inputs": ['"$(SRCROOT)/Client/Assets/reader-mode"'],
        "outputs": ['"$(TARGET_BUILD_DIR)/Client.app/reader-mode"'],
    },
    # Conditionally Add Optional Resources
    "E6639F191BF11E3A002D0853": {
        "inputs": [
            '"$(PROJECT_DIR)/$(TARGET_NAME)/Application/Settings.bundle"',
            '"$(PROJECT_DIR)/$(TARGET_NAME)/Assets/Debug"',
        ],
        "outputs": ['"$(BUILT_PRODUCTS_DIR)/$(PRODUCT_NAME).app/Settings.bundle"'],
    },
}


def edit_phase(src: str, phase_id: str, inputs, outputs) -> str:
    pattern = re.compile(
        phase_id + r" /\* [^*]+ \*/ = \{\n\t\t\tisa = PBXShellScriptBuildPhase;.*?\n\t\t\};",
        re.S,
    )
    match = pattern.search(src)
    if not match:
        sys.exit(f"phase {phase_id} not found — pbxproj layout changed?")
    block = match.group(0)
    new_block = block.replace("\t\t\talwaysOutOfDate = 1;\n", "")
    for key, values in (("inputPaths", inputs), ("outputPaths", outputs)):
        if not values:
            continue
        insertion = "".join(f"\n\t\t\t\t{v}," for v in values)
        new_block, count = re.subn(
            r"(" + key + r" = \()", r"\1" + insertion, new_block, count=1
        )
        if count != 1:
            sys.exit(f"could not insert {key} into phase {phase_id}")
    return src.replace(block, new_block)


def main() -> None:
    src = PBXPROJ.read_text()
    for phase_id, spec in EDITS.items():
        src = edit_phase(src, phase_id, spec["inputs"], spec["outputs"])
    PBXPROJ.write_text(src)
    print("01-script-phase-io: applied")


if __name__ == "__main__":
    main()
