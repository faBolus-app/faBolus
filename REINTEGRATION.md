# REINTEGRATION.md — dev/alert-rules

## Feature preserved

The custom alert-rules editor + engine: a user-authored auto-snooze/auto-dismiss rule set
(`AlertRule`: `kinds`, `alertIds`, a time-of-day window, an optional glucose gate, and an
`AlertAction` of `.autoSnooze`/`.autoDismiss`), edited via `Views/AlertRulesView.swift` (183 lines,
wired at `SettingsView.swift`'s `.alerts` router case), persisted in `AppSettings.alertRules`, and
evaluated by `TandemBackend.swift`'s `applyAutoRules` against `faBolusCore`'s `AlertRuleEngine`
(`AlertRule`/`AlertRuleEngine`/`AlertAction`) once per incoming pump-notification batch. The
`SettingsCatalog.swift` `alertRules` descriptor (`.advanced`, `backsUp: true`) made the rule set
part of a portable settings backup/restore round trip.

## State at removal

This branch was cut from `pre-narrow/2026-08-20` (the annotated, current baseline tag), then synced
to `main`'s current `DOSE_PATHS` state (`AppModel.swift` + the `DoubleToIntTrapGuardTests.swift`
retirement — see this branch's own sync commit) so `check-dose-byte-identity.sh` passes for it too.
`main` has since (Phase 7, 07-05, P-E, FEAT-08, SAFETY):

1. **Frozen** `ios/faBolus/Data/AppSettings.swift`'s `alertRules` to a getter-level constant
   `[]` (`{ get { [] } set { } }`) — no setter effect, including a restored-from-backup non-empty
   rule-set or a direct assignment, can ever make it non-empty again. Its `UserDefaults`
   init-restore line, `backupSnapshot` emission line, and `applyBackup` restore line are all
   removed too (the same belt-and-suspenders posture as `childModeEnabled`/
   `requireRemoteBolusApproval`, FEAT-04, 07-04) — the underlying persisted value becomes
   permanently unreadable, not just unwritable. `TandemBackend.swift`'s `applyAutoRules` (`guard
   !rules.isEmpty else { return }`) fires unconditionally as a result — a behavior-neutral
   early-return, and `TandemBackend.swift` itself, plus `faBolusCore`'s `AlertRuleEngine.swift`
   (`AlertRule`/`AlertRuleEngine`/`AlertAction`), are BYTE-IDENTICAL throughout (never edited). This
   branch's copy of `AppSettings.swift` has the original `didSet`-backed, freely-settable stored
   property, with its original `UserDefaults` init-restore line and full `backupSnapshot`/
   `applyBackup` participation intact.
2. `git rm`'d `ios/faBolus/Views/AlertRulesView.swift` in full (`AlertRulesView`, 183 lines). This
   branch's copy is untouched. `SettingsView.swift`'s `.alerts` router case
   (`case .alerts: AlertRulesView(...)`) was deleted along with it — this branch's copy still has it.
3. Deleted the `alertRules` `SettingsCatalog.swift` descriptor and removed the stale `"alertRules"`
   literal from `SettingsCatalogTests.swift`'s `conditionalBackupKeys` set, recomputing the
   descriptor/backed-up-key counts live. This branch's copy of both files predates the removal.
4. Authored `AlertRulesFreezeGuardTests.swift` (new, Wave 0, SAFETY) — asserts
   `applyBackup(["alertRules": .data(<a non-empty encoded rule-set>)])` leaves `alertRules.isEmpty
   == true`, and that a direct `alertRules = [...]` setter call leaves it empty too. This branch has
   no such file (it predates the removal); do not port it over on reintegration, it asserts the
   opposite of what this branch's tree looks like.
5. Registered this surface's tokens in
   `ios/faBolusAppTests/SettingsCatalogTests.swift`'s `CompileGateAudit.gatedOffSearchTokens` (§6c
   no-dangling-refs audit) — this branch's copy predates the addition.
6. Confirmed §6d (owner-accepted PASS, 07-OWNER-FLAGS.md): no SAFETY alert (glucose LOW/HIGH/
   urgent-low, or the pump-disconnect/CGM-data-loss/bolus-reconciliation trio) ever routed through
   `AlertRuleEngine` — only the CUSTOM, user-authored convenience rules did. The 3 safety suites
   (`SafetyNotificationTests`, `NotificationCoordinatorTests`,
   `PumpBackgroundDisconnectNotificationTests`) stayed green UNCHANGED throughout as the direct
   evidence. This branch needed no changes to any of the three.

## Reintegration path

1. Cherry-pick (or manually re-apply) `ios/faBolus/Views/AlertRulesView.swift` back onto the target
   tree from this branch's tip.
2. In `SettingsView.swift`, restore the `.alerts` router case (`case .alerts: AlertRulesView(settings:
   settings)`) from this branch.
3. In `AppSettings.swift`, restore `alertRules` to this branch's original `didSet`-backed stored-
   property form (remove the `{ get { [] } set { } }` freeze), restore the `UserDefaults`
   init-restore line, and restore its `backupSnapshot`/`applyBackup` participation, all from this
   branch's copy.
4. In `SettingsCatalog.swift`, restore the `alertRules` descriptor (`.init("alertRules", .alerts,
   from: .advanced, backsUp: true)`) from this branch.
5. In `SettingsCatalogTests.swift`, restore the `"alertRules"` literal to `conditionalBackupKeys`,
   recompute descriptor/backed-up-key counts, and remove this surface's tokens from
   `gatedOffSearchTokens`.
6. Delete the main-side `AlertRulesFreezeGuardTests.swift` (it asserts the frozen state;
   reintegration un-freezes it).
7. `Packages/faBolusCore/Sources/faBolusCore/AlertRuleEngine.swift` and
   `ios/faBolus/Data/TandemBackend.swift` were NEVER touched by the removal — no action needed
   there; the engine + its reader have been byte-identical the whole time.
8. Rebuild + run the full suite; `SettingsReachabilityGuardTests`/`SettingsCatalogTests` will need
   their counts recomputed again for the restored descriptor; confirm
   `PumpSwitchTests.swift`'s `s.alertRules = saved.6` / `#expect(s.alertRules.isEmpty)` writers
   still compile and pass against the restored stored property.
