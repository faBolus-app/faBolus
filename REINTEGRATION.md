# REINTEGRATION.md — dev/live-activity

## Feature preserved

The glucose Live Activity (Phase 7, FEAT-01): the Lock Screen / Dynamic Island / CarPlay ambient
glucose surface — full-bleed zone-colored plot AND classic chip HUD styles, the customizable
field/top-right-slot vocabulary, the axis-chrome + range-line toggles, the optional Bolus shortcut
pill, the Refresh/Snooze/Open-Bolus App Intents, and the app-target lifecycle manager that drives it
from the BLE publish choke point. The whole surface, end to end:

- `ios/faBolusWidgets/GlucoseLiveActivity.swift` — the widget-extension `Widget` conformer (all Lock
  Screen / Dynamic Island / CarPlay presentations).
- `ios/faBolusWidgets/FullBleedGlucosePlot.swift` — the full-bleed zone-colored curve renderer.
- `Shared/LiveActivityShared.swift` — `FaBolusGlucoseAttributes` (the `ActivityAttributes`
  conformer + `ContentState`), `LARegion`, `LAField`, `LAFieldVocabulary`, `LATopRightFieldVocabulary`,
  `LALockScreenLayout`, `FullBleedPlotState`, `LAMetrics`, `LAPlotWindow`, `LiveActivityComposer`.
- `Shared/LiveActivityIntents.swift` — `LiveActivityIntentBridge` + the 3 App Intents
  (`LAOpenBolusIntent`, `LASnoozeAlertIntent`, `LAReconnectIntent`).
- `ios/faBolus/Data/GlucoseLiveActivityManager.swift` — the app-target lifecycle manager
  (`makeContent`, `update(from:)`, `refreshForSelectionChange()`, `gateEnabled`).
- The `WidgetUI` "Phase 5 pump-chip vocabulary" section of `ios/faBolusWidgets/FaBolusWidgetBundle.swift`
  (`PumpChip` struct + `iobChip`/`reservoirChip`/`batteryChip`/`basalChip`/`controlIQChip`/
  `connectionChip`/`deltaChip`/`tirChip`/`chip(for:_:)`) — fed ONLY `GlucoseLiveActivity.swift`, no
  other widget.
- The 11 `WidgetStore.liveActivity*` App-Group mirror properties in `Shared/WidgetShared.swift`
  (`liveActivityFields`, `liveActivityStyle`, `liveActivityPlotFloor`, `liveActivityPlotCeiling`,
  `liveActivityTopRightField`, `liveActivityPlotRangeHours`, `liveActivityShowXAxisLine`,
  `liveActivityShowYAxisLine`, `liveActivityShowXAxisTicks`, `liveActivityShowYAxisTicks`,
  `liveActivityShowRangeLines`, `liveActivityShowBolusShortcut`).
- The 11 `AppSettings.swift` `liveActivity*` properties/settings (master opt-in, field selection,
  style, top-right slot, plot range, 4 axis-chrome toggles, range-lines toggle, Bolus-shortcut
  toggle) + `laFieldItems`/`laFieldLabel`/`defaultLiveActivityFields` + the `syncWidgetConfig()`
  mirror-writes + the `backupSnapshot()`/`applyBackup()`/init-restore plumbing for all 11 keys.
- The 11 `SettingsCatalog.swift` descriptors (all `.display`, `syncsToICloud: false`).
- The "Live Activity" `SettingsView.swift` Settings section + the `FullBleedLiveActivitySettingsView`
  sub-screen.
- The `App.swift` `LiveActivityIntentBridge.reconnect`/`snoozeAlertIfSafe` bridge-install assignment
  blocks.
- The `ios/faBolus/Data/WidgetPublisher.swift:93` `GlucoseLiveActivityManager.update(from: snap)`
  call site.
- 10 test files: `LiveActivityManagerTests.swift`, `LiveActivityFieldSelectionTests.swift`,
  `LiveActivityContentBuilderTests.swift`, `LiveActivityBoundaryTests.swift`,
  `LATopRightSlotTests.swift`, `LAMetricsTests.swift`, `LALockScreenLayoutTests.swift`,
  `FullBleedPlotStateTests.swift`, `WidgetLAChipTintDriftGuardTests.swift`, plus the 3
  `liveActivityFields`-specific tests that were split OUT of `LiveActivityFieldsRestoreOrderTests.swift`
  (renamed `RestoreOrderEmptyFallbackTests.swift` on `main` — this branch's copy of the original,
  un-split file has all 6 tests, LA-specific and not).

## State at removal

This branch was cut from `pre-narrow/2026-08-20` — the pristine pre-removal tip, identical to `main`
before Phase 7 Plan 01 (07-01, P-A) ran. `main` has since removed all of the above in one atomic
commit (LA is mutually coupled end-to-end — deleting only some of it leaves `main` non-compiling) plus
trimmed 6 cross-cutting test files that mixed LA-specific assertions with still-live, non-LA coverage
(kept on `main`, unmodified on this branch):

- `BatteryChargingCarrierTests.swift` — this branch's copy still has the 3
  `FaBolusGlucoseAttributes.ContentState` battery-charging round-trip tests; `main`'s copy kept only
  the parallel `WidgetSnapshot` tests + the unrelated `RemoteCommandWireFixture` coverage.
- `CiqHistoryEventWireTests.swift` — this branch's copy still has
  `contentStateLastAutoCorrectionRoundTripsAndDefaultsFailClosedOnALegacyPayload` +
  `laFieldVocabularyRegistersLastAutoCorrectionButNoT1FourField`.
