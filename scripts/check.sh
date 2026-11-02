#!/usr/bin/env bash
# The quality gates. CI runs each one as its own step; with no argument this runs them all.
#
#   scripts/check.sh                 # every gate
#   scripts/check.sh build format    # just these
#
# Gates: build, test, app, format, swiftlint, shell, actions, markdown, contract.
# The vendored ShareClient is compiled under the same rules but is not reformatted or linted, so drift
# against upstream stays visible.
set -euo pipefail
cd "$(dirname "$0")/.."

PACKAGES=(faBolusCore faBolusDesign HistoryStore ShareClient DexcomBLE GlucoseSources PumpSession Alerts RemoteProtocol WatchLink PhoneApp)

swift_files() {
  git ls-files -z '*.swift' ':!:Packages/ShareClient/*'
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
# The app target: the project generated, the app and widgets built for the simulator with warnings as
# errors, and the app's tests run, the light and dark snapshots of every screen among them.
gate_app() { ./scripts/test-ios.sh -quiet; }
gate_format() { swift_files | xargs -0 xcrun swift-format lint --strict; }
gate_swiftlint() { swiftlint lint --strict --quiet; }
gate_shell() { git ls-files -z '*.sh' | xargs -0 shellcheck; }
gate_actions() { actionlint; }
gate_markdown() { markdownlint-cli2; }
# The phone↔remote contract: the schema against its golden fixtures (the fixtures themselves are checked
# against the Swift types by RemoteProtocol's tests); and the provenance chain.
gate_contract() {
  python3 scripts/check-contract.py
  ./scripts/check-sbom.sh
}

gates=("$@")
[ "${#gates[@]}" -gt 0 ] || gates=(build test app format swiftlint shell actions markdown contract)
for g in "${gates[@]}"; do
  echo "== $g"
  "gate_$g"
done
echo "all gates passed: ${gates[*]}"
