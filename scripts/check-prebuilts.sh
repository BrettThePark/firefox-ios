#!/bin/sh

#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/
#

#
# Reports whether Apple publishes a prebuilt swift-syntax for this machine's
# toolchain and the swift-syntax version pinned in Package.resolved.
#
# swift-syntax is only in the dependency graph because ModifiedCopyMacro needs
# it to run the @Copyable macro plugin. None of it ships in the app, but when
# no prebuilt matches, every clean build compiles it from source -- around 900
# extra object files. SwiftPM substitutes a prebuilt binary automatically when
# one is published, and falls back to a source build without warning when one
# is not: the diagnostic is info-level and never reaches the Xcode build log.
# This script surfaces that silent fallback.
#
# The check is network-only. It resolves nothing and builds nothing, so it is
# safe to run at bootstrap time before any packages exist on disk.
#
# Usage:
#   scripts/check-prebuilts.sh           Report status, always exit 0.
#   scripts/check-prebuilts.sh --strict  Exit 1 when no prebuilt is published.
#                                        For CI, where the silent fallback is
#                                        worth failing over.
#

set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
RESOLVED="$REPO_ROOT/firefox-ios/Client.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

STRICT=0
if [ "${1:-}" = "--strict" ]; then
    STRICT=1
fi

# Always exits 0, including under --strict: an indeterminate result is not a
# regression in the build graph, so a missing toolchain or a flaky network must
# never fail a build. Only a confirmed miss can do that.
give_up() {
    echo "$1" >&2
    exit 0
}

if [ ! -f "$RESOLVED" ]; then
    give_up "note: $RESOLVED not found; skipping prebuilt check."
fi

# The pins array holds one object per package. Scan forward from the
# swift-syntax entry to the "version" field inside its "state" object, taking
# the value from between its quotes rather than by field position, so that a
# change in SwiftPM's spacing cannot silently yield an empty version. Stop at
# the next entry: a branch or revision pin carries no version at all, and
# reading past the end of this one would report some other package's.
SYNTAX_VERSION=$(awk '
    /"identity"[[:space:]]*:[[:space:]]*"swift-syntax"/ { found = 1; next }
    found && /"identity"[[:space:]]*:/ { exit }
    found && match($0, /"version"[[:space:]]*:[[:space:]]*"[^"]*"/) {
        version = substr($0, RSTART, RLENGTH)
        sub(/^"version"[[:space:]]*:[[:space:]]*"/, "", version)
        sub(/"$/, "", version)
        print version
        exit
    }
' "$RESOLVED")

if [ -z "$SYNTAX_VERSION" ]; then
    give_up "note: no swift-syntax pin in Package.resolved; skipping prebuilt check."
fi

# SwiftPM asks for a manifest keyed to the exact toolchain build and macOS SDK,
# e.g. swiftlang-6.3.3.1.3-macosx26.5.json. Both halves come from the active
# toolchain, so this reproduces the URL SwiftPM itself requests.
# Take the whole build identifier, not just its leading digits: a beta or
# development toolchain reports something like swiftlang-6.5.0.1.5-beta, and
# truncating that to 6.5.0.1.5 would check the *released* toolchain's manifest
# and report a prebuilt this machine cannot use.
TOOLCHAIN=$(swift --version 2>/dev/null | sed -n 's/.*swiftlang-\([^ )]*\).*/\1/p' | head -1)
SDK_VERSION=$(xcrun --show-sdk-version --sdk macosx 2>/dev/null || true)

if [ -z "$TOOLCHAIN" ] || [ -z "$SDK_VERSION" ]; then
    give_up "note: could not determine the active Swift toolchain; skipping prebuilt check."
fi

MANIFEST="swiftlang-$TOOLCHAIN-macosx$SDK_VERSION.json"
URL="https://download.swift.org/prebuilts/swift-syntax/$SYNTAX_VERSION/$MANIFEST"

# A miss redirects rather than 404ing outright, so follow redirects and judge
# the final status: a miss lands on swift.org/404.html (404), a hit answers 200
# directly. Following them also keeps this correct if a published manifest is
# ever moved behind a redirect, which a bare 200 test would read as a miss.
STATUS=$(curl --proto '=https' --tlsv1.2 -sL -o /dev/null -w '%{http_code}' -m 20 "$URL" 2>/dev/null || true)

if [ -z "$STATUS" ] || [ "$STATUS" = "000" ]; then
    give_up "note: could not reach download.swift.org; skipping prebuilt check."
fi

if [ "$STATUS" = "200" ]; then
    echo "swift-syntax $SYNTAX_VERSION: prebuilt available for $MANIFEST." >&2
    exit 0
fi

cat >&2 <<EOF

warning: no prebuilt swift-syntax for this toolchain.

  pinned swift-syntax : $SYNTAX_VERSION
  toolchain           : swiftlang-$TOOLCHAIN (macOS SDK $SDK_VERSION)
  looked for          : $URL

  Builds will compile swift-syntax from source -- roughly 900 extra object
  files on every clean build -- to run the @Copyable macro. Xcode will not
  report this; the fallback is silent.

  Apple publishes prebuilts only for recent swift-syntax versions on recent
  toolchains. If the pin is the stale half, bumping ModifiedCopyMacro is the
  fix. If the toolchain is, it usually means Apple has not published for this
  Xcode yet. See adr/0011-redux-state-reducer-initializer-cleanup-with-copy-macro.md.

EOF

if [ "$STRICT" -eq 1 ]; then
    exit 1
fi
exit 0
