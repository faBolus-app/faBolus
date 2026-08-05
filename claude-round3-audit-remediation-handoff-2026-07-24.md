# Claude remediation handoff — round-3 re-audit findings

**Date:** 2026-07-24

**Disposition:** **NO-GO for real insulin delivery**

**Purpose:** Fix the safety defects and close the test/evidence gaps that remain after
`faBolus-internal/reaudit-request-2026-07-23.md` and
`faBolus-internal/auditor-response-2026-07-23-round3.md`.

## 1. Scope and revisions

Reviewed:

- faBolus `99d613a` (`9932011` code plus a docs-only roadmap commit)
- PumpX2Kit `173bea0`; rechecked at current `802b921`, whose only additional change makes the
  `withWritePolicy` closure `@MainActor`
- faBolusGarmin `659dc34`
- The round-3 request, response, original round-2 handoff, tests, build scripts, and relevant docs

Excluded:

- faBolusNudge eating-model architecture, training, evaluation, datasets, exports, and model artifacts
- Garmin `direct-pump/`
- The deliberately deferred configurable custom max-bolus feature

The non-model Nudge SBOM check was run only because it is part of the claimed verification matrix.

## 2. Executive result

The response is **not accepted as complete**. The builds and existing suites are green, and several
changes are real improvements, but critical delivery-outcome and durability paths remain unsafe.

Most importantly:

1. After the pump accepts an initiate request, a disconnect, missing status response, status timeout, or
   failed cancellation can still be converted into a fabricated terminal result. The app can report the
   requested dose as delivered, or report cancellation, without authoritative confirmation.
2. Persistence of the pump-assigned bolus ID is best-effort. A save failure followed by a crash can leave
   an ID-less record even though initiate was sent. Relaunch then auto-clears that record as “not
   delivered,” releasing the global block.
3. PumpX2Kit still does not fail all transactions/reset policy on every transport path claimed by the
   response, and response ownership is not safely correlated or serialized across all callers.
4. The original handoff's required deterministic tests do not exist. The request acknowledges two of
   these gaps, but then contradicts itself by claiming every software acceptance criterion is met.

Keep the final disposition **NO-GO for real insulin delivery** after the fixes below. Code completion
does not replace the Phase-6 saline, hardware, Garmin-runtime, signing, and archive gates.

## 3. Plain-language operational verdict

### Will the software work as-is?

Under ideal conditions, much of it probably will:

- The projects build.
- The phone app, watch targets, widgets, Mac app, and three Garmin targets compile.
- The normal calculator cases covered by tests work.
- The new global “previous bolus outcome unknown” lock works in the tested MockBackend cases.
- Profile CRUD warning gates, Garmin's visible Cancel control, schema checks, and many message encoders
  work in their current tests.

It is **not safe to expect dependable insulin delivery as-is**. The dangerous cases are precisely the
cases that happen when Bluetooth, process lifetime, storage, or cancellation behaves imperfectly.

### What should we expect not to work properly?

- **A connection drop after the pump accepts a bolus may be reported incorrectly.** The app can assume
  the full requested amount was delivered even when it could not read the final pump status.
- **Cancel can be reported as successful when it was not confirmed.** If the cancel write fails or the
  final status cannot be read, the pump may continue delivering while the app says “cancelled.”
- **A rare storage failure plus an app crash can defeat the restart safety lock.** The app may forget the
  pump's bolus ID and later conclude that nothing was sent.
- **Some Bluetooth errors will wait for a timeout instead of failing immediately and safely.** During
  those windows, the UI can be stale and pending operations are not handled as claimed.
- **The Garmin changes compile but are not runtime-tested.** Cancel visibility and lost-echo behavior
  look correct statically, but touch/button behavior and state transitions are not proven on-device or
  in an app-layer test harness. The compiler also warns that the glance annotation is ignored on FR245,
  so the FR245 glance-specific experience should not be expected to exist.
- **The bench carb calculator is improved but not oracle-proven at its edge cases.** The current tests do
  not run the required oracle vector matrix or byte-lock the complete planned request. Non-finite or
  extremely large input can also trap during numeric conversion.
- **Some “untested feature” warning coverage is unproven or narrower than advertised.** IDP CRUD is gated,
  but batch restore/cancellation cases are missing from the table, and CGM out-of-range and rise/fall
  writes do not use the same acknowledgement gate.
- **Frozen IOB is only proved up to MockBackend.** The exact production Tandem request containing
  carb/BG/IOB metadata is not captured by a fake transport test.
