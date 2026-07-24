#!/usr/bin/env bash
# Run the app-target behavioral e2e suite (audit C-08 / T-01) on the iOS Simulator.
#
# Drives the REAL AppModel remote-delivery decision logic (divergence guard, freeze-before-approve,
# child/read-only action gates, idempotency wiring) against the in-memory MockBackend — no pump or
# BLE hardware needed. Complements faBolusCore's `swift test` (pure-logic suites) and build-sim.sh
# (compile-only). Pass extra xcodebuild args through, e.g. `-only-testing:...`.
#
# The simulator destination defaults to a current iPhone; override with FABOLUS_TEST_DEST if your
# installed Xcode ships a different device set (e.g. FABOLUS_TEST_DEST='platform=iOS Simulator,name=iPhone 15').
set -euo pipefail
cd "$(dirname "$0")/.."

# Same generation path as build-sim.sh (auto-detects Garmin, honors FABOLUS_WATCH/FABOLUS_NUDGE).
./scripts/generate-project.sh >/dev/null

# Destination: honor FABOLUS_TEST_DEST; otherwise auto-pick an INSTALLED iPhone simulator so the script
# isn't pinned to a device this Xcode may not ship (the old "iPhone 16" default is absent on Xcode 26.5,
# which installs the iPhone 17 series). Errors with a clear message if no iPhone simulator exists.
if [ -n "${FABOLUS_TEST_DEST:-}" ]; then
  DEST="$FABOLUS_TEST_DEST"
else
  SIM_NAME="$(xcrun simctl list devices available 2>/dev/null \
    | grep -oE 'iPhone [0-9][0-9A-Za-z ]*' | sed 's/[[:space:]]*$//' | head -1)"
  if [ -z "$SIM_NAME" ]; then
    echo "No installed iPhone simulator found. Install one in Xcode or set FABOLUS_TEST_DEST." >&2
    exit 1
  fi
  DEST="platform=iOS Simulator,name=$SIM_NAME"
  echo "Using auto-detected simulator: $SIM_NAME (override with FABOLUS_TEST_DEST)"
fi

set -o pipefail
xcodebuild \
  -project faBolus.xcodeproj \
  -scheme faBolus \
  -destination "$DEST" \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  test "$@"
