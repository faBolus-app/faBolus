# Claude handoff — round-2 audit remediation

**Date:** 2026-07-23  
**Disposition:** **NO-GO for every real insulin-delivery surface**  
**Purpose:** implement and test the code gaps found while reviewing
`faBolus-internal/auditor-response-2026-07-23-round2.md`

## 1. Instructions for Claude

Work through this handoff as a safety remediation, not as a documentation-only exercise.

- Read and obey each repository's `AGENTS.md` before changing it.
- Preserve all unrelated and untracked work. Check `git status` in every repository before editing.
- Do not commit, push, rewrite history, or run real pump delivery unless the user separately asks.
- Keep the existing layered insulin path intact:
  UI confirmation/hold → backend dose clamp → `WritePolicy` → signed, oracle-verified message.
- Do not weaken a gate to make a test pass.
- Add deterministic regression tests for every code fix described below.
- Do not describe an item as closed until its acceptance tests exist and pass.
- Keep Phase 6 hardware, Garmin runtime, and signed-archive gates open.

### Explicit exclusion

**Do not audit, modify, test, document, or otherwise enter the eating-model development workstream.**
This exclusion covers model architecture, training/evaluation, datasets, feature engineering,
calibration, exports, artifacts, performance/paper claims, model-specific remediation documents, and
the untracked Nudge eating-model audit documents.

The only permitted Nudge work in this handoff is non-model dependency/SBOM/pin documentation, if needed
to correct the stale faBolus SBOM statement.

## 2. Repository locations and reviewed baselines

| Repository | Location | Reviewed revision |
|---|---|---|
| faBolus | `/Users/zgranowitz/Code/zgranowitz/faBolus` | `5555291` |
| faBolus-internal | `/Users/zgranowitz/Code/zgranowitz/faBolus-internal` | `338cca1` plus untracked prior handoff |
| PumpX2Kit | `/Users/zgranowitz/Code/zgranowitz/PumpX2Kit` | `ca484c0` |
| faBolusGarmin | `/Users/zgranowitz/Code/zgranowitz/faBolusGarmin` | `7c9d4d6` |
| faBolusNudge | `/Volumes/Zev's External Drive/faBolusNudge` | `4724e08`, non-model scope only |

At the end of the review, faBolus, PumpX2Kit, and faBolusGarmin were clean. faBolus-internal contained
the untracked `faBolus-cross-repo-reaudit-handoff-2026-07-23.md`. faBolusNudge contained untracked
eating-model audit documents; preserve and ignore them.

## 3. Executive diagnosis

The response's continued NO-GO disposition is correct, but its statement that software is
“code-complete and verified” is false.

The most important unresolved defect is cross-process unknown-outcome recovery. A pump initiate can be
accepted, the response can be lost, and the app can persist a nonterminal ledger entry. After process
restart, however, the backend's global unknown-outcome block and pump bolus ID are gone. The restored
ledger blocks only the same `(peer, requestId)`; a new request ID or a local bolus can proceed without
reconciling the earlier delivery. This is a credible duplicate-insulin path.

The transport coordinator cited as the deterministic foundation for this behavior is not used by
TandemBackend. Other claims are also only partial: the bench carb calculator still drops below-target
reductions, IDP CRUD can bypass the central acknowledgement, Garmin still hides cancellation in
read-only and fabricates a cancelled fallback, and PumpX2Kit validation/policy hardening is incomplete.

## 4. Required implementation order

Implement in this order because later work depends on the earlier transport and durable-state changes.

1. **P0: durable unknown-outcome block and reconciliation**
2. **P1: integrate PumpX2Kit transaction ownership into TandemBackend**
3. **P1: correct the PumpX2Kit saline bench carb calculator**
4. **P1: complete AppModel's central unverified-therapy gate**
5. **P1: complete Garmin cancellation behavior**
6. **P2: finish PumpX2Kit policy and request validation**
7. **P2: close verification and documentation gaps**
8. Run the complete cross-repository verification matrix and revise audit claims truthfully.

