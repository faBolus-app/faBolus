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

# Same generation path as build-sim.sh (auto-detects Garmin).
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

# Force SERIAL test execution. Swift Testing runs a suite's `@Test`s in parallel by DEFAULT, using
# task groups within one process. These are @MainActor async behavioral suites that all drive the real
# AppModel, which reads process-global `AppSettings.shared` (a UserDefaults.standard-backed singleton —
# AppModel.swift reads it in ~59 places, incl. the delivery gates childModeEnabled/phoneReadOnly/
# remotesReadOnly/advancedControlEnabled). Many suites also MUTATE those same globals (appMode,
# phoneReadOnly, garminBolusEnabled, …) with a save→set→`await body()`→defer-restore pattern. That
# pattern is safe WITHIN a `@Suite(.serialized)` suite, but the `.serialized` trait
# only orders tests relative to each other WITHIN their own suite — Apple's docs: it "does not influence
# the execution of a test relative to other unrelated tests." So at every `await` a test in suite A yields
# the main actor to an interleaved test in suite B, which clobbers/observes A's shared-global setup. That
# is exactly the observed symptom: a NON-DETERMINISTIC set of failures clustered in the delivery/ledger/
# CIQ gate families, plus occasional test-host crashes ("Restarting after unexpected exit…") from racing
# the shared state. Per-suite `.serialized` cannot fix a cross-suite race; the only robust cure is to
# disable parallelization globally (the docs' "global parallelization … disabled via command-line
# arguments"). `-parallel-testing-enabled NO` does this for Swift Testing under xcodebuild — verified: it
# yields strictly sequential start→finish ordering (no interleave) and a stable green. Correctness of a
# bolus-dosing app's gate/ledger guards outranks the modest wall-clock cost of serial execution. Do NOT
# re-enable parallelism here without first removing the shared-global coupling from these suites.
set -o pipefail
xcodebuild \
  -project faBolus.xcodeproj \
  -scheme faBolus \
  -destination "$DEST" \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO \
  test "$@"
