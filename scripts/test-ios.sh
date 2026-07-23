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

DEST="${FABOLUS_TEST_DEST:-platform=iOS Simulator,name=iPhone 16}"

set -o pipefail
xcodebuild \
  -project faBolus.xcodeproj \
  -scheme faBolus \
  -destination "$DEST" \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  test "$@"
