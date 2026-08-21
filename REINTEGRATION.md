# REINTEGRATION.md — dev/backup

## Feature preserved

ALL backup/restore functionality (Phase 6, BACKUP-01): iCloud backup, `SettingsBackup`,
`PrivacyDataExport`, SiteAtlas backup, and `BackupRestoreView`.

## State at removal

This branch did not exist before Phase 2.5 (CLEAN-02) — it was created in this phase, cut from
`pre-narrow/2026-08-20` (the same pre-narrow tip every other `dev/<surface>` branch was cut from,
per `BRANCHES.md` §1.2b's TOPO-02 convention), NOT from current `main`, for topology consistency:
cutting from an already-narrowed `main` would risk the branch missing a surface `main` had already
removed by the time of the cut. Backup/restore code itself is untouched by every phase that has
run so far (Phases 1 and 2.5's own CGM/mechanism work), so this branch is presently tree-identical
to `pre-narrow/2026-08-20` and to `main` for the backup/restore surface specifically — Phase 6 has
not yet executed.

## Reintegration steps

**This is the FIRST `dev/<surface>` branch whose reintegration note must mention dose-set
stubs/frozen-wire-fields (D-04)** — the go-forward pattern this phase (2.5) establishes for later
phases. Per the phase-2.5 CONTEXT (D-04), when Phase 6 removes backup/restore code that is
entangled with dose-set files (`faBolusCore`, `AppModel.swift`, `TandemBackend.swift`), it is
expected to keep those dose files compilable via a minimal typed no-op **stub** of the referenced
type, or a **frozen wire-field** (e.g. a CIQ boolean in `RemoteCommand`/`AppModel` staying present
but frozen at its default) — rather than editing the dose file's actual behavior. This is the
"bites Phase 6 backup" case the Phase 2.5 CONTEXT explicitly calls out.

1. Check Phase 6's own removal-time documentation (authored when Phase 6 actually executes) for
   the exact list of stubs/frozen-wire-fields it introduced in the dose-set files. That
   documentation is the authoritative checklist — this note only flags that it will exist and
   must be followed, since Phase 6 has not run yet as of this writing.
2. **Un-stub each dose-set reference** identified above: replace the minimal no-op stub type (or
   un-freeze the frozen wire-field) with the restored backup/restore implementation from this
   branch, being careful to preserve `check-dose-byte-identity.sh`'s guarantee for
   `faBolusCore`/`AppModel.swift`/`TandemBackend.swift` — un-stubbing must not silently change
   dose *behavior* along the way; re-run the oracle/parity/`*DeliverInvariant`/boundary suites
   after un-stubbing, not just a compile check.
3. Restore the non-dose backup/restore files themselves (iCloud backup, `SettingsBackup`,
   `PrivacyDataExport`, SiteAtlas backup, `BackupRestoreView`) from this branch.
4. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`), paying particular attention to
   `check-dose-byte-identity.sh` — since this is the one branch whose reintegration deliberately
   touches dose-adjacent files (via the un-stub step), the byte-identity check is the primary
   safety backstop that the un-stubbing did not drift dose behavior.
