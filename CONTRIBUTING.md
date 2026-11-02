# Contributing to faBolus

Contributions are welcome by pull request. Until the rebuild merges, target `rebuild`; after that,
`main` (see [BRANCHES.md](BRANCHES.md)). Read [ARCHITECTURE.md](ARCHITECTURE.md) first.

faBolus is experimental, in-development software — not a medical device and not FDA-cleared, for
experimental and demonstration use.

## Setup

- Xcode 27.2 (CI uses the same).
- `brew install xcodegen swiftlint shellcheck actionlint` and `npm install --global markdownlint-cli2@0.24.0`.
  CI checks XcodeGen 2.46.0.
- `cp LocalConfig.xcconfig.example LocalConfig.xcconfig` and `./scripts/generate-project.sh` for the app
  target (the [build guide](docs/build/build-app.md) has the details). The packages need neither.
- For the Garmin adapter, Garmin's iOS companion SDK 1.8.0 at
  `../../vendor/connectiq-companion-app-sdk-ios-1.8.0`.

## The gates

`./scripts/check.sh` runs every gate, and CI runs the same script, one gate per step. Name gates to run
only those (`./scripts/check.sh build test`).

| Gate | What fails it |
| --- | --- |
| `build` | A compiler warning in any package (Swift 6 language mode, warnings as errors). |
| `test` | A failing package test. |
| `app` | The app or widgets failing to build for the simulator, or an app test failing, the light and dark snapshot of every screen among them. It runs on an "iPhone 17" simulator with iOS 27.2: another device or OS renders differently. |
| `format` | `xcrun swift-format lint --strict`. `./scripts/format.sh` fixes it. |
| `swiftlint` | A rule in `.swiftlint.yml`. |
| `shell`, `actions`, `markdown` | ShellCheck, actionlint, markdownlint. |
| `contract` | A version 2 golden fixture that doesn't match the schema, a broken message the schema accepts, a poll fixture whose `appVersion` isn't `MARKETING_VERSION`, or a provenance row (`docs/SBOM.md`) that doesn't match its file. |

Nothing is grandfathered. A suppression is written inline, names the rule and gives a reason. Semgrep
(`.semgrep/deslop.yml`), Periphery and CodeQL report but don't fail.

The Connect IQ adapter (`Packages/WatchLink/Sources/GarminTransport`) compiles only against Garmin's SDK,
which isn't in the repository, so CI builds the app with Garmin off and no gate covers the adapter. After changing it or the link it drives, run
`CIQ_IOS_SDK=<path to the SDK> ./scripts/check-garmin-transport.sh`.

## Tests

Tests check behavior, never source text. A ported test keeps its expectations unless its commit names
the change. A new test for a fix should fail without the fix.

## Copy before writing

Existing MIT code beats new code: the earlier app (on the `v1-final` tag and the `archive/*` tags),
pumpX2 and LoopKit. Record a copied third-party file in `THIRD_PARTY.md` and `docs/SBOM.md`, keeping its
license header. controlX2 has no license: read it for structure, copy nothing.

## Pump behavior

Message bytes live in TandemKit: change them there, with an oracle test. Don't invent pump behavior. A
field or behavior that isn't confirmed on hardware goes in
[`docs/UNVERIFIED-GUESSES.md`](docs/UNVERIFIED-GUESSES.md).

## Changing the phone↔remote contract

The contract is `Packages/RemoteProtocol`: its Swift types, and the files in `contract/` the watch is
built against.

1. Change the types, then rewrite the golden fixtures:
   `UPDATE_CONTRACT=1 swift test --package-path Packages/RemoteProtocol`. Update `schema.json` and the
   field reference in `contract/README.md` to match, and run `./scripts/check.sh contract test`.
2. Commit and push it.
3. In faBolusGarmin, run `./scripts/sync-contract.sh <that commit>`, update the Monkey C, and run its
   gates.

A change an older remote can't read is a new protocol version. Prefer an optional field an older remote
can ignore.

## Building against a local TandemKit

`Packages/PumpSession` and `Packages/PhoneApp` each pin the same TandemKit release, `exact:` its version
(SwiftPM refuses two different pins). To build against a TandemKit checkout that isn't on GitHub yet,
point SwiftPM at it with a mirror, for each package you build; the pins in `Package.swift` stay as they
are, so the checkout needs the release's tag (for commits after it, pin both packages by `revision:`
while you work):

```sh
for p in PumpSession PhoneApp; do
  swift package --package-path "Packages/$p" config set-mirror \
    --original https://github.com/faBolus-app/TandemKit.git --mirror ../TandemKit
done
```

A mirror lives in that package's `.swiftpm/`, which git ignores, and applies when that package is the one
you build or test. `config unset-mirror` removes it. The Xcode project
still resolves TandemKit from GitHub, so the app target sees a TandemKit release only once it's pushed.

## Before you open a pull request

- `./scripts/check.sh` passes.
- Every change is reviewed before it lands.
- Say what was tested on hardware and what only in tests.
