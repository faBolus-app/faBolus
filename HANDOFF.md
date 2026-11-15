# Handoff: review and fixes after pulling main (faBolus, TandemKit, faBolusGarmin)

Written 2026-11-15. **Nothing here is committed, pushed, tagged or installed.** Every fix is an
uncommitted change in the working tree of its repo. This file isn't tracked either.

| Repo | Base | Fix rounds | Last verified |
|---|---|---|---|
| faBolus | `origin/main` 84fe2ca5, branch `fix/bolus-status-after-bolus` | Round 1 done. **Round 2 in progress.** | After round 1: `./scripts/check.sh build test format swiftlint contract` passed, and the iOS app compiled (only snapshot tests failed, as expected on iOS 26.5) |
| TandemKit | `main` 44093b7 (release 0.12.0) | Two rounds done | 549 library + 107 bench tests; build, format, swiftlint pass |
| faBolusGarmin | `fix/bolus-status-after-bolus` 929f260 | Two rounds done | 116 tests pass; contract gate passes (31 fixtures) |

Local work from before the pull is kept in a `git stash` in each repo ("local review fixes on …").
Workers carried over whatever the new code still needed.

**How the review ran:** Opus reviewers read each repo, Opus workers fixed what they found, and a
second review of those fixes found the round-2 items. No reviewer found a way for a dose to go out twice
or without confirmation, before or after the fixes. TandemKit's message bytes all match the pumpx2 oracle.

**Status key:** **Fixed** · **Fixed (round 2)** fixes a problem in a round-1 fix · **In progress**
means a worker was still on it when this was written, so the code may be half-edited and faBolus may not
build · **Left as is** · **Your call**.

Not checked on this Mac: the ShellCheck, actionlint and markdownlint gates (tools not installed), and the
snapshot tests (recorded on iOS 27.2; only iOS 26.5 simulators here).

---

## faBolus: pump session, dose path and history

Packages: `PumpSession`, `faBolusCore`, `HistoryStore`, `docs/UNVERIFIED-GUESSES.md`.

### Unknown bolus outcomes and the ledger

| ID | Bug | Kind | Status | Fix |
|---|---|---|---|---|
| A1 | A bolus ledger that couldn't be read at launch (a relaunch before first unlock) stayed unread. "I checked the pump" could then confirm unknown boluses the user was never shown. | Safety | Fixed | `DurableBolusLedger.reloadIfUnreadable()` runs whenever the block is read. "Confirm all" only adopts a file that becomes readable; it doesn't confirm what's in it. Expectation changed: `confirmingAllReadsAFileThatHasBecomeReadable` was replaced by `aFileThatBecomesReadableIsAdoptedWhenTheBlockIsRead` and `confirmingAllAdoptsAFileThatHasBecomeReadableWithoutConfirmingIt`. |
| A2 | A history record from before a bolus was accepted could settle that bolus. | Safety | Fixed | A record must be no older than acceptance − 10 min and not from before a history log restart. Recorded as UNVERIFIED-GUESSES #42. |
| A3 | A cancel the pump refused could read as "may have finished", and the cancel fallback could pick an entry already confirmed. | Safety | Fixed | The fallback skips confirmed entries. A negative reply for an id that wasn't verified marks the cancel unconfirmed. |
| A4 | A dose stopped before it reached the pump still counted as a duplicate and blocked the same dose afterwards. | Correctness | Fixed | A ledger entry is indexed for duplicates only once InitiateBolus has gone out. |
| A5 | A bolus started on the pump between Review and Deliver didn't stop the phone's dose if a pump read landed in between. | Safety | Fixed | `ComposedDose.preparedIOBUnits` keeps the IOB the dose was prepared with, and delivery checks against it. |

### History sync and pump battery