- **The custom max-bolus feature intentionally does not exist yet.** Until the pump reports its maximum,
  the app uses the existing 25 U default/absolute ceiling and has no user-defined lower cap.

Treat every “unknown,” disconnect, failed cancel, or unexpected app exit during a bolus as requiring a
manual check of the pump/t:connect before another dose.

## 4. P0 — never fabricate a terminal result after initiate is written

### Evidence

In `ios/faBolus/Data/TandemBackend.swift`:

- `awaitResponse` turns a response parse/type failure into ordinary `BolusError.pumpRejected`
  (`194-210`), even though the request has already been written.
- The initiate block maps only `PumpTransactionCoordinator.TxError` to indeterminate (`549-562`).
  A parse/type error after the initiate response arrives bypasses this mapping.
- After an accepted initiate, current-status errors are discarded with `try?` (`578-588`).
- A disconnect causes the loop to break (`583-585`), but the final status read is also discarded with
  `try?` (`591-597`).
- If no authoritative matching final status is available, `delivered` remains the originally requested
  `units` (`592-597`). The method then updates local IOB/history and returns success (`599-612`).
- `cancelBolus` sets `cancelRequested = true` before sending and ignores send failure (`617-624`).
  `perform` later sets `lastBolusCancelled` solely from this local flag (`599`).

`AppModel.runLedgeredDelivery` treats that returned value as terminal, persists it, and releases the
global block (`ios/faBolus/Data/AppModel.swift:1478-1497`).

### Required behavior

Implement an explicit delivery phase/outcome state machine. At minimum distinguish:

- no initiate write attempted;
- initiate write issued, response unknown;
- authoritative initiate NACK;
- initiate accepted and delivery active;
- authoritative terminal status for the matching bolus ID;
- indeterminate, requiring reconciliation.

Rules:

1. Before initiate is written, a synchronous validation/authorization/not-ready error is a clean failure.
2. Once initiate write begins, every non-authoritative exit is indeterminate.
3. A parsed, matching, explicit initiate NACK may settle as failed.
4. A parsed accepted response is not a terminal delivery result.
5. After acceptance, only a matching authoritative current/last/history result may settle delivered or
   cancelled and update local IOB/history.
6. Disconnect, timeout, task cancellation, parse failure, missing/mismatched final ID, poll deadline, and
   write error after initiate must leave the durable ledger unresolved and globally block delivery.
7. A cancel request means “cancellation requested,” not “cancelled.” A failed/unconfirmed cancel must not
   produce a cancelled terminal result or a guessed delivered amount.
8. If the pump reports that the bolus completed before cancellation, report delivered, not cancelled.

### Required deterministic tests

Use the actual TandemBackend delivery flow behind a fake transport:

- initiate synchronous pre-write failure -> clean failed, zero initiate writes;
- initiate write then response dropped -> indeterminate;
- malformed/unparseable initiate response -> indeterminate;
- explicit initiate NACK -> failed, not indeterminate;
- accepted response then disconnect -> indeterminate;
- accepted response then all current-status responses drop -> indeterminate at deadline;
- accepted response then final last-status drops -> indeterminate;
- final status has a different bolus ID -> indeterminate;
- matching full completion -> delivered exact units;
- matching partial completion -> exact delivered units;
- cancel write fails -> not cancelled; outcome remains active/indeterminate;
- cancel response/status drops -> indeterminate;
- full dose completes before cancel -> delivered, not cancelled;
- partial cancellation with matching authoritative status -> cancelled/partial only if pump semantics
  provide authoritative cancellation; otherwise report the authoritative delivered amount without
  inventing a cancellation flag;
- every failure leaves the AppModel ledger unresolved and blocks a new local and remote dose.

## 5. P0 — make safety-ledger transitions truly durable

### Evidence

In `ios/faBolus/Data/AppModel.swift`:

- `persistLedger()` is `saveBestEffort` (`273-276`).
- `onBolusIdAssigned` mutates the ledger and calls this best-effort save (`476-482`).
- The callback cannot reject permission-to-initiate progression; TandemBackend invokes it and
  immediately continues toward metadata/initiate (`TandemBackend.swift:491-548`).
- Relaunch reconciliation auto-settles every unresolved ID-less record as “not delivered”
  (`AppModel.swift:1501-1517`).
- Manual verification clears `ledgerFailedClosed` before a successful replacement save is known
  (`305-316`).
- Production falls back to a temporary file if no durable App Group/Application Support URL exists
  (`470-473`).

Failure sequence:

