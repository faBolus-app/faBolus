# REINTEGRATION.md — dev/siri-shortcuts

## Feature preserved

Siri + read-only Shortcuts + the Temp/Profile/Mode/activity+sleep automation surface (Phase 7,
FEAT-05, D-08):

- The 5 `ios/faBolus/Intents/*.swift` files — `ModeIntents.swift`, `ProfileIntents.swift`,
  `ShortcutsIntents.swift`, `StatusIntents.swift` (contains `struct FaBolusShortcuts:
  AppShortcutsProvider`, the app's only Siri-phrase registration), `TempRateIntents.swift`.
- The 2 automation ENGINES: `ios/faBolus/Data/ProfileAutomation.swift`,
  `ios/faBolus/Data/TempRateAutomation.swift` (their only in-app callers were
  `ProfileIntents.swift`/`TempRateIntents.swift`, both above).
- `ios/faBolus/Views/ModeAutomationHelpView.swift` — the help screen the Settings section links to.
- The entire "Activity & sleep automation" `Section` in `ios/faBolus/Views/SettingsView.swift`
  (5 toggles: `autoExerciseMode`, `autoSleepMode`, `autoTempRate`, `autoProfileActivation`,
  `modeReminders`, plus the "Set up the Shortcuts automation" `NavigationLink`).
- The `autoTempRate`/`autoProfileActivation` `AppSettings` properties (declaration +
  backup/restore/reset participation) — fully deleted on `main` since their only readers (the 2
  engines) are gone.
- The 5 matching `SettingsCatalog` descriptors for all 5 toggles above.
- Test files that source-scanned the deleted code: `ShortcutsL7BoundaryTests.swift`,
  `TempRateAutomationTests.swift`, `ProfileAutomationTests.swift`.

## NOT preserved here (stays on `main`, unrelated to this removal)

- `ios/faBolus/Data/ModeAutomation.swift` — kept BYTE-FOR-BYTE on `main`. `AppModel.swift:1810,2104`
  (dose-protected, `DOSE_PATHS`) hard-reference `ModeAutomation.applyPendingIfDue`/`ModeAutomation.Mode`.
  This branch's copy is identical to `main`'s — nothing to reintegrate for this file.
- `ios/faBolus/Data/AppSettings.swift`'s `autoExerciseMode`/`autoSleepMode`/`modeReminders`
  properties — FROZEN on `main` at their existing default `false` (still read by the kept
  `ModeAutomation.swift:28,127` + `PumpWizardViews.swift:597`), not deleted. This branch's copy has
  them un-frozen (readable/settable via the Settings UI, same as before removal).
- `Shared/WidgetBolusIntents.swift` — the KEPT Quick-Bolus widget's App Intents file. Does not
  conform to `AppShortcutsProvider`, shares no file with the 5 deleted Intents. Untouched by this
  removal on either branch.
- `ios/faBolusAppTests/ModeAutomationPrecedenceTests.swift` (tests `ModeAutomation.request` directly
  — kept, unchanged on `main`) and `ios/faBolusAppTests/PumpSwitchTests.swift` (its saved/restored
  tuple never included `autoTempRate`/`autoProfileActivation` — kept, unchanged on `main`).

## State at removal

This branch was cut from `pre-narrow/2026-08-20` (the annotated, current baseline tag) — the
pristine pre-removal tip, identical to `main` before Phase 7 Plan 03 (07-03, P-C) ran. `main` has
since:

1. `git rm`'d all 5 `ios/faBolus/Intents/*.swift` files (removing `FaBolusShortcuts` in full — it
   lived entirely inside `StatusIntents.swift:146`, there was never a separate `App.swift`
   `AppShortcutsProvider` registration to delete). `ios/faBolus/App.swift` was NOT touched.
2. `git rm`'d `ShortcutsL7BoundaryTests.swift` (source-scanned the deleted `StatusIntents.swift`).
3. `git rm`'d `ios/faBolus/Data/ProfileAutomation.swift` and `ios/faBolus/Data/TempRateAutomation.swift`
   (zero `AppModel.swift`/faBolusCore references — plain deletion, no stub needed) plus
   `TempRateAutomationTests.swift`/`ProfileAutomationTests.swift` (tested the deleted engines).
4. `git rm`'d `ios/faBolus/Views/ModeAutomationHelpView.swift` and deleted the whole "Activity &
   sleep automation" `Section` from `SettingsView.swift`.
5. Deleted the `autoTempRate`/`autoProfileActivation` `AppSettings.swift` property declarations +
   their backup/restore/reset-after-switch lines, and their `SettingsCatalog.swift` descriptors,
   outright (fully dead once the 2 engines were gone).
6. FROZE (did not delete) `autoExerciseMode`/`autoSleepMode`/`modeReminders` at their existing
   default `false` — `ModeAutomation.swift` still reads them — and deleted their 3
   `SettingsCatalog.swift` descriptors (the UI rows that set them are gone).
7. Left `ios/faBolus/Data/ModeAutomation.swift` completely byte-for-byte untouched.
8. Authored `ios/faBolusAppTests/ShortcutsAbsenceGuardTests.swift` on `main` (source-scans for the
   absence of the 5 Intents files + no `AppShortcutsProvider` conformance outside the kept widget) —
   this branch has no such file (it predates the removal); do not port it over on reintegration.

## Reintegration path

1. Cherry-pick (or manually re-apply) the 5 `ios/faBolus/Intents/*.swift` files from this branch's
   tip back onto the target tree.
2. Re-apply `ios/faBolus/Data/ProfileAutomation.swift`/`TempRateAutomation.swift` and
   `ios/faBolus/Views/ModeAutomationHelpView.swift` from this branch's copies.
3. Re-apply the "Activity & sleep automation" `Section` into `SettingsView.swift` (a hand merge if
   `main` has moved, not a blind overwrite).
4. Restore the `autoTempRate`/`autoProfileActivation` `AppSettings.swift` property declarations +
   backup/restore/reset lines from this branch's copy; un-freeze
   `autoExerciseMode`/`autoSleepMode`/`modeReminders` (remove the "frozen" annotation, restore their
   `SettingsCatalog` descriptors and any UI wiring beyond the Section itself).
5. Restore the 5 `SettingsCatalog.swift` descriptors and re-add `ShortcutsL7BoundaryTests.swift`/
   `TempRateAutomationTests.swift`/`ProfileAutomationTests.swift` from this branch.
6. Delete `ShortcutsAbsenceGuardTests.swift` (it asserts the opposite of the reintegrated state) —
   do NOT port it over.
7. Run the full app build + test suite; confirm `check-dose-byte-identity.sh` is unaffected
   (`ModeAutomation.swift`/`AppModel.swift`/`AppSettings.swift` are app-layer, not `DOSE_PATHS`, so
   no dose-byte-identity concern either way).
