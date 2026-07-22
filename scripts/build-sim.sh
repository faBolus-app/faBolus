#!/usr/bin/env bash
# Build the whole faBolus app (iOS app + embedded watchOS app + widgets) for the Simulator.
#
# IMPORTANT: do NOT pass `-sdk iphonesimulator`. This scheme embeds a watchOS app, and an explicit
# `-sdk` override forces EVERY target — including the watch — onto that SDK, so the watch sources
# compile against the iOS SDK and fail on watchOS-only APIs (e.g. digitalCrownRotation). Select the
# simulator with `-destination` only and let each target use its own platform SDK.
set -euo pipefail
cd "$(dirname "$0")/.."

# Auto-detects the Garmin SDK and honors FABOLUS_WATCH so the app builds without them.
./scripts/generate-project.sh >/dev/null

xcodebuild \
  -project faBolus.xcodeproj \
  -scheme faBolus \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build "$@"