1. The durable `delivering` intent is saved without a bolus ID.
2. Pump permission assigns an ID.
3. Saving that ID fails.
4. Initiate is still sent.
5. The app crashes before a later successful save.
6. Relaunch sees an ID-less `delivering` record and auto-clears it.
7. A second bolus is allowed even though the first may have delivered.

### Required behavior

1. Make “persist assigned bolus ID” a throwing/acknowledged operation.
2. TandemBackend must not send metadata or initiate until AppModel confirms the ID is durably saved.
3. If the ID save fails, abort before initiate, keep delivery blocked or settle a durably recorded
   pre-initiate failure, and clearly tell the user nothing was initiated.
4. Persist an explicit phase. Do not infer “initiate was never sent” merely from a missing bolus ID.
5. An ID-less nonterminal record must remain blocked unless durable state explicitly proves it is
   pre-initiate/not-sent.
6. Do not release the global block after terminal reconciliation or manual verification until the clean
   terminal ledger is successfully saved.
7. If a terminal save fails, retain an in-memory global block and retry persistence; after relaunch the
   previous nonterminal record must still fail closed.
8. Do not use `/tmp` as a production safety-ledger fallback. If no durable store is available, delivery
   must remain disabled and surface a recoverable error.

### Required deterministic tests

- initial intent save failure -> no pump write;
- assigned-ID save failure -> permission may have occurred, but zero metadata/initiate writes;
- crash after permission and successful ID save, before initiate;
- crash immediately after initiate write;
- crash after accepted response, before terminal status;
- failed indeterminate save;
- failed terminal save;
- failed manual-clear save;
- no durable container/Application Support URL;
- corrupt JSON and unreadable file;
- restored explicit pre-initiate record;
- restored write-issued ID-less record;
- exactly one observed initiate write across restart/reconnect;
- no new local, widget, Watch, Garmin, Mac, or peer delivery while any ambiguous record exists.

Use an injectable ledger store that can fail selected save calls; do not simulate these cases only by
hand-authoring final JSON.

## 6. P1 — complete the real transport fail-closed behavior

### Evidence

In `PumpX2Kit/Sources/PumpX2BLE/PumpBLEClient.swift`:

- `disconnect()` does not synchronously reset policy or fail pending transactions (`188-192`).
- powered-off/resetting/unauthorized/unsupported state changes do not call `failClosed`
  (`348-360`).
- service and characteristic discovery errors only notify the delegate (`451-467`).
- write errors only notify the delegate (`538-540`).
- malformed/reassembly failures do not have a deterministic fail-all path.

TandemBackend's delegate error handler resets policy but does not fail the coordinator's pending
transactions, so omitted PumpBLEClient paths can wait until deadline.

In `PumpTransactionCoordinator.swift`:

- `write()` runs before the cancellation handler/continuation is installed (`65-90`), so an already
  cancelled task can still write.
- the coordinator stores a wire transaction ID but matches inbound frames only by characteristic/opcode
  (`99-105`).
- same-opcode requests are allowed concurrently and resolved FIFO.

TandemBackend also has fire-and-forget polling that sends `LastBolusStatusV2Request` and
`TimeSinceResetRequest` outside coordinator serialization. Those responses can overlap awaited requests
with the same characteristic/opcode.

### Required behavior

1. Add a transport seam so PumpBLEClient and TandemBackend can be exercised without CoreBluetooth
   hardware.
2. On intentional disconnect, unexpected disconnect, powered-off/resetting/unauthorized/unsupported
   state, restoration, pairing failure, discovery failure, subscription failure, parser/reassembly
   failure, read failure, and write failure:
   - reset policy to `.readOnly`;
   - resolve every pending transaction exactly once with a typed transport error.
3. Check task cancellation before writing. Cancellation of one task must remove only that task.
4. Verify whether response txId echoes/correlates to the request. If verified, match it.
5. If txId cannot be used, enforce serialization for requests sharing characteristic/opcode across
   **all** callers, including routine polling; do not rely on undocumented FIFO.
6. Pause or route routine reads through the same ownership mechanism before starting the signed flow.
7. A post-write parser/type error must preserve the write-issued classification for the caller.

### Required tests

Recreate the complete Section 6 matrix from the prior handoff around the real app/backend path:

- subscription success, delayed success, and failure;
- every CoreBluetooth error/state callback;
- intentional disconnect before and after initiate write;
- response before and after deadline;
- malformed frame and parse/type mismatch;
- same opcode with reordered txIds;
- awaited response overlapping a routine fire-and-forget read;
- pre-cancelled task emits zero writes;
- cancel one of multiple transactions;
- unsolicited frame not consumed;
- exactly one completion on every path;
- policy is `.readOnly` after every exit.

