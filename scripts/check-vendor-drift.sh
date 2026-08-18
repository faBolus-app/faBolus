#!/usr/bin/env bash
# check-vendor-drift.sh (D-02) — vendored-source-tree integrity check for the LoopPowerPack Vendor tree.
#
# Records a deterministic, sorted `shasum -a 256` manifest of every tracked file under
# ios/faBolus/Vendor/LoopPowerPack/ (excluding the manifest itself) and fails non-zero if any vendored
# byte changes without a manifest update. This is a SOURCE-TREE integrity check — deliberately NOT a
# schema-property check like scripts/check-schema-drift.sh (D-02). Vendored MIT source does not
# auto-merge; the drift surfaced here is applied by hand (see UPSTREAM.md).
#
# Usage:
#   bash scripts/check-vendor-drift.sh            # check: recompute + diff against the committed manifest
#   bash scripts/check-vendor-drift.sh --update   # regenerate the committed manifest (after a re-vendor)
set -euo pipefail
cd "$(dirname "$0")/.."

VENDOR_DIR="ios/faBolus/Vendor/LoopPowerPack"
MANIFEST="$VENDOR_DIR/.vendor-manifest.sha256"

# Deterministic, sorted sha256 manifest of every tracked (or to-be-tracked, not-ignored) file under the
# Vendor tree, excluding the manifest itself. Paths are repo-root-relative and C-sorted for stability.
generate_manifest() {
  local files
  files=$(git ls-files --cached --others --exclude-standard -- "$VENDOR_DIR" \
            | grep -v "^${MANIFEST}\$" \
            | LC_ALL=C sort)
  if [ -z "$files" ]; then
    echo "❌ check-vendor-drift: no files found under $VENDOR_DIR" >&2
    exit 1
  fi
  # shasum prints "<hash>  <path>"; feeding the C-sorted list keeps output order stable.
  printf '%s\n' "$files" | xargs shasum -a 256
}

if [ "${1:-}" = "--update" ]; then
  generate_manifest > "$MANIFEST"
  echo "✅ Regenerated $MANIFEST ($(wc -l < "$MANIFEST" | tr -d ' ') files)."
  exit 0
fi

if [ ! -f "$MANIFEST" ]; then
  echo "❌ Missing vendor manifest $MANIFEST — run: bash scripts/check-vendor-drift.sh --update" >&2
  exit 1
fi

if ! drift=$(diff -u "$MANIFEST" <(generate_manifest)); then
  echo "❌ Vendor drift: the LoopPowerPack Vendor tree no longer matches $MANIFEST." >&2
  echo "   A vendored file changed without a manifest update. Review the diff below; if this is an" >&2
  echo "   intentional re-vendor from a new upstream SHA, update UPSTREAM.md then run --update." >&2
  echo "$drift" >&2
  exit 1
fi
echo "✅ Vendor tree matches $MANIFEST ($(wc -l < "$MANIFEST" | tr -d ' ') files)."
