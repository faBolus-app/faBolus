# Unverified guesses

Values and behavior faBolus takes from pumpx2, captures or other references that haven't been confirmed
on a real pump or device. If something misbehaves, start here. Each entry gives the guess, where it lives,
what a wrong guess costs, and how to check it.

Three pumps are named: **P1**, a t:slim X2 at API 2.5 with the 16-character pairing code and no
cartridge, used on the bench; **P2**, a t:slim X2 at API 4.0 with the 6-digit code; and **P3**, a t:slim X2
at API 4.0 with the 6-digit code and a G6, benched with saline on 2026-11-14. What P3's bench confirmed
has been removed from here.

Entries keep their numbers: code, tests and notes cite them, and a number isn't reused when its entry is
resolved. Remove an entry once it's confirmed on hardware.

## 4. Bolus metadata: the type bits, the food and correction split, and the entries

faBolus builds a bolus's InitiateBolus and its entries the way Tandem's own app does in pumpx2's captures
(`InitiateBolusRequestTest`, `RemoteCarbEntryRequestTest`, `RemoteBgEntryRequestTest`), byte for byte
(`BolusCommandsTests`). The delivered amount depends only on the total; everything here is the pump's
record of the bolus.

- **Captured, and matched:** a dose typed in units has type bits 8 and no food or correction volume
  (ID10650); carbs alone have bits 1 with the whole dose as food (ID10652, ID10653); carbs with a
  correction have bits 3 with the dose split into the carbs' part and the correction (ID10677, ID10678).
  The BG entry goes first, then the carb entry, then InitiateBolus, with the pump clock read again after
  permission. Both entries carry TimeSinceReset's seconds since boot and the bolus ID, and the BG entry is
  manual and remote (entry type 0, source 1).
- **Confirmed on P3:** bits 8, 1 (with both entries) and 10 (a correction with a BG entry) are taken and
  delivered, and the pump's history and screen record the entries. The carb entry's third byte has to be 1,
  as faBolus sends it: P3 answers 0 with status 1 and the bolus can't go.
- **Unverified:**
  - the split (bits 3) has only run in Tandem's app;
  - a calculator dose for a correction with no carbs goes as bits 8, like a dose typed in units; no
    capture shows what Tandem's app sends for that case;
  - a dose the user changed from the calculator's goes as all food (bits 1); what Tandem's app sends for
    an edited dose isn't captured;
  - the carbs' part is the calculator's, rounded to 0.01 U, and the correction is the rest of the dose.
- **Where:** `Packages/PumpSession/Sources/PumpSession/BolusCommands.swift`.
- **Verify:** on P2, deliver a carb bolus with a correction and confirm the pump and t:connect show the
  split as they do for a bolus from Tandem's app.

## 5. Direct G6: iOS shares the Dexcom app's link, and the pump doesn't block it

- **The guess:** `G6Observer` reads alongside the Dexcom app by connecting to the transmitter iOS is
  already linked to, as CGMBLEKit's passive mode does. It needs no transmitter slot of its own, and the
  pump's own G6 connection doesn't get in the way.
- **Where:** `Packages/DexcomBLE/G6/Sources/G6Observer.swift`,
  `Packages/DexcomBLE/Sources/DexcomBLE/DexcomCentral.swift`.
- **Risk:** availability only. If the link isn't shared, the source says why (`dexcomAppNotConnected`,
  `sensorNotFound` or the connection error) and never shows a reading.
- **Verify:** G6 reads for 24 h on a phone running the Dexcom app, with the pump connected.

## 8. Control-IQ's zone byte: not shown until verified

- **The guess, removed:** the earlier app turned `ControlIQInfoV2Response.controlStateType` (op-179) into
  Tandem's zone words by guessing that the raw values ascend with the zones. pumpx2 decodes it as an
  unnamed int, and controlX2 doesn't use it. faBolus doesn't decode or show it, and doesn't carry
  "suspended for low", which reads the same byte. Control-IQ on or off and its mode are shown.
- **A verifiable source:** op-57 `HomeScreenMirrorResponse.ApControlStateIcon` is named and mirrors the
  pump's own home-screen icon, if the pump answers op-57.
