#!/usr/bin/env bash
# format.sh — run swift-format over first-party Swift only.
#
# Exists because swift-format has no `excluded:` setting: the vendored trees must be filtered at the
# invocation, and doing that by hand is easy to get wrong. Never restyle vendored source — drift
# against upstream has to stay visible in a diff.
#
# `.swift-format` disables all 43 swift-format RULES and keeps only the pretty-printer, so this
# reflows whitespace and line breaks but never rewrites code. The one rule left on is
# DoNotUseSemicolons, because the printer explodes `switch x { case a: …; case b: … }` one-liners
# onto separate lines and would otherwise leave a dangling `;` on each.
#
#   scripts/format.sh            # format in place
#   scripts/format.sh --lint     # report only, exit nonzero if anything is unformatted
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=format
if [ "${1:-}" = "--lint" ]; then
  MODE=lint
fi

# Vendored: ios/faBolus/Vendor (LoopPowerPack) and the four vendored Packages.
FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(
  git ls-files '*.swift' \
    ':!:ios/faBolus/Vendor/*' \
    ':!:Packages/ShareClient/*' \
    ':!:Packages/G7SensorKit/*' \
    ':!:Packages/DexcomG6Kit/*' \
    ':!:Packages/HistoryStore/*'
)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "no first-party Swift files found — is this a faBolus checkout?" >&2
  exit 1
fi

# Lint mode asks the only question that matters — "is the tree byte-identical to the formatter's
# output?" — rather than using `swift-format lint`. `lint --strict` also reports diagnostics the
# printer cannot act on (an end-of-line comment that pushes a line past the limit can only be fixed
# by MOVING the comment, which is a source change, not formatting), so it fails on a correctly
# formatted tree.
if [ "$MODE" = lint ]; then
  unformatted=()
  for f in "${FILES[@]}"; do
    if ! xcrun swift-format format "$f" | diff -q - "$f" >/dev/null 2>&1; then
      unformatted+=("$f")
    fi
  done
  if [ "${#unformatted[@]}" -gt 0 ]; then
    echo "❌ ${#unformatted[@]} file(s) are not formatted — run scripts/format.sh:" >&2
    printf '   %s\n' "${unformatted[@]}" >&2
    exit 1
  fi
  echo "✅ ${#FILES[@]} first-party Swift files are formatted"
else
  printf '%s\n' "${FILES[@]}" | xargs xcrun swift-format format --in-place --parallel
  echo "✅ formatted ${#FILES[@]} first-party Swift files"
fi
