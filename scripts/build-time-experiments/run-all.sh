#!/usr/bin/env bash
# Runs the full experiment matrix: baseline, then each experiment applied in
# isolation (apply -> measure -> git restore). Writes results/timings.csv and
# results/SUMMARY.md. Run on macOS with Xcode; expects a bootstrapped checkout
# (./bootstrap.sh) and a clean git tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

if [[ -n "$(git status --porcelain -- firefox-ios)" ]]; then
    echo "error: firefox-ios/ has uncommitted changes; experiments need a clean tree to apply/revert." >&2
    exit 1
fi

restore() { git checkout -- firefox-ios; }
trap restore EXIT

echo "==== baseline ===="
"$SCRIPT_DIR/measure.sh" baseline

for exp in "$SCRIPT_DIR"/experiments/0[1-4]-*.py; do
    label="$(basename "$exp" .py)"
    echo "==== $label ===="
    python3 "$exp"
    "$SCRIPT_DIR/measure.sh" "$label"
    restore
done

echo "==== 05-swift-syntax-cost (standalone) ===="
"$SCRIPT_DIR/experiments/05-swift-syntax-cost.sh" | tee "$SCRIPT_DIR/results/05-swift-syntax-cost.txt"

python3 "$SCRIPT_DIR/summarize.py"
echo "Done. See $SCRIPT_DIR/results/SUMMARY.md"
