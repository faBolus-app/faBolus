# Unverified best-guess values

These parameters were implemented from the protocol structs / references but **could not be
verified against a real pump or the Connect IQ simulator** in the environment they were built in.
They are surfaced with an ⚠️ note in the app. If a feature misbehaves, start here. Each item lists
the guess, where it lives, and how to verify.

> The full on-hardware validation matrix (bolus delivery on saline, carb metadata on the pump, IDP CRUD,
> Garmin runtime, signed archives) is in **[RELEASE-GATES.md](RELEASE-GATES.md)** — the gates that must
> pass before any feature here is relied on for real use.

**Accidental use is gated.** The consequential unverified actions (CGM high/low alert-type, IDP profile
create, IDP segment edit, experimental direct-BLE CGM source) now require a **blocking modal** that the
feature is untested and "will likely not work" before they run — not just the passive ⚠️ footers below
(`ios/faBolus/Views/UnverifiedFeatureGate.swift`, wired in `PumpWizardViews.swift` / `SettingsView.swift`).

**Scope note (v0.5.0 narrow-main milestone):** several entries below describe surfaces the narrow-main
removal (`BRANCHES.md` §1.2c) has since scope-narrowed off `main` — IDP profile CRUD and all Mobi-only
writes (entries 2, 6, 7) live only on `dev/mobi`. Entries 5, 9, 10 and 11 describe the rebuild's
direct-Bluetooth Dexcom readers in `Packages/DexcomBLE`. Off-main entries are marked **[off-main]** below. The guess and its verify step remain accurate for that `dev/<surface>`
branch and must still be resolved before any reintegration onto `main`; entries without the marker
(1, 3, 4, 5, 8 to 12) describe surfaces that are on `main` or `rebuild` today.

## 1. CGM alert type (high vs low)

- **Now matches the reference (still gated):** faBolus now sends `alertType: 0` = High, `alertType: 1` =
  Low, matching the jwoglom reference's named constants (`ALERT_TYPE_HIGH = 0`, `ALERT_TYPE_LOW = 1`).
  (It was previously the reverse.) The oracle's `CgmHighLowAlertRequestTest` still has **no captured BLE
  payload**, so this is reference-documented, not capture-verified — it remains **gated by the blocking
  untested-feature modal** and warned in the footer pending a pump/capture confirmation.
- **Where:** `ios/faBolus/Views/PumpWizardViews.swift` → `RemindersAlertsView` (CGM high/low section);
  backend `TandemBackend.setCgmHighLowAlert`. Rise/fall (`CgmRiseFallAlertRequest`) is not surfaced.
- **Risk:** low (only sets which threshold changes; non-insulin). Worst case: sets the wrong one.
- **Verify:** set a distinctive high/low threshold, then read it on the pump (Options → CGM alerts) and
  confirm which one moved. If reversed (as the reference implies), swap to high→0 / low→1 in
  `RemindersAlertsView` and drop the gate.

## 2. IDP profile create + segment parameters [off-main, `dev/mobi`]

