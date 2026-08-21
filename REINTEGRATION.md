# REINTEGRATION.md — dev/nudge

## Feature preserved

faBolusNudge / Smart Assist (Phase 4, NUDGE-01): the eating-detection nudge pipeline and the
Smart Assist bolus-warning submenu, gated behind `#if FABOLUS_NUDGE` / `FABOLUS_NUDGE`, including
the SPM package dependency on the `faBolusNudge` package and the Smart Assist submenu split across
HR-context, SiteAtlas, GraphDetail, Retrospective, and FoodFinder surfaces.

Both eating nudges and Smart Assist bolus warnings are also flagged in `BRANCHES.md` §1.2 as
belonging on `experimental` rather than `main` once classification is enforced (they fire on a
detector threshold / automate a judgement about a proposed dose) — reintegration onto `main`
should re-check that classification still holds at the time of reintegration.

## State at removal

Not yet touched — Phase 4 (NUDGE-01) has not executed as of this writing. This branch carries the
full pre-narrow tree, identical to `pre-narrow/2026-08-20`; nothing has diverged here yet. This
REINTEGRATION.md is being authored ahead of Phase 4 per CLEAN-02, so every `dev/<surface>` branch
is self-documenting from the start of the narrow-main milestone, not only after its surface is
actually removed.

## Reintegration steps

Exact steps are Phase 4's to determine when it runs (this branch has not diverged, so there is no
Phase-4-specific removal shape to describe yet). Expected shape, based on the existing
`FABOLUS_NUDGE` gate and `dev/<surface>` convention established by Phase 0/1:

1. Restore the SPM package-dependency fence (`FABOLUS_NUDGE`-gated `faBolusNudge` package
   declaration + target dependency edge) in `project.yml`/`generate-project.sh`, following the
   same file-exclude-vs-package-block distinction Phase 2.5 established (D-02): whole-package/
   whole-target removals stay `strip_block`-gated project.yml-shape blocks, not deleted files.
2. Restore the Smart Assist submenu UI split — this is cross-cutting across HR-context,
   SiteAtlas, GraphDetail, Retrospective, and FoodFinder, so reintegration will touch multiple
   view files, not a single self-contained source tree; check each for its own `FABOLUS_NUDGE`
   conditional at reintegration time.
3. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`) and confirm the byte-identity check
   stays green (`faBolusNudge` is not on `DOSE_PATHS`, so no dose-set stub/un-stub should be
   needed for this branch — but re-verify against Phase 4's actual removal shape when it lands,
   since that shape is not yet known).
4. If Phase 4's removal used `git rm` (deleted files) rather than a pure gate flip, this branch's
   note should be updated at that time to describe the post-removal cherry-pick path the same way
   `dev/cgm-extra`'s note does, rather than a bare gate-flip instruction.
