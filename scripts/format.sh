#!/usr/bin/env bash
# Format first-party Swift in place with the toolchain's swift-format (Xcode 27.2). `.swift-format`
# keeps only the pretty-printer and DoNotUseSemicolons, so this reflows layout but never rewrites code.
# The vendored ShareClient is left alone. `scripts/check.sh format` is the matching lint.
set -euo pipefail
cd "$(dirname "$0")/.."
git ls-files -z '*.swift' ':!:Packages/ShareClient/*' |
  xargs -0 xcrun swift-format format --in-place --parallel
