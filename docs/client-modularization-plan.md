# Plan: Moving Client code into modules for faster compile times

## Problem

The `Client` target is the compile-time bottleneck of the Firefox for iOS build. It
currently contains ~1,070 Swift files compiled as a single module, ~820 of which live
under `Client/Frontend/`. Because Swift compiles and type-checks a module as one unit,
any change inside `Client` re-invalidates the whole target, and clean builds cannot
parallelize that work across module boundaries.

By contrast, code that already lives in `BrowserKit` (22 SPM targets such as
`ToolbarKit`, `MenuKit`, `OnboardingKit`, `SummarizeKit`, `WebCompatReporterKit`)
compiles in parallel, caches independently, and is only rebuilt when the module itself
or something below it changes.

The goal of this plan is to move the compile cost of `Client` into modules —
incrementally, following the extraction pattern the project already uses.

## Current state

File counts (Swift files):

| Area | Files |
| --- | --- |
| `Client` target total | ~1,070 |
| `Client/Frontend/` | 822 |
| — `Frontend/Browser/` | 198 |
| — `Frontend/Settings/` | 158 |
| — `Frontend/Home/` | 105 |
| — `Frontend/Library/` | 49 |
| — `Frontend/Autofill/` | 47 |
| — `Frontend/TrackingProtection/` | 27 |
| — `Frontend/Translations/` | 25 |
| `Client/Application` + `Coordinators` | 95 |
| `Client/Telemetry` | 28 |

Coupling that keeps code pinned inside `Client`:

- `import Shared` in ~340 Client files (strings, utilities, `Profile`-adjacent types)
- `import Redux` in ~130 files (app-wide `AppState` / store)
- `MozillaAppServices` in ~107 files (Rust components: places, logins, nimbus, glean)
- `import Storage` in ~84 files

Existing precedent: recently extracted kits (`OnboardingKit`, `SummarizeKit`,
`QuickAnswersKit`, `WebCompatReporterKit`) depend only on `Common`,
`ComponentLibrary`, and system frameworks. App-specific concerns — localized strings,
Glean telemetry, Nimbus configuration, Profile/Storage access — stay in `Client` and
are passed in through protocols and model objects (e.g.
`OnboardingCardInfoModelProtocol`). This is the pattern every extraction below reuses.

## Guiding rules

1. **One kit per feature, extracted bottom-up.** A kit may depend on `Common`,
   `ComponentLibrary`, `Redux`, `SiteImageView`, and other kits below it — never on
   `Client`, `Shared` (app target), `Storage`, or `MozillaAppServices`.
2. **Strings, Glean, Nimbus, and Profile stay in Client.** Kits declare small
   protocols (view models, delegates, telemetry hooks); `Client` implements them.
   This keeps localization tooling and Rust dependencies out of the package graph.
3. **Extract state + views together.** Where a feature uses Redux, its state,
   actions, middleware, and views move as one unit; `BrowserKit/Redux` is already a
   package target, so this is possible today.
4. **Every extraction lands as its own PR** with tests moved alongside
   (`firefox-ios-tests` → `BrowserKit/Tests/<Kit>Tests`), keeping diffs reviewable
   and bisectable.
5. **No behavior changes inside an extraction PR.** Renames and access-control changes
   (`internal` → `public`) only.

## Phase 0 — Baseline and guardrails (1 PR)

- Record clean and incremental build times for `Fennec` (`fxios test` scheme) with
  Xcode's build timeline and `-driver-time-compilation`, and capture per-target
  timings. Store the method and numbers in this doc so each phase can show its win.
- Add `-warn-long-function-bodies=200 -warn-long-expression-type-checking=200` to a
  local diagnostic configuration (not CI) to find type-checking hotspots that are
  cheap wins independent of modularization.

## Phase 0.5 — Build hygiene (before any modularization)

Fixed per-build overhead that modularization does not address. Each item is
testable in isolation with `scripts/build-time-experiments/run-all.sh`, which
measures cold, no-op, and incremental builds for the baseline and for each
change applied on its own (see `scripts/build-time-experiments/README.md`).

1. **Run-script phases marked `alwaysOutOfDate`.** The Nimbus FML phase
   declares proper inputs/outputs but is still `alwaysOutOfDate = 1`, so it
   runs on every build; the SwiftLint, test-fixtures rsync, reader-mode rsync,
   and optional-resources phases are `alwaysOutOfDate` with no declared
   outputs. (Both Glean phases are already correctly declared.) Experiments 01
   and 03 measure dropping the flag + declaring I/O, and skipping in-build
   SwiftLint entirely.
2. **dSYM generation in dev configs.** Two `Fennec_Testing` configurations
   still use `dwarf-with-dsym`; dev builds only need `dwarf`. Experiment 02.
3. **`ModifiedCopyMacro` pulls in swift-syntax (600.0.1) as a from-source
   build dependency** — a well-known multi-minute clean-build cost. ~63 call
   sites, all Redux state structs. Experiment 05 isolates the cost with a
   standalone probe package; the fix is either prebuilt swift-syntax support
   (newer Xcode/SwiftPM) or hand-writing the `copy` helpers.
