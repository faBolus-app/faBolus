# REINTEGRATION.md — dev/healthkit

## Feature preserved

The WHOLE Apple HealthKit surface (Phase 5, HEALTH-01): the `healthkit` CGM source
(`Shared/HealthKitGlucoseSource.swift`), the 09.18b on-demand HR reader
(`Shared/HealthKitHeartRateSource.swift`), the 09.23 retrospective carbs/insulin/glucose import
(`Shared/HealthKitHistoryImporter.swift`) and bolus/carbs/insulin/glucose export
(`Shared/HealthKitExporter.swift`), plus the shared origin-tagging helper
(`Shared/HealthKitOriginTag.swift`) — together with the `FABOLUS_HEALTHKIT` compile flag, the
`com.apple.developer.healthkit`/`.access` entitlement, and both `NSHealthUpdateUsageDescription`/
`NSHealthShareUsageDescription` Info.plist usage strings that gated/described it.

## State at removal

Phase 5, Plan 01 (this branch's cut point) `git rm`'d the removal in two commits:

- **Task 2 (TRACER)**: `git rm`'d all 5 `Shared/HealthKit*.swift` files; deleted the
  `# >>> HEALTHKIT ... # <<< HEALTHKIT` entitlement block and the `NSHealthUpdateUsageDescription`
  tagged usage-string block from `project.yml`, plus the unconditional (untagged)
  `NSHealthShareUsageDescription` prose string (owner flag 1, adopted); removed the
  ` FABOLUS_HEALTHKIT` token from every `SWIFT_ACTIVE_COMPILATION_CONDITIONS` line (the iOS
  Debug/Release target lines and the `faBolusAppTests` target's own copy); deleted the `HEALTHKIT`
  var + its comment block, the `strip_block HEALTHKIT`/`drop_flag FABOLUS_HEALTHKIT` conditional,
  and every `$HEALTHKIT` reference in the summary/status echoes from `scripts/generate-project.sh`
  (mirrors the `$NUDGE` reconciliation Phase 4 did for `FABOLUS_NUDGE`). The watchOS
  `faBolusWatch` target (and its own `WatchModel.swift:15` unconditional
  `HealthKitGlucoseSource()` reference, plus its own `NSHealthShareUsageDescription` string) had
  already been removed from `main` in full by Phase 3 (REMOTE-03) before this phase ran, so that
  half of the originally-planned fix was a no-op — confirmed against the live tree at execution
  time, not assumed from the plan.
- **Task 3**: deleted the `#if FABOLUS_HEALTHKIT` `healthkit` descriptor from
  `ios/faBolus/Data/GlucoseSourceRegistry.swift`; deleted the `#if FABOLUS_HEALTHKIT` HR-context
  state var + query block from `ios/faBolus/Views/GlucoseChartView.swift`; deleted the
  `healthKitConfigSection` and its `#if FABOLUS_HEALTHKIT ids.insert("healthkit") #endif` block from
  `ios/faBolus/Views/CgmCredentialsView.swift`; `git rm`'d the 5 HealthKit-only test files
  (`HealthKitBuildGateGuardTests.swift`, `HealthKitHistoryImporterTests.swift`,
  `HealthKitExporterTests.swift`, `HealthKitTracerTests.swift`,
  `HealthKitImportSettingsTests.swift`). The keep-green boundary proofs
  (`HealthKitImportDosePathGuardTests.swift`, `HeartRateSchemaAbsenceGuardTests.swift`) stayed on
  `main`, now trivially green.

This branch (`dev/healthkit`) was cut from `main`'s pristine pre-deletion tip (before either
commit above landed), so it carries the full pre-removal tree — the 5 `Shared/HealthKit*.swift`
files, the flag/entitlement/usage-string machinery, and the `#if FABOLUS_HEALTHKIT` call sites in
`GlucoseSourceRegistry.swift`/`GlucoseChartView.swift`/`CgmCredentialsView.swift` — exactly as they
stood immediately before Phase 5 Plan 01 began.

## What is NOT on this branch (stays on `main`, never removed)

`ios/faBolus/Data/AppModel.swift`'s `#if FABOLUS_HEALTHKIT` blocks (`:10-27`, `:1441-1605`,
`:1802-1805`) are dose/signed, byte-identity-protected (D-02), and were never touched by this
phase — their source bytes are untouched on `main` today; their condition is simply permanently
false now that the flag is gone. `ios/faBolus/Data/AppSettings.swift`'s unconditional
`healthKit*Enabled` stored properties (import/export toggles) also stay on `main`, unconditionally
present, per D-13's original design ("deliberately NOT a SettingsCatalog row") — they are inert
dead reads/writes once nothing binds to them, but were left out of this phase's edit scope.
Reintegrating this branch's UI does NOT require touching either of these two files; the settings
model plumbing already exists on `main` today.

