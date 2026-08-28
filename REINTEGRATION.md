# REINTEGRATION.md — dev/garmin-hr-relay (faBolus repo, phone half)

## Feature preserved

The phone-side half of the Garmin-to-phone ambient-HR relay (Phase 09.18b originally; removed here as
NARROW-HR-22). By exact symbol:

- `ios/faBolus/Data/AppModel.swift`: the relay members `onWantHeartRate` (`((Bool) -> Void)?` closure set
  by the Garmin bridge), `lastWantHR` (de-dupe cache), `latestGarminHeartRate` (`(bpm: Double, date: Date)?`
  — the observed display-only cache), `setWantHeartRate(_:)` (de-duped setter), `reconcileHeartRateWanted()`
  (reconciles the watch HR-send state to the in-app toggle), and `ingestGarminHeartRate(bpm:at:)` (stores
  the latest out-of-band sample) — plus the `refreshEffectsCoordinator.onReconcileHeartRateWanted = { [weak
  self] in self?.reconcileHeartRateWanted() }` coordinator-wiring line.
- `ios/faBolus/Data/Remote/GarminRemoteBridge.swift`: the `hr_window` ingest branch (parses the
  out-of-band envelope and calls `AppModel.ingestGarminHeartRate`, returning BEFORE
  `RemoteCommand.fromValidated` — never entered the signed schema), the `onWantHeartRate` control-push
  closure (`sendRaw(["v": 1, "type": "hr_ctl", "on": on])`), and the `newestHeartRate(in:)` static parse
  helper (fail-safe bpm/date extraction from the untrusted BLE-delivered dict).
- `ios/faBolus/Data/Settings/AppSettings.swift`: `heartRateContextEnabled` (decl + `_heartRateContextEnabled
  Stored<Bool>` property wrapper + store injection + init-restore) — the device-local toggle that gated the
  watch HR-send state, default `true`.
- `ios/faBolus/Data/App/RefreshEffectsCoordinator.swift`: the `onReconcileHeartRateWanted: () -> Void = {}`
  sink declaration and its ordered call + `recordStep("reconcileHeartRateWanted")` pair inside the
  cross-surface fan-out section of the coordinator's ordered spine.
- `ios/faBolusAppTests/AppSettingsStoredMigrationTests.swift`: `heartRateContextEnabledStoredRoundTrip`
  (the migration round-trip test for the deleted setting).
- `ios/faBolusAppTests/RefreshOrderingCharacterizationTests.swift`: the `"reconcileHeartRateWanted"` entry
  in the ordered `spine` array (this branch's copy still expects it between `"updateEatingNudge"` and
  `"evaluateSavePinOffer"`).

This is the CONSUMER/CONTROLLER half of the relay. The producer half (the Garmin watch reading ambient HR
and radioing the `hr_window` envelope / accepting the `hr_ctl` toggle) is preserved separately on the
faBolusGarmin repo's own `dev/garmin-hr-relay` branch (cut at faBolusGarmin `main`'s pre-removal HEAD
`bba3c4b`, see that repo's `REINTEGRATION.md`) — the two branches, one per repo, together restore the full
signal path.

## State at removal

This branch was cut from faBolus `main`'s pre-removal HEAD `38c576d` — the pristine tip immediately before
this phase's (Phase 22, NARROW-HR-22) phone-side removal commits landed. `main` has since (or will, in the
commits immediately following this branch cut):

1. Deleted the `onReconcileHeartRateWanted` sink declaration and its call + `recordStep(...)` pair from
   `RefreshEffectsCoordinator.swift`, retargeting `RefreshOrderingCharacterizationTests.swift`'s `spine`
   array to drop the `"reconcileHeartRateWanted"` entry (D-03a) — the spine now runs `...updateEatingNudge`
   → `evaluateSavePinOffer` → `maybeAutoSyncPumpTime...` contiguously. This branch's copies of both test
   and coordinator files still have the entry/step.
