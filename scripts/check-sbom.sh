#!/usr/bin/env bash
# Audit L-01: fail if a vendored/local package lacks a LICENSE or a row in docs/SBOM.md.
# Keeps the provenance chain honest — a new bundled dependency can't slip in undocumented.
set -euo pipefail
cd "$(dirname "$0")/.."

SBOM="docs/SBOM.md"
fail=0

[[ -f "$SBOM" ]] || { echo "MISSING: $SBOM"; exit 1; }

# Every local package under Packages/ must ship a LICENSE (in-repo MIT packages are covered by the
# root LICENSE, so a missing file is allowed only for the two first-party ones) AND appear in the SBOM.
for dir in Packages/*/; do
  name="$(basename "$dir")"
  if ! grep -q "\b$name\b" "$SBOM"; then
    echo "MISSING SBOM ENTRY: $name (Packages/$name) is not listed in $SBOM"; fail=1
  fi
  # Vendored (non-first-party) packages must carry their upstream LICENSE.
  case "$name" in
    faBolusCore|HistoryStore) : ;;   # first-party, covered by the repo LICENSE
    *)
      if [[ ! -f "$dir/LICENSE" && ! -f "$dir/LICENSE.md" && ! -f "$dir/LICENSE.txt" ]]; then
        echo "MISSING LICENSE: vendored package $name has no LICENSE file"; fail=1
      fi ;;
  esac
done

if [[ "$fail" -ne 0 ]]; then
  echo "SBOM check FAILED — reconcile the component with $SBOM (audit L-01)." >&2
  exit 1
fi
echo "SBOM check passed: all Packages/* accounted for in $SBOM."