- **P3:** the mirror's Control-IQ state reads 0 (on and idle) and 200 (off); the other states are unseen.
- **Verify before showing a zone:** check op-57 on P1 and P2, and compare its icon with the pump's screen
  in each Control-IQ state.

## 9. G6 and G7: the Dexcom app's sign-in can finish before faBolus is listening

- **The guess:** control notifications go on only after the Dexcom app's authenticated, bonded challenge
  reply is seen on the authentication characteristic. This is CGMBLEKit's and G7SensorKit's rule;
  CGMBLEKit found that turning authentication off while the Dexcom app uses it breaks CoreBluetooth. If
  the Dexcom app signs in before faBolus's service discovery and notification setup finish, that cycle's
  reply is missed and no reading arrives. After two such cycles the status says the Dexcom app isn't
  connected.
- **How the others differ (protocol facts only; xDrip4iOS is GPL):** xDrip4iOS's G6 coexistence mode
  waits for the reply the same way, but counts the transmitter as bonded when the third byte is anything
  but 2 (CGMBLEKit requires 1) and doesn't check the authenticated byte. Its G7 mode turns on
  authentication, control and backfill notifications all at once on discovery, and when iOS answers
  "Encryption is insufficient" it disconnects and retries on the next cycle.
- **Where:** `G6Observer.received(_:on:from:now:)`, `G7Observer.received(_:on:from:now:)`,
  `AuthChallengeRxMessage`.
- **Risk:** availability only, plus a misleading status if it happens every cycle.
- **Verify:** the 24 h checks. If readings skip cycles, or the status blames the Dexcom app while it shows
  readings, record a session log (**Settings → About & help → Export Dexcom Bluetooth log**) and switch to
  xDrip4iOS's approach (G7) or its looser bonded check (G6).

## 10. G6: the transmitter's clock

- **The guess:** a G6 reading's time is relative to the transmitter's clock. `G6Observer` dates it from
  the clock start worked out from the latest `transmitterTimeRx` reply the Dexcom app asked for, as
  CGMBLEKit does. It keeps that clock start across launches, as CGMBLEKit stores it and xDrip4iOS dates
  its coexistence readings from it, and forgets it when another transmitter signs in. A reading with no
  known clock start isn't used, and the status says it's waiting for the clock.
- **Where:** `G6Observer.controlResponse(_:from:now:)`, `DexcomMemory.activationDate`.
- **Risk:** no reading from a new transmitter until the Dexcom app asks for the clock. A phone clock
  changed by hand shifts readings until the next clock reply.
- **Verify:** in the 24 h check, the first reading after setup arrives within one or two cycles.

## 11. G7: a reading's time is its arrival less the sensor's reported age

- **The guess:** as in G7SensorKit, a G7 glucose message carries the seconds since the sensor started
  and the age of its reading, so the reading was measured at arrival less that age, and backfill is
  dated from the latest message's sensor clock.
- **Where:** `Packages/DexcomBLE/G7/Sources/G7Observer.swift` (`glucose(_:from:now:)`,
  `flushBackfill()`).
- **Risk:** a notification delivered late (the app suspended past its background budget) would date the
  reading late, so it would look fresher than it is by the delay.
- **Verify:** in the G7 24 h check, compare faBolus's reading times with the Dexcom app's.

## 13. A bolus is absent from history only when no record shows the pump started it

An unknown outcome becomes "failed, never delivered" when a history search finds no record naming the
bolus among the initiate records (types 292, 293, 343, 298), requested (64–66), activated, delivery or
completed records, after reaching back past the moment the pump granted the permission (less 10 minutes),
with every record on the way received, no pump clock change in between, and the pump not reporting it
active. The permission records (338, 297) are ignored: the pump writes one when it grants permission,
which is exactly the bolus that never started.

- **Evidence:** the capture of bolus 3 in pumpx2's `btsnoop_hci.csv` has the initiate, requested,
  activated, delivery and completed records for a remote bolus, and a 297 record naming it before them.
- **Confirmed on P3 (API 4.0):** every bolus writes the requested and initiate records, a link dropped
  just after the request included. One cancelled before delivery starts writes no activated or delivery
  record, but its completed record names it.
- **Unverified:** that P1's older firmware writes them too, and the 10-minute margin.
- **Verify:** on P1, start a bolus and drop the link, and confirm a requested or activated record appears.