## 5. P0 — durable unknown-outcome recovery

### Current evidence

- `faBolus/ios/faBolus/Data/AppModel.swift:256-264` lazily loads `RemoteBolusLedger`.
- `AppModel.swift:1328-1384` persists `delivering` before the backend call and marks an
  `indeterminate` result, but never records the pump-assigned bolus ID.
- `faBolus/Packages/faBolusCore/Sources/faBolusCore/RemoteBolusLedger.swift:98-105` supports storing a
  bolus ID, and `:141-149` exposes `unreconciled()`. Neither is used by production code.
- `faBolus/ios/faBolus/Data/TandemBackend.swift:243-245` keeps `deliveryOutcomeUnknown` and
  `unknownOutcomeBolusId` only in memory.
- `TandemBackend.swift:426-444` can reconcile an in-memory unknown outcome and posts
  `.faBolusIndeterminateResolved`, but AppModel does not observe or consume that notification.
- `TandemBackend.swift:1294-1296` calls reconciliation on reconnect only when the same backend instance
  still has its in-memory flag.
- `RemoteBolusLedgerStore.swift:34-40` loads a missing or corrupt file as an empty ledger. There is no
  global fail-closed pump gate to make corruption safe.
- `faBolus/ios/faBolusAppTests/AppModelBehaviorTests.swift:325-344` tests relaunch only after a completed
  terminal delivery.

### Required behavior

Design one coherent durable delivery-transaction state shared by AppModel and the Tandem backend.
Exact structure is an implementation decision, but all of these invariants are mandatory:

1. Persist the delivery intent atomically before the first pump write.
2. Persist the pump-assigned bolus ID as soon as permission is received and before initiate can become
   ambiguous.
3. Persist whether initiate was not sent, sent with unknown outcome, or terminally resolved.
4. On launch, treat every `delivering` or `indeterminate` record as a **global insulin-delivery block**,
   not merely a duplicate-request block.
5. The global block must cover local standard bolus, local extended bolus, widget, Watch, Garmin, Mac,
   and peer-remote paths.
6. Reconcile nonterminal records against authoritative current/last pump bolus state by bolus ID after
   reconnect.
7. Settle the matching ledger entry with the authoritative delivered/cancelled result, persist it, then
   and only then release the global delivery block.
8. A different or missing last-bolus ID must keep the block active and surface “outcome unknown; verify
   on pump,” not silently clear it.
9. A missing/corrupt/unreadable ledger after prior state has existed must fail closed. Do not convert
   corruption into an empty, delivery-enabled ledger.
10. Do not use an unobserved `NotificationCenter` post as the only ownership link. Prefer an explicit
    backend result/callback/protocol state that AppModel can deterministically test.
11. Preserve idempotent replay for the same request and reject same-ID/different-payload conflicts.

### Required tests

Add deterministic tests for:

- crash/relaunch before permission, after permission ID, before initiate write, after initiate write,
  after pump response, and before/after terminal persistence;
- restored `delivering` and restored `indeterminate` records;
- same ID/same payload, same ID/different payload, and a completely new request ID while unresolved;
- local delivery while a remote transaction is unresolved, and remote delivery while a local
  transaction is unresolved;
- reconnect with the bolus active, reconnect after full completion, reconnect after partial
  cancellation, last-bolus mismatch, and pump history temporarily unavailable;
- corrupt JSON, unreadable file, failed atomic save, and failed terminal save;
- exact one-initiate assertion across restart/reconnect;
- all remote surfaces receiving `unknown`/verification-required rather than `failed`.

### Acceptance criteria

- No new insulin delivery can start while any prior sent transaction is unresolved.
- Relaunch cannot erase the global block.
- A terminal result is produced only from an authoritative pump response/history match.
- The existing response's FB-02/FB-03 claim must remain open until these tests pass.

## 6. P1 — make PX-08 the real Tandem transport path

### Current evidence