| ID | Bug | Kind | Status | Fix |
|---|---|---|---|---|
| B1 | Boluses already confirmed on the pump were searched for in history again after every connection. | Pump battery | Fixed | Confirmed outcomes are never searched. **P4** goes further. |
| B2 | A search asked for while another was running was dropped. | Correctness | Fixed | The trigger is kept and runs after the current search. **P5** fixes this item's test. |
| B3 | A short history page ended a search early, and a gap could count as proof a bolus never happened. | Safety | Fixed | A short page continues the search; a gap never proves absence. |
| B4 | An empty sync marked the log as synced. | Correctness | Fixed | Retried after 60 s, at most 3 times. **P2/P3** fix how this one finishes. |
| B5 | A reconnect to the same pump re-read settings, CGM hardware and history that had just been read. | Pump battery | Fixed | Recent reads are kept across a reconnect. |

### Session state, clocks and the link

| ID | Bug | Kind | Status | Fix |
|---|---|---|---|---|
| C1 | `followPhoneClock` didn't move the alert lists when the clock stepped. | Correctness | Fixed | Alert lists move with the clock step. |
| C2 | The G7 grace-time read was asked once and never again. | Display | Fixed | `graceReadAsked` is re-armed. |
| C3 | A pending request's `requestedAt` didn't follow a clock step. | Correctness | Fixed | It now follows the step. |
| C4 | Pump notices triggered reads that were supposed to be resting after no answer, or during a tracked bolus. | Pump battery | Fixed | Notice reads follow the rest and tracked-bolus rules. |
| C5 | A suspected UserInteraction could go out ahead of the dose reads. | Correctness | Fixed | It's held until after them. The test that drove this hung for 6.5 h because it didn't advance the scripted clock; fixed with `rig.run(upTo:)`. |
| C6 | `pumpReachable` could be true from alerts read on an earlier connection. | Display | Fixed | It needs alerts from the current connection. |
| C7 | The periodic tick ran before the pump's identity was trusted. | Correctness | Fixed | The tick needs `identityTrusted`. |

### Glucose used for dosing

| ID | Bug | Kind | Status | Fix |
|---|---|---|---|---|
| D1 | A reading stamped ahead of the phone's clock stayed "current" too long. | Safety | Fixed | `Observed` ages from min(measuredAt, receivedAt). See X1. |
| D2 | A dose was recorded with the latest reading, not the reading it was corrected from. | Correctness | Fixed | The dose records the reading it was corrected from. |
| D3 | A stale calculator snapshot meant the max-hourly-bolus limit couldn't be checked, and nothing said so. | Safety | Fixed, then **replaced by P1** | New `DoseConfirmation.bolusLimitsNotChecked` reused the `maxHourlyBolus` wire kind. Re-review found that on remotes, which match confirmations by kind alone, the two prompts became interchangeable. |

### Round 2 (found by re-reviewing the round-1 fixes)

| ID | Bug | Kind | Status |
|---|---|---|---|
| P1 | D3's shared wire kind lets a watch or Live Activity confirm "limits not checked" with a "max hourly" answer. Plan: make `bolusLimitsNotChecked` phone-only, refuse a remote dose on a snapshot outside its window (no wire change), and test that the two prompts aren't interchangeable. | Safety | **In progress** |
| P2 | An empty-window sync never finishes. Plan: finish after bounded retries and reset `emptySyncRetries` in `ready()`. | Correctness | **In progress** |
| P3 | `historySyncedRecently` doesn't know the last sync was short. | Correctness | **In progress** |
| P4 | A confirmed outcome can still be searched for repeatedly. Plan: settle it from HistoryStore records, or allow exactly one search ever (persisted). | Pump battery | **In progress** |
| P5 | Test `aSearchAskedForDuringAnotherRunsAfterIt` doesn't test what it says. | Test | **In progress** |
| P6 | Unreadable-ledger re-reads (A1) happen on every block read. Plan: throttle them. | Efficiency | **In progress** |
| P7 | Check only: can the phone app begin the same request id again after the reading moved? | Safety check | **In progress** |
| P8 | The calculator snapshot is read only about once a minute, so the watch hides corrections (W6 sends "not read") until it catches up. Plan: read it once per new CGM reading. | Correctness | **In progress** |