## 14. One pump clock for status, history and signing

The pump's TimeSinceReset `currentTime`, the CGM reading's timestamp, LastBolusStatusV2's timestamp and
the history records' times are read as one clock, the pump's own seconds since 2008. A time is placed on
the phone by the offset measured at the last TimeSinceReset, never by reading it as the phone's local
time.

- **Evidence:** in the bolus-3 capture TimeSinceReset reads 445539182 and the history records written
  13 s later read 445539195.
- **Known limit:** a history record from before the pump's clock was changed is placed by today's offset,
  so it is off by the change. A search for an absent bolus that crosses a clock change stays unknown
  (#13).

## 15. The pump session's timings

How often status is read while a bolus delivers (1 s), how long a delivering bolus may go without a
status answer before its outcome is unknown (90 s, one and a half request deadlines: two unanswered reads
in a row, never one; a poll on the wire gets its whole deadline, but one held in the queue behind other
unanswered reads doesn't stretch the 90 s),
how long it's followed at most (30 min), when a history page counts as complete (2.5 s with no frame),
and how often an unknown outcome is searched for (every 2 minutes, 5 times a connection; every 15 s while
the pump still reports it active) are guesses, in `PumpSession.Configuration`. How long the pump has to
answer a request (60 s, `requestDeadline`) is t:connect's one timer, for every request, reads and a
bolus's writes alike; how long a t:slim really takes to answer is not measured. One request is on the
wire at a time, so a cancel queued behind an InitiateBolus the pump doesn't answer waits up to 60 s, and
the phone says it can be stopped on the pump meanwhile. A routine read the pump leaves unanswered twice in
a row isn't asked again for one deadline, so a read it never answers can't hold the wire for good and the
alert reads and history searches still go; that gap is a guess too.

## 17. Which pump alert bits are CGM alerts

Pump notifications are posted under two switches, "Pump alerts & alarms" and "CGM alerts & errors", like
Tandem's app. Every CGM alert, and the alert bits pumpx2 names as CGM alerts or errors (19, 20, 22, 25,
27, 28, 29, 39–42, 44–46, 48), go under CGM; every alarm, malfunction, other alert and reminder under the
pump (`NotificationRules.category(for:)`).

- **Unverified:** the firmware names of bits 19, 20 and 22 (`aaAlert_STUCK_BUTTON`,
  `aaAlert_CGM_SUPPORT_PACKAGE_ERROR`, `aaAlert_STK_CSP_REQ`) disagree with pumpx2's (low transmitter,
  transmitter alert, sensor expiring). A wrong bit only lands under the other switch; both are on by
  default.
- **Verify:** when the pump raises one of these, compare what it shows with the category the app posts it
  under.

## 18. Whether a t:slim acts on a remote clear (DismissNotification, op-184)

The earlier app never sent op-184 to a t:slim: its capability note said "t:slim X2 firmware silently
rejects a remote dismissal". op-184 is recorded as used in the field on P2, but no record shows a clear
that took effect. Each pump alert carries `remoteClear` (`available`, `tryable`, `unavailable`), decided in
one place, `RemoteClearing.decide`: the alert's own dismissable flag, then the class table
`RemoteClearing.knownClasses` (empty for the t:slim), then this unit's trial result. The phone and the
watch read it and nothing else; the watch clears only `available`.

While the class is unknown, the phone may try one clear (`tryable`). The pump's "cleared" (status 0) is
only a claim: the alert read that follows decides it for that unit and firmware. Gone, the unit clears.
Still showing is reported at once as `DismissOutcome.notCleared` ("clear it on the pump"), but recorded as
"doesn't clear" only if a routine read at least `PumpSession.trialSettle` (5 s) later still shows it, in
case the pump drops the alert a moment after answering; gone by then records nothing. Only an alert the
session held when the clear was sent counts, so one already cleared on the pump never reads as a clear
that worked.

- **P3 (API 4.0):** a clear of a CGM alert drew an op-77 and the pump's history logged a TIPS error for
  op-184 with error 6 (BAD_OPCODE); the pump then dropped the link, and the alert stayed. So a t:slim at
  API 4.0 refuses the opcode itself, whatever the alert, and `knownClasses` says so.
