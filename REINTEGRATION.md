# REINTEGRATION.md — dev/watch-host

## What it is

Apple-Watch-as-host / direct-to-pump (Phase 3, REMOTE-04): `watch/faBolusWatch/direct-pump/` (5
Swift files + `STATUS.md`), gated `FABOLUS_WATCH_DIRECT_PUMP=0` by default (Phase 0, pre-existing,
mature gate). `WatchPumpClient` is a SECOND pump-connection holder that drives `PumpBLEClient`
directly, bypassing the `PumpBackend` seam entirely — none of the safety machinery the seam exists to
enforce (the central therapy gate, the durable idempotency ledger, the delivery-outcome state
machine, the cross-client mutex) applies to anything it does. Pairing it evicts the phone's pairing
(the pump keeps one pairing at a time), which on a Mobi means the charging base is needed to recover.
Same posture as `faBolusGarmin/direct-pump/` (bench-only, never shipped, never worn).

**Relationship to `dev/watch-remote`:** this subtree lived INSIDE `watch/faBolusWatch/` (the Watch
remote app's own directory) but is a functionally and architecturally distinct concern from the
remote app itself — it was excluded from the remote app's own sources via the
`WATCH_DIRECT_PUMP_OFF` block even before this removal. REMOTE-03 (the remote app) and REMOTE-04 (this
direct-pump subtree) were removed together, in the same commit, as part of the same whole-target
deletion — but are preserved on SEPARATE branches (`dev/watch-remote` vs. this one) matching the
phase's own topology (`00-02`'s sub-branch cut).

## State at removal

Phase 3 Plan 03 (03-03) executed the removal in the SAME two commits as `dev/watch-remote` (see that
branch's `REINTEGRATION.md` "State at removal" for the full `project.yml`/`generate-project.sh`
cascade retirement — the `WATCH_DIRECT_PUMP`/`WATCH_DIRECT_PUMP_OFF` blocks lived INSIDE the
now-deleted `faBolusWatch` target-def body and disappeared with it, requiring NO separate
`strip_block` call and sidestepping the word-boundary hazard (D-06) that motivated `strip_block`'s
anchored-match fix in the first place — see `scripts/generate-project.sh`'s own historical comment on
that fix). `watch/faBolusWatch/direct-pump/` was `git rm`'d as part of the same `git rm -r
watch/faBolusWatch` that removed the whole remote-app tree (Task 2's single commit), then split onto
this separate preservation branch.

REMOTE-04 was confirmed a PURE deletion with zero dose-set coupling (D-07) before finishing: `grep -rnE
'WatchPumpClient|FABOLUS_WATCH_DIRECT_PUMP' ios/faBolus/Data/AppModel.swift
ios/faBolus/Data/TandemBackend.swift Packages/faBolusCore` returns only two doc-comment lines in the
frozen `Packages/faBolusCore/Sources/faBolusCore/WatchSelfDiagnostics.swift` (never edited — it is
part of the byte-identity-protected dose set) — no real `AppModel`/`TandemBackend`/`faBolusCore`
coupling exists or ever existed. No dose-set stub was added for REMOTE-04 (unlike some other Phase-3
surfaces) — there was nothing on the dose-set side to stub against.

A real `./scripts/generate-project.sh` + `xcodebuild build` + `./scripts/check-dose-byte-identity.sh`
all passed green after removal.

`ios/faBolusAppTests/WatchDirectBleScopeGuardTests.swift` (the scope guard pinning that
`direct-pump/WatchPumpClient.swift`'s BLE stack never leaks into `WatchDebugView.swift` outside the
gated directory) was DELETED outright in 03-03's Task 3 (not neutered into a vacuous pass — Pitfall
G) and is preserved here, since it pins paths exclusively inside this subtree.

## Reintegration steps

Moderate-to-high complexity — this is not a simple file restore because a second pump-connection
holder has direct architectural implications beyond its own files:

1. **Target defs to re-add first** — this subtree cannot be restored alone; it depends on the
   `faBolusWatch` target existing at all. Reintegrate `dev/watch-remote` first (its `REINTEGRATION.md`
   has the full `project.yml`/`generate-project.sh` steps), THEN layer this subtree back in.
2. **Restore the subtree + its own gate** — copy `watch/faBolusWatch/direct-pump/` back from this
   branch (`git checkout dev/watch-host -- watch/faBolusWatch/direct-pump`), restore the
   `WATCH_DIRECT_PUMP_OFF` block (excludes `direct-pump` from the target's sources unless
   `FABOLUS_WATCH_DIRECT_PUMP=1`) inside the `faBolusWatch` target-def's `sources:` list, restore the
   `WATCH_DIRECT_PUMP` block (the `TandemMessages`/`TandemAuth`/`TandemBLE` dependencies + the
   `WKBackgroundModes`/entitlement pieces, if any) inside its `dependencies:`/`settings:`, and restore
   the `FABOLUS_ONWATCH_EATING`/`FABOLUS_WATCH_DIRECT_PUMP` pair in the target's own
   `SWIFT_ACTIVE_COMPILATION_CONDITIONS`. In `scripts/generate-project.sh`, restore
   `DIRECT_PUMP="${FABOLUS_WATCH_DIRECT_PUMP:-0}"` (+ `[ "$WATCH" = 0 ] && DIRECT_PUMP=0`) and the
   `if [ "$DIRECT_PUMP" = 0 ]; then strip_block WATCH_DIRECT_PUMP; drop_flag
   FABOLUS_WATCH_DIRECT_PUMP; else strip_block WATCH_DIRECT_PUMP_OFF; fi` conditional — use the
   ANCHORED `strip_block` (word-boundary match) from the CURRENT script, not a naive re-add, since the
   whole reason this hazard (D-06) existed is a bare-substring `strip_block WATCH_DIRECT_PUMP` also
   matching `# >>> WATCH_DIRECT_PUMP_OFF`.
3. **Re-confirm the C9 eviction behavior** — with two pump-connection holders active (the normal
   `PumpBackend` path and this direct-to-pump watch path), the eviction/ownership handoff logic must
   still correctly enforce single ownership. This is the single most important re-verification step
   for this branch; do not treat a clean compile as sufficient.
4. **Restore the test** — `ios/faBolusAppTests/WatchDirectBleScopeGuardTests.swift` from this branch.
5. Confirm this remains bench-only and default-OFF (`FABOLUS_WATCH_DIRECT_PUMP=0`) on any build that
   will be worn or distributed — this is a deliberate constraint on distribution, not just a
   compile-time default. See `direct-pump/STATUS.md` (preserved here) for the full C9 rationale.
6. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`); these files are not part of the dose/signed
   set, so no dose-set stub/un-stub is expected, but the C9 eviction re-check above is the functional
   equivalent of a boundary-suite re-run for this specific surface. Also re-run
   `./scripts/check-dose-byte-identity.sh` — reintegrating this subtree must not touch it.
