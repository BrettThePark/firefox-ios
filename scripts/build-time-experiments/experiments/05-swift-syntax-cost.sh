#!/usr/bin/env bash
# Experiment 05: isolate the clean-build cost of swift-syntax pulled in by
# ModifiedCopyMacro (pinned at 2.2.0 in Client.xcodeproj).
#
# Builds a throwaway package that depends on ModifiedCopyMacro and times a cold
# `swift build`. That time is approximately what removing the macro (or getting
# prebuilt swift-syntax) would save from every clean build of the app.
# Standalone: does not modify the repo, run directly on a Mac.
set -euo pipefail

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > Package.swift <<'EOF'
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacroCostProbe",
    platforms: [.iOS(.v15), .macOS(.v12)],
    dependencies: [
        .package(url: "https://github.com/WilhelmOks/ModifiedCopyMacro.git", exact: "2.2.0"),
    ],
    targets: [
        .target(
            name: "MacroCostProbe",
            dependencies: [.product(name: "ModifiedCopy", package: "ModifiedCopyMacro")]),
    ]
)
EOF
mkdir -p Sources/MacroCostProbe
cat > Sources/MacroCostProbe/Probe.swift <<'EOF'
import ModifiedCopy

@Copyable
public struct Probe {
    public var value: Int
}
EOF

echo "-- resolving (not timed)"
swift package resolve > /dev/null

echo "-- timing cold build of ModifiedCopyMacro + swift-syntax"
t0="$(perl -MTime::HiRes=time -e 'printf "%.2f", time')"
swift build > build.log 2>&1 || { cat build.log; exit 1; }
t1="$(perl -MTime::HiRes=time -e 'printf "%.2f", time')"
perl -e "printf \"swift-syntax + macro cold build: %.1fs\n\", $t1 - $t0"
