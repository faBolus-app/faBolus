# REINTEGRATION.md — dev/clock-sync

## Feature preserved

The **pump clock-sync write path** (narrow-main gate §3) — the full auto-time-sync feature as
it exists before its retirement removes it from `main`. On `main` the feature is force-pinned
off (`autoSyncPumpTime = false`) AND its `AppModel`/coordinator driver half has already been
removed by the dead-code programme's Phase 33 (position 7); the *capability + action + backend*
half is still present on `main` but double-dead. This branch is the only frozen pointer that
carries **both halves** together, un-pinned and wired.

## Base

Cut from `experimental` — critical here: `experimental` is the ONLY candidate tip that still
contains `AppModel.maybeAutoSyncPumpTime` / `AppModel.syncTimeToNow()` (both were deleted from
`main` by Phase 33). `main` no longer has the driver half, so `main` cannot preserve the full
surface. `experimental` still has it end-to-end.

## Actual symbols preserved (verified present on this branch)

- **Stored flag + pin** — `ios/faBolus/Data/AppSettings.swift`: `autoSyncPumpTime` and the
  force-pin `autoSyncPumpTime = false` in `AppSettings.init` (the §3 pin, ~:1254 on this base).
- **Capability** — `Packages/faBolusCore/.../Models.swift`: `capabilities.supportsTimeSync`
  and its `hasRequiredCapability` denier in `GatedPumpWrite.swift`
  (axis A returns false for `syncTimeToNow` by design; `supportsTimeSync` is its only denier).
- **Signed action** — `Packages/faBolusCore/.../GatedPumpWrite.swift`:
  `case syncTimeToNow` (~:40); `PumpBackend.syncTimeToNow()` and the
  `TandemBackend` / `PumpBackend` / `MockBackend` implementations.
- **Driver half (present ONLY on this base, removed from `main` by Phase 33)** —
  `ios/faBolus/Data/AppModel.swift`: `syncTimeToNow()` wrapper (~:2156, `runControl(.syncTimeToNow)`),
  `maybeAutoSyncPumpTime(force:)` (~:2163) and its call sites (~:919 connect, ~:1820 refresh),
  `timeSyncInFlight`, `lastTimeSyncKey`; the `RefreshEffectsCoordinator` clock-sync step; the
  `NSSystemClockDidChange` observer.
- **UI / diagnostics** — `ios/faBolus/Views/SettingsView.swift` (the auto-sync toggle),
  `ios/faBolus/Views/PumpControlView.swift`, `ios/faBolus/Data/CapabilityDiagnostics.swift`.
- **Tests** — `AccessPolicyTests.swift`, `GatedPumpWriteTests.swift`,
  `AppModelBehaviorTests.swift`, and the clock-sync hidden-boundary tests.

## Reintegration steps

1. Restoration must restore BOTH halves together: the capability + `GatedPumpWrite.syncTimeToNow`
   case + backend implementations AND the `AppModel`/`RefreshEffectsCoordinator` driver. The
   `AppModel` driver half must be re-derived against the post-Phase-33 `RefreshEffectsCoordinator`
   spine (the ordered step list moved); do not copy the deleted driver back verbatim.
2. `GatedPumpWrite` / `PumpBackend` are dose/signed-core paths — hold byte-identity discipline.
3. Removing the capability while the action still exists leaves the action ungated; restoring
   must keep them coherent (action + denier together). Un-pin `autoSyncPumpTime`.
4. Re-confirm TandemKit oracle byte-parity + `faBolusCore` + app tests green with the sync path
   reachable.
