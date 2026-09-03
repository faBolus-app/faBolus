# REINTEGRATION.md — dev/aam-malfunction-code (faBolus repo)

## Feature preserved

The AAM (Active Alert Malfunction) read fan-in, removed by `f2be9179`
("refactor(pump): remove dead AAM read fan-in from app (tslim-reconnect-loop Phase B)"):

- `ios/faBolus/Data/Tandem/PumpReadScheduler.swift`: `alertRead()`'s AAM tail — the two extra requests
  (`HighestAamRequest`/`ActiveAamBitsRequest`) appended to the periodic alert-read burst (7 back-to-back
  reads here, back to 5 on `main`).
- `ios/faBolus/Data/TandemBackend.swift` and `ios/faBolus/Data/Tandem/PumpResponseApplier.swift`: the
  `highestAam`/`activeAamBits` fan-in vars, `setHighestAam`/`setActiveAamBits` closures, and the
  `HighestAamResponse`/`ActiveAamBitsResponse` applier cases.
- The never-reached `aamCode` plumbing in `toAlert`; the `malfunctionDisplay` codepath (collapsed to the
  generic path on `main`).
- `highestAamForTesting`/`activeAamBitsForTesting` test accessors + the dedicated AAM tests
  (`ios/faBolusAppTests/PumpReadSchedulerAamFanInTests.swift`, 92 lines).
- `op120`/`op146` in `PumpReadCatalog.alertReadOpcodes`.

**Not preserved here (never removed — stay on `main` too):** the static `PumpKnownUnsupportedReads`
`{op20,op120,op146}` entries and the TandemKit `op120` minApi floor, kept deliberately as harmless
backstops if AAM read plumbing is ever re-added. TandemKit's `HighestAamRequest`/`ActiveAamBitsRequest`
request TYPES also stay on TandemKit `main` — only the app-side fan-in that read them is gone.

## State at removal

This branch is the pristine `main` tip immediately before the removal, commit **`9dd95369`**
("fix(pump): suppress op120/op146 AAM reads on API-2.5 t:slim (reconnect-loop fix)") — the parent of the
single removal commit `f2be9179`. `main` has since deleted, in that one commit:

1. The AAM tail in `PumpReadScheduler.alertRead()` — this branch's copy still sends all 7 reads
   back-to-back; `main` sends 5.
2. `highestAam`/`activeAamBits` + their setters/closures + the two `PumpResponseApplier` cases
   (`TandemBackend.swift`, `PumpResponseApplier.swift`) — this branch's copies still have them.
3. The `aamCode` plumbing in `toAlert` and the `malfunctionDisplay` function — this branch's copy still
   has the AAM-aware branch; `main`'s `toAlert` uses the generic path unconditionally.
4. `highestAamForTesting`/`activeAamBitsForTesting` (`FakePumpTransport.swift`) and
   `PumpReadSchedulerAamFanInTests.swift` outright (92 lines) — this branch's copies still have both.
5. `op120`/`op146` from `PumpReadCatalog.alertReadOpcodes` — this branch's copy still lists both.
6. Retargeted (not deleted) the read-cascade/opcode-registry tests that assert over the alert-read set —
   `PumpBadOpcodeReprobeTests.swift`, `PumpStaticUnsupportedReadRegistryTests.swift`,
   `ReadCascadeMembershipGuardTests.swift`, `PumpPairingInstrumentationTests.swift`,
   `PreIdentitySendContractTests.swift`, `SafetyNotificationTests.swift` — this branch's copies are at
   their pre-retarget counts/expectations (7-read burst, not 5).

No signed dose/delivery path was touched by the removal (AAM was confirmed dead plumbing — no UI/decision
consumer, `aamCode` always `nil` at every call site). No JDK-21 oracle re-proof was required or performed.

## Reintegration path

1. Re-add the AAM tail (`HighestAamRequest`/`ActiveAamBitsRequest`) to `PumpReadScheduler.alertRead()`
   from this branch's copy — a hand merge against the target tree if `main` has moved since this cut,
   not a blind overwrite.
2. Re-add `highestAam`/`activeAamBits`, `setHighestAam`/`setActiveAamBits`, and the
   `HighestAamResponse`/`ActiveAamBitsResponse` applier cases to `TandemBackend.swift` /
   `PumpResponseApplier.swift`.
3. Restore the `aamCode` plumbing in `toAlert` and reinstate `malfunctionDisplay`.
4. Restore `highestAamForTesting`/`activeAamBitsForTesting` and
   `PumpReadSchedulerAamFanInTests.swift`.
5. Re-add `op120`/`op146` to `PumpReadCatalog.alertReadOpcodes`.
6. Re-retarget the 6 read-cascade/opcode tests back to a 7-read alert burst, using this branch's copies
   as the reference expectation.
7. Re-derive whether the reconnect-loop provocation this removal fixed (auto-polling AAM to a
   Control-IQ-off / no-CGM API-2.5 t:slim X2 provoked op-77 + deliberate BLE teardown) still applies —
   the original fix (`9dd95369`) that suppressed the op120/op146 reads predates this cut and stays either
   way; re-adding the fan-in on top of it needs a fresh read of whether the suppression is still correct
   for the target `main`.
