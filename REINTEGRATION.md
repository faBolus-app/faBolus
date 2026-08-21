# REINTEGRATION.md — dev/nightscout

## Feature preserved

Nightscout source + upload + backfill (Phase 5, HEALTH-02): the glucose-polling
`ios/faBolus/Data/Sources/NightscoutSource.swift`, the upload client
`ios/faBolus/Data/Sources/NightscoutUploader.swift` (fires `AppModel.swift:1799`'s frozen
`NightscoutUploader.shared.sync(...)` call), and the backfill client
`ios/faBolus/Data/Sources/NightscoutBackfill.swift` (fires `AppModel.swift:1420-1436`'s frozen
`maybeBackfillNightscout()` call via `NightscoutBackfill.fetch(...)`).

## State at removal

This branch was cut from `main`'s pristine pre-deletion tip during Phase 5 Plan 01 (Task 1),
BEFORE any Nightscout removal work landed — Phase 5 Plan 01 only removes HealthKit (HEALTH-01);
Nightscout removal (HEALTH-02) is Phase 5 Plan 02's job. At the moment this branch was cut, `main`
still carries the full, real Nightscout implementation (`NightscoutSource.swift`,
`NightscoutUploader.swift`, `NightscoutBackfill.swift`), unstubbed. This branch therefore currently
holds the SAME tree as `main` for the Nightscout surface — it will diverge once Plan 02 executes
its removal.

**⚠ Un-stubbing is the load-bearing difference from every prior `dev/*` branch.** Nightscout's
`AppModel.swift` call sites (`:1799` upload, `:1420-1436` backfill) are UNGATED (no `#if`) —
unlike HealthKit's `#if FABOLUS_HEALTHKIT`-guarded call sites, which compile out cleanly once the
flag is gone. Removing the 3 real Nightscout source files from `main` therefore requires Plan 02
to author a minimal typed no-op stub (`NightscoutUploader`/`NightscoutBackfill` types reproducing
the exact frozen call-site contracts) so `AppModel.swift` stays byte-identical while still
type-checking. Reintegrating this branch's real implementation means **deleting that `main`-only
stub file and restoring these 3 real files in its place** — not merely flipping a compile flag, and
not merely dropping files back in alongside the stub (a stub + the real types in the same build
would collide on the `NightscoutUploader`/`NightscoutBackfill` symbol names).

## Reintegration steps

1. **Identify and delete the `main`-only Nightscout stub** (Plan 02 names it, e.g.
   `ios/faBolus/Data/Sources/NightscoutStub.swift` — confirm the actual filename in `main`'s tree at
   reintegration time; it exists ONLY on `main`, never on this branch) — its
   `NightscoutUploader`/`NightscoutBackfill` symbols must be gone before the real ones are restored,
   or the build fails on a duplicate-symbol/redeclaration error.
2. **Restore the 3 real Nightscout source files** from this branch into `main`:
   `ios/faBolus/Data/Sources/NightscoutSource.swift`,
   `ios/faBolus/Data/Sources/NightscoutUploader.swift`,
   `ios/faBolus/Data/Sources/NightscoutBackfill.swift`.
3. **Restore the `nightscout` `GlucoseSourceRegistry` descriptor** and the Nightscout config
   section(s)/rows in `ios/faBolus/Views/CgmCredentialsView.swift` /
   `ios/faBolus/Views/CgmStatusView.swift` / `ios/faBolus/Views/SettingsView.swift` /
   `ios/faBolus/Data/SettingsCatalog.swift` — see this branch's copies of each file for the
   pre-removal shape; re-derive against whatever `main` looks like at reintegration time rather
   than pasting back verbatim, since Plan 02's own removal edits (and any work since) will have
   moved the surrounding source.
4. **Restore or re-derive the Nightscout-specific test coverage** removed/edited by Plan 02
   (`CgmSourceValidationTests.swift`'s two Nightscout test methods,
   `CgmShareOnlyBoundaryTests.swift`'s registry-contents assertion,
   `CgmConnectionKindTests.swift`'s classification-table entry) from this branch's pre-removal
   copies — re-derive rather than paste verbatim.
5. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`) plus
   `./scripts/check-dose-byte-identity.sh` (confirms `AppModel.swift`'s frozen call sites still
   type-check against the restored real types with byte-identical source) and a fresh repo-wide
   grep for `NightscoutStub`/`nightscout` to confirm no dangling stub reference or orphaned
   §6c entry was missed.

`AppModel.swift`'s two frozen Nightscout call sites (`:1799`, `:1420-1436`) themselves are NEVER
edited by this reintegration — restoring the real types makes the frozen closure's `r.carbs`/
`r.insulin` reads and the `NightscoutUploader.shared.sync(...)` call resolve to the real
implementation again, with zero change to `AppModel.swift`'s bytes (D-02/D-04).