- `PumpX2Kit/Sources/PumpX2BLE/PumpBLEClient.swift:263-282` defines `sendAwaitingResponse`.
- No production caller uses it; only the isolated coordinator tests reference it.
- `faBolus/ios/faBolus/Data/TandemBackend.swift` still uses mutable `timeCont`, `permissionCont`,
  `initiateCont`, `lastBolusCont`, timers, and manual generation checks.
- `PumpTransactionCoordinator.swift:36-44` stores a wire txId, but `:92-99` matches only
  `(characteristic, opcode)` and resolves FIFO.
- `PumpBLEClient.swift:442-452` calls `setNotifyValue` and marks the client ready without waiting for
  `didUpdateNotificationState`.
- `PumpBLEClient.swift:425-480` has discovery, read/parse, notification, and write error paths that notify
  the delegate without always calling the library's fail-closed reset.
- `PumpBLEClient.disconnect()` does not synchronously reset policy/fail pending work.

### Required behavior

1. Replace TandemBackend's hand-owned request/response continuation slots with the PumpX2Kit transaction
   API for the signed delivery flow, including time, permission, initiate, current/last status, and other
   safety-critical awaited responses.
2. Establish a real subscription-ready barrier. Required notification characteristics must report
   notification state successfully before `.ready`.
3. Correlate by wire transaction ID when verified by protocol behavior. If the response format cannot
   safely support txId matching, serialize requests sharing the same characteristic/opcode and document
   the verified limitation; do not pretend FIFO is full correlation.
4. Handle Swift task cancellation with cancellation handlers that remove and resume only the owning
   transaction.
5. Fail all pending transactions and reset policy on intentional disconnect, unexpected disconnect,
   powered-off/resetting/unauthorized state, restoration, pairing failure, discovery failure,
   subscription failure, parser/reassembly failure, read failure, and write failure.
6. Distinguish a synchronous/pre-write error from a timeout/disconnect after initiate was written.
   Delivery callers must map the latter to durable indeterminate state.
7. Do not leave a stale deadline capable of resolving a later transaction.

### Required tests

Use a deterministic fake transport around the actual PumpBLEClient/TandemBackend integration:

- pre-write authorization/not-ready failure;
- write succeeds, response dropped;
- response arrives before and after deadline;
- disconnect immediately before and after initiate write;
- same opcode with reordered txIds;
- cancellation of one of multiple transactions;
- subscription success/failure and delayed subscription;
- every CoreBluetooth error/state callback resets policy and resumes pending work;
- an unsolicited frame is not consumed by a transaction;
- exactly one continuation completion on every path.

### Acceptance criteria

- `rg "sendAwaitingResponse"` shows real TandemBackend production use.
- The old delivery continuation slots are removed or no longer own the signed delivery path.
- The fake-transport tests cited by the response actually exist and exercise the app/backend path.

## 7. P1 — correct the saline bench carb calculator

### Current evidence

`PumpX2Kit/Sources/PumpX2BenchHarness/main.swift:161-177` computes:

- food from carbs/carb ratio;
- correction as `max(0, (BG-target)/ISF)`;
- IOB only as a subtraction from that nonnegative correction;
- total rounding directly to 0.05 U.

This drops the signed below-target correction and related IOB reduction that the oracle applies to a
food dose. It also skips the oracle's two-decimal component rounding. The FOOD1/FOOD2 bitmask fix is
correct but does not repair the dose calculation.

### Required behavior

1. Extract a pure, testable bench bolus planner instead of leaving the formula embedded in the BLE
   monitor.
2. Match the oracle/faBolusCore semantics exactly:
   signed BG correction, IOB interaction, two-decimal HALF_UP component rounding, zero floor, final
   0.05 U pump increment, and explicit bench cap.
3. Keep FOOD1 for carbs, FOOD2 for no carbs, and add CORRECTION/EXTENDED only when coherent.
4. Snapshot the entire planned `InitiateBolusRequest`, not just the type byte.
5. The bench output must clearly print every calculator input and component so it can be compared with
   the pump during saline validation.

### Required tests

