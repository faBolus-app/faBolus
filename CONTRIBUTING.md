# Contributing to faBolus

faBolus is designed so new pumps and new host apps are added **in-tree, behind stable interfaces**
— not by forking. Read `ARCHITECTURE.md` first for the two seams. All contributions are
for **experimental use only** (in development, not FDA-cleared).

**Which branch does your change target?** Read `BRANCHES.md` before opening a PR. In short: `main` is
the CI-green baseline; `experimental` holds anything that fires on a threshold, automates a decision, or
produces output you can't check against the pump (§1.2). Anything touching dosing guidance, thresholds,
or automation copy is behind a **clinical-review gate** and must not reach anyone but the developer
until that review lands. The delivery disposition is **NO-GO for real insulin delivery** — keep it so.

## Ground rules
- Keep the app pump- and host-agnostic: no `import` of a specific pump library outside its backend
  module.
- Never weaken a safety interlock (confirmation + max-bolus clamp). Dosing changes get extra review.
- Everything outgoing to a pump must stay byte-validated against the pumpX2 oracle (for the Tandem
  backend) or the equivalent for your backend.

## Add a pump backend (support a new pump)
1. **Copy `ios/faBolus/Data/MockBackend.swift`** as a template — it's a full `PumpBackend`.
2. Implement `PumpBackend`: `snapshot`, `glucoseHistory`, `iobHistory`, `bolusMarkers`,
   `activeNotifications` (map your pump's alerts → neutral `PumpAlert`), `connect/disconnect`,
   `recommendBolus`, `deliverBolus` (return actual delivered units), `cancelBolus`,
   `dismissNotification`, pairing, and `onChange`.
3. Declare **`PumpCapabilities`** honestly — the UI hides features you don't support.
4. Put your pump's protocol/BLE engine in its **own package** and depend on it from your backend
   module only (like `TandemBackend` → TandemKit).
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

## Versioning & the cross-repo contract (§1.3 / §1.4)
`BRANCHES.md` is the **canonical** governance doc for versioning, the experimental gate (§1.2), the
promotion criteria (§1.4), and the cross-repo contract (§1.3). This section points at it; it does not
restate it.

- **App version** lives once in `Config.xcconfig` (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`) and
  is inherited by every target — do not add per-target version literals in `project.yml`. Bump it on a
  release and add a `CHANGELOG.md` (Keep a Changelog) entry.
- **Backend pin.** The contract is: TandemKit released under annotated tags, apps pinned to an explicit
  version **or a pinned commit `revision:`** (with a documented local-path override for development),
  and a committed `Package.resolved`. This is now **MET**, via a `url:`+`revision:` pinned revision
  (2026-08-13) rather than the exact-version tag originally envisioned. See `BRANCHES.md` §1.3 for the
  full reason, the pinned revision, the tag state, and the compatibility matrix.
- **Garmin lockstep.** A Garmin `main` release accompanies every app `main` release at the same quality
  bar; it does not lag or ship separately. Enforced by the branch-aware cross-repo CI (§1.3).

## Before you open a PR
- `xcodegen generate` after adding/removing files.
- Build the `faBolus` scheme (and `faBolusWatch` if you touched watch/shared code).
- Run the core tests: `swift test --package-path Packages/faBolusCore` (models, remote round-trips,
  and the `PumpBackend` conformance harness — a good template for your own backend's tests).
- If you touched the contract, run `scripts/check-schema-drift.sh` (also enforced in CI) and update
  the Monkey C mirror in faBolusGarmin.
- For pump-protocol work in TandemKit, its own `scripts/test.sh` (oracle parity) must be green.
- Note anything hardware-tested vs. only compiled.

CI (`.github/workflows/ci.yml`) runs the drift check and `faBolusCore` tests on every PR, so these
are the same gates a reviewer sees.