- **Unverified:** whether P1 (API 2.5) acts on op-184, and how soon after answering the pump's alert read
  reflects a clear.
- **Verify:** on P1 and P2, clear a real alert from the phone and confirm it goes from the pump's screen
  and from the next alert read.
- **Then finish it:** add a row per class to `RemoteClearing.knownClasses` (`PumpClass(model: .tslim,
  apiVersion: …)`: `.clears` or `.doesNotClear`), and delete the trial:
  - `RemoteClear.tryable`, `PumpSessionRecord.remoteClearTrials`, `PumpAlertLists.unitClears`;
  - in `PumpSession`: `remoteClearTrialResult`, `trialCheck` (with `statusRead(for:)`, `statusKind(of:)`,
    `isShowing`, `recordRemoteClearTrial`), `pendingTrial` with `PendingRemoteClearTrial`, `trialSettle`
    and `settleRemoteClearTrial`;
  - `DismissOutcome.notCleared`, and the `dismissLeavesAlert` knob in `ScriptedPump`;
  - the phone's "Try clearing from phone" action (`AppModel+Actions.swift`, `Presentation.swift`,
    `PumpAlertsList.swift`);
  - their tests: `theTrialDecidesFromTheReadsAfterTheClear`, `anAlertThatGoesLateRecordsNothing`,
    `aClearOfAnAlertNoLongerHeldIsNotATrial`, `aNewPairingDecidesAlertsFromItsOwnRecord`,
    `theTrialIsKeptPerUnitAndFirmware`, `anAlertClearedOnThePumpDoesntCount`,
    `anOlderRecordReadsAsUnknown`, and the trial cases in `PresentationTests`.

  The status format and the watch don't change, and `aClassKnownToClearIsAvailableWithNothingRecorded`
  and `aClassKnownNotToClearIsUnavailableAndNothingIsSent` keep passing.

## 19. A bolus that ends short is "stopped", and why

- **The guess:** pumpx2 doesn't name `BolusCompleted`'s completion status, so the outcome can't tell a
  cancel from an alarm or an interruption. A bolus whose authoritative delivered amount is below the
  request ends as `BolusOutcome.stopped(delivered:requested:)`, shown as "Bolus stopped" with both
  amounts. The cancel result the phone shows ("Bolus cancelled") comes from the pump's answer to the
  cancel, not from history. The logbook shows a bolus as stopped, with both amounts, by t:connect's
  rule: a completion status t:connect counts as cut short (0, 1, 2, 4 or 6) and less delivered than
  requested. It names the cause from the status, with the names Tandem's apps give its values: 0 stopped
  on the pump, 1 by an alarm, 2 by a malfunction, 4 cancelled from a phone, 6 for a predicted low. Which
  status a t:slim records for each was unverified.
- **P3:** a cancel records 0, from the phone or the pump's screen alike, before delivery starts or part
  way. 4 was never seen, so the logbook can't tell the two apart and names 0 only as stopped. A dropped
  link doesn't stop a bolus, so there is no link-drop case. The alarm case is unverified.
- **Where:** `Packages/faBolusCore/Sources/faBolusCore/BolusOutcome.swift`,
  `Packages/PumpSession/Sources/PumpSession/PumpSession+Delivery.swift`,
  `Packages/PumpSession/Sources/PumpSession/HistoryProjection.swift`.
- **Verify:** let a bolus be stopped by an alarm and compare its completion status with the logbook's name.

## 20. The pump's CGM hardware string is the G6 transmitter ID

- **The guess:** `CGMHardwareInfoResponse.hardwareInfoString` (op-97) is the G6 transmitter ID. The earlier
  app used it that way. `G6TransmitterID.normalized` accepts it only if it's six letters and digits, and
  an ID typed in settings wins.
- **Evidence:** on P1, `CGMHardwareInfoRequest` (op-96) was answered with no sensor paired; with a sensor
  it's untested. Don't use `GetG6TransmitterHardwareInfo` instead: on P1 it draws op-77 and a dropped
  link.
- **Where:** `Packages/PumpSession/Sources/PumpSession/PumpReadings.swift`,
  `Packages/GlucoseSources/Sources/GlucoseSources/GlucoseSourceRegistry.swift`.
- **Verify:** with a G6 paired to the pump, compare **From the pump** in **Settings → CGM & backup** with
  the transmitter's printed ID.