- Below/at/above target × carbs/no carbs × IOB below/equal/above correction.
- Rounding boundaries that change a 0.05 U result when component-level dp2 is omitted.
- Zero-floor and bench-cap cases.
- Full request cargo equality for total, FOOD1/FOOD2, food/correction components, carbs, BG, and IOB.
- Reuse or generate fixtures from the authoritative oracle; do not invent pump semantics.

### Acceptance criteria

- The former below-target case produces a smaller dose than food-only when the oracle does.
- The bench planner matches all selected oracle vectors exactly.
- Phase 6 must not use the harness until these tests pass.

## 8. P1 — complete the central unverified-therapy gate

### Current evidence

- `faBolus/ios/faBolus/Data/AppModel.swift:1046-1074` gates create and segment CRUD.
- `AppModel.swift:1043-1045` sends set-active, rename, and delete-profile directly through `runControl`.
- Current app tests cover create-profile, segment delete, and one CGM alert path, not every claimed CRUD
  entry point.

### Required behavior

1. Route all IDP/profile CRUD through the same AppModel-level acknowledgement boundary:
   create, set active, rename, delete, add segment, modify segment, and delete segment.
2. Keep batch restore behind one explicit acknowledgement, using private raw helpers so it does not ask
   once per segment.
3. Audit the remaining unverified CGM-alert operations consistently. Do not claim “CGM alerts are
   centrally gated” if only high/low is gated.
4. Keep child-mode/read-only/control interlocks in force underneath the acknowledgement.
5. Ensure the acknowledgement is one-shot or explicitly scoped to one batch, never ambient indefinitely.

### Required tests

Create a table-driven direct-AppModel test that invokes every public therapy-write entry point:

- without acknowledgement: backend call count remains zero and a clear error is surfaced;
- with acknowledgement: exactly the intended call runs;
- after one-shot consumption: a second standalone call fails closed;
- batch restore: one acknowledgement covers only that batch;
- cancellation: no write occurs;
- a newly added entry point must be included in the central policy table/test.

### Acceptance criteria

- `setActiveProfile`, `renameProfile`, and `deleteProfile` cannot bypass the gate.
- The response must not say “all IDP CRUD” until the complete matrix passes.

## 9. P1 — finish Garmin cancellation safety

### Current evidence

- `faBolusGarmin/source/app/MainView.mc:56-64` returns on read-only before drawing Cancel.
- `source/app/BolusOnlyView.mc:22-31` does the same.
- Delegates check `canCancel()` first, which can make an invisible tap region work, but there is no
  visible cancellation control.
- `source/app/AppState.mc:356-368` turns `cancelling` into `cancelled` when bolusing disappears even when
  no authoritative terminal echo arrived.

### Required behavior

1. Read-only blocks starting a new bolus but never hides or disables cancellation of an in-flight bolus.
2. Every relevant view must draw the red Cancel state when `canCancel()` is true, before considering
   read-only.
3. Keep view geometry and touch/button delegates consistent.
4. A cancel request is not a confirmed cancellation. If the terminal host echo is lost, transition to
   `unknown`, not `cancelled`, and instruct the user to check pump/t:connect history.
5. Only an authoritative `bolusStatus` for the matching request may display delivered/cancelled and
   delivered units.
6. Preserve the existing GA-01 residual-risk documentation and NO-GO product gate; this handoff does not
   authorize inventing a gesture-proof protocol.

### Required tests

- read-only false/true × idle/delivering/cancelling × touch/button device;
- visible Cancel and working input in read-only;
- cancel requested, full dose completes before cancel;
- partial cancellation;
- terminal echo dropped;
- stale/mismatched request ID;
- reconnect after cancellation;
- no fabricated delivered or cancelled outcome.

If a Connect IQ runtime test harness is unavailable, add pure state-transition tests where possible and
leave the real-device matrix explicitly open.

## 10. P2 — finish PumpX2Kit policy and request validation

### PX-03/PX-04 policy requirements

Current `PumpBLEClient.writePolicy` is a public, sticky ambient property. `.allowDestructive` is a useful
new tier, but the original requirement was an explicit, short-lived authorization.

