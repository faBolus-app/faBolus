# REINTEGRATION.md — dev/watch-host

## Feature preserved

Apple-Watch-as-host / direct-to-pump (Phase 3, REMOTE-04): `watch/faBolusWatch/direct-pump/`,
gated behind `FABOLUS_WATCH_DIRECT_PUMP` (already authored, default-OFF, Phase 0). This is a
**second pump-connection holder** that bypasses the normal `PumpBackend` ownership path.

## State at removal

Not yet touched — Phase 3 (REMOTE-04) has not executed as of this writing. This branch carries the
full pre-narrow tree, identical to `pre-narrow/2026-08-20`; nothing has diverged here yet. This
REINTEGRATION.md is being authored ahead of Phase 3 per CLEAN-02.

`FABOLUS_WATCH_DIRECT_PUMP` is bench-only and explicitly violates the "C9: one owner, N remotes"
architectural invariant when enabled — it must never be a build a person actually wears, only a
bench-testing configuration.

## Reintegration steps

Moderate-to-high complexity — this is not a simple file restore because a second pump-connection
holder has direct architectural implications beyond its own files:

1. Restore/flip the `FABOLUS_WATCH_DIRECT_PUMP` gate and the `watch/faBolusWatch/direct-pump/`
   source tree (check whether Phase 3 physically deleted the files or merely kept the exclude gate
   — follow whichever shape Phase 3 actually used at reintegration time).
2. **Re-confirm the C9 eviction behavior** — with two pump-connection holders active
   (the normal `PumpBackend` path and this direct-to-pump watch path), the eviction/ownership
   handoff logic must still correctly enforce single ownership. This is the single most important
   re-verification step for this branch; do not treat a clean compile as sufficient.
3. Confirm this remains bench-only and default-OFF on any build that will be worn or distributed —
   this is a deliberate constraint on distribution, not just a compile-time default.
4. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`); these files are not part of
   `DOSE_PATHS`, so no dose-set stub/un-stub is expected, but the C9 eviction re-check above is
   the functional equivalent of a boundary-suite re-run for this specific surface.
