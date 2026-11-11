#!/usr/bin/env bash
# The quality gates. CI runs each one as its own step; with no argument this runs them all.
#
#   scripts/check.sh                 # every gate
#   scripts/check.sh build format    # just these
#
# Gates: traits, build, test, app, format, swiftlint, shell, actions, markdown, contract.
# The vendored ShareClient is compiled under the same rules but is not reformatted or linted, so drift
# against upstream stays visible.
set -euo pipefail
cd "$(dirname "$0")/.."

PACKAGES=(faBolusCore faBolusDesign HistoryStore ShareClient DexcomBLE GlucoseSources PumpSession Alerts RemoteProtocol WatchLink PhoneApp)

swift_files() {
  git ls-files -z '*.swift' ':!:Packages/ShareClient/*'
}

# No app build may turn on a TandemKit package trait. BenchWrites adds two signed writes for TandemKit's
# bench only; the check covers the manifests, SwiftPM's resolved graph and TandemKit's default traits, and
# first proves each check fails on a package that enables the trait.
gate_traits() { python3 scripts/check-tandemkit-traits.py; }
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
#
# The build log must also have no compiler warning at all. Warnings as errors isn't enough on its own:
# Swift leaves a diagnostic that `@preconcurrency` downgraded a warning under -warnings-as-errors and
# -Werror alike (a nonisolated test calling a SwiftUI view's static method, whose main-actor isolation
# comes from the View conformance). Only diagnostics count, with a location or the compiler's or linker's
# prefix, not a test's runtime log. CI builds from clean, so every file's warnings are in its log.
gate_app() {
  local log status=0 warnings
  log="$(mktemp)"
  ./scripts/test-ios.sh -quiet 2>&1 | tee "$log" || status=$?
  # awk, not grep: it exits 0 with no match, so any failure to read the log fails the gate.
  warnings="$(awk '/^([^ ].*:[0-9]+:[0-9]+: |macro expansion .*: |ld: |<unknown>:0: )?warning: /' "$log")" || status=$?
  rm -f "$log"
  [ "$status" -eq 0 ] || return "$status"
  if [ -n "$warnings" ]; then
    printf 'app gate: the build has warnings:\n%s\n' "$warnings" >&2
    return 1
  fi
}
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
[ "${#gates[@]}" -gt 0 ] || gates=(traits build test app format swiftlint shell actions markdown contract)
for g in "${gates[@]}"; do
  echo "== $g"
  "gate_$g"
done
echo "all gates passed: ${gates[*]}"