Required changes:

- introduce a scoped/one-operation policy elevation API that always restores `.readOnly` with `defer`;
- prevent arbitrary long-lived destructive elevation where practical;
- update faBolus and the bench harness to use the scoped API;
- reset fail-closed on every connection and transport error described in Section 6;
- test success, thrown error, timeout, cancellation, and disconnect during the scoped operation.

Do not reduce the existing separation:
`read < benign < settings < destructive < delivery`.

### PX-07 validation requirements

`PumpX2Kit/Sources/PumpX2Messages/Requests/Control/InitiateBolusRequest.swift:47-84` validates some
bounds but still permits incoherent payloads.

Add validation for:

- exactly one of FOOD1 or FOOD2;
- FOOD1 and nonzero carb metadata coherence;
- CORRECTION bit and correction component/BG coherence where protocol behavior is verified;
- `foodVolume + correctionVolume <= totalVolume + extendedVolume` with checked, nonwrapping arithmetic;
- checked addition for total + extended and an overflow error;
- extended total/component semantics;
- any verified upper limits needed before wire encoding.

Decide how to handle the public nonthrowing initializers. Production/external-value paths must not be
able to silently truncate or trap. Preserve parsing/oracle-fixture needs without leaving an easy unsafe
construction path.

Required tests:

- FOOD1|FOOD2, neither food bit, metadata/bit mismatches;
- components individually valid but sum too large;
- UInt32 overflow;
- extended edge cases;
- property/fuzz tests asserting every accepted request round-trips without truncation;
- existing oracle cargo remains byte-identical for valid inputs.

## 11. P2 — verification and documentation gaps

### FB-04 actual app-built IOB test

The code now supplies IOB to `InitiateBolusRequest`, but the current tests prove the encoder and Mock
behavior separately. Add a spy/fake transport test of the actual TandemBackend request for:

- nonzero, zero, negative/nonfinite/extreme source IOB handling;
- IOB changed after approval;
- exact frozen IOB rather than a later live snapshot;
- standard and extended delivery;
- exact carbs/BG/IOB metadata equality.

### Garmin calculator parity

The GA-04 code shape is plausible and compiles, but compilation is not oracle parity. Run a captured
fixture set through a pure Monkey C calculator test or another deterministic harness. Verify component
HALF_UP rounding and final 0.05 U results, especially boundary vectors.

### App-test destination

`faBolus/scripts/test-ios.sh:17` defaults to `iPhone 16`, which is absent from the current Xcode 26.5
runtime. Make the script robust by selecting an installed simulator or using a documented configurable
generic default. Preserve `FABOLUS_TEST_DEST`.

### Nudge SBOM wording

`faBolus/docs/SBOM.md:5-8,45` says faBolusNudge does not publish an SBOM. The non-model Nudge repository
now has `SBOM.md` and `scripts/check-sbom.sh`. Correct only this code-dependency statement; do not enter
or summarize model/dataset inventory.

### Audit response and trackers

Before the code is fixed, update claims to open/partial rather than leaving false “DONE” language.
After fixes, record:

- exact commits reviewed;
- exact test commands and counts;
- which behavior is deterministic-test verified;
- which behavior remains hardware/runtime/signing gated.

Do not use “code-complete” while any acceptance criterion in this handoff is missing.

## 12. Verification commands

Run these after implementation. Use clean scratch paths where appropriate.

### faBolus