- `CiqLockoutBarWireTests.swift` — this branch's copy still has
  `contentStateLockoutUntilDateRoundTripsAndDefaultsFailClosedOnALegacyPayload`.
- `CiqSuspendWireTests.swift` — this branch's copy still has
  `contentStateSuspendFieldsRoundTripAndDefaultFailClosedOnALegacyPayload`.
- `WidgetStalenessTests.swift` — this branch's copy still has
  `stalenessGateIsIdenticalAcrossBothLiveActivityStylesForTheSameSnapshot` +
  `freshTrendArrowCarriedIdenticallyAcrossBothLiveActivityStyles` (both call
  `GlucoseLiveActivityManager.makeContent`).
- `GlucoseStatusGlyphGuardTests.swift` — this branch's copy still pins `GlucoseLiveActivity.swift` as
  a 4th glucose surface in `pinnedSurfaces` (`main`'s copy dropped to 3, with the counts recomputed).
- `FirstLaunchDefaultsTests.swift` — this branch's copy still asserts
  `settings.liveActivityEnabled == false` / `settings.liveActivityFields ==
  AppSettings.defaultLiveActivityFields` on a fresh install.

`main` also authored a new `LiveActivityAbsenceGuardTests.swift` (source-scans for the absence of
`ActivityKit` outside `AppModel.swift`/tests/build, and for `App.swift` no longer referencing
`LiveActivityIntentBridge`) — this branch has no such file (it predates the removal); do not port it
over on reintegration.

`main` also updated `docs`/prose comments in `Shared/WidgetShared.swift`,
`ios/faBolus/Views/RootTabView.swift`, `SettingsCatalog.swift` to drop stale LA cross-references —
this branch's copies of those files still read as if LA is live (accurate for this branch's own
tree). `AppModel.swift` was NOT edited by the removal (D-03 byte-identity; its 2 doc-comment
prose mentions of `LiveActivityIntentBridge` are a documented exception, unchanged on both branches).

Note: `WidgetSnapshot.hasSnoozeEligibleAlert` and the 5 pump-surface fields (`iobDate`,
`basalRateUnitsPerHour`, `deliverySuspended`, `controlIQMode`, `controlIQEnabled`) in
`Shared/WidgetShared.swift` were originally added to feed the Live Activity's chips/snooze button —
`main` did NOT delete these fields (they are general PumpSnapshot mirrors and `AppModel.swift`'s
write path to them is byte-identity protected); they are simply unused-but-compiled on `main` now.
This branch's copy has them with their original LA-consuming callers intact.

## Reintegration path

1. Cherry-pick (or manually re-apply) the 5 main source files back onto the target tree from this
   branch's tip: `GlucoseLiveActivity.swift`, `FullBleedGlucosePlot.swift`,
   `Shared/LiveActivityShared.swift`, `Shared/LiveActivityIntents.swift`,
   `GlucoseLiveActivityManager.swift`.
2. Restore the `WidgetUI` "Phase 5 pump-chip vocabulary" section in
   `ios/faBolusWidgets/FaBolusWidgetBundle.swift` (the `PumpChip` struct + all 8 chip functions +
   `chip(for:_:)`) and the `GlucoseLiveActivity()` registration line in `FaBolusWidgetBundle`'s
   `body`.
3. Restore the 11 `WidgetStore.liveActivity*` properties in `Shared/WidgetShared.swift` (this
   branch's copy has the exact original text).
4. Restore the 11 `AppSettings.swift` properties + `laFieldItems`/`laFieldLabel`/
   `defaultLiveActivityFields` + the `syncWidgetConfig()` mirror-writes + the
   `backupSnapshot()`/`applyBackup()`/init-restore lines for all 11 keys — re-derive the exact
   insertion points against the target's current `AppSettings.swift` rather than pasting back
   verbatim, since later phases may have moved the surrounding code.
5. Restore the 11 `SettingsCatalog.swift` descriptors.
6. Restore the "Live Activity" `SettingsView.swift` section + `FullBleedLiveActivitySettingsView`.
7. Restore the `App.swift` bridge-install assignment blocks.
8. Restore the `WidgetPublisher.swift:93` `GlucoseLiveActivityManager.update(from: snap)` call site.
9. Restore/re-derive the 9 whole-file tests + re-merge the 6 trimmed LA-specific test cases back
   into their (post-removal) target-tree siblings — do not paste the whole trimmed files back
   verbatim, since `main`'s non-LA content in those files may have changed since. Remove or
   re-scope `main`'s `LiveActivityAbsenceGuardTests.swift` — it is written to assert ABSENCE; a
   full reintegration would make its assertions fail by design, which is the correct signal that
   the boundary test itself must be retired/rewritten as part of undoing this removal.
10. Reconcile `CompileGateAudit.gatedOffSearchTokens` — remove `"liveactivity"` from the gated-off
    set once the surface is live again.
11. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`). This branch's removal never touched
    `Packages/faBolusCore`, `ios/faBolus/Data/TandemBackend.swift`, or (functionally)
    `ios/faBolus/Data/AppModel.swift` — `check-dose-byte-identity.sh` should need no reconciling
    step; Live Activity was a NO-dose-set-stub, clean-delete surface throughout (D-01/D-02). Note:
    a separate, isolated infra commit generalized
    `Packages/faBolusCore/Tests/faBolusCoreTests/DoubleToIntTrapGuardTests.swift`'s liveness check
    away from a FoodFinder-specific hardcode (07-01, unrelated to LA) — that edit is already
    cherry-picked onto this branch and needs no reintegration action either way.