- **Now aligned to captured reference values (audit C-07), still bench-gated:** the field bitmasks were
  best guesses (`0`/`1`) that the reference captures contradict; faBolus now sends the captured values:
  - `CreateIDPRequest`: `timeSegmentBitmask: 31` (all segment fields), `bolusSettingsBitmask: 5`
    (insulinDuration|carbEntry), `idpSourceId: 255` (0xFF = brand-new, not a duplicate), `carbEntry: 1`
    — from `CreateIDPRequestTest.new1` + the field doc-comments. (Was `1 / 0 / 0`, i.e. "almost nothing
    set" and "duplicate profile 0".)
  - `SetIDPSegmentRequest`: `idpStatusId` = the changed-fields bitmask (`31` = all) for create/modify,
    `0` for delete — from the captured `SetIDPSegmentRequest` vectors. (Was `0` = "nothing changed",
    the likely reason writes didn't take.) Byte-locked in TandemKit `RemoteEntryAndIdpOracleTests`.
- **Where:** `TandemBackend.createProfile` / `setSegment`; UI in `PumpWizardViews.swift`
  (`ProfileCreateView`, `ProfileSegmentsView`, `SegmentEditSheet`).
- **Risk:** insulin-affecting (changes the basal schedule). Gated behind advanced-control + Mobi +
  hold-to-confirm **+ the blocking untested-feature modal**. Values match the reference, but the
  end-to-end pump write is unproven — **bench-validate on saline before real use.**
- **Verify:** create/edit a profile, then read it back on the pump and confirm every field (start time,
  basal, carb ratio, ISF, target, insulin duration) matches.

## 3. Garmin complication `:unit` key + numeric color path — RESOLVED against the SDK

- **Resolved (no guess left):** the Connect IQ SDK's own type source
  (`.../connectiq-sdk-mac-9.2.0.../bin/api.mir`, `Complications.Data` typedef) defines the accepted keys
  as exactly `:value`, `:unit` (**singular**), `:shortLabel`, `:ranges`. `:units` (plural) appears ONLY
  in one typo-ridden Core-Topics doc example and is **not** an SDK key — so there was never a real
  ambiguity. `BgComplication` now makes a single SDK-correct `updateComplication` call with a numeric
  `:value`, the trend arrow in `:unit`, `:shortLabel`, and `:ranges` breakpoints. The only documented
  throw is `OperationNotAllowedException` (id not yet owned) — unknown keys are ignored at runtime, not
  thrown — so the old two-phase / `:units`-fallback dance was unnecessary (removed).
- **Color:** `:ranges` are numeric breakpoints; the CONSUMER (Face It / the watch face) colors by them —
  a publisher can't set the color itself. The real "reads 0" bug was a String `:value`; a numeric
  `:value` (as sent now) is the fix.
- **Where:** `faBolusGarmin/source/app/BgComplication.mc` (`pushComplication`),
  `resources-complications/complications/complications.xml` (`<range>` bands).
- **Fallback:** the in-app "Complication display" option has a "value + trend" **string** mode.
- **Optional confirm (Connect IQ simulator — NOT pump-bench):** run a complications device (e.g. venu3s)
  in the CIQ simulator with a Face It face to eyeball the number + arrow + coloring. Not required for
  correctness — the API usage now matches the SDK type source.

## 4. Bolus pump metadata: the type bits, the food/correction split and the entries

faBolus builds a bolus's InitiateBolus and entries the way Tandem's own app does in pumpx2's captures
(`InitiateBolusRequestTest`, `RemoteCarbEntryRequestTest`, `RemoteBgEntryRequestTest`), byte for byte
(`BolusCommandsTests`). The delivered amount depends only on the total; everything here is the pump's
record of the bolus.

- **Captured, and matched:** a dose typed in units has type bits 8 and no food or correction volume
  (ID10650); carbs alone have bits 1 with the whole dose as food (ID10652, ID10653); carbs with a correction
  have bits 3 with the dose split into the carbs' part and the correction (ID10677, ID10678). The BG entry
  goes first, then the carb entry, then InitiateBolus, the pump clock read again after permission; both
  entries carry TimeSinceReset's seconds since boot and the bolus ID, and the BG entry is manual and remote
  (entry type 0, source 1).
- **Unverified:**
  - faBolus never sent the split (bits 3) before; it has run only in Tandem's app.
  - A calculator dose for a correction with no carbs goes as bits 8, like a dose typed in units. There is no
    capture of Tandem's app sending one, so its own choice for that case is unknown.
  - A dose the user changed from the calculator's goes as all food (bits 1), the form faBolus always sent;
    what Tandem's app sends for an edited dose isn't captured.
  - The carbs' part is the calculator's rounded to 0.01 U, and the correction is the rest of the dose.
- **Verify:** deliver a carb bolus with a correction and confirm the pump and t:connect show the split as
  they do for a bolus from Tandem's app.

## 5. Passive Dexcom G6: iOS shares the Dexcom app's link, and the pump doesn't block it

- **The guess:** `G6Observer` reads alongside the Dexcom app by connecting to the transmitter iOS is
  already linked to, the way CGMBLEKit's passive mode does. It needs no transmitter slot of its own,
  and the pump's own G6 connection doesn't get in the way.
- **Where:** `Packages/DexcomBLE/G6/Sources/G6Observer.swift`, `Packages/DexcomBLE/Sources/DexcomBLE/DexcomCentral.swift`.
- **Risk:** availability only. If the link isn't shared, the source says why (`dexcomAppNotConnected`,
  `sensorNotFound` or the connection error) and never shows a reading.
- **Verify:** the S7 owner check, run on the S9 app: G6 reads for 24 h on a phone running the Dexcom
  app, with the pump connected.

## 6. Mobi native Sleep-schedule write (`SetSleepScheduleRequest.flag`) — Phase 09.10 [off-main, `dev/mobi`]

- **Narrowed (not removed):** the write's `activeDays` day-of-week bitmask is now **CONFIRMED** —
  Monday=bit0(1), Tuesday=2, Wednesday=4, Thursday=8, Friday=16, Saturday=32, Sunday=bit6(64) — fixed by
  upstream `MultiDay.java` and corroborated by two human-labeled real captures (`0x1F`="M Tu W Th F",
  `0x20`="Sat", `127`="Su-Sa"). This is **not a guess**.
- **`flag`'s VALUE is pinned to the captured golden 3** — faBolus now sends `flag: 3`, the value
  jwoglom's `SetSleepScheduleRequestTest` captures from the real Tandem app (both the enable AND the
  disable of slot 0 assert `flag == 3`), replacing the old placeholder `1`.
