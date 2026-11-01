#!/usr/bin/env bash
# Build the whole faBolus app (iOS app + widgets) for the Simulator.
#
# Select the simulator with `-destination` only and let each target use its own platform SDK.
set -euo pipefail
cd "$(dirname "$0")/.."

# Auto-detects the Garmin SDK so the app builds without it when absent.
./scripts/generate-project.sh >/dev/null

xcodebuild \
  -project faBolus.xcodeproj \
  -scheme faBolus \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build "$@"
