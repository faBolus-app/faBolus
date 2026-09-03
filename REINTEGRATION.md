# REINTEGRATION.md — dev/nightscout

## Feature preserved

Nightscout source + upload + backfill (Phase 5, HEALTH-02): the glucose-polling
`ios/faBolus/Data/Sources/NightscoutSource.swift`, the upload client
`ios/faBolus/Data/Sources/NightscoutUploader.swift` (fired `AppModel.swift`'s frozen
`NightscoutUploader.shared.sync(...)` call, reached via the `onNightscoutSync`
`RefreshEffectsCoordinator` seam), and the backfill client
`ios/faBolus/Data/Sources/NightscoutBackfill.swift` (fired a frozen `maybeBackfillNightscout()`
call via `NightscoutBackfill.fetch(...)` — that call no longer exists on `main` at all; its
absence is pinned by test).

## State at removal

**CONFIRMED (Phase 5 Plan 02, HEALTH-02, executed 2026-08-21):** this branch was cut from `main`'s
pristine pre-deletion tip during Phase 5 Plan 01 (Task 1), before any Nightscout removal work
landed, so it still holds the full, real, unstubbed Nightscout implementation exactly as it existed
before HEALTH-02. Plan 02 has since executed the removal on `main`:

- `git rm` of the 3 real files (`NightscoutSource.swift`, `NightscoutUploader.swift`,
  `NightscoutBackfill.swift`) landed in the SAME commit as the new stub, below.
- The `main`-only no-op stub is `ios/faBolus/Data/CGM/Sources/NightscoutStub.swift` (relocated
  under `Data/CGM/Sources` since this branch was cut; the exact filename guessed in this file's
  original draft — confirmed, no rename occurred).
- `GlucoseSourceRegistry.enabled` collapsed to `{dexcom-share}`; the Nightscout config
  section/rows in `CgmCredentialsView.swift`/`CgmStatusView.swift`/`SettingsView.swift` and the
  `nightscoutUploadEnabled` `SettingsCatalog.swift` descriptor are all deleted.
- `AppSettings.swift`'s `nightscoutUploadEnabled` property + its UserDefaults key were LEFT IN
  PLACE (at Plan 02's landing) as a hidden, unregistered device-local flag — same hidden-flag
  pattern as `watchBolusEnabled`/`requireRemoteBolusApproval`.
- ⚠ **Superseded 2026-09-03 (Phase 33 Plan 03):** the hidden `nightscoutUploadEnabled` flag, the
  stub file (`NightscoutUploader`/`NightscoutBackfill`), the `onNightscoutSync`
  `RefreshEffectsCoordinator` seam, and the `AppModel.swift` binding
  (`NightscoutUploader.shared.sync(...)`) are now ALL deleted from `main` outright — the hidden-flag
  posture above no longer holds, and `AppModel.swift` is **no longer byte-identical** to this
  branch. Reintegration now requires restoring the coordinator seam (the `onNightscoutSync` sink
  declaration + its `performEffects` invocation + `recordStep` tag) in addition to the file swap
  described below — not merely un-stubbing.

**⚠ Un-stubbing is the load-bearing difference from every prior `dev/*` branch.** Before Phase 33
Plan 03, Nightscout's `AppModel.swift` call sites were UNGATED (no `#if`) — unlike HealthKit's
`#if FABOLUS_HEALTHKIT`-guarded call sites, which compile out cleanly once the flag is gone.
Reintegrating this branch's real implementation means **deleting `main`'s `NightscoutStub.swift`,
restoring the 3 real files from this branch in its place, AND re-adding the `onNightscoutSync`
coordinator seam** — not merely flipping a compile flag, and not merely dropping the real files
back in alongside the stub (the stub + the real types in the same build collide on the
`NightscoutUploader`/`NightscoutBackfill` symbol names — exactly the duplicate-symbol hazard Plan
02's single-commit swap was designed to avoid on the removal side).

## Reintegration steps

1. **Confirm `main`'s Nightscout stub is already absent** (Phase 33 Plan 03 deleted
   `ios/faBolus/Data/CGM/Sources/NightscoutStub.swift` outright — there is no longer a stub to
   `git rm` first).
2. **Restore the 3 real Nightscout source files** from this branch into `main`:
   `ios/faBolus/Data/Sources/NightscoutSource.swift`,
   `ios/faBolus/Data/Sources/NightscoutUploader.swift`,
   `ios/faBolus/Data/Sources/NightscoutBackfill.swift`.
3. **Re-add the `onNightscoutSync` coordinator seam**: the `RefreshEffectsCoordinator` sink
   declaration, its invocation + `recordStep("nightscoutSync")` tag inside `performEffects`, the
   `AppModel.swift` binding (`NightscoutUploader.shared.sync(...)`), and the `"nightscoutSync"`
   spine entry in `RefreshOrderingCharacterizationTests.swift` — all deleted by Phase 33 Plan 03.
4. **Restore the `nightscoutUploadEnabled` accessor** on `AppSettings.swift` (its `Stored<Bool>`
   backing, `.store` wiring, and init restore), and the `nightscout` `GlucoseSourceRegistry`
   descriptor plus the Nightscout config section(s)/rows in
   `ios/faBolus/Views/CgmCredentialsView.swift` / `ios/faBolus/Views/CgmStatusView.swift` /
   `ios/faBolus/Views/SettingsView.swift` / `ios/faBolus/Data/SettingsCatalog.swift` — see this
   branch's pre-removal copies of each file for the shape; re-derive against whatever `main` looks
   like at reintegration time rather than pasting back verbatim, since work since Plan 02 will have
   moved the surrounding source.
5. **Restore or re-derive the Nightscout-specific test coverage** removed/edited across Plan 02 and
   Phase 33 Plan 03:
   - `CgmSourceValidationTests.swift`'s two deleted Nightscout malformed-URL test methods
     (`nightscoutMalformedURLThrowsInsteadOfTrapping`,
     `nightscoutBackfillMalformedURLThrowsInsteadOfTrapping`) — restore from this branch.
   - `CgmShareOnlyBoundaryTests.swift`'s `registryContainsOnlyDexcomShare` (renamed from
     `registryContainsOnlyShareAndNightscout` by Plan 02) needs `"nightscout"` added back to its
     expected set (and possibly reverting the rename, at the reintegrator's discretion).
   - `CgmConnectionKindTests.swift`'s classification-table `"nightscout": .cloudPoll` entry.
   - `NightscoutStubInertnessTests.swift` (re-derived as an absence guard by Phase 33 Plan 03)
     should be deleted — it pins the ABSENT surface's non-existence, which no longer applies once
     the real implementation is restored.
   - `SettingsCatalogTests.swift`: remove `"nightscout"` from `gatedOffSearchTokens` and recompute
     `descriptors.count`/`backedUpKeys.count` empirically (adding the `nightscoutUploadEnabled`
     descriptor back increases both by 1).
   - `AppSettings.swift`: re-add `nightscoutUploadEnabled` to `backupSnapshot()`/`applyBackup()`.
   - `RefreshOrderingCharacterizationTests.swift`: re-add `"nightscoutSync"` to the ordering spine.
   Re-derive rather than paste verbatim in every case above.
6. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`) and a fresh repo-wide grep for
   `NightscoutStub`/`nightscout` to confirm no dangling stub reference or orphaned entry was
   missed. `AppModel.swift` is no longer byte-identical after Phase 33 Plan 03, so the old
   `check-dose-byte-identity.sh` byte-for-byte claim in this file's earlier draft no longer applies —
   re-run whatever dose-path characterization suite is current at reintegration time instead.