## 7. P1 — finish bench planner verification and input safety

The pure planner is a good structural change, and the common below-target case is corrected. The current
tests do not satisfy the prior acceptance matrix:

- no full below/at/above-target × carbs/no-carbs × IOB matrix;
- `belowTargetWithIobFloorsAtZero` actually uses the default zero IOB;
- the rounding test checks `3.57` but not a case where component dp2 changes the final 0.05 U result;
- `fullRequestCargoMatchesPlan` only asserts that cargo is nonempty; it does not compare all fields or
  bytes to an authoritative expected request;
- no selected oracle vectors are executed by the planner test;
- non-finite/huge carb or IOB inputs can reach trapping `UInt32`/`Int` conversions before the bench cap.

Required:

1. Add authoritative oracle fixtures for the required matrix and exact final 0.05 U results.
2. Byte-lock the complete `InitiateBolusRequest` cargo for selected vectors.
3. Add finite/range validation before every integer conversion.
4. Apply bounds without first converting an unbounded Double to UInt32/Int.
5. Test NaN, positive/negative infinity, negative carbs, extremely large carbs/IOB, invalid profile
   values, cap below minimum, and all rounding boundaries.
6. Do not use the carb bench path for Phase 6 until these tests pass.

## 8. P1 — correct the central-gate claim and finish its matrix

The seven IDP CRUD entry points are now routed through `runGatedTherapy`. That part is improved.

The test named `everyTherapyWriteEntryPointIsCentrallyGated` includes only those seven operations plus
CGM high/low. It omits:

- `applyPumpSettings` batch restore;
- cancellation/no-write behavior;
- CGM out-of-range;
- CGM rise/fall;
- any explicit completeness mechanism that fails when a new gated operation is added.

`setCgmOutOfRangeAlert` and `setCgmRiseFallAlert` currently call `runControl` directly.

Required:

1. Decide and document exactly which unverified therapy/settings writes require acknowledgement.
2. Gate all operations in that declared set at AppModel.
3. Add direct tests for batch restore:
   - no acknowledgement -> zero writes;
   - one acknowledgement covers only the one batch;
   - failure stops the batch;
   - cancellation before execution -> zero writes;
   - acknowledgement is consumed and cannot authorize a later standalone write.
4. Add the remaining CGM operations if they are part of the unverified gate, or narrow the response
   language so it does not claim every therapy-write/CGM-alert entry point.
5. Rename the current test/comment unless its table is genuinely complete.

## 9. P2 — finish InitiateBolus validation

The new validation correctly adds food-bit XOR and checked sums, but the response overstates it as full
coherence:

- nonzero carbs require FOOD1, but FOOD1 does not require nonzero carbs;
- CORRECTION requires a component, but a nonzero correction component does not require CORRECTION;
- foodVolume is not checked against FOOD1/FOOD2 semantics;
- public nonthrowing initializers remain easy to call and can trap or truncate; the extended initializer
  uses unchecked `totalVolume + extendedVolume` inside a precondition.

Required:

1. Enforce every bidirectional relationship that is verified by protocol evidence.
2. For unverified relationships, document the limitation and stop claiming “all incoherent component
   combinations.”
3. Test both directions of each enforced relationship.
4. Remove, restrict, clearly label, or safely wrap the public trapping constructors. Production and
   external-value code must have a nontrapping path.
5. Test overflow through every public construction path, not only `init(validating:)`.
6. Preserve existing oracle byte equality for valid captured messages.

## 10. P2 — add the actual Tandem frozen-metadata test

The two FB-04 tests stop at MockBackend. They prove that AppModel passes a frozen `iob` argument, not that
TandemBackend builds and sends the expected request.

Add a fake-transport capture of the real production request and assert:

- nonzero, zero, negative, NaN, infinity, and extreme IOB handling;
- IOB changes between freeze and confirmation;
- standard and extended delivery;
- exact bolus ID, total, type bits, food/correction components, carbs, BG, and IOB;
- exact request bytes against existing PumpX2Kit oracle fixtures where verified;
- metadata writes and initiate ordering.

## 11. P2 — Garmin runtime tests and compiler warnings

The static changes for visible Cancel and `unknown` on lost echo look directionally correct. They are not
runtime-verified.

Add an app-layer Monkey C state harness, or extract pure state transitions that the test target can run:

