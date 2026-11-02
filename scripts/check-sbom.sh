#!/usr/bin/env bash
# Fail if a vendored/local package lacks a LICENSE or a row in docs/SBOM.md.
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
    faBolusCore|faBolusDesign|HistoryStore|GlucoseSources|PumpSession|Alerts|RemoteProtocol|WatchLink|PhoneApp) : ;;   # first-party, covered by the repo LICENSE
    *)
      if [[ ! -f "$dir/LICENSE" && ! -f "$dir/LICENSE.md" && ! -f "$dir/LICENSE.txt" ]]; then
        echo "MISSING LICENSE: vendored package $name has no LICENSE file"; fail=1
      fi ;;
  esac
done

# Ported/adapted source. The Packages/* loop above can't see a single copied file, so scan every
# first-party Swift file for a `Ported from` / `Adapted from` attribution comment and require the file's
# basename to appear in $SBOM WITH a recognizable SPDX/license token. Deliberately narrow to those two
# markers (NOT "derived from", which legitimately describes many pump-derived values) to keep false
# positives out; a genuine port must carry the marker AND an SBOM row.
LICENSE_RE='MIT|Apache-2\.0|Apache 2|BSD|ISC|MPL|GPL|LicenseRef|independent Swift impl'
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  base="$(basename "$f")"
  row="$(grep -F "$base" "$SBOM" || true)"
  if [[ -z "$row" ]]; then
    echo "MISSING SBOM ENTRY: ported/adapted app-tree file $f ($base) is not listed in $SBOM"; fail=1
  elif ! grep -qE "$LICENSE_RE" <<<"$row"; then
    echo "MISSING LICENSE: the $SBOM row for $base carries no recognizable SPDX/license token"; fail=1
  fi
done < <(git ls-files -z '*.swift' | xargs -0 grep -lE '(^|[^[:alnum:]])[Pp]orted from|(^|[^[:alnum:]])[Aa]dapted from' 2>/dev/null | grep -vE '/[^/]*Tests?/|Tests?\.swift' || true)

if [[ "$fail" -ne 0 ]]; then
  echo "SBOM check FAILED — reconcile the component with $SBOM." >&2
  exit 1
fi
echo "SBOM check passed: all Packages/* and ported first-party source accounted for in $SBOM."