4. **Explicitly Built Modules** (Xcode 16+): settings flip, measured by
   experiment 04; verify the build still succeeds before trusting numbers.

## Phase 1 — Cut the seams (2–3 PRs)

These unblock everything after them:

1. **Theme/UX constants**: anything in `Client/Frontend/Theme` still referenced by
   feature code should live in `Common` (most theming already does).
2. **Telemetry seam**: introduce narrow, per-feature telemetry protocols (following
   `SummarizeKit`) rather than one giant protocol, so kits never import Glean.
3. **Redux seam**: features that will be extracted must key their state off
   `ScreenState` sub-states rather than reaching into unrelated parts of `AppState`.
   Audit the ~130 Redux-importing files and untangle cross-feature state reads first.

## Phase 2 — Leaf feature kits (one PR each, ordered by cost/benefit)

Start with features that are self-contained UI with few `Storage`/`Profile` touches:

| New kit | Source | Files | Notes |
| --- | --- | --- | --- |
| `TrackingProtectionKit` | `Frontend/TrackingProtection` | 27 | Mostly UI + models; stats injected |
| `TranslationsKit` | `Frontend/Translations` | 25 | Recent, already well-isolated code |
| `MicrosurveyKit` | `Frontend/Microsurvey` | 16 | Redux state moves with it |
| `PasswordGeneratorKit` | `Frontend/PasswordGenerator` | 9 | Logins write-back via delegate |
| `NativeErrorPageKit` | `Frontend/NativeErrorPage` | 10 | |
| `ReaderModeUIKit` | `Frontend/Reader` | 13 | Reader parsing stays where it is |
| `ShareKit` | `Frontend/Share` | 13 | |

Each extraction follows the same recipe:

1. Create `BrowserKit/Sources/<Kit>` + `Tests/<Kit>Tests`, add the library product to
   `BrowserKit/Package.swift`.
2. Move files; make the entry points `public`; replace `Client` imports with injected
   protocols (strings model, telemetry hook, data provider).
3. In `Client`, add a thin glue file implementing those protocols (this is where
   `.Strings`, Glean, and Profile access remain).
4. Move the feature's unit tests; run `fxios test` and SwiftLint.

## Phase 3 — The big three (one kit each, split into stacked PRs)

These carry most of the compile cost and need the Phase 1 seams:

1. **`HomepageKit`** (~105 files): homepage is already Redux-driven and largely
   isolated behind `HomepageState`; storage-backed sections (top sites, stories,
   bookmarks) get data-source protocols.
2. **`SettingsKit`** (~158 files): the settings table infrastructure
   (`Setting`, `SettingsTableViewController` hierarchy) extracts first as the kit's
   core; individual settings screens migrate in follow-up PRs. Screens that touch
   `Profile` directly get small view-model protocols.
3. **`LibraryKit`** (~49 files + `PasswordManagement` 17): bookmarks, history,
   downloads, reading list panels behind data-provider protocols over `Storage` types
   (`Site`, `BookmarkNode` equivalents defined in the kit or in `Common`).

`Frontend/Browser` (198 files, including `BrowserViewController`) is deliberately
**not** extracted: it is the integration hub that wires everything together. It
shrinks naturally as toolbars (already `ToolbarKit`), menus (`MenuKit`), and the
features above leave it.

## Phase 4 — Retire duplicated app-target frameworks (stretch)

`Storage` (42 files), `Sync`, and `Account` remain Xcode framework targets inside
`Client.xcodeproj`. Once Phases 2–3 land, evaluate moving `Storage`'s
non-Rust-dependent model types (`Site`, `VisitType`, etc.) into a `StorageKit` SPM
target so feature kits can share types without linking the Rust megamodule. This is
higher risk (app-services coupling) and should only start after the earlier phases
prove out.

## Measuring success

After each phase, re-run the Phase 0 measurement and update this table:

| Milestone | Clean build | Incremental (touch 1 Frontend file) |
| --- | --- | --- |
| Baseline | _record_ | _record_ |
| After Phase 2 | | |
| After Phase 3 | | |

Expected effects:

- **Incremental builds**: editing an extracted feature rebuilds only that kit plus
  `Client` linking, not 1,000+ files of type-checking context.
- **Clean builds**: SPM targets compile in parallel; moving ~400 files out of
  `Client` (Phases 2–3) meaningfully shortens the serialized critical path.
- **CI caching**: unchanged BrowserKit targets hit the build cache across PRs.

## Risks and mitigations

- **Access-control churn** (`public` sprawl): keep kit APIs minimal; only entry-point
  types and injected protocols go public.
- **String handling**: strings stay in `Client/Strings.swift` and are passed via view
  models, matching `OnboardingKit`; no localization pipeline changes needed.
- **Merge conflicts with feature work**: extractions are file moves — coordinate each
  kit's PR with the owning team and land quickly; avoid long-lived branches.
- **Redux store singleton**: kits use `Redux` types but the store instance is owned by
  `Client` and injected, as `WindowManager`-scoped code already does.