---

## faBolus: phone app, CGM sources and alerts

Packages: `PhoneApp` (with `WidgetContent`), `ios/`, `GlucoseSources`, `DexcomBLE`, `Alerts`.

| ID | Bug | Kind | Status | Fix |
|---|---|---|---|---|
| F1 | The bolus screen stayed locked after a successful bolus until the app was relaunched. | Correctness | Fixed | `BolusFlow` goes back to `.editing` once a delivery has started. Final results stay up until OK, and `dismissResult` only clears a result. |
| F2 | The Live Activity's Cancel couldn't be tapped again after a cancel the pump didn't confirm, and it stuck on "Delivering…". | Safety | Fixed | Cancel is enabled again after an unconfirmed cancel, and `cancelling` clears when no bolus is going. **Q4** adds a guard. |
| F3 | While the app was suspended, the lock screen didn't mark IOB, reservoir and pump link stale on time. | Display | Fixed | `LiveActivityContent.staleDate` returns the next future crossing. |
| F4 | One future-dated CGM reading hid every reading after it. | Correctness | Fixed | `GlucoseSourceBuffer.add` drops samples beyond `futureSkewTolerance`. |
| F5 | The bolus screen auto-filled a correction right after a bolus. | Safety | Fixed | Auto-fill is held after a delivery until carbs or glucose are typed, or "Use the suggestion" is tapped. |
| F6 | After `deliver` returned, the Live Activity could show an older outcome instead of the ledger's current one. | Display | Fixed | It shows the ledger's current outcome (`showCurrent` is now internal). |
| F7 | A backup CGM source paused on a hold never started again. | Correctness | Fixed | `GlucoseSourceRegistry.endHoldIfOver`, `AppModel.resumeBackupSourceAfterHold`, `backupSourcePicked`, `chosenBackupSourceID`, `backupHeldOffUntil`. **Q1** fixes a double start this exposed. |
| F8 | After the first unlock, the app never re-read the bolus block or alert state that had been unreadable at launch. | Safety | Fixed | iOS `protectedDataBecameAvailable()` re-reads `ledger.block` and alert state. |
| F9 | Corrupt or missing alert state left old notifications up, and an unreadable state file could be overwritten. | Correctness | Fixed | `AlertCoordinator` withdraws all old notifications when state is corrupt or missing, and retries an unreadable file instead of overwriting it. **Q2/Q3** follow up. |
| Q1 | A backup CGM source could start twice at launch. Plan: resume only after `launched`, one start at a time. | Correctness | **In progress** (probably done) |  |
| Q2 | Alert-state adoption can run re-entrantly (`AlertCoordinator.swift` ~317–325). | Correctness | **In progress** |  |
| Q3 | Inputs deferred until unlock are replayed with the unlock time, can post notifications a second time, and the deferred list has no bound. | Correctness | **In progress** |  |
| Q4 | Two Live Activity cancels can be in flight at once (`LiveActivityFlow.swift` ~474). | Safety | **In progress** |  |

---

## faBolus: watch link (phone side)

Packages: `WatchLink`, `RemoteProtocol`. No wire or contract change.

