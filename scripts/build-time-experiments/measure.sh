#!/usr/bin/env bash
# Measures build times for the CURRENT working tree state.
# Produces: cold build, warm no-op builds, warm incremental ("op") builds.
# Usage: measure.sh <label>
# Env overrides: SCHEME, CONFIGURATION, DESTINATION, WARM_ITERATIONS, TOUCH_FILE, RESULTS_DIR
set -euo pipefail

LABEL="${1:?usage: measure.sh <label>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PROJECT="$REPO_ROOT/firefox-ios/Client.xcodeproj"
SCHEME="${SCHEME:-Fennec}"
CONFIGURATION="${CONFIGURATION:-Fennec}"
DESTINATION="${DESTINATION:-generic/platform=iOS Simulator}"
WARM_ITERATIONS="${WARM_ITERATIONS:-3}"
TOUCH_FILE="${TOUCH_FILE:-$REPO_ROOT/firefox-ios/Client/Frontend/Browser/BrowserViewController/BrowserViewController.swift}"

RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/results}"
DERIVED="$SCRIPT_DIR/DerivedData"
PKG_CACHE="$SCRIPT_DIR/SourcePackages"
LOG_DIR="$RESULTS_DIR/logs/$LABEL"
CSV="$RESULTS_DIR/timings.csv"

mkdir -p "$RESULTS_DIR" "$LOG_DIR"
[[ -f "$CSV" ]] || echo "label,case,iteration,seconds,script_phases_run" > "$CSV"

now() { perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }

build() { # build <case> <iteration>
    local case_name="$1" iteration="$2"
    local log="$LOG_DIR/${case_name}-${iteration}.log"
    local t0 t1 phases
    t0="$(now)"
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED" \
        -clonedSourcePackagesDirPath "$PKG_CACHE" \
        -showBuildTimingSummary \
        COMPILER_INDEX_STORE_ENABLE=NO \
        build > "$log" 2>&1 || { echo "BUILD FAILED ($case_name), see $log" >&2; exit 1; }
    t1="$(now)"
    phases="$(grep -c '^PhaseScriptExecution' "$log" || true)"
    local secs
    secs="$(perl -e "printf '%.2f', $t1 - $t0")"
    echo "$LABEL,$case_name,$iteration,$secs,$phases" >> "$CSV"
    echo "  [$LABEL] $case_name #$iteration: ${secs}s (script phases run: $phases)"
}

echo "== Measuring '$LABEL' (scheme $SCHEME, config $CONFIGURATION) =="

echo "-- prewarm: resolving packages (not timed)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -clonedSourcePackagesDirPath "$PKG_CACHE" \
    -resolvePackageDependencies > "$LOG_DIR/resolve.log" 2>&1

echo "-- cold build (DerivedData wiped, package checkouts cached)"
rm -rf "$DERIVED"
build cold 1

echo "-- warm no-op builds (nothing changed)"
for i in $(seq 1 "$WARM_ITERATIONS"); do
    build noop "$i"
done

echo "-- warm incremental builds (touch $(basename "$TOUCH_FILE"))"
for i in $(seq 1 "$WARM_ITERATIONS"); do
    touch "$TOUCH_FILE"
    build op "$i"
done

echo "-- script phases run during last no-op build:"
grep '^PhaseScriptExecution' "$LOG_DIR/noop-$WARM_ITERATIONS.log" | sed 's/PhaseScriptExecution /  /;s/ \/.*//' || echo "  (none)"
