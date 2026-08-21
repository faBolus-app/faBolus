# REINTEGRATION.md — dev/nudge

## Feature preserved

faBolusNudge / Smart Assist (Phase 4, NUDGE-01): the eating-detection nudge pipeline and the
Smart Assist bolus-warning submenu, gated behind `#if FABOLUS_NUDGE` / `FABOLUS_NUDGE`, including
the SPM package dependency on the `faBolusNudge` package and the Smart Assist submenu split across
HR-context, SiteAtlas, GraphDetail, Retrospective, and FoodFinder surfaces — plus, as of the D-06a
refresh, the Control-IQ-awareness readout VIEWS that had originally been classified `[KEEP]`-forever
before the owner overrode that classification for their UI (the 6 underlying `ciq*Enabled` wire
fields themselves are NOT preserved here — they never left `main`; see "What is NOT on this branch"
below).

Both eating nudges and Smart Assist bolus warnings are also flagged in `BRANCHES.md` §1.2 as
belonging on `experimental` rather than `main` once classification is enforced (they fire on a
detector threshold / automate a judgement about a proposed dose) — reintegration onto `main`
should re-check that classification still holds at the time of reintegration.

## State at removal

Phase 4 (NUDGE-01) has now executed in full, across three plans, each `git rm`-ing (delete-on-main,
Phase 2.5 CLEAN-01 convention) rather than gate-flipping:

- **04-01**: removed the `faBolusNudge` remote SPM package declaration, its 4 iOS product-dependency
  lines, and both `FABOLUS_NUDGE` compile tokens from `project.yml`; reconciled
  `scripts/generate-project.sh`'s `$NUDGE` auto-detect/strip_block/summary logic away entirely;
  `git rm`'d the two whole-file `#if FABOLUS_NUDGE` glue sources `ios/faBolus/Data/
  EatingAccelPipeline.swift` and `ios/faBolus/Data/EatingPersonalization.swift`.
- **04-02**: `git rm`'d `ios/faBolus/Views/SmartAssistSettingsView.swift` and `ios/faBolus/Views/
  EatingNudgeSettingsView.swift`; removed the `.smartAssist` `SettingsCategory`/`SettingsSidebarItem`
  enum cases in full (not just their switch arms) from `ios/faBolus/Views/SettingsView.swift`; removed
  all 4 `.smartAssist` `SettingsCatalog` descriptors (`eatingNudgesEnabled`, `eatingTriggerConfig`,
  `eatingLearnFromFeedback`, `siteAtlasEnabled`) from `ios/faBolus/Data/SettingsCatalog.swift`; dropped
  `siteAtlasEnabled` from `AppSettings.backupSnapshot()`/`applyBackup()` (D-06b — a legacy backup
  carrying the key is now silently ignored on restore).
- **04-03**: deleted the Control-IQ-awareness readout VIEWS (D-06a) — the render logic gated by the 6
  `ciq*Enabled` flags — across `ios/faBolus/Views/StatusPillsView.swift` (the `"ciqZone"` pill case +
  `ciqZoneChip`/`ciqZoneIcon`, the `ciqSuspendedForLowElapsedLabel` branch, 3 already-dead cases +
  `lastAutoCorrectionAgeLabel`), `ios/faBolus/Views/MainHUDView.swift` (both
  `ciqLockoutCountdownEnabled` blocks, the `SleepExerciseAwarenessCard` struct + call sites),
  `ios/faBolus/Views/BolusEntryView.swift` (`lockoutCountdownFraction`/`lockoutAvailableAt`, the render
  call site, the now-dead shared `LockoutCountdownBarView` struct), and `ios/faBolus/Views/
  PumpControlView.swift` (`maxBasalReadout`, the one-time-notice trigger + alert, the render `Section`,
  the dead `MaxBasalReadoutView` struct, and the dead `hasAcknowledgedMaxBasalNotice`/
  `maxBasalNoticeAckAt`/`acknowledgeMaxBasalNotice` idiom). Also removed the one CIQ selection surface
  living OUTSIDE the deleted submenu: the `"ciqZone"` entry in `AppSettings.pillItems`/`pillLabel`
  (Pitfall 7), and the 3 dead `ciqAwarenessNoticeAckAt`/`hasAcknowledgedCiqAwarenessNotice`/
  `acknowledgeCiqAwarenessNotice` ack-flag members whose only reader was the already-deleted
  `SmartAssistSettingsView.swift`.

This branch (`dev/nudge`) still carries the full pre-narrow tree, identical to
`pre-narrow/2026-08-20` — nothing has diverged here. `main` has removed everything this branch
preserves.

## What is NOT on this branch (stays on `main`, never removed)

The 6 `ciq*Enabled` wire fields (`ciqStateReadoutsEnabled`, `ciqLockoutCountdownEnabled`,
`ciqMaxBasalReadoutEnabled`, `ciqSleepExerciseAwarenessEnabled`, `ciqPlusTempRateEnabled`,
`ciqCeilingFlagsEnabled`) themselves — declared in `ios/faBolus/Data/AppSettings.swift:198-209`,
woven unconditionally into the SIGNED command at `ios/faBolus/Data/AppModel.swift:603-608` and
`Packages/faBolusCore/Sources/faBolusCore/RemoteCommand.swift:515-520` — are dose/signed,
byte-identity-protected, and were **never removed from `main`, never on this branch either**. D-06a
explicitly resolved: delete the readout VIEWS, freeze the wire fields at their defaults. Reintegrating
this branch's UI does NOT require touching those two files; the wire plumbing already exists on
`main` today, unconditionally, regardless of `dev/nudge`'s state.

Also NOT removed (left physically untouched, flagged not decided — see `04-OWNER-FLAGS.md`):
`ios/faBolus/Views/PumpWizardViews.swift`'s `ControlIQDisableWarning` (ungated, no settings flag,
pinned by `CiqAwarenessScopeGuardTests`'s signature floor — categorically unrelated to this
branch's feature), and `ios/faBolus/Views/PumpControlView.swift`'s `ciqPlusTempRateSection` (a
WRITE control, not a readout; double-gated unreachable; deferred to Phase 9/MOBI-02 pending
owner/planner sign-off).

## Reintegration steps (POST-Phase-4 shape — read this, not the old gate-flip)

**Before Phase 4, "bring this back" meant "flip `FABOLUS_NUDGE=1`."** That mechanism no longer
restores anything — the files themselves are gone from `main`'s tree, and the submenu/readout-view
UI was deleted at the source level, not merely excluded from compilation. Do NOT attempt a bare
gate-flip as the reintegration method. The correct, heavier, post-Phase-4 path is:

1. **Restore the `faBolusNudge` SPM package fence** in `project.yml`/`generate-project.sh` (the
   package declaration, its 4 iOS product-dependency lines, and the `FABOLUS_NUDGE` compile token
   on both `SWIFT_ACTIVE_COMPILATION_CONDITIONS` lines) — see this branch's own `project.yml` for the
   pre-removal shape.
2. **Cherry-pick or copy back** `ios/faBolus/Data/EatingAccelPipeline.swift`, `ios/faBolus/Data/
   EatingPersonalization.swift`, `ios/faBolus/Views/SmartAssistSettingsView.swift`, and
   `ios/faBolus/Views/EatingNudgeSettingsView.swift` from this branch into `main`.
3. **Restore the `.smartAssist` `SettingsCategory`/`SettingsSidebarItem` enum cases** in
   `ios/faBolus/Views/SettingsView.swift` (both switch arms, both category-loop filters, the
   `SettingsExtraIndex` search entry, and the two hand-placed sidebar/settings-list rows) and the 4
   `.smartAssist` `SettingsCatalog` descriptors in `ios/faBolus/Data/SettingsCatalog.swift`
   (`eatingNudgesEnabled`, `eatingTriggerConfig`, `eatingLearnFromFeedback`, `siteAtlasEnabled`) —
   re-derive against whatever `main` looks like at reintegration time rather than pasting back
   verbatim, since the surrounding Settings scaffolding may have moved on. Re-add `siteAtlasEnabled`
   to `AppSettings.backupSnapshot()`/`applyBackup()` if SiteAtlas is part of the reintroduced set.
4. **Restore the Control-IQ-awareness readout VIEWS** (D-06a) from this branch's copies of
   `StatusPillsView.swift`, `MainHUDView.swift`, `BolusEntryView.swift`, and `PumpControlView.swift` —
   the `ciqZone` pill case + helpers, the lockout-countdown blocks + `LockoutCountdownBarView`, the
   `SleepExerciseAwarenessCard`, and the max-basal readout + `MaxBasalReadoutView` + its one-time-notice
   idiom. Re-add the `"ciqZone"` entry to `AppSettings.pillItems`/`pillLabel` and the matching case in
   `StatusPillsView.pillFor` if the dashboard-pill selection surface is being restored too. The 6
   `ciq*Enabled` wire fields these views read are **already present, unconditionally, on `main`** (see
   "What is NOT on this branch" above) — no wire-side change is needed to make the restored views
   functional again.
5. **Restore or re-derive the sidebar-parity + catalog-count test assertions**
   (`SettingsSidebarParityTests.swift`'s count back up from 6, `SettingsCatalogTests.swift`'s
   descriptor/backed-up-key counts back up) — this branch's copies are the reference implementation
   pre-removal, but re-derive rather than paste verbatim.
6. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`) plus `./scripts/check-dose-byte-identity.sh`
   and a fresh repo-wide grep for `"ciqZone"`/`FABOLUS_NUDGE`/`SmartAssistSettingsView` to confirm no
   other dangling reference was missed.

None of the restored files are dose-adjacent (`scripts/check-dose-byte-identity.sh`'s `DOSE_PATHS`
covers only `Packages/faBolusCore`, `ios/faBolus/Data/AppModel.swift`, and
`ios/faBolus/Data/TandemBackend.swift` — none of which this branch's removal ever touched), so
reintegration never requires a dose-set stub/un-stub, unlike `dev/backup`'s own REINTEGRATION.md.
