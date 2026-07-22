# AGENTS.md — faBolus

Working notes for AI coding agents (and humans). Companion to [`llms.txt`](llms.txt) (the map) — this
is the **workflow + rules**. faBolus is an experimental, not-FDA-cleared remote-bolus + status app for
Tandem t:slim X2 / Mobi. Read the file-header doc-comment of anything you touch first.

## Safety invariants — do not violate
- Insulin path is layered: **UI confirm/hold → backend clamp** (`Interlocks.absoluteMaxUnits` = 25 U,
  min 0.05 U) **→ `WritePolicy` interlock** (`.readOnly` default) **→ signed message** flagged
  `modifiesInsulinDelivery`, byte-verified against the PumpX2Kit oracle. Never add a delivery path that
  bypasses any layer.
- All action gating happens in **`AppModel`** (`childBlocked` for child mode; `PeerRemoteHost`/
  `RemotePermission` for remote peers). Add gates there, not scattered in views.
- Stale glucose (> ~6 min, `GlucoseFreshness`) is shown marked, never as current, never auto-fills a
  correction.
- Don't invent pump behavior. If a field/bit is unverified on-device, note it in
  `docs/UNVERIFIED-GUESSES.md` rather than guessing.

## Commands
- **Core unit tests:** `swift test --package-path Packages/faBolusCore`
- **Simulator build (iOS app + watch + widgets):** `./scripts/build-sim.sh`
- **macOS remote build:** `xcodebuild -project faBolus.xcodeproj -scheme faBolusMac -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build`
- **Device build + install:** set `DEVELOPMENT_TEAM` in `LocalConfig.xcconfig`, then
  `xcodegen generate` → `xcodebuild -scheme faBolus -destination 'id=<UDID>' -allowProvisioningUpdates -derivedDataPath build/DDdevice build` → `xcrun devicectl device install app --device <UDID> build/DDdevice/Build/Products/Debug-iphoneos/faBolus.app`
- **Schema drift (after touching `RemoteCommand`):** `./scripts/check-schema-drift.sh`
- **Always run `xcodegen generate` after editing `project.yml`.** New files under globbed dirs
  (`ios/faBolus`, `Shared`, `mac/faBolusMac`) are picked up automatically.

## How to add X
- **A user setting:** `AppSettings.swift` (UserDefaults `var` + `didSet`, defaulted/sanitized in
  `init`) → a `*SettingsView` in `SettingsView.swift` → a `SettingsIndex` entry for search.
- **A pump action:** add to `PumpBackend` (default-throwing extension) → implement in `TandemBackend`
  **and** `MockBackend` → expose through `AppModel` → gate it if it changes insulin.
- **A remote command:** extend `RemoteCommand` + `schema/command.schema.json` (drift check) → handle in
  the `*RemoteHost` receivers and `RemoteClientModel`. Phone/Mac-only kinds (auth/sealed/approval) are
  intentionally kept OUT of the shared schema/Garmin mirror.
- **A CGM source:** implement `GlucoseSource`, add a `GlucoseSourceDescriptor` to
  `GlucoseSourceRegistry.enabled`.
- **A permission:** `ChildFeature` (local) or `RemotePermission` (peers); enforce via `AppModel`.

## Conventions
- Swift 6 / strict concurrency: most UI + model types are `@MainActor`; delegate callbacks that aren't
  (e.g. CoreBluetooth/AVFoundation) must be `nonisolated` and hop back with `Task { @MainActor in … }`.
- Every file opens with a doc-comment stating its role; use `[[Type]]` to cross-link. Keep this current.
- Match surrounding style; prefer reusing value-driven views over new ones (remotes reuse host views).

## Git / workflow
- Follow the user's branching (feature branches; merge to `main` when asked). Don't push or commit
  unless asked. End commit messages with the required `Co-Authored-By` trailer.
- Sibling repos: `../PumpX2Kit` (pump protocol — change message bytes there, with an oracle test) and
  `../faBolusGarmin` (Garmin remote). Keep the `RemoteCommand` schema in sync across them.

## Gotchas
- One CoreBluetooth restore-id per central per process (a 2nd restorable central SIGABRTs — see
  `DexcomG6BLESource`). The pump owns `com.fabolus.app.pump`; the BLE peer peripheral is separate.
- `AppModel.addRemoteEcho`/`addStatusListener` are append-only (not removable) — don't re-register.
- Chained remotes (parent's own watch/Mac via relay) are deferred; see `ROADMAP.md` for blockers.
