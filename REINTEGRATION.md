# REINTEGRATION.md — dev/backup

## Feature preserved

ALL backup/restore functionality (Phase 6, BACKUP-01): iCloud settings sync (`ICloudSettingsSync`),
`SettingsBackup`, `PrivacyDataExport` (the JSON export half of Privacy & data), SiteAtlas backup
(`siteAtlasBackup`/`restoreSiteAtlas`), the caffeine/alcohol tracker backup
(`trackersBackup`/`restoreTrackers`), the pump-settings backup/reconfigure batch
(`readPumpSettingsForBackup`/`canApplyPumpSettings`/`applyPumpSettings`, `createProfileRaw`/
`addProfileSegmentRaw`), and `BackupRestoreView` (the UI that drives all of the above).

**NOT preserved here, because it never left `main`:** the on-device "Delete all on-device data" /
"Full reset" affordance (`AppModel.EraseOutcome`, `eraseAllOnDeviceHealthData()`,
`eraseEverythingFullReset()`) and the erase-only half of `PrivacyDataView.swift` — per the owner's
D-08 carve-out, these stay live and ungated on every branch including narrow `main`. See "What is
NOT on this branch" below.

## State at removal

This branch was cut from `pre-narrow/2026-08-20` before this phase began (Phase 2.5 CLEAN-02), then
received the phase's own compile-gate-authoring commits (06-01: `a691e26`/`5315e9c`/`007aa87`,
authoring `#if FABOLUS_BACKUP` and default-PRESENT gating — these commits DO exist on this branch,
since 06-01 cherry-picked its gate-authoring commit onto every live branch, `dev/backup` included).
`dev/backup` was NOT touched by 06-02 or 06-03 — those two plans' `git rm`/trim/test-audit work only
ran against `main`; this branch still carries the FULL, un-trimmed backup surface (including the
`SiteAtlasTests.swift` and `PrivacyDataTests.swift` export tests that 06-02 removed from `main`).

Phase 6 has now executed in full against `main`, across three plans:

- **06-01**: authored the `#if FABOLUS_BACKUP` compile gate (default PRESENT at the time), wrapping
  AppModel.swift's backup-adjacent members in 6 blocks — **Block A** (SiteAtlas MARK section:
  `siteAtlasBackup()`, `restoreSiteAtlas(_:)`), **Block B** (trackers MARK section:
  `trackerSourceID`, `trackersBackup()`, `restoreTrackers(_:)`), **Block C**
  (`buildPrivacyExport(now:)`, `exportPrivacyDataJSON(now:)`), **Block E** (`createProfileRaw`/
  `addProfileSegmentRaw`, each guarded individually), and **Block F** (the "Backup / reconfigure"
  MARK section: `readPumpSettingsForBackup()`, `canApplyPumpSettings`, `applyPumpSettings`). The
  first-pass plan's "Block D" (the erase MARK section) is **NOT** one of these — see next paragraph.
  Also guarded `App.swift`'s two `ICloudSettingsSync.shared.start()`/`.push()` call sites.
  Relocated the erase path's one hard dependency, `SettingsBackup.cgmSecretAccounts`, to the
  always-present `ios/faBolus/Data/Sources/CredentialStore.swift` as
  `CredentialStore.cgmSecretAccounts` (an unconditional, ungated `static let`) — this is the D-08
  relocation `AppModel.eraseEverythingFullReset()` now reads instead of the gated type.
  **Owner decision D-08 (adopted at re-plan time, before 06-01 landed):** the erase MARK section —
  `AppModel.EraseOutcome`, `eraseAllOnDeviceHealthData()`, `eraseEverythingFullReset()` — EXITS the
  guarded set entirely and stays LIVE/ungated on every branch, `main` included. If you are
  reintegrating this branch's backup surface, do **not** re-wrap the erase MARK section in
  `#if FABOLUS_BACKUP` — it was never gated, and gating it now would create the exact drift `main`'s
  copy has spent this phase avoiding.
