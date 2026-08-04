# watchOS direct-to-pump — PARKED, and excluded from shipping builds

**Status:** Phase 1 (pairing) written, **never tested on hardware**. Phase 2 (status polling + signed
delivery) not started. **Excluded from every build by default.**

**Do not enable this in a build anybody wears.**

## Why it is excluded

Constraint **C9** of `faBolus-handoff-v3.md` is *one owner, N remotes*: exactly one application holds
the pump connection, and every other surface is a remote that goes through it. This directory breaks
that in two ways:

1. `WatchPumpClient` is a **second pump-connection holder**. It drives `PumpBLEClient` directly and
   never touches the `PumpBackend` seam, so none of the safety machinery the seam exists to enforce —
   the central therapy gate, the durable idempotency ledger, the delivery-outcome state machine, the
   cross-client mutex — applies to anything it does. Those are not features it is missing; they are
   invariants it is outside of.
2. Pairing it **evicts the phone**. The pump keeps one pairing at a time, so pairing the watch
   silently unpairs the iPhone, and the iPhone must be re-paired to use the pump again. On a **Mobi**
   that needs the charging base, so a user away from home cannot recover. An unguarded button that
   does this is a therapy event, not a settings change.

It is also the reason the "all surfaces see one capability set" invariant cannot be tested: the direct
path never touches the seam the capability channel is threaded through.

## How the exclusion works

`scripts/generate-project.sh` defaults `FABOLUS_WATCH_DIRECT_PUMP=0`, which:

- excludes this directory from the `faBolusWatch` target's sources, and
- drops the `PumpX2Messages` / `PumpX2Auth` / `PumpX2BLE` dependencies.

`WatchPumpClient.swift` is the **only** file on the watch that imports those, so with the flag off the
watch app does not link the pump BLE stack at all. That is a stronger property than hiding a page: a
shipping watch build has no code path to a pump connection. `WatchApp.swift` guards the single call
site with `#if FABOLUS_WATCH_DIRECT_PUMP`.

Verify it (both directions are checked, so the parked code cannot rot invisibly):

```sh
./scripts/generate-project.sh                                # flag off — the default
grep -c WatchDirectView.swift faBolus.xcodeproj/project.pbxproj   # → 0

FABOLUS_WATCH_DIRECT_PUMP=1 ./scripts/generate-project.sh    # bench only
xcodebuild -scheme WatchCI -destination 'generic/platform=watchOS' build
```

Both configurations are expected to compile. If the opt-in build breaks, fix it or delete this
directory — do not leave it half-compiling.

## Same posture as Garmin

`faBolusGarmin/direct-pump/` is excluded from its shipping jungles for the same reason, and carries
its own `DIRECT_PUMP_STATUS.md`. Keeping the directory name and the exclusion mechanism parallel is
deliberate: there is one answer to "where is the parked direct-pump code and why is it off".

## What this directory contains

| File | Role |
|---|---|
| `WatchPumpClient.swift` | The second connection holder. Full JPAKE pairing over the watch's own Bluetooth; resume-auth on later connects. Only watch file importing PumpX2*. |
| `WatchDirectView.swift` | The "Direct to pump" page — pair / re-pair / forget. |
| `WatchPairingView.swift` | 6-digit code entry, plus the Mobi fixed-PIN save offer. |
| `WatchPairingStore.swift` | The watch's own JPAKE derived secret, in the watch Keychain. |
| `WatchPumpModelStore.swift` | Last-seen Tandem model, so the PIN offer appears only on a Mobi. |

## Before this could ship

Not a task list so much as the set of things that are currently untrue:

- Route it through `PumpBackend` rather than beside it, so one gate, one ledger, one outcome machine
  cover the watch too — or accept it as a genuinely separate owner and answer C9 explicitly.
- Resolve the eviction: a pairing flow that unpairs the phone needs the §2.2.3 forced-settings-backup
  precondition and an explicit Mobi charging-base warning.
- Hardware validation. Nothing here has ever run against a pump.
