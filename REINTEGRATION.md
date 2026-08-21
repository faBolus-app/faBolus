# REINTEGRATION.md — dev/nightscout

## Feature preserved

Nightscout source + upload + backfill (Phase 5, HEALTH-02): the glucose-polling
`ios/faBolus/Data/Sources/NightscoutSource.swift`, the upload client
`ios/faBolus/Data/Sources/NightscoutUploader.swift` (fires `AppModel.swift:1799`'s frozen
`NightscoutUploader.shared.sync(...)` call), and the backfill client
`ios/faBolus/Data/Sources/NightscoutBackfill.swift` (fires `AppModel.swift:1420-1436`'s frozen
`maybeBackfillNightscout()` call via `NightscoutBackfill.fetch(...)`).

## State at removal

**CONFIRMED (Phase 5 Plan 02, HEALTH-02, executed 2026-08-21):** this branch was cut from `main`'s
pristine pre-deletion tip during Phase 5 Plan 01 (Task 1), before any Nightscout removal work
landed, so it still holds the full, real, unstubbed Nightscout implementation exactly as it existed
before HEALTH-02. Plan 02 has since executed the removal on `main`:

- `git rm` of the 3 real files (`NightscoutSource.swift`, `NightscoutUploader.swift`,
  `NightscoutBackfill.swift`) landed in the SAME commit as the new stub, below.
- The `main`-only no-op stub is `ios/faBolus/Data/Sources/NightscoutStub.swift` (the exact filename
  guessed in this file's original draft — confirmed, no rename occurred).
- `GlucoseSourceRegistry.enabled` collapsed to `{dexcom-share}`; the Nightscout config
  section/rows in `CgmCredentialsView.swift`/`CgmStatusView.swift`/`SettingsView.swift` and the
  `nightscoutUploadEnabled` `SettingsCatalog.swift` descriptor are all deleted.
- `AppSettings.swift`'s `nightscoutUploadEnabled` property + its UserDefaults key are LEFT IN
  PLACE as a hidden, unregistered device-local flag (no `SettingsCatalog` row, no
  `backupSnapshot`/`applyBackup` participation) — same hidden-flag pattern as
  `watchBolusEnabled`/`requireRemoteBolusApproval`. No migration was performed or is needed.
- `AppModel.swift` stayed byte-identical throughout (verified via
  `./scripts/check-dose-byte-identity.sh`, which diffs THIS branch against `main` and reports
  identical dose/signed core bytes even after the removal — the stub, not an `AppModel.swift`
  edit, is what keeps the frozen closure type-checking).

**⚠ Un-stubbing is the load-bearing difference from every prior `dev/*` branch.** Nightscout's
`AppModel.swift` call sites (`:1799` upload, `:1420-1436` backfill) are UNGATED (no `#if`) —
unlike HealthKit's `#if FABOLUS_HEALTHKIT`-guarded call sites, which compile out cleanly once the
flag is gone. Reintegrating this branch's real implementation means **deleting `main`'s
`NightscoutStub.swift` and restoring the 3 real files from this branch in its place** — not merely
flipping a compile flag, and not merely dropping the real files back in alongside the stub (the
stub + the real types in the same build collide on the `NightscoutUploader`/`NightscoutBackfill`
symbol names — exactly the duplicate-symbol hazard Plan 02's single-commit swap was designed to
avoid on the removal side).

## Reintegration steps

1. **Delete `main`'s Nightscout stub**: `git rm ios/faBolus/Data/Sources/NightscoutStub.swift`.
   Its `NightscoutUploader`/`NightscoutBackfill` symbols must be gone before the real ones are
   restored, or the build fails on a duplicate-symbol/redeclaration error.
2. **Restore the 3 real Nightscout source files** from this branch into `main`:
   `ios/faBolus/Data/Sources/NightscoutSource.swift`,
   `ios/faBolus/Data/Sources/NightscoutUploader.swift`,
   `ios/faBolus/Data/Sources/NightscoutBackfill.swift`.
3. **Restore the `nightscout` `GlucoseSourceRegistry` descriptor** and the Nightscout config
   section(s)/rows in `ios/faBolus/Views/CgmCredentialsView.swift` /
   `ios/faBolus/Views/CgmStatusView.swift` / `ios/faBolus/Views/SettingsView.swift` /
   `ios/faBolus/Data/SettingsCatalog.swift` — see this branch's pre-removal copies of each file for
   the shape; re-derive against whatever `main` looks like at reintegration time rather than
   pasting back verbatim, since work since Plan 02 will have moved the surrounding source.
4. **Restore or re-derive the Nightscout-specific test coverage** removed/edited by Plan 02:
   - `CgmSourceValidationTests.swift`'s two deleted Nightscout malformed-URL test methods
     (`nightscoutMalformedURLThrowsInsteadOfTrapping`,
     `nightscoutBackfillMalformedURLThrowsInsteadOfTrapping`) — restore from this branch.
   - `CgmShareOnlyBoundaryTests.swift`'s `registryContainsOnlyDexcomShare` (renamed from
     `registryContainsOnlyShareAndNightscout` by Plan 02) needs `"nightscout"` added back to its
     expected set (and possibly reverting the rename, at the reintegrator's discretion).
   - `CgmConnectionKindTests.swift`'s classification-table `"nightscout": .cloudPoll` entry.
   - `NightscoutStubInertnessTests.swift` (added by Plan 02) should be deleted — it pins the STUB's
     inertness, which no longer applies once the real implementation is restored.
   - `SettingsCatalogTests.swift`: remove `"nightscout"` from `gatedOffSearchTokens` and recompute
     `descriptors.count`/`backedUpKeys.count` empirically (adding the `nightscoutUploadEnabled`
     descriptor back increases both by 1 from Plan 02's post-removal baseline).
   - `AppSettings.swift`: re-add `nightscoutUploadEnabled` to `backupSnapshot()`/`applyBackup()`.
   Re-derive rather than paste verbatim in every case above.
5. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`) plus
   `./scripts/check-dose-byte-identity.sh` (confirms `AppModel.swift`'s frozen call sites still
   type-check against the restored real types with byte-identical source) and a fresh repo-wide
   grep for `NightscoutStub`/`nightscout` to confirm no dangling stub reference or orphaned
   §6c entry was missed.

`AppModel.swift`'s two frozen Nightscout call sites (`:1799`, `:1420-1436`) themselves are NEVER
edited by this reintegration — restoring the real types makes the frozen closure's `r.carbs`/
`r.insulin` reads and the `NightscoutUploader.shared.sync(...)` call resolve to the real
implementation again, with zero change to `AppModel.swift`'s bytes (D-02/D-04).
