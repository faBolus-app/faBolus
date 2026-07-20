# Contributing to faBolus

faBolus is designed so new pumps and new host apps are added **in-tree, behind stable interfaces**
— not by forking. Read `ARCHITECTURE.md` first for the two seams. All contributions are
**bench/experimental only** (saline into a container on a scale, never on a body).

## Ground rules
- Keep the app pump- and host-agnostic: no `import` of a specific pump library outside its backend
  module.
- Never weaken a safety interlock (confirmation + max-bolus clamp). Dosing changes get extra review.
- Everything outgoing to a pump must stay byte-validated against the pumpX2 oracle (for the Tandem
  backend) or the equivalent for your backend.

## Add a pump backend (support a new pump)
1. **Copy `ios/faBolus/Data/MockPumpDataSource.swift`** as a template — it's a full `PumpBackend`.
2. Implement `PumpBackend`: `snapshot`, `glucoseHistory`, `iobHistory`, `bolusMarkers`,
   `activeNotifications` (map your pump's alerts → neutral `PumpAlert`), `connect/disconnect`,
   `recommendBolus`, `deliverBolus` (return actual delivered units), `cancelBolus`,
   `dismissNotification`, pairing, and `onChange`.
3. Declare **`PumpCapabilities`** honestly — the UI hides features you don't support.
4. Put your pump's protocol/BLE engine in its **own package** and depend on it from your backend
   module only (like `TandemBackend` → PumpX2Kit).
5. Register it: append one `BackendDescriptor` to `BackendRegistry.enabled`
   (`ios/faBolus/Data/BackendRegistry.swift`). That's the whole wiring — the Settings picker and the
   app pick it up automatically.
6. Add tests that validate your outgoing messages against your pump's reference/oracle.

## Host the remotes from another app (e.g. Loop)
The Apple Watch / Garmin remotes speak the JSON contract in `schema/command.schema.json`. To let
your app drive them:
1. Implement the **host** side of the contract: receive `RemoteCommand`s (statusRead, bolusRequest
   with units *or* carbs, cancelBolus, dismissAlert) and emit the status payload. Use faBolus's
   `PhoneRemoteHost` (Apple Watch, over `RemoteLink`) and `GarminRemoteBridge` (Connect IQ) as the
   reference implementations.
2. Map the contract to your app's APIs (for Loop: LoopKit stores for status; Loop's dosing +
   authorization for boluses, **keeping Loop's own confirmation**). A starting sketch lives in
   `hosts/loop/`.
3. **Enforce the interlocks** (confirm + max clamp) in your host — the spec requires it.
4. For Garmin: register for the faBolusGarmin Connect IQ app UUID (see faBolusGarmin) — the wire
   payload is identical, so the watch app needs no changes.

## Contract changes
`schema/command.schema.json` is the source of truth (versioned via `version`). If you change it,
update **both** the Swift `RemoteCommand` and the Monkey C mirror, and bump the version. Prefer
additive, optional fields so older remotes keep working.

## Before you open a PR
- `xcodegen generate` after adding/removing files.
- Build the `faBolus` scheme (and `faBolusWatch` if you touched watch/shared code).
- Run the package tests (PumpX2Kit: `scripts/test.sh`).
- Note anything bench-tested vs. only compiled.
