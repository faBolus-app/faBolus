# REINTEGRATION.md — dev/watch-remote

## Feature preserved

Apple-Watch-as-remote (Phase 3, REMOTE-03): the watch app and its complication, gated behind the
existing, mature `FABOLUS_WATCH` gate (predates the v0.5.0 narrow-main milestone).

## State at removal

Not yet touched — Phase 3 (REMOTE-03) has not executed as of this writing. This branch carries the
full pre-narrow tree, identical to `pre-narrow/2026-08-20`; nothing has diverged here yet. This
REINTEGRATION.md is being authored ahead of Phase 3 per CLEAN-02.

## Reintegration steps

Low-to-moderate complexity — `FABOLUS_WATCH` is an existing, mature gate that predates this
milestone, so this is the most straightforward reintegration among the Phase-3 surfaces:

1. Flip `FABOLUS_WATCH` back to `1` (or restore the target/source tree if Phase 3 physically
   deleted files rather than keeping the existing gate — check `project.yml`/
   `generate-project.sh` at reintegration time for which shape was actually used).
2. Restore the watch-app re-embed into the iOS host target and the complication registration.
3. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`); this surface is not part of
   `DOSE_PATHS`, so no dose-set stub/un-stub is expected, but re-verify against Phase 3's actual
   removal shape when it lands.
