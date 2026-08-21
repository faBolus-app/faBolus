# REINTEGRATION.md — dev/mac

## Feature preserved

The Mac menu-bar remote (Phase 3, REMOTE-01): the `faBolusMac`/`faBolusMacWidgets` targets and
`MacRemoteAuthStore`, gated behind a whole-target `FABOLUS_MAC` `strip_block` fence in
`project.yml`/`generate-project.sh` (already authored, Phase 0).

## State at removal

Not yet touched — Phase 3 (REMOTE-01) has not executed as of this writing. This branch carries the
full pre-narrow tree, identical to `pre-narrow/2026-08-20`; nothing has diverged here yet. This
REINTEGRATION.md is being authored ahead of Phase 3 per CLEAN-02, so every `dev/<surface>` branch
is self-documenting from the start of the narrow-main milestone.

## Reintegration steps

The `FABOLUS_MAC` gate is a **whole-target** strip (an entire Xcode target, not standalone source
files), which per Phase 2.5's D-02(a) distinction is the class of removal that stays
`strip_block`-gated in `project.yml` rather than becoming a `git rm` of individual files — so
reintegration is expected to be low-complexity relative to the other branches:

1. Flip `FABOLUS_MAC` back to `1` (or restore the target block if Phase 3 went further and deleted
   the target declaration outright — check `project.yml` at reintegration time for which shape
   Phase 3 actually used, since D-02(a)'s "keep for whole-target/package blocks" guidance may or
   may not have been followed exactly as anticipated here).
2. Restore the `faBolusMac`/`faBolusMacWidgets` target source directories if they were physically
   removed from `main` (rather than merely excluded) — compare this branch's `mac/` tree against
   `main`'s at reintegration time to find any deleted files.
3. Restore `MacRemoteAuthStore` and re-verify its interaction with the shared remote-auth surface
   (check for any dose-adjacent boundary tests introduced between Phase 0 and reintegration time).
4. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`); this target is not part of
   `DOSE_PATHS`, so no dose-set stub/un-stub is expected, but re-verify against Phase 3's actual
   implementation when it lands.