- **Still unverified: `flag`'s SEMANTIC meaning**, and whether the captured slot-0 write generalizes to
  slots 1-3 — no write to any slot other than 0 has ever been captured. Slots 2-3 aren't even visible on
  the pump's own UI (RESEARCH addendum 2026-08-15 Item 5), so a write to them is doubly unconfirmed.
- **Where:** `ios/faBolus/Data/TandemBackend.swift` (`setSleepSchedule`); UI in
  `ios/faBolus/Views/PumpWizardViews.swift` (`SleepScheduleView` / `SleepScheduleSlotEditRow`), Mobi-only
  (`PumpCapabilities.supportsSleepScheduleWrite`) — mirrors the upstream `SetSleepScheduleRequest`/
  `SetSleepScheduleResponse` `MOBI_ONLY`/`MOBI_API_V3_5` device-scope annotation.
- **Risk:** mode-only, non-insulin (L7 — the write is `.settings`-risk, structurally incapable of
  reaching the dose/delivery path; see `SleepScheduleWriteBoundaryTests`). Worst case: the schedule
  doesn't take, or a slot behaves unexpectedly.
- **Gated:** behind the blocking untested-feature modal (`UnverifiedFeatureGate`) on every Save button.
- **Verify (Phase-11 bench):** set a distinctive schedule on each of the 4 slots from the app, then read
  it back directly on the pump's own touchscreen and confirm every slot (including 2-3) took the exact
  value written — this is the confirmation step that resolves `flag`'s semantics.

## 7. `CurrentActiveIdpValuesResponse.currentTargetBg` byte-4 decode — Phase 09.8-04 (D-07) [off-main, `dev/mobi`]