2. Deleted the six `AppModel.swift` relay members (`onWantHeartRate`, `lastWantHR`, `latestGarminHeartRate`,
   `setWantHeartRate(_:)`, `reconcileHeartRateWanted()`, `ingestGarminHeartRate(bpm:at:)`) and the
   coordinator wiring line that bound `reconcileHeartRateWanted()` to the sink. This branch's copy has all
   six plus the wiring line.
3. Deleted the `hr_window` ingest branch, the `onWantHeartRate` control-push closure, and the
   `newestHeartRate(in:)` helper from `GarminRemoteBridge.swift`, leaving the surviving `imu_window` branch
   and `eating_sense`/`onWantAccelSensing` push untouched. This branch's copy has all three.
4. Deleted `heartRateContextEnabled` OUTRIGHT (decl + store injection + init-restore) from
   `AppSettings.swift` per owner decision D-02 — it was already UI-less (no settings row) and not in
   `backupSnapshot`, matching the `dev/graph-detail` `graphDetailEnabled` delete-outright precedent (NOT
   the freeze-as-inert-hidden-flag pattern, which is reserved for flags that still gate live behavior).
   This branch's copy still has the property. A doc-comment at `AppSettings.swift:582` that used
   `heartRateContextEnabled` as a same-idiom example alongside `eatingNudgesEnabled` was reworded on
   `main` to drop the now-dangling name; this branch's copy still has the original wording.
5. Retired (deleted outright, not retargeted) `AppSettingsStoredMigrationTests.swift`'s
   `heartRateContextEnabledStoredRoundTrip` — the setting itself is gone, so there is nothing left to
   round-trip. This branch's copy still has the test. The ADJACENT
   `healthKitImportHeartRateEnabledStoredRoundTrip` test was left completely untouched on `main` (D-07 — a
   separate feature; see below).
6. Reworded a doc-comment in `AppModel+EatingNudge.swift` that named `setWantHeartRate` (now removed) so no
   dangling symbol reference remains in prose; this branch's copy still names the symbol.
7. Left `HeartRateSchemaAbsenceGuardTests.swift` COMPLETELY untouched on `main` (D-04) — it asserts HR is
   ABSENT from the signed schema and stays green throughout this removal (it already excludes
   `GarminRemoteBridge.swift` from its scan, and legitimately keeps `hr_window`/`heartrate` in its own
   banned-token list). This branch has the same file, also untouched.
8. Left the SEPARATE HealthKit HR path — `healthKitImportHeartRateEnabled`, `AppModel+HealthKit.swift`'s
   `ingestHeartRate`, and `HistoryStore`'s `StoredHeartRate` — COMPLETELY byte-unchanged on `main` (D-07).
   This branch's copy is identical to `main`'s in this respect; reintegration must not disturb it either.
9. No signed-wire, `RemoteCommand.swift`, `schema/command.schema.json`, or `schemaVersion` change anywhere
   in this removal (D-04) — the relay was always strictly out-of-band, returning before
   `RemoteCommand.fromValidated`. No JDK-21 oracle re-proof was required or performed.

## Reintegration path