- **06-02**: flipped `main`'s `FABOLUS_BACKUP` default `1 → 0` in `scripts/generate-project.sh`
  (this branch's own copy is untouched — still whatever default 06-01 left it at); `git rm`'d 7
  app-layer files/dirs from `main` ONLY (all 7 still resolve on this branch, unmodified):
  `ios/faBolus/Data/SettingsBackup.swift`, `ios/faBolus/Data/PrivacyDataExport.swift`,
  `ios/faBolus/Views/BackupRestoreView.swift`, `ios/faBolus/Data/ICloudSync.swift`,
  `ios/faBolus/Data/SiteAtlasStore.swift`, `ios/faBolus/Views/SiteAtlas/` (3 files:
  `SiteAtlasBodyMapView.swift`, `SiteAtlasLogEntrySheet.swift`, `SiteAtlasRootView.swift`), and
  `ios/faBolus/Vendor/LoopPowerPack/SiteAtlas/SiteAtlas_Models.swift`; trimmed
  `ios/faBolus/Views/PrivacyDataView.swift` to erase-only IN PLACE on `main` (export
  `Section`/`@State`/`.fileExporter`/`export()` removed there — this branch's copy of that file is
  the FULL pre-trim version, export half included); did the §6c `SettingsView.swift` teardown
  (removed `.backupRestore` sidebar case/tag/link/`SettingsExtraIndex` row; kept `.privacyData`;
  removed the unpair flow's step-1 "back up first" gate — `UnpairStep` went from a 2-case enum
  (`.backup`/`.confirm`) to 1-case (`.confirm` only), both unpair entry points now route straight to
  confirm); deleted `siteAtlasEnabled` from `ios/faBolus/Data/AppSettings.swift` (CLEAN-02 — the
  property decl + its persisted-default read; it had already been dropped from
  `backupSnapshot()`/`applyBackup()` and from the `SettingsCatalog` descriptor list by Phase 4).
- **06-03**: authored the ungated `BackupRemovalBoundaryTests.swift` (D-08 absence +
  non-interference + erase-stays-reachable proof); extended `main`'s
  `CompileGateAudit.gatedOffSearchTokens` with this phase's search tokens
  (`icloud`/`restore`/`files`/`import` — deliberately excluding `backup`/`export`, which collide
  with still-live rows unrelated to this feature); re-derived `SettingsCatalog` descriptor/
  backed-up-key counts LIVE (both unchanged at 59/57, since `siteAtlasEnabled` was already
  unregistered by Phase 4); finalized the `SettingsSidebarParityTests.swift` count (5, unchanged);
  ran the full assembled exit gate.

This branch (`dev/backup`) still carries the pre-06-02 tree for every one of the files above —
nothing on this branch has diverged since 06-01's gate-authoring commit.

### Phase 33 (dead-code programme): the guards themselves, not just the default, are now gone

A later phase (the "retire the no-op stubs and the unconditionally stripped compile flags"
programme) went further than 06-02's default flip. As of that phase, on `main`:

- **Blocks A, B, and C no longer exist as `#if`-guarded source at all** — they lived in
  `ios/faBolus/Data/App/AppModel+Backup.swift` (129 lines: guards at what were roughly `:11-39`
  Block A, `:42-89` Block B, `:92-128` Block C), and that whole file is now `git rm`'d from `main`.
  This branch's own copy of `AppModel+Backup.swift` is unaffected and still has all three blocks —
  use IT as the restore source, not any commit on `main` after that phase.
- **Blocks E and F are also deleted outright from `AppModel.swift`**, not merely re-gated —
  `createProfileRaw`/`addProfileSegmentRaw` (Block E) and the "Backup / reconfigure" MARK section
  (`readPumpSettingsForBackup()`/`canApplyPumpSettings`/`applyPumpSettings`, Block F) no longer
  appear in `main`'s `AppModel.swift` in any form, guarded or otherwise.
- **`App.swift`'s two `ICloudSettingsSync.shared.start()`/`.push()` guards are deleted outright**,
  along with their trailing comments — not merely inert.
- **The `FABOLUS_BACKUP` compile-condition token itself is removed from both
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS` lines in `project.yml`**, and `generate-project.sh`'s
  `drop_flag FABOLUS_BACKUP` call is deleted along with it. The `$BACKUP` shell variable itself
  survives in `generate-project.sh`, but only to drive the still-present, unrelated
  `APP_SOURCE_EXCLUDES` file-exclude gate (a different phase's territory) — setting
  `FABOLUS_BACKUP=1` today defines no compile-condition token at all.
- **`BackupRemovalBoundaryTests.swift`'s `#if FABOLUS_BACKUP`-checking test was replaced** by a
  source-scan test asserting the token's absence from `project.yml`; the erase-reachability tests
  it also carries are unaffected and still the right proof that the D-08 carve-out survived.
- **The 7 dead payload section types in `Packages/faBolusCore/Sources/faBolusCore/BackupModels.swift`
  are also deleted** by that same phase: `SecretsBackup`, `PumpSettingsBackup`, `SiteAtlasBackup`,
  `SiteAtlasEntryBackup`, `TrackerBackup`, `CaffeineEntryBackup`, `AlcoholEntryBackup`, plus the four
  optional section properties on `FaBolusBackup` (and their initializer parameters) that referenced
  them. `FaBolusBackup` itself and `BackupValue` stay live (unrelated round-trip consumers exist
  elsewhere) — only the seven dead section structs and the four properties naming them are gone.
  `Packages/faBolusCore/Tests/faBolusCoreTests/BackupModelsTests.swift` was rewritten in the same
  commit to drop the six tests constructing the removed types, keeping only the surviving
  container's coverage. This branch's own copies of both files are untouched and still declare the
  full type set.

None of this changes what is preserved HERE — this branch was cut before that phase ran and was not
touched by it, so every symbol below still exists on `dev/backup` unmodified. It changes what a
reintegration must restore: the earlier assumption that Blocks A/B/C/E/F were merely `#if`-disabled
source sitting dormant on `main` no longer holds. Reintegrating now means re-creating files and
symbols that no longer exist on `main` in any form, not un-commenting a flag.

## What is NOT on this branch (stays on `main`, never removed, never gated)

The erase MARK section — `AppModel.EraseOutcome`, `eraseAllOnDeviceHealthData()`,
`eraseEverythingFullReset()` (`ios/faBolus/Data/AppModel.swift`, immediately following Block C) —
and the erase-only half of `ios/faBolus/Views/PrivacyDataView.swift` are **owner-required (D-08)**
to survive on every branch regardless of `FABOLUS_BACKUP`. They are NOT preserved here as "the
removed feature" because they were never removed — this branch's own copy of
`AppModel.swift`/`PrivacyDataView.swift` has the SAME erase code `main` does (it's the export half
of `PrivacyDataView.swift` that differs — this branch's is un-trimmed).

`eraseEverythingFullReset()`'s one dependency on backup-adjacent code —
`SettingsBackup.cgmSecretAccounts` pre-06-01, `CredentialStore.cgmSecretAccounts` post-06-01 — is
likewise unconditional on every branch; `ios/faBolus/Data/Sources/CredentialStore.swift` is not part
of the guarded/removed surface.

## Reintegration steps

**Before reintegrating, confirm `FABOLUS_BACKUP` is DEFINED.** On `main` today the token no longer
appears on either `SWIFT_ACTIVE_COMPILATION_CONDITIONS` line at all (it was removed outright, not
merely defaulted to 0), and `generate-project.sh` has no `drop_flag FABOLUS_BACKUP` call left to
delete — reintegrating means ADDING the token back to both lines and re-authoring a strip/default
mechanism for it, not flipping an existing default. This branch's own `project.yml`/
`generate-project.sh` still default it to whatever 06-01 left it at (PRESENT) — diff this branch's
copies against `main`'s current ones before reintegrating, don't assume either default is still
current.

1. **Add `FABOLUS_BACKUP` back to both `SWIFT_ACTIVE_COMPILATION_CONDITIONS` lines** in `project.yml`
   and re-author a default/strip mechanism for it in `generate-project.sh` (this branch's own copies
   are the reference for what that machinery looked like before removal). The `# >>> BACKUP`
   `APP_SOURCE_EXCLUDES` block and the `$BACKUP` shell variable survive on `main` independent of this
   step (different phase's territory) — reconcile against whatever state they're in at reintegration
   time rather than assuming this document's description of them is still current.
2. **Copy the 7 originally `git rm`'d files/dirs back** from this branch, verbatim, into the target:
   `SettingsBackup.swift`, `PrivacyDataExport.swift`, `BackupRestoreView.swift`, `ICloudSync.swift`,
   `SiteAtlasStore.swift`, `Views/SiteAtlas/` (3 files), `SiteAtlas_Models.swift`.
3. **Also restore `ios/faBolus/Data/App/AppModel+Backup.swift` in full** (Blocks A/B/C —
   `siteAtlasBackup`/`restoreSiteAtlas`, `trackerSourceID`/`trackersBackup`/`restoreTrackers`,
   `buildPrivacyExport`/`exportPrivacyDataJSON`) and **re-add Blocks E and F inline in
   `AppModel.swift`** (`createProfileRaw`/`addProfileSegmentRaw`; the "Backup / reconfigure" MARK
   section — `readPumpSettingsForBackup()`/`canApplyPumpSettings`/`applyPumpSettings`) from this
   branch's copy of `AppModel.swift`, splicing them back at their original call sites (`main`'s
   current `AppModel.swift` has moved on since — re-derive placement, don't assume old line numbers).
4. **Restore the 7 dead `BackupModels.swift` section types** (`SecretsBackup`, `PumpSettingsBackup`,
   `SiteAtlasBackup`, `SiteAtlasEntryBackup`, `TrackerBackup`, `CaffeineEntryBackup`,
   `AlcoholEntryBackup`) and the four optional section properties + initializer parameters they fed
   on `FaBolusBackup`, from this branch's copy of
   `Packages/faBolusCore/Sources/faBolusCore/BackupModels.swift`. Restore the matching six tests in
   `BackupModelsTests.swift` from this branch's copy, folded back around whatever the target's
   current file looks like (do not just overwrite — the surviving-container tests may have diverged).
5. **Restore `PrivacyDataView.swift`'s export half FROM THIS BRANCH's copy, not `main`'s.** `main`'s
   copy is permanently trimmed to erase-only (D-08 — that trim is NOT something to undo, the owner
   requires it to stay erase-only on narrow `main` even after any partial reintegration elsewhere).
   This branch's copy is the pre-trim reference with both halves intact — use it as the merge base
   for the export Section/`@State`/`.fileExporter`/`export()` code, folded back around whatever
   erase-only code the reintegration target already has (do not just overwrite — the erase half may
   have diverged since 06-02).
6. **Re-add the two `#if FABOLUS_BACKUP` guards in `App.swift`**
   (`ICloudSettingsSync.shared.start()`/`.push()`) — these are deleted outright on `main` now, not
   merely inert, so this step is required regardless of how much `App.swift` has otherwise diverged.
7. **Restore the §6c `SettingsView.swift` surface**: the `.backupRestore` `SettingsSidebarItem` case
   + its sidebar `Label`/`.tag`/`NavigationLink`/`SettingsExtraIndex` entry (this branch's copy has
   the exact pre-removal shape, keyword string `"backup restore icloud files settings export
   import"`); re-add the unpair flow's step-1 "back up first" gate if the two-step unpair UX is
   being restored too (`UnpairStep.backup` case + its `confirmationDialog` + the `BackupRestoreView`
   sheet + `showBackupSheet`/`repairAfterBackup` state) — re-derive against whatever the target's
   `SettingsView.swift`/unpair flow looks like at reintegration time rather than pasting back
   verbatim, since the surrounding code may have moved on.
8. **Restore `siteAtlasEnabled`** in `AppSettings.swift` (property decl + persisted-default read) if
   SiteAtlas is part of what's being reintroduced — re-add it to `SettingsCatalog.descriptors`,
   `backupSnapshot()`/`applyBackup()`, and `SettingsSidebarParityTests`/`SettingsCatalogTests`'s
   counts ONLY if reintroducing it; it was already an unregistered/hidden flag as of Phase 4, so a
   backup-only reintegration that leaves SiteAtlas out needs no catalog change at all.
9. **Restore or re-derive the test-side split**: `ios/faBolusAppTests/SiteAtlasTests.swift` (this
   branch's full copy) and the 2 export tests currently only on this branch's copy of
   `PrivacyDataTests.swift` (`exportCarriesSettingChangeLogAndLedgerAndRoundTrips`,
   `trackerExportRoundTripsAndDecodesLegacyPayload`) — re-derive against the target's current
   `PrivacyDataTests.swift` (main's kept erase tests must stay untouched) rather than pasting the
   whole file back. Remove or re-scope `main`'s `BackupRemovalBoundaryTests.swift` source-scan test —
   it is written to assert ABSENCE of the token; a full reintegration would make it fail by design,
   which is the correct signal that the boundary test itself must be retired or rewritten as part of
   un-doing this removal, not silently left red.
10. **Reconcile `CompileGateAudit.gatedOffSearchTokens`** (`SettingsCatalogTests.swift`) — remove
    `icloud`/`restore`/`files`/`import` from the gated-off set once the row they described is live
    again, or the §6c orphan audit will (correctly) start flagging the restored
    `"Backup & restore"` row as a dangling reference to a "removed" feature that no longer is one.
11. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`), paying particular attention to
    `./scripts/check-dose-byte-identity.sh` — `AppModel.swift`'s guarded blocks (A/B/C/E/F) sit
    inside the dose-set file this invariant protects; un-gating them must not change one byte of the
    surrounding dose-path code the check pins. This branch's own removal never touched
    `Packages/faBolusCore` (beyond the section types above) or `ios/faBolus/Data/TandemBackend.swift`,
    so reintegration should not need a dose-set stub/un-stub step the way `dev/nudge`'s reintegration
    never did either — the `#if FABOLUS_BACKUP` wrapping IS the byte-identity-preserving mechanism
    here, not a stub.