- **Capture-backed, NOT oracle-backed, NOT bench-confirmed.** The TandemKit port decodes the pump's
  active-IDP target BG as `Bytes.readShort(raw, 4)` (fixed in 09.8-04 from the buggy `Int(raw[5])`, which
  decoded the real capture as 0). Ground truth is the real hardware capture `7017000073002c012800` (present
  in upstream's own test suite, cited in `gh pr diff 102 --repo jwoglom/pumpx2`) which decodes to
  `currentTargetBg == 115` at byte 4, independently re-derived by Codex (HIGH confidence for the observed
  10-byte layout). **This fix landed WITHOUT clean cliparser-oracle backing** — the pinned oracle is itself
  DEFECTIVE for this field (its `buildCargo` writes targetBg at byte 5, padding at byte 4; the OPPOSITE of
  the real wire), so the capture is the substitute ground truth (owner-acknowledged deviation from the
  no-unbacked-change rule, OWNER-DECISIONS.md 2026-08-16).
- **Residual device + software-version variance:** byte-4 is confirmed only on the primary pinned pump
  (`t:slim X2 · Control-IQ+ 7.10.2`). An unverified decompiled-Mobi rationale reads targetBg at byte 5, and
  the layout may differ by **t:slim SOFTWARE VERSION** as well as by pump family (t:slim vs Mobi). If a
  genuine byte-5 variant is captured, decoding must become variant-aware keyed on `(pump family, firmware
  version)`.
- **Where:** `TandemKit/Sources/TandemMessages/Responses/Responses.swift`
  (`CurrentActiveIdpValuesResponse.currentTargetBg`). **No live faBolus consumer today** — a grep for
  `currentTargetBg` in faBolus returns 0 hits, so no `UnverifiedFeatureGate` modal is wired now.
- **Risk:** dose-path-adjacent (the pump's bolus-calculator target BG feeds, or will feed, faBolus's
  StackingGuard above-target comparison). A wrong offset silently misreports therapy state.
- **GATING RULE:** ANY future consumer that feeds `currentTargetBg` into the StackingGuard above-target
  comparison (or any dosing decision) MUST gate on this entry with a blocking untested-feature modal
  (mirroring entries 1/2/6 via `ios/faBolus/Views/UnverifiedFeatureGate.swift`) until the Phase-11 bench
  confirms byte-4 per (pump family, firmware version). Do NOT rely on this value for real insulin before then.
- **Verify (Phase-11 saline bench):** TandemKit `docs/BENCH-SESSION-PLAN.md` **Objective 4** — set a known
  IDP target on the pump, read `CurrentActiveIdpValuesResponse`, and confirm byte 4 carries it on BOTH pump
  families and across more than one t:slim software version; confirm no genuine byte-5 variant exists.

## 8. `ControlIQInfoV2Response.controlStateType` → `ciqZone` word mapping — Phase 09.15-01 (D-01/D-08)

- **Not oracle-backed, not capture-backed, not bench-confirmed.** T1-1's "what Control-IQ is doing" state
  chip mirrors Tandem's own five zone words verbatim (Increases/Decreases/Maintains/Stops/Delivers, (c)
  Tandem) — the WORDS are Tandem's, but the raw op-179 byte that selects among them (`controlStateType`,
  byte 9 of `ControlIQInfoV2Response`) has **no named enum anywhere upstream**: the pinned jwoglom oracle
  decodes it only as an unnamed `int controlStateType` with no documented value table, and the only
  same-shaped precedent in the kit (`HomeScreenMirrorResponse.ApControlStateIcon`, op-57 — a DIFFERENT
  response/byte) has just 4 states, not 5, so it cannot be reused directly.
