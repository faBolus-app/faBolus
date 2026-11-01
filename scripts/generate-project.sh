#!/usr/bin/env bash
# Generates faBolus.xcodeproj from project.yml (needs xcodegen). Writes a derived spec,
# project.generated.yml (gitignored), with the optional parts settled:
#
#   - Garmin: on when Garmin's iOS companion SDK is at ../../vendor/connectiq-companion-app-sdk-ios-1.8.0
#     (relative to the repository), otherwise off: the SDK package, the Connect IQ adapter and the GARMIN
#     compile flag are removed and the app builds without a watch. FABOLUS_GARMIN=0/1 overrides.
#   - FABOLUS_DATA_PROTECTION=1 and FABOLUS_TIME_SENSITIVE=1 keep entitlements that need the capability
#     provisioned on your App ID (a paid account). Off by default, so an unmodified clone signs.
#
# Also writes ios/faBolus/Generated/AppRevision.swift, the commit the build came from (gitignored).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

SDK_DIR="$REPO/../../vendor/connectiq-companion-app-sdk-ios-1.8.0"
GARMIN="${FABOLUS_GARMIN:-}"
if [ -z "$GARMIN" ]; then
  GARMIN=0
  [ -d "$SDK_DIR" ] && GARMIN=1
fi

SPEC="project.generated.yml"
cp project.yml "$SPEC"

# Removes the lines from "# >>> TAG" to "# <<< TAG", inclusive; the tag must match as a whole word.
strip_block() {
  awk -v tag="$1" '
    $0 ~ ("# >>> " tag "([^A-Za-z0-9_]|$)") { skip=1; next }
    $0 ~ ("# <<< " tag "([^A-Za-z0-9_]|$)") { skip=0; next }
    !skip { print }
  ' "$SPEC" >"$SPEC.tmp" && mv "$SPEC.tmp" "$SPEC"
}

if [ "$GARMIN" = 0 ]; then
  strip_block GARMIN
  sed -i '' '/SWIFT_ACTIVE_COMPILATION_CONDITIONS/ s/ GARMIN//' "$SPEC"
fi
[ "${FABOLUS_DATA_PROTECTION:-0}" = 1 ] || strip_block DATA_PROTECTION
[ "${FABOLUS_TIME_SENSITIVE:-0}" = 1 ] || strip_block TIME_SENSITIVE

./scripts/stamp-revision.sh
xcodegen generate --spec "$SPEC" --project . --quiet
echo "Generated faBolus.xcodeproj (Garmin: $([ "$GARMIN" = 1 ] && echo on || echo off))"
