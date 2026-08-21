# REINTEGRATION.md — dev/cgm-extra

## Feature preserved

Dexcom G6 and G7 direct-BLE CGM sources, LibreLinkUp, and the xDrip App-Group failover source
(CGM-02..05): `ios/faBolus/Data/Sources/DexcomG6BLESource.swift`,
`Shared/DexcomG7BLESource.swift`, `ios/faBolus/Data/Sources/LibreLinkUpSource.swift`, and
`ios/faBolus/Data/Sources/XDripAppGroupSource.swift`, plus their `GlucoseSourceRegistry`
descriptors, their `project.yml`/`generate-project.sh` package-dependency machinery
(`DexcomG6Kit`, `G7SensorKit`), and the presence-guard test suites that used to pin them on
`main` (`DexcomG6BLESourceTests.swift`, `DexcomG6CopyGuardTests.swift`,
`DexcomG6ScopeGuardTests.swift`, `DexcomG6RestoreIdentifierTests.swift`,
`DexcomG7BLESourceTests.swift`, `DexcomG7RestoreIdentifierTests.swift`).

## State at removal

This branch is the **only** `dev/<surface>` branch that has actively diverged from `main` so
far — `main` has removed what this branch preserves, in two steps:

- **Phase 1** (CGM-02..05): removed all 4 sources from the *narrow build* via `GlucoseSourceRegistry`
  deletion + `APP_SOURCE_EXCLUDES`/`project.yml` file-exclude gates (`FABOLUS_CGM_G6`,
  `FABOLUS_CGM_G7`, `FABOLUS_CGM_LIBRELINKUP`, `FABOLUS_CGM_XDRIP`, all default `0`), and deleted
  the presence-guard test files outright. The 4 source files themselves still physically existed
  on `main`'s tree at that point, merely excluded from compilation.
- **Phase 2.5** (CLEAN-01/03, this phase's sibling plan): `git rm`'d all 4 source files from
  `main` outright, plus retired the now-dead `FABOLUS_CGM_G6`/`FABOLUS_CGM_LIBRELINKUP`/
  `FABOLUS_CGM_XDRIP`/`FABOLUS_CGM_G7` gate machinery from `generate-project.sh`/`project.yml`
  (the `DexcomG6Kit`/`G7SensorKit` package *declarations* themselves were left in place per
  D-02(a) — only the app-target dependency edges + file excludes were retired), and removed the
  now-dead `LoopAppGroupIdentifier`/`TrioAppGroupIdentifier` Info.plist properties (their only
  reader, `XDripAppGroupSource.swift`, was gone).

This branch (`dev/cgm-extra`) has never diverged from the `pre-narrow/2026-08-20` tip — it still
holds the full, all-4-sources, all-guard-tests tree exactly as it stood before Phase 1 ran.

## Reintegration steps (POST-Phase-2.5 shape — read this, not the old gate-flip)

**Before Phase 2.5, "bring these sources back" meant "flip `FABOLUS_CGM_*=1`."** That mechanism
no longer restores anything, because the files themselves are gone from `main`'s tree, not merely
excluded from compilation. Do NOT attempt a bare gate-flip as the reintegration method. The
correct, heavier, post-Phase-2.5 path is:

1. **Cherry-pick or copy the 4 source files back** from this branch into `main`:
   `ios/faBolus/Data/Sources/DexcomG6BLESource.swift`, `Shared/DexcomG7BLESource.swift`,
   `ios/faBolus/Data/Sources/LibreLinkUpSource.swift`,
   `ios/faBolus/Data/Sources/XDripAppGroupSource.swift`.
2. **Restore the `GlucoseSourceRegistry` descriptors** for whichever sources are being
   reintroduced (see this branch's `ios/faBolus/Data/GlucoseSourceRegistry.swift` for the
   pre-removal descriptor shape).
3. **Restore the `project.yml` package-dependency fences** (`CGM_G6_KIT`/`CGM_G7_KIT` target
   `dependencies:` entries — the package declarations were never removed from `main`, only the
   app-target's dependency edge to them) and re-add file-exclude-shaped `generate-project.sh`
   gates if a default-off toggle is still wanted during reintegration (or land the sources
   unconditionally if the feature is graduating straight to shipped).
4. **Restore or rewrite the Phase-1-deleted presence-guard tests** — they no longer exist on
   `main` at all (not merely inverted); this branch's copies are the reference implementation,
   but re-derive them against whatever `main` looks like at reintegration time rather than
   pasting them back verbatim, since the surrounding registry/test scaffolding may have moved on.
5. **Restore the `LoopAppGroupIdentifier`/`TrioAppGroupIdentifier` Info.plist `info.properties`**
   in `project.yml` if `XDripAppGroupSource` is part of the reintroduced set, then re-run
   `xcodegen generate` so the tracked `ios/faBolus/Info.plist` picks the keys back up.
6. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`) plus a fresh repo-wide grep for the 4
   type names to confirm no other dangling reference was missed.

None of the 4 files are dose-adjacent (`scripts/check-dose-byte-identity.sh`'s `DOSE_PATHS` does
not cover any of them or their containing directories), so reintegration never requires a dose-set
stub/frozen-wire-field un-stub — that concern is specific to `dev/backup` (see its own
REINTEGRATION.md), not this branch.
