#!/usr/bin/env bash
# The quality gates. CI runs each one as its own step; with no argument this runs them all.
#
#   scripts/check.sh                 # every gate
#   scripts/check.sh build format    # just these
#
# Gates: build, test, format, swiftlint, shell, actions, markdown, contract.
# legacy/ (the old app, copied from during the rebuild) is outside every gate. The vendored ShareClient is
# compiled under the same rules but is not reformatted or linted, so drift against upstream stays visible.
set -euo pipefail
cd "$(dirname "$0")/.."

PACKAGES=(faBolusCore faBolusDesign HistoryStore ShareClient DexcomBLE GlucoseSources PumpSession Alerts RemoteProtocol WatchLink)

swift_files() {
  git ls-files -z '*.swift' ':!:legacy/*' ':!:Packages/ShareClient/*'
}

gate_build() {
  for p in "${PACKAGES[@]}"; do
    echo "-- $p"
    swift build --package-path "Packages/$p" --build-tests -Xswiftc -warnings-as-errors
  done
}
# Same flags as gate_build, so running both doesn't compile everything twice.
gate_test() {
  for p in "${PACKAGES[@]}"; do
    [ -d "Packages/$p/Tests" ] || continue
    echo "-- $p"
    swift test --package-path "Packages/$p" -Xswiftc -warnings-as-errors
  done
}
gate_format() { swift_files | xargs -0 xcrun swift-format lint --strict; }
gate_swiftlint() { swiftlint lint --strict --quiet; }
gate_shell() { git ls-files -z '*.sh' ':!:legacy/*' | xargs -0 shellcheck; }
gate_actions() { actionlint; }
gate_markdown() { markdownlint-cli2; }
# The phone↔remote contract: version 2's schema against its golden fixtures (the fixtures themselves are
# checked against the Swift types by RemoteProtocol's tests); version 1's drift check until the old app is
# deleted; and the provenance chain.
gate_contract() {
  python3 scripts/check-contract.py
  ./scripts/check-schema-drift.sh
  ./scripts/check-sbom.sh
}

gates=("$@")
[ "${#gates[@]}" -gt 0 ] || gates=(build test format swiftlint shell actions markdown contract)
for g in "${gates[@]}"; do
  echo "== $g"
  "gate_$g"
done
echo "all gates passed: ${gates[*]}"
