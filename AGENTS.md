# AGENTS.md — faBolus

Working notes for agents and humans. Experimental, not-FDA-cleared remote-bolus and status app for the
Tandem t:slim X2. Companion map: [`llms.txt`](llms.txt). Branches: [`BRANCHES.md`](BRANCHES.md).

## Layout

- `Packages/` holds everything that compiles: `faBolusCore` (domain types, the dose composer, the access
  policy), `PumpSession` (the one owner of the pump; it and `PhoneApp` pin the same TandemKit release,
  and `CONTRIBUTING.md` says how to build against a local checkout), `HistoryStore`, `Alerts` (the phone's
  alert pipeline), the CGM sources (`GlucoseSources`, `DexcomBLE`, the vendored `ShareClient`),
  `RemoteProtocol` (the phone↔remote protocol, version 2, with its contract files in `contract/`),
  `WatchLink` (the link to the watch, the host that answers it, and the Connect IQ adapter), `PhoneApp`
  (the app's model and wiring, and `WidgetContent`) and `faBolusDesign`.
- `ios/` is the app target, the widget extension (widgets and the Live Activity) and the app's snapshot
  tests. The project is generated: `./scripts/generate-project.sh`.
- `scripts/check-garmin-transport.sh` compiles the Connect IQ adapter against Garmin's iOS SDK, which
  isn't in the repository.

## Safety — do not violate

- Every dose goes through one path: `DoseComposer` (which applies `AccessPolicy`), the durable bolus
  ledger, `PumpSession`, then TandemKit's per-call write grant (`PumpConnection.send(_:allowing:)`) and a
  signed message byte-verified against the TandemKit oracle. Never add a delivery path that skips a layer.
- The pump's own limits govern; the app adds no limit of its own beyond the optional remote size limit.
- An unknown bolus outcome blocks new boluses, across restarts, until pump history settles it or the
  user confirms on the pump.
- Stale glucose is shown marked, never as current, and never auto-fills a correction. Staleness comes
  from the measurement time, not the time a value was received.
- Don't invent pump behavior. Unverified fields go in `docs/UNVERIFIED-GUESSES.md`.

## Quality gates

- `./scripts/check.sh` runs every gate; CI runs the same script, one gate per step, on Xcode 27.2.
  Each gate fails the build: compiler warnings (Swift 6 language mode), the package tests, the app
  target's build and snapshot tests, `xcrun swift-format lint --strict`, SwiftLint, ShellCheck,
  actionlint, markdownlint, and the contract and SBOM checks. Nothing is grandfathered. A suppression is
  written inline, names the rule and gives a reason.
- `./scripts/format.sh` formats in place. `.swift-format` turns off every rule except
  `DoNotUseSemicolons`, so it reflows layout but never rewrites code. The vendored `ShareClient` is
  never restyled.
- `.swiftlint.yml` is a short list of correctness rules. Never rename a wire field, settings key or
  message kind to satisfy a linter.
- Report only: Semgrep (`.semgrep/deslop.yml`, residue such as ticket IDs and drifted line
  references), Periphery and CodeQL.
- Every change is reviewed with `/code-review` before it lands.

## Reviewing

Facts a reviewer needs that the diff doesn't show:

- The Safety section above names what matters most here.
- Out of scope: the vendored `ShareClient` apart from the diff's own edits to it (each is listed in its
  `docs/SBOM.md` row), and anything a `check.sh` gate already fails on.
- Most new code ports or replaces a file from the earlier app, on the `v1-final` tag. A ported test keeps
  its expectations unless its commit names the change. Tests check behavior, never source text.
- Pump behavior is checked against pumpx2, vendored as TandemKit's `vendor/pumpx2-oracle`. controlX2 has
  no license: it is read for structure, and nothing is copied from it.
- Some types carry cases for features not built yet (Mobi, extended boluses, alarm escalation). They are
  deliberate room, not dead code.
- The golden fixtures are what the Swift types write. The watch reads them only from its vendored copy,
  so a contract change reaches faBolusGarmin's tests only once its `contract/PIN` is synced to a pushed
  commit that has it.
- Most past bugs were in the phone↔pump and phone↔watch links: state kept outside a state machine, retry
  and reconnect loops, stuck states after a drop, suspension and relaunch, and messages lost, duplicated
  or reordered.

## Conventions

- Swift 6, strict concurrency. No core protocol is `@MainActor`. CoreBluetooth callbacks are
  `nonisolated` and hop to their owner explicitly.
- Copy before writing: existing MIT code (the earlier app, pumpx2, LoopKit) beats new code. Record copied
  third-party files in `THIRD_PARTY.md` and `docs/SBOM.md`.
- Comments explain why (safety, hardware, fail-closed). No phase or ticket IDs, "moved from X" notes,
  or file-header novels.
- Sibling repos: `../TandemKit` (pump protocol: change message bytes there, with an oracle test) and
  `../faBolusGarmin`. A contract change: rewrite the fixtures with
  `UPDATE_CONTRACT=1 swift test --package-path Packages/RemoteProtocol`, push, then run faBolusGarmin's
  `scripts/sync-contract.sh <commit>`, which updates its `contract/` and `contract/PIN`.

## Git

Follow the user's branching. Don't push or commit unless asked.

## Gotchas

- One CoreBluetooth restore ID per central per process (a second restorable central crashes). The
  pump owns `com.fabolus.app.pump`; any other central uses its own ID.
- The bundle ID stays the earlier app's (`APP_BUNDLE_ID`, `com.fabolus.app` unless a self-builder sets
  their own in `LocalConfig.xcconfig`): the App Group and the Connect IQ companion link derive from it.
  The first launch removes everything the earlier app stored (`FirstLaunchWipe`).
- The `app` gate's snapshots are recorded on an "iPhone 17" simulator at iOS 27.2.