## 21. The delivered amount after a mid-delivery cancel, and at a larger dose

- **The guess:** when a bolus ends, the amount the pump reports in `LastBolusStatusV2` (or, failing
  that, the history's completed record) is what went in: the partial amount when the bolus was cancelled
  or stopped partway, and the full amount at any size. Only a 0.10 U delivery has been checked on a pump
  (its screen agreed), and it finishes too fast to cancel partway.
- **Where:** `Packages/PumpSession/Sources/PumpSession/PumpSession+Delivery.swift` (`settleFinished`),
  which sets the outcome the phone and the watch show.
- **Risk:** the bolus outcome shows the wrong amount ("Bolus stopped" with a partial amount, or
  "delivered").
- **P3:** cancelled part way, from the phone (219 of 1000 mU) and on the pump (89 mU), LastBolusStatus B
  and C and the history's completed record agree, and the pump's screen shows the amount cut to two
  decimals (0.08 U). A cancel in the ~15 s before delivery starts puts in 0, and LastBolusStatus then keeps
  the bolus before; the history's completed record settles it.
- **Verify:** deliver 1–2 U in full and compare the request, `LastBolusStatusV2` and the pump screen, and a
  cancel that arrives just as the bolus finishes.

## 22. The pump's comms-suspended notice (qualifying-event bit 19)

- **The guess:** the bit needs no action from the phone. pumpx2 names it `PUMP_COMMUNICATIONS_SUSPENDED`
  (524288) and gives it no handler, and t:connect only logs it. faBolus pauses nothing on it, as t:connect
  does. controlX2 pauses every send for 5 s per notice; faBolus did too until the owner chose t:connect's
  handling.
- **Where:** `Packages/PumpSession/Sources/PumpSession/PumpSession.swift` (`qualifyingEvents`).
- **Risk:** if the pump really stops answering while the bit is set, a request sent meanwhile waits for its
  60 s deadline (guess #15), and an InitiateBolus that times out is an unknown outcome, which blocks new
  boluses until history settles it. Nothing is sent that a pause would have kept back from the pump.
- **P3:** never seen, across boluses, cancels, a suspend and resume, a clock change and dropped links.
- **Verify:** on P1 and P2, record the qualifying events across a bolus, a cancel, a cartridge change and
  a suspend and resume, and note when bit 19 comes and whether a request sent just after it is answered.

## 25. When a t:slim says its CGM reading isn't one to dose from

- **The guess:** the pump's home screen (HomeScreenMirror) shows a CGM alert icon other than "no error"
  (255) whenever its reading shouldn't be used, a Libre's Check BG trend icons are 8-13, and an EGV status
  of 2 or 3 means LOW or HIGH. faBolus lets the pump's reading correct a dose only when the icon read for
  the attempt is 255, the trend isn't Check BG and the status isn't LOW or HIGH; otherwise the dose is for
  carbs only, or from a typed BG. No recording shows the icon in any state but no error, or a Libre, and
  nothing shows which icon a t:slim shows in which sensor state, or what number comes with LOW or HIGH.
- **Where:** `Packages/faBolusCore/Sources/faBolusCore/PumpState.swift` (`glucoseCaution`),
  `Packages/PumpSession/Sources/PumpSession/PumpReadings.swift` (the mirror and EGV cases).
- **Risk:** fails closed for the dose. If a t:slim showed a non-255 icon in normal use, every CGM
  correction from the pump's reading would stop. The mirror has to be read for each dose: a pump that
  never answers it gets no CGM correction at all.
- **P3:** the icon stayed 255 through normal readings and through a CGM high alert. Later in the session
  CurrentEGVGuiData read 0 mg/dL with status 4 for at least two minutes; what the sensor was doing then
  isn't known.
- **Verify:** on P1 and P2, run the bench's `cgm` read through a sensor's warm-up, a normal reading and a
  sensor error, and note the alert icon, the trend icon and the EGV status with each.

## 27. The calculator snapshot's too-many-boluses bytes

- **The guess:** bytes 24 and 25 of the calculator snapshot are set when the pump says too many boluses
  were asked for (the hourly limit and IOB). The layout is pumpX2's; P3 never set either. Bytes 7-8 (the
  insulin left, whole units) and 20-23 (the bolus insulin delivered in the last 60 minutes, milliunits,
  partial amounts and the pump's own boluses included) are confirmed on P3. faBolus asks the user to confirm
  from them, on the phone and on a remote.
- **Where:** `Packages/faBolusCore/Sources/faBolusCore/DoseConfirmation.swift` (`confirmations`);
  `Packages/PumpSession/Sources/PumpSession/PumpReadings.swift`.
- **Risk:** a wrong reading asks too often or not at all; no confirmation changes or blocks a dose, and
  the pump's own limits still apply.
- **Verify:** with saline, note bytes 24 and 25 when the pump refuses a bolus for its hourly limit.

## 29. Carbs off on the pump (the calculator snapshot's byte 13)

- **The guess:** byte 13 of the calculator snapshot is 0 when the active profile has carbs turned off, as
  t:connect's parser reads it. faBolus then takes the calculator's food entry as insulin units, as
  Tandem's apps do, and sends the bolus as a dose with no carbs: no carb amount, no RemoteCarbEntry, and
  the same food and correction fields as any dose with no carbs (what t:connect puts in them with carbs off
  wasn't traced). It doesn't need the carb ratio then, since what the pump reports for it with carbs off
  isn't known.
- **Where:** `Packages/faBolusCore/Sources/faBolusCore/PumpState.swift` (`carbsOff`, `isUsable`);
  `Packages/faBolusCore/Sources/faBolusCore/DoseComposer.swift` (`CalculatorFood`);
  `Packages/PumpSession/Sources/PumpSession/BolusCommands.swift`.
- **Risk:** low. A dose with no carbs is what faBolus already sends for a correction or a dose in units;
  an entry typed before carbs were turned on or off is refused, never converted.
- **P3:** with carbs off, byte 13 is 0 and bytes 14-17 still carry the carb ratio. The pump's own
  calculator then sends the dose as bits 1 (food) with no carb entry.
- **Verify:** with saline and carbs off, a dose from faBolus's calculator: note that the pump takes it and
  what its history records.

## 30. Which bits a t:slim raises, and when

- **The guess:** a t:slim raises each qualifying-event bit when the thing it names changes, so the reads a
  notice brings keep the display current. faBolus reads what each bit names, as t:connect does (limited to
  the reads faBolus already sends), and syncs history after every
  notice. TandemKit clears the bits when the link becomes ready and after every notice (a clear held back
  by a signed write goes when the wire frees), as t:connect does. The bit values are confirmed; which bits
  a t:slim raises, how often, and whether it keeps a bit set, sending no new notice for it, until the phone
  clears it are not. The scripted pump can behave that way (`holdsNoticesUntilCleared`), so the clears are
  tested against the worst case.
- **Where:** `Packages/PumpSession/Sources/PumpSession/PumpSession+Reads.swift` (`NoticeReads`);
  `Packages/PumpSession/Sources/PumpSession/PumpSession.swift` (`qualifyingEvents`).
- **Risk:** low. The timed reads stay as they are (alerts every 15 s, the rest every 60 s, history every
  15 minutes), so a missed notice costs freshness, not a dose; a dose reads its own inputs fresh.
- **P3:** bits 5 and 10 come with a bolus, 11 about once a minute while IOB changes, 14 with a BG entry
  (remote or typed on the pump), 15 with a CGM reading, 16 with the battery, 31 with a revoked permission,
  and 8, 15 and 20 with a clock change. A cartridge change wasn't recorded.
- **Verify:** on P1 and P2, record the notices across a bolus, a cancel, a suspend and resume, a CGM
  reading, a cartridge change and a battery change, then lengthen the alert read to 60 s if every alert
  raised its bit.

## 31. The reconnect cooldown on iOS, and whether a t:slim says it is in pairing mode

- **The guess:** t:connect's reconnect waits are for Android's error codes: 3 s after a link-layer timeout,
  10 s after a generic or framework error, 1 s otherwise, doubled per failure in a row up to 30 s.
  TandemKit maps them to CoreBluetooth's nearest: 3 s after a supervision timeout (`CBError` 6), 10 s after
  a connect that failed, 1 s otherwise. It counts failures since the link last held, where t:connect counts
  since the last connect. The pairing scan's 120 s timer stops early only when the strongest pump
  advertises that it is accepting connections, which a Mobi does; nothing shows a t:slim X2 advertises
  that state, so for a t:slim the timer runs until a pump is picked.
- **Where:** TandemKit's `LinkConfiguration` (`cooldown`, `cooldownAfterTimeout`,
  `cooldownAfterFailedConnect`, `pairingScanTimeout`) and `PumpRegistrationState`.
- **Risk:** low. Reconnecting never stops; a wrong base only makes a reconnect a few seconds early or late.
- **P3:** at the range edge the link dropped with `CBError` 6 after holding, and came back on the way back.
- **Verify:** at the range edge, record the drops' errors and how long each connection lasted (BAT-009's
  bench), and on P1 and P2 log the manufacturer data a pump in pairing mode advertises.

## 32. A pump's log can restart

A `HistoryLogRequest`'s start is the newest record wanted, and the pump streams from it down, newest first:
confirmed on P3 for a page below the newest record, and 250 and 255 come back whole. When the pump's newest
record is older than one the phone holds, faBolus takes the log as restarted, as Mobi does: it drops what
it holds and the logbook, and fetches the log again. The boluses unknown then are from before the restart,
and the new log can't show they never started, so history never settles them as absent: they stay unknown
until the pump confirms them. No t:slim has been seen restarting its log.

- **Known limit:** a restarted log that has grown past the newest record the phone holds before the next
  sync isn't noticed (Mobi's check has the same gap): what the phone holds then hides the new records with
  the same numbers, and an unknown bolus from before the restart could be settled as absent.