- `ControlIQZone.fromControlStateType(_:)` (`Packages/faBolusCore/Sources/faBolusCore/Models.swift`) maps
  raw ordinals `0...4` → `stops/decreases/maintains/increases/delivers`, a best-effort hypothesis that the
  byte ascends in the same order as Tandem's own documented ~70/112.5/160/180 mg/dL predicted-glucose zone
  thresholds (BRAINSTORM.md "IDEA 1/2"). Any other raw value → `nil` (chip renders ABSENT, never a guessed
  or fabricated word — D-06 guardrail #6).
- **Where:** `Models.swift` (`ControlIQZone`), `PumpResponseApplier.swift` (op-179 case), `RemoteCommand.swift`
  (`ciqZone` field + `validate()` membership bound). No `UnverifiedFeatureGate` modal wired — this is a
  pure DISPLAY primitive (T-09.15-01-I: info-disclosure severity low/accept in the phase threat register)
  with a structurally enforced fail-closed default, not a consequential/dose-affecting action gated by the
  blocking-modal convention (entries 1/2/6 above).
- **Risk:** low — display-only, never a dose input (C3); worst case is a wrong (or absent) status word,
  never a wrong dose. A confidently-wrong word is still a UX/trust hazard (mistaking "Increases" for
  "Decreases"), which is why an unmapped raw value fails closed to absent rather than guessing.
- **Verify (Phase-11 saline bench or a live capture):** put the pump through each of the 5 documented
  Control-IQ zones (predicted BG in each of the 4 threshold bands) and record the `controlStateType` byte
  seen at op-179 for each; confirm/correct the ordinal mapping above against the real values.
- **09.15-05 addendum (T1-2, D-09.1):** `ControlIQSuspendAttribution.isCiqAttributedSuspend(controlStateType:)`
  (`Packages/faBolusCore/Sources/faBolusCore/ControlIQMode.swift`) reuses this SAME unverified ordinal
  mapping — it returns `true` only when `ControlIQZone.fromControlStateType(_:) == .stops` — rather than
  hypothesizing a second, independent raw-byte guess for "Control-IQ paused basal to prevent a low."
  Resolving this item's Phase-11 bench verification also resolves T1-2's cause-attribution predicate;
  they are the same open question, not two.

## 9. G6 and G7: the Dexcom app's sign-in can finish before this app is listening

- **The guess:** control notifications go on only after the Dexcom app's authenticated, bonded
  challenge reply is seen on the authentication characteristic. This is CGMBLEKit's and
  G7SensorKit's rule; CGMBLEKit found that turning authentication off while the Dexcom app uses it
  breaks CoreBluetooth. If the Dexcom app signs in before this app's service discovery and
  notification setup finish, that cycle's reply is missed and no reading arrives. After two such
  cycles the status says the Dexcom app isn't connected.
- **How the others differ (protocol facts only; xDrip4iOS is GPL):** xDrip4iOS's G6 coexistence mode
  waits for the reply the same way, but counts the transmitter as bonded when the third byte is
  anything but 2 (CGMBLEKit requires 1) and doesn't check the authenticated byte. Its G7 mode turns on
  authentication, control and backfill notifications all at once on discovery, and when iOS answers
  "Encryption is insufficient" it disconnects and retries on the next cycle.
- **Where:** `G6Observer.received(_:on:from:now:)`, `G7Observer.received(_:on:from:now:)`,
  `AuthChallengeRxMessage`.
- **Risk:** availability only, plus a misleading status if it happens every cycle.
- **Verify:** the 24 h owner checks. If readings skip cycles, or the status blames the Dexcom app while
  it shows readings, record a session log and switch to xDrip4iOS's approach (G7) or its looser
  bonded check (G6).

## 10. G6: the transmitter's clock

- **The guess:** a G6 reading's time is relative to the transmitter's clock. `G6Observer` dates it
  from the clock start worked out from the latest `transmitterTimeRx` reply the Dexcom app asked for,
  as CGMBLEKit does. It keeps that clock start across launches, as CGMBLEKit stores it and
  xDrip4iOS dates its coexistence readings from it, and forgets it when another transmitter signs in.
  A reading with no known clock start is not used, and the status says it is waiting for the clock.
- **Where:** `G6Observer.controlResponse(_:from:now:)`, `DexcomMemory.activationDate`.
- **Risk:** fail-closed for a new transmitter until the Dexcom app asks for the clock. A phone clock
  changed by hand shifts readings until the next clock reply.
- **Verify:** the 24 h owner check: the first reading after setup should arrive within one or two
  cycles.

## 11. G7: a reading's time is its arrival minus the sensor's reported age

- **The guess:** as in G7SensorKit, a G7 glucose message carries the seconds since the sensor started
  and the age of its reading, so the reading was measured at arrival time minus that age, and
  backfill is dated from the latest message's sensor clock.
- **Where:** `Packages/DexcomBLE/G7/Sources/G7Observer.swift` (`glucose(_:from:now:)`, `flushBackfill()`).
- **Risk:** a notification delivered late (the app suspended past its background budget) would date
  the reading late, so it would look fresher than it is by the delay.
- **Verify:** the G7 24 h owner check: compare the app's reading times with the Dexcom app's.

Also unverified: the pump's `CGMHardwareInfoResponse.hardwareInfoString` (op 97) is the G6 transmitter
ID. The old app used it that way; `G6TransmitterID.normalized` accepts it only if it is six letters and
digits, and an ID typed in settings wins. On P1 the bench saw `CGMHardwareInfoRequest` (op 96) answered
with no sensor paired; with a sensor it is untested (TandemKit `Bench/bench-coverage/COVERAGE-MATRIX.md`).
Don't use `GetG6TransmitterHardwareInfo` instead: on P1 it draws op-77 and a link drop (F16).

## 12. `CurrentBatteryV2Response.chargingStatus == 1` (op-145 byte 2) — Phase 09.27 (D-03)

- **Kit decodes it; not oracle-confirmed live.** The pinned TandemKit (`1a09dba`) already decodes the
  charging bit — `chargingStatus = Int(raw[2])` in `CurrentBatteryV2Response`
  (`TandemKit/Sources/TandemMessages/Responses/Responses.swift:1001`, pinned, READ-ONLY reference), and
  the vendored jwoglom oracle confirms the field's SHAPE (`vendor/pumpx2-oracle/.../
  CurrentBatteryV2Response.java:57`: `chargingStatus = raw[2]`, `isCharging() { return chargingStatus
  == 1; }`). App-side only — no TandemKit PR; the pin stays HELD (D-01, 09.14 D-05). D-07's optional
  inert kit-decode parity test is DEFERRED (see 09.27 CONTEXT.md) — not planned this phase.
- **The caveat that keeps this UNVERIFIED:** jwoglom's own V2 javadoc notes the extra bytes beyond the
  headline reading "often read 0" on a real pump. Nobody has yet confirmed `chargingStatus == 1` fires
  live when a real pump is actually on its charger, for either pump family (t:slim X2 / Mobi) or across
  firmware/software versions. Treat it exactly like entry 8's ordinal-hypothesis guess: plausible,
  oracle-shaped, but NOT bench-confirmed.
- `PumpSnapshot.batteryCharging` (`PumpResponseApplier.swift` op-145 apply site) captures
  `chargingStatus == 1` ONLY — any other/unknown value fails closed to `false` (plain battery, no
  charging badge), never inferred from a rising percentage. Threaded display-only, additive-optional,
  through the `WidgetSnapshot`/`RemoteCommand.batteryCharging` wire to the iOS widgets and to Garmin's
  `AppState.batteryCharging` over the same remote wire. The Mac-remote and peer-iPhone-remote consumers
  named in earlier phases (`RemoteClientModel`/`MacRemoteModel`/`RemoteControlView`) are **off-main**
  now (deleted from `main`, preserved on `dev/mac` / `dev/phone-remote` per `BRANCHES.md` §1.2c).
  Nothing here is claimed "verified against a real pump on its charger."
- **Where (on `main`):** `Models.swift` (`PumpSnapshot.batteryCharging`), `PumpResponseApplier.swift`
  (op-145 case), `Packages/faBolusDesign/Sources/faBolusDesign/BatteryChargingPresentation.swift`
  (glyph/text/tint), `Shared/WidgetShared.swift`/`ios/faBolus/Data/WidgetPublisher.swift`
  (`batteryCharging` field), `ios/faBolusWidgets/StatusWidget.swift`,
  `faBolusGarmin/source/app/AppState.mc` + `DetailsView.mc`.
- **Risk:** display-only, never a dose input (D-06) — worst case is a wrong (or absent) charging badge,
  never a wrong dose. A confidently-wrong charging claim is still a trust hazard (a user believing the
  pump is charging when it isn't, or vice versa), which is why every hop fails closed to "not charging"
  on absent/invalid/legacy rather than guessing.
- **Verify (Phase-11 saline bench):** put the pump on its charger and confirm `chargingStatus == 1` is
  observed live at op-145, per pump family (t:slim X2 / Mobi) and firmware/software version; also
  confirm it correctly reads NOT-1 when off the charger. See the Resolution Ledger row below and the
  ROADMAP Phase 11 objective.

## 13. A bolus is absent from history only when no record shows the pump started it

An unknown outcome becomes "failed, never delivered" when a history search finds no record naming the bolus
among the initiate records (types 292, 293, 343, 298), requested (64-66), activated, delivery or completed
records, after reaching back past the moment the pump granted the permission (less 10 minutes), with every
record on the way received, no pump clock change in between, and the pump not reporting it active. The
permission records (338, 297) are ignored: the pump writes one when it grants permission, which is exactly the
bolus that never started.

- **Evidence:** the capture of bolus 3 in pumpx2's `btsnoop_hci.csv` has the initiate, requested,
  activated, delivery and completed records for a remote bolus, and a 297 record naming it before them.
- **Unverified:** that every firmware writes at least one of those records for every bolus it starts (P1's
  older firmware is the one to check), and the 10-minute margin.
- **Verify:** on P1, start a bolus and drop the link, and confirm a requested or activated record appears.

## 14. One pump clock for status, history and signing

The pump's TimeSinceReset `currentTime`, the CGM reading's timestamp, LastBolusStatusV2's timestamp and the
history records' times are read as one clock, the pump's own seconds since 2008. A time is placed on the
phone by the offset measured at the last TimeSinceReset, never by reading it as the phone's local time.

- **Evidence:** in the bolus-3 capture TimeSinceReset reads 445539182 and the history records written 13 s
  later read 445539195.
- **Known limit:** a history record from before the pump's clock was changed is placed by today's offset, so
  it is off by the change. A search for an absent bolus that crosses a clock change stays unknown (#13).

## 15. The pump session's timings

How often status is read while a bolus delivers (1 s), how long a delivering bolus may go without a status
answer before its outcome is unknown (60 s), how long it is followed at most (30 min), when a history page
counts as complete (2.5 s with no frame), and how often an unknown outcome is searched for (every 2 minutes,
5 times a connection; every 15 s while the pump still reports it active) are guesses, in
`PumpSession.Configuration`.

## 16. Which IOB the pump's calculator reply reports

The IOB shown and dosed from is op-109's by the pump's own IOB model (pumpx2's `getPumpDisplayedIOB`:
Mudaliar for type 0, Swan 6-hour for type 1, the larger for an unknown type); the old app always used Swan.
The dose path cross-checks it against op-115's own IOB and, when they differ by more than 0.05 U, treats IOB
as unverified and sizes from the larger.

- **Unverified:** which model op-115 reports. On a Control-IQ pump (type 1, P2) both are Swan. On a pump
  using Mudaliar (type 0; P1 runs with Control-IQ off) the two may differ, and then IOB never verifies: a
  remote carb dose is refused and the phone always asks. That fails closed, but would make P1's dose path
  unusable.
- **Verify:** on P1 with insulin on board, compare op-109's type and both values with op-115's `iob`.

## Resolution Ledger (09.14, D-03 — todo #17 Task A)

Most of the items below are **bench-gated and cannot be resolved in 09.14** — they REASSIGN to
**v0.4.0 Phase 11** (the on-hardware saline bench), not resolved here. This ledger does **NOT**
un-gate any pump-protocol guess; the full on-hardware validation matrix that must pass first lives in
[RELEASE-GATES.md](RELEASE-GATES.md). Only item 3 (already resolved against the Connect IQ SDK, before
this phase) reads as Closed.

| # | Item | Current state | Resolves via | Owner/phase |
|---|------|----------------|---------------|-------------|
| 1 | CGM alert type (high=0/low=1) | Reference-documented, blocking-modal-gated; no captured BLE payload yet | Set a distinctive high/low threshold, read back on the pump | v0.4.0 Phase 11 |
| 2 | IDP profile create + segment params | Aligned to captured reference values, insulin-affecting, bench-gated | Create/edit a profile, read back every field on the pump | v0.4.0 Phase 11 |
| 3 | Garmin complication `:unit`/color | **RESOLVED** — SDK type source confirms the key usage; no guess remains | — (optional Connect IQ simulator eyeball-confirm, not required) | Closed |
| 4 | Carb-bolus metadata (FOOD1/foodVolume/bolusIOB/isAutopopBg/BG) | Mostly oracle-locked; extended+carbs split and carb-graph/Control-IQ awareness still unverified | Deliver a carb bolus, confirm carb shows on pump/t:connect + Control-IQ awareness | v0.4.0 Phase 11 |
| 5 | Passive Dexcom G6 direct BLE | Validation-pending (D-14), not unreliable — mechanism confirmed confident by 09.20-RESEARCH.md's re-check (see item 5 above); only the on-device UAT (D-13) hasn't run yet | On-device UAT `09.20-UAT.md` (owner-tracked, not bench-blocked) | Owner, on-device UAT |
| 6 | Mobi sleep-schedule `SetSleepScheduleRequest.flag` semantic + slots 1-3 | Value pinned to captured golden `3`; day-of-week bitmask confirmed; `flag`'s semantic meaning and slots 1-3 generalization unconfirmed | Set a distinctive schedule on all 4 slots, read back directly on the pump | v0.4.0 Phase 11 (09.10 bench) |
| 7 | `CurrentActiveIdpValuesResponse.currentTargetBg` byte-4 decode | Capture-backed, not oracle-backed, not bench-confirmed; no live faBolus consumer today | TandemKit `docs/BENCH-SESSION-PLAN.md` Objective 4 — confirm byte 4 across pump families and t:slim software versions **before any dosing consumer relies on it**, matching this entry's own GATING RULE above | v0.4.0 Phase 11 |
| 8 | `controlStateType` → `ciqZone` word mapping | Ordinal-hypothesis guess (0-4 ascending with Tandem's documented zone thresholds); no oracle/capture backing; display-only, fail-closed to absent on any unmapped value | Cycle the pump through each documented CIQ zone on the Phase-11 bench (or a live capture) and record the real `controlStateType` byte per zone | v0.4.0 Phase 11 |
| 12 | `CurrentBatteryV2Response.chargingStatus == 1` (op-145 byte 2) | Kit-decoded, oracle-shaped, display-only, fail-closed to `false` on any other/unknown value; jwoglom's V2 javadoc notes the extra bytes "often read 0" so live semantics are unconfirmed | On the Phase-11 saline bench, put the pump on its charger and confirm `chargingStatus == 1` is observed live, per pump family (t:slim X2 / Mobi) and firmware/software version (and confirm NOT-1 off the charger) | v0.4.0 Phase 11 |

Every non-Closed row above (1, 2, 4, 5, 6, 7, 8, 12) is tagged for the keep-off-narrow-main gating rule added
to the 999.5 per-surface checklist (`.planning/intel/prep/999.5-branch-model-reorg/PER-SURFACE-CHECKLIST.md`,
"Gating Rule: Unverified-Guess-Gated Features Stay Off Narrowed main") — none of these surfaces may be
promoted onto the narrowed `main` until its "Resolves via" step clears.

---
Remove an entry once it's been confirmed on hardware.
