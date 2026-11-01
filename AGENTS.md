# AGENTS.md — faBolus

Working notes for agents and humans. Experimental, not-FDA-cleared remote-bolus and status app for the
Tandem t:slim X2. Companion map: [`llms.txt`](llms.txt).

This is the `rebuild` branch. The app is being rebuilt in slices; `main` keeps today's app until all
three repos (faBolus, TandemKit, faBolusGarmin) merge together. The maintainers' rebuild plan says which
slice owns which piece.

## Layout on `rebuild`

- `Packages/` holds everything that compiles: `faBolusCore`, `faBolusDesign`, `HistoryStore`, the
  vendored `ShareClient`, the CGM sources (`DexcomBLE`, `GlucoseSources`), `PumpSession`, the one owner
  of the pump (it depends on `../TandemKit` by pinned revision; `CONTRIBUTING.md` says how to build against
  a local checkout), `Alerts`, the phone's alert pipeline, `RemoteProtocol`, the phone↔remote protocol
  (version 2) with its contract files in `contract/`, and `WatchLink`, the phone's link to the watch, the
  host that answers it and the Connect IQ adapter (`scripts/check-garmin-transport.sh` compiles the adapter
  against Garmin's iOS SDK, which isn't in the repository). New packages land here as slices add them.
- `legacy/` is the old phone app (`legacy/ios`, `legacy/Shared`, its `project.yml` and build scripts).
  It is not compiled, linted or tested. Copy from it; don't edit it. It is deleted at the end of the
  rebuild. There is no app target until the phone-app slice brings it back.

## Safety — do not violate

- Every dose goes through one composer, the access policy, TandemKit's `WritePolicy` and a signed
  message byte-verified against the TandemKit oracle. Never add a delivery path that skips a layer.
- The pump's own limits govern; the app adds no limit of its own beyond the optional remote size limit.
- An unknown bolus outcome blocks new boluses, across restarts, until pump history settles it or the
  user confirms on the pump.
- Stale glucose is shown marked, never as current, and never auto-fills a correction. Staleness comes
  from the measurement time, not the time a value was received.
- Don't invent pump behavior. Unverified fields go in `docs/UNVERIFIED-GUESSES.md`.

## Quality gates

- `./scripts/check.sh` runs every gate; CI runs the same script, one gate per step, on Xcode 27.2.
  Each gate fails the build: compiler warnings (Swift 6 language mode), the package tests,
  `xcrun swift-format lint --strict`, SwiftLint, ShellCheck, actionlint, markdownlint, and the v1
  contract and SBOM checks. Nothing is grandfathered. A suppression is written inline, names the rule
  and gives a reason.
- `./scripts/format.sh` formats in place. `.swift-format` turns off every rule except
  `DoNotUseSemicolons`, so it reflows layout but never rewrites code. The vendored `ShareClient` is
  never restyled.
- `.swiftlint.yml` is a short list of correctness rules. Never rename a wire field, settings key or
  `RemoteCommand` case to satisfy a linter.
- Report only: Semgrep (`.semgrep/deslop.yml`, residue such as ticket IDs and drifted line
  references), Periphery and CodeQL.
- Every change is reviewed with `/code-review` before it lands on `rebuild`.

## Reviewing

<!-- Only facts a reviewer can't get from the diff. How to review is the review tool's job; don't restate it here. -->

Facts a reviewer needs that the diff doesn't show:

- The Safety section above names what matters most here.
- Out of scope: `legacy/`, the vendored `ShareClient` apart from the diff's own edits to it (each is
  listed in its `docs/SBOM.md` row), and anything a `check.sh` gate already fails on.
- `legacy/` is what today's app does, and most new code ports or replaces a file from it. A ported test
  keeps its expectations unless its commit names the change. Tests check behavior, never source text: the
  source-text tests in `legacy/` broke when code was reformatted, and they aren't ported.
- Pump behavior is checked against pumpx2, vendored as TandemKit's `vendor/pumpx2-oracle`. controlX2 has
  no license: it is read for structure, and nothing is copied from it.
- Some types carry cases for features not built yet (Mobi, extended boluses, alarm escalation). They are
  deliberate room, not dead code.
- `check-schema-drift.sh` checks field names and hand-written sample payloads, not messages the code
  produces, so a change to a `RemoteCommand` field's type or meaning can pass it and still break the watch.
- Most past bugs were in the phone↔pump and phone↔watch links: state kept outside a state machine, retry
  and reconnect loops, stuck states after a drop, suspension and relaunch, and messages lost, duplicated
  or reordered.

## Conventions

- Swift 6, strict concurrency. No core protocol is `@MainActor`. CoreBluetooth callbacks are
  `nonisolated` and hop to their owner explicitly.
- Copy before writing: existing MIT code (`legacy/`, pumpx2, LoopKit) beats new code. Record copied
  third-party files in `THIRD_PARTY.md` and `docs/SBOM.md`.
- Comments explain why (safety, hardware, fail-closed). No phase or ticket IDs, "moved from X" notes,
  or file-header novels.
- Sibling repos: `../TandemKit` (pump protocol: change message bytes there, with an oracle test) and
  `../faBolusGarmin`. Until protocol v2 lands, keep the v1 `RemoteCommand` schema in sync
  (`scripts/check-schema-drift.sh`).

## Git

Follow the user's branching. Don't push or commit unless asked.

## Gotchas

- One CoreBluetooth restore ID per central per process (a second restorable central crashes). The
  pump owns `com.fabolus.app.pump`; any other central uses its own ID.
- The bundle ID stays the old app's (`APP_BUNDLE_ID`, `com.fabolus.app` unless a self-builder sets
  their own in `LocalConfig.xcconfig`): the App Group and the Connect IQ companion link derive from it.
