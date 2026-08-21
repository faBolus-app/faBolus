#!/usr/bin/env bash
# check-cgm-files-removed.sh — delete-completeness assertion for the Phase-1 CGM retro-clean (CLEAN-03,
# D-07). Asserts each of the 4 flag-excluded CGM source files is:
#   (a) ABSENT from `main`'s tree (git-rm'd, not merely build-excluded), and
#   (b) PRESENT on `origin/dev/cgm-extra` (the preservation branch — nothing is lost, D-05).
#
# Exits non-zero and prints every violation if EITHER half of either assertion fails for ANY file — this
# is the backstop that proves "delete on main, preserve on dev/<surface>" (D-01) actually holds, not just
# "the source no longer compiles."
#
# Usage:
#   scripts/check-cgm-files-removed.sh                  # check against HEAD (defaults to `main`'s tree)
set -uo pipefail

cd "$(dirname "$0")/.."

MAIN_REF="${MAIN_REF:-HEAD}"
PRESERVE_REF="${PRESERVE_REF:-origin/dev/cgm-extra}"

# The 4 Phase-1 CGM source files retro-cleaned this phase (02.5-CONTEXT.md D-07).
CGM_FILES=(
  "ios/faBolus/Data/Sources/DexcomG6BLESource.swift"
  "Shared/DexcomG7BLESource.swift"
  "ios/faBolus/Data/Sources/LibreLinkUpSource.swift"
  "ios/faBolus/Data/Sources/XDripAppGroupSource.swift"
)

fail=0
printf '== check-cgm-files-removed.sh — main: %s — preserve: %s ==\n' "$MAIN_REF" "$PRESERVE_REF"

if ! git rev-parse --verify --quiet "$PRESERVE_REF" >/dev/null; then
  echo "  ✗ preservation ref '$PRESERVE_REF' does not exist locally — fetch it before running this check"
  exit 1
fi

for f in "${CGM_FILES[@]}"; do
  if git cat-file -e "${MAIN_REF}:${f}" 2>/dev/null; then
    printf '  ✗ %-55s still present on %s (must be git rm'"'"'d)\n' "$f" "$MAIN_REF"
    fail=1
  else
    printf '  ✓ %-55s absent from %s\n' "$f" "$MAIN_REF"
  fi

  if git cat-file -e "${PRESERVE_REF}:${f}" 2>/dev/null; then
    printf '  ✓ %-55s present on %s\n' "$f" "$PRESERVE_REF"
  else
    printf '  ✗ %-55s MISSING from %s (would be an unrecoverable loss)\n' "$f" "$PRESERVE_REF"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "❌ CGM delete-completeness check FAILED — see violations above"
  exit 1
fi
echo "✅ all 4 Phase-1 CGM sources absent from $MAIN_REF and preserved on $PRESERVE_REF"