```bash
cd /Users/zgranowitz/Code/zgranowitz/faBolus
swift test --package-path Packages/faBolusCore
./scripts/check-schema-drift.sh
./scripts/check-sbom.sh
./scripts/test-ios.sh
./scripts/build-sim.sh
xcodebuild -project faBolus.xcodeproj -scheme faBolusMac \
  -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

If `project.yml` changes, run `xcodegen generate` before the builds.

### PumpX2Kit

```bash
cd /Users/zgranowitz/Code/zgranowitz/PumpX2Kit
./scripts/test.sh
```

The oracle must run fail-closed. Do not set `PUMPX2_ALLOW_ORACLE_SKIP=1` for acceptance.

### faBolusGarmin

```bash
cd /Users/zgranowitz/Code/zgranowitz/faBolusGarmin
./scripts/check-schema-drift.sh
```

Compile at least:

```bash
MONKEYC='/Users/zgranowitz/Library/Application Support/Garmin/ConnectIQ/Sdks/connectiq-sdk-mac-9.2.0-2026-06-09-92a1605b2/bin/monkeyc'
KEY='/Users/zgranowitz/garmin_dev_key.der'
"$MONKEYC" -f monkey.jungle -o /tmp/faBolusGarmin-venu3s.prg -y "$KEY" -d venu3s -w
"$MONKEYC" -f monkey.jungle -o /tmp/faBolusGarmin-fr245.prg -y "$KEY" -d fr245 -w
"$MONKEYC" -f monkey.jungle -o /tmp/faBolusGarmin-fenix7.prg -y "$KEY" -d fenix7 -w
```

### faBolusNudge, non-model only

```bash
cd "/Volumes/Zev's External Drive/faBolusNudge"
FABOLUS_DIR=/Users/zgranowitz/Code/zgranowitz/faBolus bash scripts/check-sbom.sh
```

Do not add, alter, interpret, or report on eating-model-specific tests as part of this handoff. A
repository-wide verification command may execute existing model-related tests incidentally; treat them
as out of scope and do not change their code or claims.

## 13. Baseline results from the re-review

These passed before remediation and must remain green:

- faBolusCore: **109 tests passed**
- PumpX2Kit: **184 tests passed**
- faBolus app simulator: **26 tests passed** when run on the installed iPhone 17 simulator
- faBolus schema/payload validation: passed
- faBolus SBOM check: passed
- Garmin schema drift: passed
- Garmin compile: venu3s, fr245, fenix7 passed
- Nudge non-model SBOM/pin check: passed

These green results do **not** close the missing cases identified above.

## 14. Required final report from Claude

Return a concise implementation report containing:

1. Files changed, grouped by repository.
2. For each finding, the implemented invariant and its regression tests.
3. Exact test/build commands, pass/fail result, and final test counts.
4. Anything still open, separated into:
   - remaining code/test gap;
   - pump hardware gate;
   - Garmin runtime/product gate;
   - Apple signing/archive gate.
5. Confirmation that eating-model development was untouched.
6. Updated delivery disposition. It must remain NO-GO until the documented Phase 6 gates pass, even if
   every code item above is fixed.

## 15. Completion checklist

- [ ] Restored nonterminal ledger state globally blocks every delivery surface.
- [ ] Pump bolus ID and send/unknown state survive process restart.
- [ ] Reconciliation settles the correct ledger entry before unblocking.
- [ ] Corrupt/unreadable durable state fails closed.
- [ ] TandemBackend uses the real transaction coordinator.
- [ ] Subscription readiness and every transport failure are deterministic and tested.
- [ ] Bench carb planner matches signed below-target/IOB/rounding oracle behavior.
- [ ] All IDP CRUD is centrally gated and table-tested.
- [ ] Garmin visibly permits cancellation in read-only.
- [ ] Garmin never fabricates `cancelled` without a terminal host outcome.
- [ ] Destructive policy elevation is short-lived and resets on every exit.
- [ ] InitiateBolus validation rejects all incoherent/overflowing component combinations.
- [ ] Actual app-built frozen IOB/BG/carb metadata is spy-transport tested.
- [ ] Garmin calculator fixtures run, rather than merely compile.
- [ ] iOS app-test script selects an available simulator.
- [ ] faBolus SBOM acknowledges the Nudge code SBOM without touching model scope.
- [ ] All baseline tests/builds remain green and new regression tests pass.
- [ ] Audit response/tracker language matches the implementation and evidence.
- [ ] Phase 6 hardware/runtime/signing gates remain open and delivery remains NO-GO.
