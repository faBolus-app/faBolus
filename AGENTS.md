# AGENTS.md — faBolus

Working notes for agents and humans. Experimental, not-FDA-cleared remote-bolus + status app for
Tandem t:slim X2 (this build declines to pair a Mobi). Companion map: [`llms.txt`](llms.txt).
Branch model, experimental gate, and versioning: [`BRANCHES.md`](BRANCHES.md) — read it; do not
restate it here.

## Safety — do not violate
- Insulin path: **UI confirm/hold → backend clamp** (`Interlocks.absoluteMaxUnits` = 25 U, min 0.05 U)
  **→ TandemKit `WritePolicy`** (default `.readOnly`; risk-tiered, not a boolean) **→ signed message**
  flagged `modifiesInsulinDelivery`, byte-verified against the TandemKit oracle. Never add a delivery
  path that bypasses a layer.
- Action gating is **`AccessPolicy`** in `faBolusCore`, reached from `AppModel.allow(_:from:peerId:)` /
  `accessDecision`. Add gates there, not in views.
- Stale glucose (> ~6 min, `GlucoseFreshness`) is shown marked, never as current, never auto-fills a
  correction.
- Don't invent pump behavior. Unverified fields go in `docs/UNVERIFIED-GUESSES.md`.

## Commands
- **Core unit tests:** `swift test --package-path Packages/faBolusCore`
- **Simulator (iOS app + widgets):** `./scripts/build-sim.sh`
- **Device build:** set `DEVELOPMENT_TEAM` in `LocalConfig.xcconfig`, then `./scripts/generate-project.sh` →
  `xcodebuild -scheme faBolus -destination 'id=<UDID>' -allowProvisioningUpdates -derivedDataPath build/DDdevice build` →
  `xcrun devicectl device install app --device <UDID> build/DDdevice/Build/Products/Debug-iphoneos/faBolus.app`
- **Schema drift** (after touching `RemoteCommand`): `./scripts/check-schema-drift.sh`
- Run `./scripts/generate-project.sh` — **not** bare `xcodegen generate` — after editing
  `project.yml`. `project.yml` is a template: the script derives the real spec by picking the
  pinned-vs-local `TandemKit` block and dropping retired compile flags. Bare `xcodegen` keeps both
  `TandemKit` blocks, silently resolves to the unpinned sibling checkout, and fails to compile.
  New files under globbed dirs (`ios/faBolus`, `Shared`) are picked up automatically.

There is **no Watch app on `main`**. Do not build `faBolusWatch` or assume a `watch/` tree.

## How to add X
- **A user setting:** `AppSettings.swift` (UserDefaults `var` + `didSet`, defaulted/sanitized in
  `init`) → a settings screen in `SettingsView.swift` → a `SettingsIndex` entry for search.
- **A pump action:** add to `PumpBackend` (default-throwing extension) → implement in `TandemBackend`
  **and** `MockBackend` → expose through `AppModel` → gate it via `AccessPolicy` if it changes insulin.
- **A remote command:** extend `RemoteCommand` + `schema/command.schema.json` (drift check) → handle in
  the remote-host receivers. Phone/Mac-only kinds (auth/sealed/approval) stay out of the shared
  schema/Garmin mirror.
- **A CGM source:** implement `GlucoseSource`, add a `GlucoseSourceDescriptor` to
  `GlucoseSourceRegistry.enabled`.
- **A permission:** `ChildFeature` (local) or `RemotePermission` (peers); enforce via `AccessPolicy`.

## Conventions
- Swift 6 / strict concurrency: most UI + model types are `@MainActor`; CoreBluetooth/AVFoundation
  callbacks that aren't must be `nonisolated` and hop back with `Task { @MainActor in … }`.
- Match surrounding style. Comments explain **why** (safety, hardware, fail-closed). Do not add
  phase/ticket IDs, “moved from X” notes, or file-header novels.
- Sibling repos: `../TandemKit` (pump protocol — change message bytes there, with an oracle test) and
  `../faBolusGarmin`. Keep the `RemoteCommand` schema in sync.

## Git
Follow the user's branching. Don't push or commit unless asked.

## Gotchas
- One CoreBluetooth restore-id per central per process (a second restorable central SIGABRTs). The
  pump owns `com.fabolus.app.pump`; any other BLE central must use a different id.
- `AppModel.addRemoteEcho` / `addStatusListener` are append-only — don't re-register.
- Chained remotes are deferred; see `ROADMAP.md`.
- TandemKit is consumed by `url:` + `revision:` in `project.yml` (`FABOLUS_TANDEM_LOCAL=1` for a
  sibling checkout). Read the pin from `project.yml`, not from this file.