1. Re-add the six `AppModel.swift` relay members (`onWantHeartRate`, `lastWantHR`, `latestGarminHeartRate`,
   `setWantHeartRate(_:)`, `reconcileHeartRateWanted()`, `ingestGarminHeartRate(bpm:at:)`) from this
   branch's copy, plus the `refreshEffectsCoordinator.onReconcileHeartRateWanted = { [weak self] in
   self?.reconcileHeartRateWanted() }` wiring line — a hand merge against the target tree if `main` has
   moved since this cut, not a blind overwrite.
2. Re-add the `onReconcileHeartRateWanted: () -> Void = {}` sink declaration and its ordered call +
   `recordStep("reconcileHeartRateWanted")` pair into `RefreshEffectsCoordinator.swift`, restoring it to
   its original position between the `onUpdateEatingNudge`/`updateEatingNudge` step and the
   `onEvaluateSavePinOffer`/`evaluateSavePinOffer` step.
3. Restore the `"reconcileHeartRateWanted"` entry in `RefreshOrderingCharacterizationTests.swift`'s `spine`
   array, between `"updateEatingNudge"` and `"evaluateSavePinOffer"`.
4. Re-add `heartRateContextEnabled` (decl + `_heartRateContextEnabled` Stored property + store injection +
   init-restore) to `AppSettings.swift`, restoring the original `heartRateContextEnabled`/
   `eatingNudgesEnabled` doc-comment example wording at the reworded site if desired (cosmetic only, safe
   to leave either way).
5. Re-add the `hr_window` ingest branch, the `onWantHeartRate` control-push closure, and the
   `newestHeartRate(in:)` helper to `GarminRemoteBridge.swift`, restoring the guard order so the branch
   still returns strictly BEFORE `RemoteCommand.fromValidated` (D-04 — this must never change on
   reintegration either; the relay stays out-of-band).
6. Re-add `heartRateContextEnabledStoredRoundTrip` to `AppSettingsStoredMigrationTests.swift`.
7. Revert the `AppModel+EatingNudge.swift` doc-comment rewording if desired (cosmetic only).
8. Do NOT touch `HeartRateSchemaAbsenceGuardTests.swift`'s banned-token list on reintegration — a
   `hr_window`-typed dict must again be intercepted by the ingest branch BEFORE reaching
   `RemoteCommand.fromValidated`, so the guard's existing assertions should still hold; re-run it as part
   of the exit gate to confirm.
9. Do NOT touch the HealthKit HR path (`healthKitImportHeartRateEnabled` / `ingestHeartRate` /
   `StoredHeartRate`) — it was never part of this removal and needs no reintegration step.
10. Reintegrate the faBolusGarmin repo's own `dev/garmin-hr-relay` branch (the watch-side producer half) in
    the SAME reintegration effort — restoring only this phone half without the watch half leaves a
    `heartRateContextEnabled` toggle and `onWantHeartRate`/`hr_ctl` push with no watch listener on the
    other end (harmless but inert; the two halves are meant to land together).
11. Run the full exit gate (`FABOLUS_GARMIN=0 ./scripts/test-ios.sh` full suite,
    `HeartRateSchemaAbsenceGuardTests`, `RefreshOrderingCharacterizationTests`) to confirm the re-added
    surface compiles and nothing else regressed.

## D-06a dependency note — reintegrate this branch BEFORE dev/graph-detail

**`dev/graph-detail` (the faBolus repo's HR DISPLAY half — the GraphDetailView scrubbable-readout overlay,
Phase 09.18b/FEAT-02) depends on THIS branch's preserved surface.** `dev/graph-detail`'s own
`REINTEGRATION.md` (`## Feature preserved`) names `heartRateContextEnabled` (the SETTING, distinct from the
`GraphDetailView` view PARAM of the same name) and `latestGarminHeartRate` as symbols its `GraphDetailView`
call sites and `GlucoseChartView` view params assume EXIST on the target tree before it can be reintegrated
— both are deleted by THIS phase (Phase 22, NARROW-HR-22) and only restored by reintegrating THIS branch.

**Therefore: reintegrate `dev/garmin-hr-relay` (this branch, the relay + setting + ingest half) FIRST, then
`dev/graph-detail` (the display half) SECOND.** Reintegrating `dev/graph-detail` alone, without first
restoring `heartRateContextEnabled`/`latestGarminHeartRate` from this branch, will not compile — the
`GraphDetailView`/`GlucoseChartView` call sites `dev/graph-detail` restores reference both symbols directly.

This branch does not touch faBolus's dose/signed core (`RemoteCommand.swift`, `schema/command.schema.json`,
`Packages/faBolusCore`) — the relay was always strictly out-of-band — so no dose-set stub/frozen-wire-field
un-stub is applicable to this reintegration.
