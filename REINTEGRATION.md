# REINTEGRATION.md — dev/watch-remote

## What it is

Apple-Watch-as-remote (Phase 3, REMOTE-03): the `faBolusWatch`/`faBolusWatchWidgets` Xcode targets
(`watch/faBolusWatch/**`, `watch/faBolusWatchWidgets/**`, `watch/README.md` — 27 tracked files: app
sources, the glucose-complication widget extension, entitlements, Info.plist, asset catalogs), plus
the `project.yml` fenced `# >>> WATCH ... # <<< WATCH` embed block, both unfenced target-def bodies,
the `WatchCI` scheme, and the `FABOLUS_WATCH`/`WATCH_EMBEDDED` gate machinery in
`scripts/generate-project.sh` that used to strip them at `FABOLUS_WATCH=0`. It never touched the pump
directly: it relayed bolus requests to the iPhone host over WatchConnectivity (`RemoteLink`) and the
phone confirmed and delivered. The watch app also carried a passive Dexcom G7/ONE+ direct-BLE
failover (unrelated to this removal's dose path — no dose-set coupling).

**Not preserved here (preserved on `dev/watch-host` instead):** `watch/faBolusWatch/direct-pump/`
(the Apple-Watch-as-host / direct-to-pump subtree, REMOTE-04) — a second pump-connection holder that
bypasses the `PumpBackend` seam, gated `FABOLUS_WATCH_DIRECT_PUMP=0` by default. It shares the
`watch/faBolusWatch/` parent directory with the remote app above but is a functionally distinct,
architecturally separate concern (constraint C9, "one owner, N remotes") — split onto its own
preservation branch per the phase's own topology.

**Not preserved here (still live on `main`):** `Shared/RemoteClientModel.swift`'s superclass logic —
the type itself was moved into `watch/faBolusWatch/RemoteClientModel.swift` by 03-02 (since
`WatchModel: RemoteClientModel` needed it live until this plan removed the whole Watch target) and IS
preserved here as part of the tree above. `PhoneRemoteHost.swift` (the shared
Garmin/widget-adjacent WatchConnectivity receiver core) stays on `main` — it now serves the Garmin
remote and the Quick-Bolus widget only, and is producer-less on the watch side (expected, harmless).

## State at removal

Phase 3 Plan 03 (03-03) executed the removal in two commits on `main`:

1. **Gate retirement** — deleted BY HAND both unfenced watch target-def bodies (`faBolusWatch`,
   `faBolusWatchWidgets`) from `project.yml`, the fenced `# >>> WATCH ... # <<< WATCH` embed block,
   the `faBolusWatch: all` `WatchCI` scheme (now orphaned once the target was gone), and dropped
   `WATCH_EMBEDDED` from both `SWIFT_ACTIVE_COMPILATION_CONDITIONS` lines. In
   `scripts/generate-project.sh`, retired the `WATCH` gate var, the `ONWATCH`/`DIRECT_PUMP`
   derivations, the `WATCH` strip + `WATCH_EMBEDDED` sed, the `ONWATCH_EATING`/`WATCH_DIRECT_PUMP`/
   `_OFF` strip logic, and the watch-related summary/diagnostic echoes — no dangling `$WATCH`
   reference survives under `set -euo pipefail`. No `WATCH_DIRECT_PUMP` strip_block was introduced
   (the whole target was deleted outright, sidestepping the word-boundary hazard entirely — see
   `03-RESEARCH.md`'s Pitfall/D-06). Rule-3 fixed the now-orphaned `ci.yml` `watch-build` job (built
   via the deleted `WatchCI` scheme) and several stale-doc dangling refs (`README.md`,
   `docs/architecture.md`, `.github/pull_request_template.md`, `scripts/build-sim.sh`/`test-ios.sh`
   comments, two `WIP-REGISTER.md` entries) — see `03-03-SUMMARY.md`'s Deviations section.
2. **Tree deletion** — `git rm -r`'d `watch/faBolusWatch/` (including the `direct-pump/` subtree,
   REMOTE-04 — preserved separately on `dev/watch-host`, not here), `watch/faBolusWatchWidgets/`, and
   the now-orphaned `watch/README.md` from `main` outright (delete-on-main; the gate was already
   retired in step 1, so there was nothing left to gate). Fixed two out-of-scope pre-existing stale
   file-path pins directly broken by this removal (`BandDriftGuardTests.swift`'s `WatchChartView.swift`
   pin, `GlucoseStatusGlyphGuardTests.swift`'s `WatchHUDView.swift`/`GlucoseComplication.swift` pins +
   its "6 pinned surfaces" count assertions, now 4) and a stale doc comment in
   `ios/faBolusAppTests/Support/RemoteCommandWireFixture.swift`.

