#!/usr/bin/env bash
# Runs the app's tests (the snapshot tests among them) on an iPhone simulator. The snapshots are recorded
# on FABOLUS_TEST_DEVICE (default "iPhone 17") at iOS 27.2; another device or OS renders differently.
# FABOLUS_TEST_DEST overrides the whole destination. Extra arguments go to xcodebuild.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/generate-project.sh >/dev/null
DEST="${FABOLUS_TEST_DEST:-platform=iOS Simulator,name=${FABOLUS_TEST_DEVICE:-iPhone 17},OS=27.2}"
xcodebuild -project faBolus.xcodeproj -scheme faBolus -destination "$DEST" -configuration Debug \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO test "$@"
