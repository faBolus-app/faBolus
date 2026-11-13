# Unverified guesses

Values and behavior faBolus takes from pumpx2, captures or other references that haven't been confirmed
on a real pump or device. If something misbehaves, start here. Each entry gives the guess, where it lives,
what a wrong guess costs, and how to check it.

Two pumps are named: **P1**, a t:slim X2 at API 2.5 with the 16-character pairing code and no
cartridge, used on the bench; and **P2**, a t:slim X2 at API 4.0 with the 6-digit code.

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

## 7. `CurrentActiveIdpValuesResponse.currentTargetBg` is at byte 4

- **The guess:** TandemKit decodes the active profile's target BG with `Bytes.readShort(raw, 4)`. The
  ground truth is a real capture in pumpx2's tests (`7017000073002c012800`, target 115). The pinned
  oracle writes the field at byte 5, the opposite of the capture, so this decode has no oracle backing.
  Byte 4 is confirmed only on one t:slim (Control-IQ+ 7.10.2); the layout may differ by pump family and
  software version.
- **Where:** TandemKit `Sources/TandemMessages/Responses/Responses.swift`
  (`CurrentActiveIdpValuesResponse.currentTargetBg`). faBolus doesn't read it.
- **Risk:** none today. A future use for dosing must confirm it first.
- **Verify:** set a known target on the pump, read the response, and confirm byte 4 carries it, on more
  than one software version.

## 8. Control-IQ's zone byte: not shown until verified

- **The guess, removed:** the earlier app turned `ControlIQInfoV2Response.controlStateType` (op-179) into
  Tandem's zone words by guessing that the raw values ascend with the zones. pumpx2 decodes it as an
  unnamed int, and controlX2 doesn't use it. faBolus doesn't decode or show it, and doesn't carry
  "suspended for low", which reads the same byte. Control-IQ on or off and its mode are shown.
- **A verifiable source:** op-57 `HomeScreenMirrorResponse.ApControlStateIcon` is named and mirrors the
  pump's own home-screen icon, if the pump answers op-57.
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

## 12. The battery's charging bit

- **The guess:** `CurrentBatteryV2Response.chargingStatus` (op-145, byte 2) equal to 1 means the pump is
  charging, as pumpx2's `isCharging()` reads it. pumpx2's own notes say the bytes after the headline
  reading often read 0 on a real pump, and nobody has seen it read 1 on a pump on its charger. Any other
  value counts as not charging, never inferred from a rising percentage.
- **Where:** `Packages/PumpSession/Sources/PumpSession/PumpReadings.swift` (op-145),
  `PumpBattery.isCharging`, `Packages/faBolusDesign/Sources/faBolusDesign/BatteryChargingPresentation.swift`,
  the status message's `battery.charging`, and the watch's Details row.
- **Risk:** display only; a wrong or missing charging mark, never a dose input.
- **Verify:** with the pump on its charger, op-145 reads 1; off the charger, not 1. On P1 and P2.

## 13. A bolus is absent from history only when no record shows the pump started it

An unknown outcome becomes "failed, never delivered" when a history search finds no record naming the
bolus among the initiate records (types 292, 293, 343, 298), requested (64–66), activated, delivery or
completed records, after reaching back past the moment the pump granted the permission (less 10 minutes),
with every record on the way received, no pump clock change in between, and the pump not reporting it
active. The permission records (338, 297) are ignored: the pump writes one when it grants permission,
which is exactly the bolus that never started.

- **Evidence:** the capture of bolus 3 in pumpx2's `btsnoop_hci.csv` has the initiate, requested,
  activated, delivery and completed records for a remote bolus, and a 297 record naming it before them.