| ID | Bug | Kind | Status | Fix |
|---|---|---|---|---|
| W1 | A watch request with a reused id could be told "Not delivered" even though the first dose went in. | Safety | Fixed | `requestIdReused` is answered from the ledger entry. |
| W2 | A damaged copy of a request didn't claim its id, so a later copy could act on it twice. | Safety | Fixed, then **corrected by T1** | The damaged copy claims the id synchronously. |
| W3 | After a phone relaunch, a resent request waited on pump reads before the watch heard the outcome. | Correctness | Fixed | A resent request with a ledger entry is answered before `received` and before pump reads. |
| W4 | Bolus answers queued behind a send that stalled before the phone slept. | Correctness | Fixed | The stalled-send hold runs on a clock that counts sleep (`CLOCK_MONOTONIC_RAW`). |
| W5 | A late send completion could re-arm a hold that wasn't active. | Correctness | Fixed | It re-arms only if a hold was active. |
| W6 | The watch could offer a correction from a reading other than the one the phone will correct from. | Safety | Fixed (depends on **P8**) | `StatusComposer` sends a caution only when the reading sent matches the calculator snapshot's (same value, times within 5 s), and otherwise sends `notread`. Until P8 is done this hides corrections about 10–20% of the time. `aFlaggedReadingSaysWhy` had its setup changed. |
| T1 | W2's claim made a damaged copy that arrived first block the good copy of the same request. | Correctness | Fixed (round 2) | A good copy that arrives while a damaged copy is still being looked up takes the request over and is delivered once. The damaged copy's handler then sends and records nothing. Each damaged copy has its own claim number. All three arrival orders are tested. Test changed to the opposite expectation: `anUnreadableCopyDoesntFailAReadableCopyAcceptedMeanwhile` → `aReadableCopyTakesOverFromAnUnreadableOneStillLookingUp`. `anUnreadableDuplicateOfALiveRequestIsIgnored` now also checks exactly one delivery. New test: `twoUnreadableCopiesAreAnsweredOnce`. |
| T2 | The early answer-from-entry path didn't check that it was the same request, and a reused id with no readable entry left the watch waiting. | Safety | Fixed (round 2) | The early answer needs `RemoteHost.isSameRequest`; a different request under a used id goes through the composer's reused-id path. With no readable entry, the watch gets "Outcome unknown" and "check the pump and the phone". The plan was a refusal, but that would show "Not delivered" for a dose that may have gone in. Nothing is recorded. New test: `aReusedRequestIdWithNoReadableEntryIsUnknown`; `aReusedRequestIdIsAnsweredFromItsEntry` gained an argument. WatchLink 144 tests and RemoteProtocol 37 pass; contract fixtures unchanged. |

## faBolus: cross-cutting

| ID | Bug | Kind | Status | Fix |
|---|---|---|---|---|
| X1 | Backup CGM readings carried no arrival time, so staleness couldn't use min(measured, received). | Safety | Fixed | `GlucoseSample` has an optional arrival time plus `agedFrom` and `received(at:)` (`faBolusCore/GlucoseSource.swift`). `GlucoseSourceBuffer` records arrival; `GlucoseArbiter` and `AlertCoordinator` use `agedFrom`. |
| X2 | The user-visible fixes weren't in the changelog. | Docs | Fixed | A "Fixed" section (Phone app / Pump / Watch link) under Unreleased in `CHANGELOG.md`. Round-2 entries are **in progress**. |

---

## TandemKit

Working tree on `main` at 44093b7 (release 0.12.0). Done through two rounds; the second review found no
safety defect.

