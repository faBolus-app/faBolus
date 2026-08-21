# REINTEGRATION.md — dev/mobi

## Feature preserved

Mobi pump support plus ALL advanced t:slim control at the capability-model level (Phase 9,
MOBI-01..04). `FABOLUS_MOBI` is currently a documented no-op placeholder gate (zero
`#if FABOLUS_MOBI` call sites exist anywhere on `main` as of this writing) — the real removal
shape has not been authored yet.

## State at removal

Not yet touched — Phase 9 has not executed and is deliberately sequenced **LAST** in the v0.5.0
narrow-main milestone (highest risk of all 8 surfaces). This branch carries the full pre-narrow
tree, identical to `pre-narrow/2026-08-20`; nothing has diverged here yet. This REINTEGRATION.md
is being authored ahead of Phase 9 per CLEAN-02.

## Reintegration steps

**This is the highest-complexity reintegration of all 8 `dev/<surface>` branches** — flagged
explicitly here so a future reintegrator does not underestimate it by analogy with the simpler
gate-flip branches (`dev/mac`, `dev/watch-remote`):

1. Mobi support is a `PumpModel` **capability-model** change, not a source-file-exclude or
   whole-target strip. It threads through dose-adjacent code: `faBolusCore`, `AccessPolicy`, and
   `GatedPumpWrite`. Reintegration is NOT a simple file restore or gate flip — it requires
   re-deriving how the capability model interacts with whatever `faBolusCore`/`AccessPolicy`/
   `GatedPumpWrite` look like on `main` at reintegration time (these are dose/signed-core paths
   under `scripts/check-dose-byte-identity.sh`'s `DOSE_PATHS`, so any restoration touching them
   must go through the same D-03/D-04 discipline as the original removal: byte-identity held,
   stubs/frozen-wire-fields un-stubbed carefully, not a direct copy-back).
2. **A full oracle/parity re-run is required on reintegration** — do not treat this as done until
   `swift test --package-path Packages/faBolusCore` (including `BolusMathParityTests`) and the
   TandemKit oracle byte-parity checks are re-confirmed green with Mobi support restored.
3. Cross-reference whatever Phase 9's own removal-time documentation says about the exact
   stub/frozen-field techniques it used (D-04) — that documentation, written when Phase 9 actually
   executes, is the authoritative un-stub checklist; this note only flags that the checklist will
   exist and must be followed precisely, not what it contains (Phase 9 hasn't run yet).
4. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`) after restoration, treating it as a
   full re-verification of dose behavior, not a mechanical smoke test.