## Reintegration steps

1. **Restore the `FABOLUS_HEALTHKIT` flag/entitlement machinery** in `project.yml` (the
   `com.apple.developer.healthkit`/`.access` entitlement block, both `NSHealthUpdateUsageDescription`
   / `NSHealthShareUsageDescription` usage strings, and the ` FABOLUS_HEALTHKIT` token on all
   `SWIFT_ACTIVE_COMPILATION_CONDITIONS` lines) and `scripts/generate-project.sh` (the `HEALTHKIT`
   var + comment, the `strip_block HEALTHKIT`/`drop_flag FABOLUS_HEALTHKIT` conditional, and the
   summary/status echo lines) — mirror dev/nudge's "restore the fence" step; see this branch's own
   copies of both files for the pre-removal shape.
2. **Cherry-pick or copy back** the 5 `Shared/HealthKit*.swift` files
   (`HealthKitGlucoseSource.swift`, `HealthKitHeartRateSource.swift`,
   `HealthKitHistoryImporter.swift`, `HealthKitExporter.swift`, `HealthKitOriginTag.swift`) from
   this branch into `main`, then restore the `#if FABOLUS_HEALTHKIT`-guarded call sites in
   `ios/faBolus/Data/GlucoseSourceRegistry.swift` (the `healthkit` descriptor),
   `ios/faBolus/Views/GlucoseChartView.swift` (the HR-context state var + query block), and
   `ios/faBolus/Views/CgmCredentialsView.swift` (`healthKitConfigSection` + the
   `configuredSectionSourceIds` insert) from this branch's copies — re-derive against whatever
   `main` looks like at reintegration time rather than pasting back verbatim, since the
   surrounding source may have moved on.
3. **Restore the 5 HealthKit-only test files** from this branch
   (`HealthKitBuildGateGuardTests.swift`, `HealthKitHistoryImporterTests.swift`,
   `HealthKitExporterTests.swift`, `HealthKitTracerTests.swift`,
   `HealthKitImportSettingsTests.swift`) and re-derive the discretionary dead-`#if` test cleanup in
   `CgmConfigSectionCopyGuardTests.swift`/`CgmConnectionKindTests.swift`/
   `CgmShareOnlyBoundaryTests.swift` if Phase 5 Plan 02 later collapsed those blocks.
4. If the watchOS `faBolusWatch` target has since been restored (it was removed by Phase 3,
   REMOTE-03, before this branch was cut, and is out of this branch's scope), re-check whether it
   still needs its own `WatchModel.swift:15` `directSources` fix and its own
   `NSHealthShareUsageDescription` string — consult `dev/watch-remote`'s REINTEGRATION.md for the
   watch target's own restoration steps; this branch does not carry watch-target state.
5. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`) plus
   `./scripts/check-dose-byte-identity.sh` and a fresh repo-wide grep for `FABOLUS_HEALTHKIT`/
   `HealthKitGlucoseSource`/`HealthKitHeartRateSource` to confirm no other dangling reference was
   missed.

None of the restored files are dose-adjacent — `AppModel.swift`'s `#if FABOLUS_HEALTHKIT` blocks
stay byte-identical throughout (D-02); reintegration never requires a dose-set stub/un-stub for
this branch, unlike `dev/nightscout`'s own REINTEGRATION.md.