- **Unverified:** that every firmware writes at least one of those records for every bolus it starts
  (P1's older firmware is the one to check), and the 10-minute margin.
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

## 16. Which IOB the pump's calculator reply reports

The IOB shown and dosed from is op-109's, by the pump's own IOB model (pumpx2's `getPumpDisplayedIOB`:
Mudaliar for type 0, Swan 6-hour for type 1, the larger for an unknown type). The dose path cross-checks
it against op-115's own IOB and, when they differ by more than 0.05 U, treats IOB as unverified and sizes
from the larger.

- **Unverified:** which model op-115 reports. On a Control-IQ pump (type 1, P2) both are Swan. On a pump
  using Mudaliar (type 0; P1 runs with Control-IQ off) the two may differ, and then IOB never verifies: a
  remote carb dose is refused and the phone always asks. That fails closed, but would make P1's dose path
  unusable.
- **Where:** `Packages/PumpSession/Sources/PumpSession/PumpReadings.swift`.
- **Verify:** on P1 with insulin on board, compare op-109's type and both values with op-115's `iob`.

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

- **Unverified:** whether P1 (API 2.5) and P2 (API 4.0) act on op-184, or answer status 0 and leave the
  alert, and how soon after answering the pump's alert read reflects a clear.
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

## 19. A bolus that ends short is "stopped", not "cancelled"

- **The guess avoided:** pumpx2 doesn't name `BolusCompleted`'s completion status, so faBolus can't tell
  a cancel from an alarm or an interruption. A bolus whose authoritative delivered amount is below the
  request ends as `BolusOutcome.stopped(delivered:requested:)`, shown as "Bolus stopped" with both
  amounts. The cancel result the phone shows ("Bolus cancelled") comes from the pump's answer to the
  cancel, not from history.
- **Where:** `Packages/faBolusCore/Sources/faBolusCore/BolusOutcome.swift`,
  `Packages/PumpSession/Sources/PumpSession/PumpSession+Delivery.swift`.
- **Verify:** cancel a bolus, let one be stopped by an alarm, and let one be cut off by a link drop, and
  compare the completion status in each history record. Name the cause once the values are known.

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
- **Verify:** with a saline cartridge, deliver 1–2 U and compare the request, `LastBolusStatusV2` and the
  pump screen; then start a 2 U bolus, cancel it partway, and compare the reported amount with the pump
  screen and t:connect, including a cancel that arrives just as the bolus finishes.

## 22. The pump's comms-suspended notice (qualifying-event bit 19)

- **The guess:** the bit needs no action from the phone. pumpx2 names it `PUMP_COMMUNICATIONS_SUSPENDED`
  (524288) and gives it no handler, and t:connect only logs it. faBolus pauses nothing on it, as t:connect
  does. controlX2 pauses every send for 5 s per notice; faBolus did too until the owner chose t:connect's
  handling.
- **Where:** `Packages/PumpSession/Sources/PumpSession/PumpSession.swift` (`qualifyingEvents`).
- **Risk:** if the pump really stops answering while the bit is set, a request sent meanwhile waits for its
  60 s deadline (guess #15), and an InitiateBolus that times out is an unknown outcome, which blocks new
  boluses until history settles it. Nothing is sent that a pause would have kept back from the pump.
- **Verify:** on P1 and P2, record the qualifying events across a bolus, a cancel, a cartridge change and
  a suspend and resume, and note when bit 19 comes and whether a request sent just after it is answered.

## 23. The first bytes of the calculator snapshot and the last-bolus reply

- **The guess:** a calculator snapshot (op-115) is an answer only when its byte 0 is 0, and a
  `LastBolusStatusV2` reply describes the bolus only when its byte 0 is 1. Every recorded snapshot has 0
  there and the recorded last-bolus reply has 1, but no recording shows a pump sending anything else, or
  when it would.
- **Where:** `Packages/PumpSession/Sources/PumpSession/PumpReadings.swift` (the op-115 case) and
  `PumpSession+Delivery.swift` (`settleFinished`, and the snapshot read once permission is held).
- **Risk:** fails closed. If a pump used another value for a good reply, its snapshot would never count
  (every calculator dose asks about unconfirmed settings, and every bolus is refused at the re-read after
  permission), or every bolus would settle from history instead of the last-bolus reply.
- **Verify:** on P1 and P2, run the bench's `snapshot` and `lastbolus` reads and note byte 0, idle, during
  a bolus and right after one.

## 24. A bolus the pump gives between a dose's reads and its permission

- **The guess:** a t:slim grants bolus permission when its own bolus (from its screen, or Control-IQ)
  started and finished after faBolus read the dose's inputs, and the IOB in its calculator snapshot then
  includes that bolus. faBolus reads the snapshot again once permission is held and abandons the bolus
  (releasing the permission) when its IOB is more than one step above the IOB the dose was decided
  against. A recording shows the pump answering the snapshot while permission is held; nothing shows what
  it reports after its own bolus.
- **Where:** `Packages/PumpSession/Sources/PumpSession/PumpSession+Delivery.swift` (`runDelivery`).
- **Risk:** if the pump's IOB lags its own bolus, the re-read misses it and the dose goes ahead sized
  without it. If the IOB moves by more than a step for another reason in those seconds, a bolus is
  abandoned with nothing delivered.
- **Verify:** with a saline cartridge, start a bolus on the pump screen, let it finish, then ask for
  permission from the bench and read the snapshot; and note how far the IOB moves over a few seconds with
  Control-IQ active.

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
- **Verify:** on P1 and P2, run the bench's `cgm` read through a sensor's warm-up, a normal reading and a
  sensor error, and note the alert icon, the trend icon and the EGV status with each.

## 26. The calculator snapshot's auto-fill flag (byte 37)

- **The guess:** byte 37 of the calculator snapshot says whether the pump lets its CGM reading fill in a
  correction. faBolus honours it from a snapshot read for the attempt: off means no automatic correction.
  Both recorded snapshots have it on, beside a reading; nothing shows what clears it.
- **Where:** `Packages/faBolusCore/Sources/faBolusCore/PumpState.swift` (`glucoseCaution`).
- **Risk:** fails closed. A pump that cleared it in normal use would turn off every CGM correction.
- **Verify:** on P1 and P2, run the bench's `snapshot` read with a fresh reading, a stale one, and none,
  and note byte 37 with each.

## 27. The calculator snapshot's insulin left, last hour and too-many-boluses bytes

- **The guess:** bytes 7-8 of the calculator snapshot are the insulin left in the cartridge in whole units;
  bytes 20-23 are the insulin bolused in the last hour in milliunits; bytes 24 and 25 are set when the pump
  says too many boluses were asked for (the hourly limit and IOB). The layout is pumpX2's. The meanings
  are how Tandem's apps use them; both recorded snapshots read 120 U left, 2.81 U and 0 U in the last hour,
  and neither flag set. faBolus asks the user to confirm from them, on the phone and on a remote.
- **Where:** `Packages/faBolusCore/Sources/faBolusCore/DoseConfirmation.swift` (`confirmations`);
  `Packages/PumpSession/Sources/PumpSession/PumpReadings.swift`.
- **Risk:** a wrong reading asks too often or not at all; no confirmation changes or blocks a dose, and
  the pump's own limits still apply.
- **Verify:** on P1 and P2 with saline, run the bench's `snapshot` read before and after two boluses a
  few minutes apart, and note bytes 7-8 against the pump's insulin screen, bytes 20-23 against the
  boluses given, and bytes 24 and 25 when the pump refuses a bolus for its hourly limit.

## 28. A correction glucose of 20-39 or 401-600 mg/dL in the bolus message

- **The guess:** the pump takes a BG from 20 to 600 mg/dL in InitiateBolus's BG field, as Tandem's app
  sends one in that range. faBolus sent 40-400 only; the calculator now corrects from 20-600 and sends the
  glucose it corrected from.
- **Where:** `Packages/PumpSession/Sources/PumpSession/BolusCommands.swift`;
  `Packages/faBolusCore/Sources/faBolusCore/CalculatorGlucose.swift`.
- **Risk:** fails closed: a pump that refuses the value refuses the bolus, and nothing is delivered.
- **Verify:** with saline on P1 and P2, bolus from a typed 30 mg/dL and a typed 450 mg/dL, and note
  whether each is accepted and what the pump's history records as the BG.

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
- **Verify:** with saline on P1 and P2, turn carbs off in a profile, run the bench's `snapshot` read and
  note bytes 13 and 14-17, then bolus from the calculator with insulin entered and a typed BG, and note
  what the pump's history records.

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
- **Verify:** at the range edge, record the drops' errors and how long each connection lasted (BAT-009's
  bench), and on P1 and P2 log the manufacturer data a pump in pairing mode advertises.

## 32. A history request names its page's newest record, and a pump's log can restart

- **The guess:** a `HistoryLogRequest`'s start is the newest record wanted, and the pump streams from it
  down, newest first. t:connect and Mobi both send it that way. In t:connect's capture every request names
  the pump's newest record and the pump streams down from it, but that capture can't tell this reading from
  one where the start is the oldest record and the pump stops at its newest; no t:slim has been asked for a
  page below its newest record. Pages hold at most 250 records, as t:connect asks. When the pump's newest
  record is older than one the phone holds, faBolus takes the log as restarted, as Mobi does: it drops what
  it holds and the logbook, and fetches the log again. The boluses unknown then are from before the
  restart, and the new log can't show they never started, so history never settles them as absent: they
  stay unknown until the pump confirms them. No t:slim has been seen restarting its log.
- **Known limit:** a restarted log that has grown past the newest record the phone holds before the next
  sync isn't noticed (Mobi's check has the same gap): what the phone holds then hides the new records with
  the same numbers, and an unknown bolus from before the restart could be settled as absent.
- **Where:** `Packages/PumpSession/Sources/PumpSession/PumpSession+History.swift` (`fetchPage`,
  `runHistorySync`); `historyPageSize` in `PumpSession.Configuration`.
- **Risk:** fails closed. If the start were the oldest record, each page would overlap what was asked in
  one record: a sync would credit almost nothing and an unknown bolus would stay unknown, never settled
  wrongly.
- **Verify:** the bench runbook's `history` step on P1 and P2 (`start=last-20 count=5` should come back
  `top`), and `history cap` for 250 and 255.