- **Where:** `Packages/PumpSession/Sources/PumpSession/PumpSession+History.swift` (`fetchPage`,
  `runHistorySync`).

## 33. The chart's basal line comes from Basal Rate Change records

- **The guess:** the chart draws the basal rate from the pump's Basal Rate Change records (type 3, the
  commanded rate in U/h), and its suspended spans from Pumping Suspended and Pumping Resumed (types 11 and
  12). t:connect draws its line from the Basal Delivery records (type 279) instead, whose rate fields
  TandemKit reads as integers in an unconfirmed unit. Whether a t:slim writes a Basal Rate Change for every
  Control-IQ and temp-rate change, and not only for profile changes, isn't known.
- **Where:** `Packages/PumpSession/Sources/PumpSession/HistoryProjection.swift` (`batch`),
  `Packages/faBolusCore/Sources/faBolusCore/BasalChart.swift`.
- **Risk:** display only. A rate change with no record leaves the line at the last recorded rate; nothing
  a dose uses reads it.
- **Verify:** with Control-IQ on, compare the pump's own basal graph over a few hours with the types 3 and
  279 records for the same time, and switch to 279 if 3 misses changes.

## 34. The home screen's basal icon and a temp rate's percent

- **The guess:** byte 5 of the pump's home screen (HomeScreenMirror) is its basal icon, with pumpX2's ids:
  4 while delivery is suspended, 5 while Basal-IQ has stopped basal for a predicted low, 2 while a temp rate
  runs and 3 for a zero temp rate. TempRate (op 43)
  says in byte 0 whether a temp rate runs and in byte 1 its percent. faBolus shows the basal as suspended,
  or as a temp rate with its percent, from them, as t:connect's dashboard does. P1 answered TempRate on the
  bench, but no recording has a suspension or a temp rate running.
