#!/usr/bin/env bash
# check-info-plist-orphans.sh — Info.plist dead-key assertion for the Phase-1 CGM retro-clean
# (CLEAN-01, INV-02). ios/faBolus/Info.plist's `LoopAppGroupIdentifier`/`TrioAppGroupIdentifier` keys
# were read ONLY by the now-deleted `XDripAppGroupSource.swift` (02.5-RESEARCH.md Finding 1). Once that
# source is git rm'd, the two keys are dead weight shipped in every build's Info.plist — a real
# INV-02/§6c dangling reference that the generic no-dangling-type grep does not catch (Info.plist keys
# are not Swift type references).
#
# Asserts both keys are ABSENT from the tracked, XcodeGen-written ios/faBolus/Info.plist. Exits non-zero
# and names any key still present.
#
# No automated Info.plist-key-orphan check existed before this phase (RESEARCH Validation Architecture,
# Wave 0 Gaps) — this script fills that gap.
#
# Usage:
#   scripts/check-info-plist-orphans.sh
set -uo pipefail

cd "$(dirname "$0")/.."

PLIST="ios/faBolus/Info.plist"

if [ ! -f "$PLIST" ]; then
  echo "✗ $PLIST does not exist"
  exit 1
fi

# Dead keys — only reader was the deleted XDripAppGroupSource.swift.
ORPHAN_KEYS=(
  "LoopAppGroupIdentifier"
  "TrioAppGroupIdentifier"
)

fail=0
printf '== check-info-plist-orphans.sh — %s ==\n' "$PLIST"

for key in "${ORPHAN_KEYS[@]}"; do
  count=$(grep -c "<key>${key}</key>" "$PLIST")
  if [ "$count" -eq 0 ]; then
    printf '  ✓ %-30s absent\n' "$key"
  else
    printf '  ✗ %-30s still present (%d occurrence(s)) — dead key, only reader was XDripAppGroupSource.swift\n' "$key" "$count"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "❌ Info.plist orphan-key check FAILED — see violations above"
  exit 1
fi
echo "✅ no orphaned App-Group Info.plist keys"
