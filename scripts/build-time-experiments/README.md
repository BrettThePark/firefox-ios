# Build-time experiments

Measures the compile-time proposals from
[docs/client-modularization-plan.md](../../docs/client-modularization-plan.md)
before any modularization work. Each experiment is applied in isolation to a
clean tree, measured, and reverted, so the numbers are directly comparable to
the baseline.

Requires macOS with Xcode and a bootstrapped checkout (`./bootstrap.sh`).

## Running

```bash
./scripts/build-time-experiments/run-all.sh
```

Results land in `scripts/build-time-experiments/results/`:

- `timings.csv` — every timed build
- `SUMMARY.md` — medians per experiment with deltas vs. baseline
- `logs/<label>/` — full xcodebuild logs (including `-showBuildTimingSummary`
  output and which `PhaseScriptExecution` steps ran)

Each experiment measures three cases against the `Fennec` scheme:

- **cold** — DerivedData wiped (SPM checkouts cached, so network fetch is not
  counted, but dependency compilation is)
- **no-op** — rebuild with no changes; measures fixed per-build overhead
- **op** — `touch` `BrowserViewController.swift`, rebuild; measures the
  incremental path a developer pays on every edit

Knobs (env vars): `SCHEME`, `CONFIGURATION`, `DESTINATION`, `WARM_ITERATIONS`
(default 3), `TOUCH_FILE`. A single state can be measured directly with
`./measure.sh <label>`.

## Experiments

| # | What it changes | What it tests |
| --- | --- | --- |
| 01 | Drops `alwaysOutOfDate` and declares inputs/outputs for the Nimbus FML, test-fixtures, reader-mode, and optional-resources phases | Whether Xcode skipping those scripts shrinks no-op/incremental builds. (Both Glean phases already declare I/O correctly and are left alone.) |
| 02 | `DEBUG_INFORMATION_FORMAT = dwarf` for `Fennec`/`Fennec_Testing` configs still set to `dwarf-with-dsym` | dSYM generation cost in dev builds |
| 03 | Short-circuits the SwiftLint phase (`exit 0`) | Ceiling of gating/removing in-build lint (lint still runs via push hooks) |
| 04 | `SWIFT_ENABLE_EXPLICIT_MODULES = YES` in Debug.xcconfig | Explicitly Built Modules (Xcode 16+); watch for build breakage — it is experimental |
| 05 | Nothing (standalone probe package) | Cold-build cost of swift-syntax pulled in by `ModifiedCopyMacro` 2.2.0 — the approximate clean-build saving from dropping the macro or adopting prebuilt swift-syntax |

## Interpreting

- Experiments 01 and 03 should show up in **no-op** and **op**; check the
  "script phases run" count in the summary/logs to confirm phases were skipped.
- Experiment 02 shows up mostly in **op** (dSYM regenerates after relinking)
  and **cold**.
- Experiment 04 mainly affects **cold** and module-graph-heavy incremental
  builds; verify the build still succeeds before trusting its numbers.
- Experiment 05 is an isolated number, not a diff against baseline.

These are measurement mutations, not landable patches. Before landing 01 for
real, review the declared inputs/outputs for correctness (e.g. directory
inputs only track the directory's own mtime, not deep file edits) and whether
the optional-resources phase needs per-configuration outputs.