- **Where:** `Packages/PumpSession/Sources/PumpSession/PumpReadings.swift` (`PumpBasalParts`, and the
  mirror, CurrentBasalStatus and TempRate cases), `Packages/PumpSession/Sources/PumpSession/PumpSession.swift`
  (the TempRate read).
- **Risk:** display only: nothing a dose uses reads the basal state, and the pump itself refuses a bolus
  while suspended. A wrong byte would show a suspension or a temp rate that isn't there, or miss one. A
  Basal-IQ suspension is shown apart from the pump's, as t:connect shows it, since a bolus still goes.
- **P3:** a 150 % temp rate reads byte 5 = 2, and TempRate active, 150 %, 900 s. The suspended icon wasn't
  read.
- **Verify:** on P1 and P2, suspend the pump and read the mirror and CurrentBasalStatus, resume and read
  them again; then set a 150 % temp rate and read the mirror and TempRate. On a Basal-IQ pump, read the
  mirror during a predicted-low suspension.

## 35. The home screen's status and bolus icons, IOB time left, and the CGM session's times

- **The guess:**
  - Bytes 2, 3 and 4 of the pump's home screen (HomeScreenMirror) are its first status icon (1 the transmitter,
    4 the transmitter out of range), its second (1 a calibration's blood drop) and its bolus icon (0 a bolus
    running, 1 a Control-IQ automatic bolus running), with pumpX2's ids and offsets. Mobi reads the same
    three icons at the same bytes, with the same values.
  - The IOB reply's byte 4 is the time left of insulin action. faBolus shows it only when byte 16 says the
    Mudaliar model (0), as t:connect does.
  - The mirror's byte 7 is the "+" t:connect shows before the cartridge's units, and InsulinStatus's byte 3
    the level below which it marks the cartridge low (both pumpX2's offsets).
  - CGMStatus (op 81) carries the last calibration (bytes 1 to 4) and the sensor start (5 to 8) in pump time,
    with 0 for unset. faBolus shows them while a session runs. With no CGM type read, a Libre's or a G7's
    last calibration is taken to be 0, so its row is left out; t:connect leaves it out for a Libre by type.
- **Where:** `Packages/PumpSession/Sources/PumpSession/PumpReadings.swift` (the mirror, ControlIQIOB and
  CGMStatus cases, `statusIcons`), `Packages/PhoneApp/Sources/PhoneApp/PumpDisplay.swift`.
- **Risk:** display only: no dose reads any of them. A wrong byte would show a mark, a time left or a time
  that isn't the pump's, or miss one.
- **P3:** the IOB time left resets to 5 h at each bolus and counts down; CGMStatus's session start and
  length match the pump's screen; status icon 1 reads 1 with a G6 running. The bolus icons, the calibration
  drop and the out-of-range icon weren't seen.
- **Verify:** on P1 and P2, read the mirror with a bolus running, with a calibration due and with the
  transmitter out of range; read ControlIQIOB on P1 (Control-IQ off) after a bolus and compare the time left
  with the pump's IOB screen; read CGMStatus during a G6 session and compare with the pump's CGM info screen.

## 37. Whether a granted bolus permission lapses

Bit 31 is the pump taking back a granted permission, confirmed on P3: it comes when the pump's own bolus
screen opens while the phone holds a permission, and a release after it answers status 1. A delivery that
has its permission and hasn't queued InitiateBolus then stops, releases the permission and sends nothing
more.

- **Unverified:** whether a permission lapses by itself. P3 kept one 120 s, and one 30 s right after its
  own bolus, without revoking. One held 600 s saw bit 31 0.5 s after the phone's release went out at 600 s,
  so a 10-minute lapse and a revoke raised by that release can't be told apart.
- **Where:** `Packages/PumpSession/Sources/PumpSession/PumpSession.swift` (`qualifyingEvents`),
  `Packages/PumpSession/Sources/PumpSession/PumpSession+Delivery.swift` (`DeliveryInProgress.stopReason`).
- **Risk:** fails closed: a stop before InitiateBolus delivers nothing.
- **Verify:** hold a permission past 600 s with the pump untouched.

## 39. CGM status B's grace period time left

- **The guess:** after CGM alert 32 (the G7 grace period ending soon), CGM status B (190 → 191) carries the
  time left at bytes 14 to 17 and the grace flag at byte 19, as pumpX2 lays it out and Mobi reads it.
  t:connect reads B for it below API 4.1 (form C at 4.1 or later, which TandemKit doesn't have), and says
  about 2 hours from 2101 to 7500 s left and about 30 minutes from 1 to 2100 s; faBolus puts that in alert
  32's detail. Whether the time left is the session's or the grace period's own is unshown; the windows
  don't depend on it.
- **Where:** `Packages/PumpSession/Sources/PumpSession/PumpSession.swift` (`readGracePeriodIfRaised`),
  `Packages/PumpSession/Sources/PumpSession/PumpReadings.swift` (`PumpAlertLists.graceDetail`).
- **Risk:** display only. A wrong byte would say the wrong time left, or none.
- **Verify:** on P2 with a G7, let a session run into its grace period and compare B with the pump's screen.