| ID | Bug | Kind | Status | Fix |
|---|---|---|---|---|
| L1 | First subscriptions had no time bound, so requests could hang. | Correctness | Fixed | `LinkTimer.subscriptions`; requests end with `notSent(.characteristicUnavailable)`. |
| L2 | A reconnect after a drop retried at once with no backoff. | Pump battery | Fixed | `LinkState.backoffUntil`, `TransportCommand.delayedConnect(UUID, startDelay:)` using `CBConnectPeripheralOptionStartDelayKey`, `.cancelPendingConnect(UUID)`. |
| L3 | Catch-up could open windows as well as end them. | Correctness | Fixed | Catch-up only ends windows. |
| L4 | `.restored` changed `appActive`. | Correctness | Fixed | `.restored` leaves it alone. |
| L5 | Drop records weren't kept per pump. | Diagnostics | Fixed | The last 4 drops are kept per pump. |
| L6 | A dropped pairing wasn't named. | Correctness | Fixed, then **corrected by R1** | Round 1 retried a wrong pairing code forever. |
| R1 | — (fixes L6) | Correctness | Fixed (round 2) | Two pairing refusals in a row (a link drop, a failed write on `authorization`, or an establishment timeout) → `pairingDropped`. |
| L7 | A scan with pumps already listed failed with `pumpNotFound`. | Correctness | Fixed, then **corrected by R2** | Round 1's scan never ended. |
| R2 | — (fixes L7) | Correctness | Fixed (round 2) | A scan with pumps listed doesn't fail `pumpNotFound`; RSSI 127 is never "strongest"; `LinkConfiguration.pairingScanMaxDuration` caps the scan at 600 s. |
| R3 | An optional characteristic that stopped notifying during discovery hung discovery. | Correctness | Fixed | It's marked unavailable. |
| R4 | The connect failure that answers our own cancel was treated as a real failure. | Correctness | Fixed | `LinkState.cancelledPendingConnect` ignores it. |
| R5 | A rescan cleared `backoffUntil`. | Pump battery | Fixed | It's kept through a rescan. |
| R6 | Flags survived `stopEverything`, power-off and `connected`. | Correctness | Fixed | Cleared on all three. |
| R7 | After a restore, an already-notifying characteristic wasn't reported as subscribed. | Correctness | Fixed | The transport reports it as subscribed. |
| M1 | `BolusEndReason` didn't match the oracle. | Correctness | Fixed | Matches oracle values 0–6; `LastBolusStatusV3Response.EndReason` is a separate type. |
| M2 | Signed writes weren't gated by pump API version. | Correctness | Fixed | `SupportMatrix.signedWriteMinimumApi` (UserInteraction needs ≥ 3.0). |
| M3 | Alert 39 had no name. | Display | Fixed | Named. |
| M4 | The bench hold wasn't cleared. | Test | Fixed | Cleared. |
| M5 | The docs lagged the code. | Docs | Fixed | Docs, CHANGELOG and WIP-REGISTER updated. |

**faBolus must absorb these when the pin moves:** the new `TransportCommand` cases (`.delayedConnect`,
`.cancelPendingConnect`) and `LinkTimer.subscriptions`. `PumpScript/ScriptedPump.perform` must handle
the two new commands; today it falls through to `default:`. None of these fixes reach the phone until a
TandemKit release and a pin bump.

**Not verified on a real phone:** the start-delay connect option while the app is suspended, and the
restored-subscription behaviour (R7). Both are listed in `WIP-REGISTER.md`.

---

## faBolusGarmin (watch app)

Working tree on `fix/bolus-status-after-bolus` at 929f260. Done through two rounds.

| ID | Bug | Kind | Status | Fix |
|---|---|---|---|---|
| K1 | The data-age estimate could make old data look fresh, or the phone look gone. | Safety | Fixed, then **corrected by S2** | Age is the older of the relative and absolute estimates. Only status, outcome or chart messages count as hearing the phone, at min(sentAt + 30 s, now). |
| K2 | A malformed inbound message could crash the background service, which then never exited. | Correctness | Fixed | An `instanceof` check in `Inbound.dataOf`; the service always exits. |
| K3/K4 | Alerts seen in the background weren't remembered by the foreground app, so they buzzed again. | Correctness | Fixed, then **corrected by S4** | `ALERTS_SEEN` is readable in the background; added `ALERTS_GONE`. |
| K5 | Outcomes the service took could be applied twice or lost. | Safety | Fixed | The service passes what it took back via `Background.exit`; outcomes are numbered and applied once. |
| K6 | The background poll was skipped while `phoneConnected` was false, so it never recovered. | Correctness | Fixed | The poll isn't gated on it. |
| K7 | A clock set back made the phone look gone. | Correctness | Fixed, then **corrected by S2** | — |
| S1 | Round 1 hid Cancel while a bolus could still be running (fixes F4). | Safety | Fixed (round 2) | See F4. |
| S2 | Fixes K1/K7. | Correctness | Fixed (round 2) | "Live" needs both wall clock and uptime; a clock stepped back is handled. |
| S3 | The app stopped getting messages after a re-register was missed. | Correctness | Fixed | The app re-registers for messages on every poll. |
| S4 | Fixes K3/K4: a returning alert didn't buzz, or buzzed repeatedly. | Correctness | Fixed (round 2) | `BG_NOTIFIED_AT`, `ALERTS_SHOWN_AT`, `BG_SHOWN_GONE`; a returning alert buzzes exactly once. |
| S5 | Data of unknown age looked current. | Safety | Fixed | Unknown age is shown as old. |
| F1 | "Include stale" stayed on, so a stale reading could be offered. | Safety | Fixed | `includeStale` is cleared; `offeredGlucose` needs `staleIncludable(now)`. |
| F2 | A different reading after a carbs-only bolus didn't count as a change. | Correctness | Fixed | It counts as changed. |
| F3 | The correction question was dropped when only one dose was over the limit. | Correctness | Fixed | It's dropped only if both are over. |
| F4 | Cancel wasn't always offered while a bolus was shown. | Safety | Fixed (with S1) | Cancel is always offered: "Cancel · bolus status old", and "May not reach phone. Stop it on the pump". |
| F5 | An unknown config token broke config parsing. | Correctness | Fixed | Unknown tokens are skipped. |
| F6 | The calculator message used a rounded total. | Correctness | Fixed | It's built from the unrounded total. |
| F7 | A failed send didn't say nothing was sent. | Display | Fixed | "Couldn't send. Nothing was sent." |