A real `./scripts/generate-project.sh` + `xcodebuild build` + `./scripts/check-dose-byte-identity.sh`
all passed green after both steps — the dose/signed core (`Packages/faBolusCore`, `AppModel.swift`,
`TandemBackend.swift`) was never touched. The zero-coupling grep for `WatchPumpClient`/
`FABOLUS_WATCH_DIRECT_PUMP` across `AppModel.swift`/`TandemBackend.swift`/`Packages/faBolusCore`
returns only the frozen `WatchSelfDiagnostics.swift` doc-comment mentions (never touched — it is part
of the byte-identity-protected dose set).

**Standard companion-app removal note (03-RESEARCH.md "Runtime State Inventory"):** the Apple Watch
app installs via `WKCompanionAppBundleIdentifier` — once `faBolusWatch` was dropped from the phone's
embed list, a device that already had the watch app installed will have it silently removed by
watchOS on its next sync. This is standard OS companion-app behavior, not a faBolus-specific
migration concern; no script/task exists (or is needed) to write for it.

## How to reintegrate

1. **Target defs to re-add** — restore both unfenced target-def bodies (`faBolusWatch`,
   `faBolusWatchWidgets`) in `project.yml` from this branch's copy (the reference shape as of
   removal), restore the `# >>> WATCH ... # <<< WATCH` embed block on the `faBolus` app target, and
   restore the `WatchCI` scheme. Re-add `WATCH_EMBEDDED` to both `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
   lines.
2. **`WATCH`/`WATCH_EMBEDDED` cascade to restore** — in `scripts/generate-project.sh`, restore the
   `WATCH="${FABOLUS_WATCH:-1}"` gate var, the `ONWATCH`/`DIRECT_PUMP` derivations (`[ "$WATCH" = 0 ]
   && ONWATCH=0` etc. — note `DIRECT_PUMP` also needs `dev/watch-host` reintegrated, or hardcode it to
   `0` if only the remote app/complication is being restored), the `if [ "$WATCH" = 0 ]; then
   strip_block WATCH; sed ... WATCH_EMBEDDED; fi` conditional, and the watch summary/diagnostic
   echoes — this branch's pre-removal copy of the script is the reference shape.
3. **Tree to restore** — copy `watch/faBolusWatch/` (all files EXCEPT `direct-pump/` unless
   `dev/watch-host` is also being reintegrated), `watch/faBolusWatchWidgets/`, and `watch/README.md`
   back onto `main` from this branch (`git checkout dev/watch-remote -- watch/faBolusWatch
   watch/faBolusWatchWidgets watch/README.md` or an equivalent cherry-pick, then `git rm -r
   watch/faBolusWatch/direct-pump` if `dev/watch-host` is not also being restored).
4. **Tests to restore** — `ios/faBolusAppTests/WatchDirectBleScopeGuardTests.swift` and
   `WatchDiagnosticsOverWCTests.swift` were deleted (not neutered) in 03-03's Task 3, preserved on this
   branch (WatchDiagnosticsOverWCTests) / `dev/watch-host` (the direct-BLE scope guard, since it pins
   `direct-pump/WatchPumpClient.swift`) — restore whichever matches what you're reintegrating. Restore
   the `BandDriftGuardTests.swift`/`GlucoseStatusGlyphGuardTests.swift` pins this branch's pre-removal
   copies show (`WatchChartView.swift`, `WatchHUDView.swift`, `GlucoseComplication.swift`) and bump
   `GlucoseStatusGlyphGuardTests`' pinned-surface count back to 6 (or higher, if Mac is also
   restored). Re-register the `watchBolusEnabled` `SettingsCatalog` descriptor (hidden-flag-to-live
   reversal — see step 5) and remove its `gatedOffSearchTokens` entry in `SettingsCatalogTests.swift`.
5. **`watchBolusEnabled` settings descriptor** — 03-03's Task 3 demoted `watchBolusEnabled` to a
   hidden/unregistered `AppSettings` flag (accessor kept, `SettingsCatalog` row removed) — the five
   Garmin-shared descriptors (`watchDefaultBolusMode`/`watchBolusIncrement`/`watchCarbIncrement`/
   `watchDetailsOrder`/`watchChartRanges`) and the small-screen plot pair
   (`glucosePlotFloorSmall`/`glucosePlotCeilingSmall`) were NEVER hidden (they are Garmin-shared,
   Pitfall E) and need no reintegration. Re-add ONLY the `watchBolusEnabled` descriptor row.
6. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`): tag currency, dose/signed byte-identity,
   green main + full safety suite, schema drift, no-dangling-refs. Re-verify the standard companion-app
   install/removal behavior on-device (not exercised by any CI script).