- read-only true/false × idle/delivering/cancelling;
- touch and physical-button devices;
- visible and actionable Cancel in read-only;
- full completion before cancel;
- partial cancellation;
- cancel send failure;
- terminal echo dropped;
- stale/mismatched request ID;
- reconnect after cancel;
- no fabricated delivered/cancelled state.

Also update verification wording:

- all three targets **compile successfully with warnings**, not “compile clean”;
- FR245 reports that glance annotations are unsupported/ignored;
- venu3s scales a mismatched launcher icon;
- numerous container-type warnings remain.

Decide whether the FR245 glance omission is an accepted device limitation. Document it in user-facing
compatibility notes if it is.

## 12. P2 — investigate runtime formatting diagnostics

The iOS app suite passed but repeatedly emitted Foundation diagnostics stating that a `%.2f U` format was
given an integer argument. This may cause an incorrect/missing amount label.

Required:

1. Reproduce with a symbolic/log breakpoint and identify the exact call site.
2. Fix the argument type or replace fragile vararg formatting with typed formatting.
3. Add targeted tests for nil/default, integer-looking, fractional, and extreme amount labels.
4. Keep this separate from the excluded eating-model/CoreML simulator diagnostics.

## 13. Correct the audit response and request

The response cannot simultaneously say:

- the full CoreBluetooth integration test and Garmin app-layer tests are deterministic gaps that remain
  open; and
- every software acceptance criterion possible without hardware is met.

After implementation:

1. Remove “every code item is done” until every required acceptance test exists and passes.
2. Change the current checked boxes for transport, durable ID/send state, planner parity, validation,
   actual frozen metadata, and documentation truthfulness back to open until their tests pass.
3. Report exact test names, not only aggregate counts.
4. Do not call a MockBackend method-entry assertion an “exactly one initiate write” test.
5. Keep Garmin calculator/runtime tests open until they run.
6. Keep the final disposition NO-GO until Phase 6 is complete.

## 14. Verification reproduced during this re-audit

Passed:

- `swift test --package-path Packages/faBolusCore` -> 109 tests
- `./scripts/test-ios.sh` -> auto-selected iPhone 17 Pro; 35 tests
- `./scripts/check-schema-drift.sh` -> 36 properties; 8 valid + 6 rejected payload cases
- `./scripts/check-sbom.sh` -> pass
- unsigned faBolusMac `xcodebuild` -> BUILD SUCCEEDED
- PumpX2Kit `./scripts/test.sh` at `173bea0` -> 205 tests, oracle fail-closed
- PumpX2Kit `./scripts/test.sh` re-run at `802b921` -> 205 tests
- Garmin schema drift -> 34 keys
- Garmin compile for venu3s, fr245, and fenix7 -> BUILD SUCCESSFUL, with warnings
- Nudge non-model SBOM/pin check -> pass

Not separately rerun:

- `./scripts/build-sim.sh`; the iOS test command built the app, watch, widgets, and test targets
- signed Apple archives/privacy reports
- hardware, saline, Garmin on-device, or real-pump tests

The green suites do not cover the failure windows listed in this handoff.

## 15. Completion checklist for Claude

- [ ] No post-initiate ambiguous path can settle delivered/cancelled or unblock delivery.
- [ ] Failed/unconfirmed cancellation never fabricates a terminal result.
- [ ] Assigned bolus ID is durably acknowledged before initiate can be written.
- [ ] Ledger phase distinguishes not-sent from write-issued/accepted/unknown.
- [ ] Failed ID/terminal/manual-clear persistence remains globally blocked.
- [ ] Production has no temporary-file safety-ledger fallback.
- [ ] Every listed transport/state/error callback fails pending work exactly once and resets policy.
- [ ] Response ownership is txId-correlated or comprehensively serialized.
- [ ] Actual TandemBackend fake-transport matrix passes.
- [ ] Bench planner runs authoritative oracle/cargo fixtures and rejects unsafe numeric input.
- [ ] Central-gate batch/cancellation/declared CGM matrix passes.
- [ ] InitiateBolus coherence and construction APIs are nontrapping for production/external values.
- [ ] Frozen carb/BG/IOB is captured from the actual Tandem request for standard and extended boluses.
- [ ] Garmin app-layer calculator/cancellation tests run.
- [ ] Garmin compatibility/warning language is accurate.
- [ ] iOS amount-format diagnostic is identified, fixed, and tested.
- [ ] Request/response claims match the tests that actually exist.
- [ ] All baseline suites/builds still pass.
- [ ] Phase-6 hardware/runtime/signing gates remain open.
- [ ] Delivery remains NO-GO for real insulin use.