New tests: `tests/LateMessageTest.mc`, `tests/BolusEdgeTest.mc`. Changed `FaultTest` expectations:
`aBackgroundPushIsSavedUnderItsOwnKeys`, `aClockSteppedBackDoesntStopAging`,
`aLateStatusDoesntRollTheWatchBack`.

---

## Left as is

- **Your call: chart gaps.** Upstream now leaves readings outside the chart's range off the chart on both
  phone (`GlucoseChartView.swift:128`) and watch (`InfoViews.mc`, `CgmView.onPlot`), with no marker, so a
  45 mg/dL low or a stretch above 300 shows as a gap. This is deliberate upstream; an edge marker is
  a small change if you want one.
- The "never delivered" (`.absent`) settlement was traced and is tightly guarded, so it wasn't changed.
- Remote and Live Activity confirmations are matched by kind only (`DoseComposer+Remote.swift:174`), and
  the 0.10 U dose tolerance is the remote design. P1 removes the one place the fixes made kinds collide.
- The watch keeps the bolus button closed with "No reply" if its clock is more than about 90 s fast. This
  fails closed. faBolusGarmin's `CHANGELOG.md` says "about 30 s fast"; the real limit is 30–90 s, and that
  line wasn't changed.
- Minor: UserInteraction is sent once per process; readings are dropped without a reason when the phone
  clock is more than 5 min slow; the urgent-low LOW time ages from measured time only; on the watch, a
  config or dismiss result no longer counts as hearing the phone.

## Not verified on a pump or phone

- The time of the reading in the calculator snapshot (bytes 26–29, UNVERIFIED-GUESSES #36). How fresh a
  correction is depends on it.
- The record window around acceptance (UNVERIFIED-GUESSES #42, A2).
- TandemKit's delayed connect while suspended, and restored subscriptions (in `WIP-REGISTER.md`).

## What's left

1. Finish faBolus round 2: P1–P8 and Q1–Q4 (T1–T2 are done). The format gate currently fails on two lines
   that are too long and still being edited: `Alerts/AlertEngine.swift:681` and
   `faBolusCoreTests/DoseConfirmationTests.swift:97`.
2. Run the full faBolus gates again:
   `./scripts/check.sh build test format swiftlint contract`, plus the iOS 26.5 app build.
3. A short confirming review of the round-2 changes; finish the round-2 changelog entries.
4. When you're ready: commit each repo, release TandemKit and bump the pin (update `ScriptedPump` for the
   new commands), sync the watch contract if it changed, and test on the pump.
