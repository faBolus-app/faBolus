#!/usr/bin/env bash
# Builds the app for the iOS simulator, warnings as errors, unsigned. Extra arguments go to xcodebuild.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/generate-project.sh >/dev/null
xcodebuild -project faBolus.xcodeproj -scheme faBolus -destination 'generic/platform=iOS Simulator' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build "$@"
