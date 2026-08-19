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

## 2. IDP profile create + segment parameters
- **Now aligned to captured reference values (audit C-07), still bench-gated:** the field bitmasks were
  best guesses (`0`/`1`) that the reference captures contradict; faBolus now sends the captured values:
  - `CreateIDPRequest`: `timeSegmentBitmask: 31` (all segment fields), `bolusSettingsBitmask: 5`
    (insulinDuration|carbEntry), `idpSourceId: 255` (0xFF = brand-new, not a duplicate), `carbEntry: 1`
    — from `CreateIDPRequestTest.new1` + the field doc-comments. (Was `1 / 0 / 0`, i.e. "almost nothing
    set" and "duplicate profile 0".)
  - `SetIDPSegmentRequest`: `idpStatusId` = the changed-fields bitmask (`31` = all) for create/modify,
    `0` for delete — from the captured `SetIDPSegmentRequest` vectors. (Was `0` = "nothing changed",
    the likely reason writes didn't take.) Byte-locked in `RemoteEntryAndIdpOracleTests`.
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

## 4. Carb-bolus pump metadata (FOOD1 / foodVolume / bolusIOB / isAutopopBg) — audit C-07
- **Now correct + oracle-locked:** a carb bolus sends `bolusTypeBitmask = FOOD1 (1)` (not FOOD2) with
  `foodVolume == totalVolume`, matching the reverse-engineered reference captures
  (`InitiateBolusExtendedTests.carbBolusFood1CargoMatchesOracle` / `…WithIobCargoMatchesOracle`). Carbs
  are bounded to [0, 1000] g and BG to [0, 600] mg/dL before conversion. Delivered dose is driven by
  `totalVolume` and is unchanged by these metadata fields.
- **`bolusIOB` — now wired (FB-04, done):** `perform()` sends the **frozen calculator IOB** — the active
  insulin the dose was computed against, captured at freeze time and threaded through the delivery API as
  `iobUnits` — converted to milliunits (`bolusIobMu`, `TandemBackend.swift:511-513`) and passed to both
  `InitiateBolusRequest` constructors as `bolusIOB: bolusIobMu` (`:556`/`:559`). It is the FROZEN value,
  not the live snapshot (a live IOB may have moved since approval, which wouldn't preserve the approved
  inputs); when no frozen IOB is supplied it sends `0` rather than substituting a live read. The oracle
  byte-lock (`InitiateBolusExtendedTests.carbBolusWithIobCargoMatchesOracle`, vector ID10653:
  `bolusIOB 130` == 0.13 U) proves the encoding. Metadata only — never changes the delivered dose.
  (Still bench-gate the end-to-end pump graph / Control-IQ effect — the *value sent* is verified, its
  on-pump interpretation is not.)
- **BG entry now matches captured ground truth (no longer a guess):** the six captured real-app
  `RemoteBgEntryRequest` vectors all send `entryType = MANUAL (0)` + `source = REMOTE (1)`. faBolus now
  sends exactly that (was `source = PUMP (0)` via the old `isAutopopBg:false` convenience — which
  contradicted every capture). Byte-locked in `RemoteEntryAndIdpOracleTests`. The "isAutopopBg" concept
  was a misread: the real app doesn't set an autopop flag, it always uses MANUAL/REMOTE.
- **Still unverified (bench-gate before trusting the pump graph / Control-IQ carb awareness):**
  - **Extended + carbs**: `foodVolume` is left 0 for the extended path (**no oracle vector exists** for a
    combo bolus with carbs, so the component-volume split can't be verified without a bench or a capture
    from the reference app); the FOOD1|EXTENDED bit selection is applied but the split is unproven.
  - The `RemoteCarbEntry/BgEntry` inserts are best-effort `try?` (a rejected entry never aborts the
    bolus) with no ack/rollback.
- **Verify (saline):** deliver a carb bolus; confirm the carb amount shows on the pump / t:connect and
  Control-IQ treats it as a carb bolus; confirm the inserts don't disrupt delivery.

## 5. Passive Dexcom G6 direct BLE source (pre-existing, still experimental pending on-device UAT)
- **Updated Phase 09.20 (D-03/D-05):** "a passive G6 read may never connect" was the ORIGINAL framing
  and has been **retracted** — a `LoopKit/CGMBLEKit`-mirror re-check (09.20-RESEARCH.md, "D-05
  reliability re-check" + "Already-paired-sensor first-run behavior") found no evidence for it: the
  official Dexcom app's own "Read from Dexcom app" (follow) mode is this exact mechanism, mandatory in
  xDrip4iOS's Dexcom setup, and re-authentication happens every ~5-min cycle regardless of when a
  sensor was originally paired — no authenticated session is needed for a SECOND passive listener.
  Marked **experimental** still means only ONE thing now: it is **validation-pending** (D-14) — the
  mechanism itself is confident, but the on-device UAT (`09.20-UAT.md`, D-13) hasn't run yet. See
  `docs/operate/cgm-failover.md` for the user-facing explanation and `09.20-CONTEXT.md`/
  `09.20-RESEARCH.md` for the full evidence trail.

## 6. Mobi native Sleep-schedule write (`SetSleepScheduleRequest.flag`) — Phase 09.10
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

## 7. `CurrentActiveIdpValuesResponse.currentTargetBg` byte-4 decode — Phase 09.8-04 (D-07)
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

## 9. G6 per-connection anchor-stability design (vs G7's per-message reset) — Phase 09.20-01/02 sign-off (D-08a)
- **Signed off 2026-08-18 (09.20-02 Task-1 checkpoint, owner-authorized default): `reject-and-stable`.**
  `DexcomG6BLESource.activationDate` is held STABLE per-connection — refreshed ONLY when a fresh
  `transmitterTimeRx` (0x25) is observed — rather than reset on every glucose message the way
  `DexcomG7BLESource.handleGlucose` does. This was implemented PROVISIONALLY in Plan 01; Plan 02
  Task 1 confirms it as the deliberate, permanent design (not a bug to "fix" back toward G7's
  per-message reset).
- **Where:** `ios/faBolus/Data/Sources/DexcomG6BLESource.swift` (`activationDate`, `ingest(controlFrame:)`).
- **Risk:** dose-path-adjacent. A stale anchor (if the transmitter's sensor clock itself drifted
  between `transmitterTimeRx` observations) would misdate subsequent glucose frames — bounded by the
  (separately logged) 0x25-cadence/no-anchor-bound guess below (entry 10), and further bounded by the
  implausible-age rejection gate in the same file (a grounded correctness check, not itself a numbered
  UNVERIFIED-GUESS — it only rejects wildly-wrong anchor arithmetic, never real physiology).
- **Verify:** D-13 on-device UAT — confirm glucose frames continue dating correctly across a live
  session with only occasional `transmitterTimeRx` frames observed, and that the anchor is not
  needlessly reset.

## 10. G6 `transmitterTimeRx` (0x25) wire cadence + no-anchor bound (≈10 min / 2 wake cycles) — Phase 09.20-02 (Warning 1)
- **UNVERIFIED-GUESS, owner/bench-confirmable.** The RESEARCH did not establish how often a G6/G5/ONE
  transmitter actually broadcasts `transmitterTimeRx` on the control characteristic during a passive
  third-central listen. `DexcomG6BLESource.noAnchorBound` (default ≈10 min = 2 assumed wake cycles) is
  the time a connection may run with NO anchor ever observed before it gives up (`status = .stale`)
  rather than trusting any never-anchored frame.
- **Where:** `ios/faBolus/Data/Sources/DexcomG6BLESource.swift` (`connectedAt`, `noAnchorBound`, the
  never-anchored branch of `handle()`).
- **Risk:** availability-only, fail-closed — an under-estimated bound makes the source give up on a
  connection that would have anchored soon after; an over-estimated bound just delays the `.stale`
  signal. Never affects the calc (a never-anchored frame is never published either way).
- **Verify (D-13 on-device UAT, Pitfall 5):** measure the actual latency from BLE connect to the first
  `transmitterTimeRx` observed; if 0x25 proves rare in practice, tune `noAnchorBound` (and possibly the
  first-reading-latency expectation) to match.

## 11. G7 stable per-connection anchor thresholds (bootstrap-once) — Phase 09.22-01 (D-02)

The G7 sensor-time anchor was rewritten (D-02, closing the A2 self-defeat) to bootstrap ONCE per
connection from a near-real-time glucose message and then hold stable — never re-derived per message.
Three thresholds gate that bootstrap/accept path; all are owner/bench-adjustable `static var`s in
`Shared/DexcomG7BLESource.swift`, deferred to on-device UAT (Wave 5) / Phase-11 bench.

- **(a) `anchorBootstrapMaxAge = 60s`** — only a message whose self-reported `age` (seconds from
  sensor reading to BLE transmission) is at or below this may (re-)establish the anchor. A larger
  value risks bootstrapping off a batched/old first frame; a smaller value risks never bootstrapping
  if the first observed frame is slightly delayed. **Risk:** availability-only, fail-closed — an
  un-bootstrapped source publishes nothing (never a wrong reading).
- **(b) `plausibleFrameAgeCeiling = 900s` (~3 G7 wake cycles)** — a frame whose own `age` exceeds this
  is rejected outright as stale-at-transmission, independent of anchor arithmetic. **Risk:**
  fail-closed — an over-tight ceiling drops otherwise-usable delayed frames; it never admits a bad one.
- **(c) The "bootstrap once, never re-refresh" assumption (Assumption A1)** — that G7's sensor RTC
  drift is negligible over a single connection, so one legitimately-bootstrapped anchor stays valid
  for the connection's life. **Not verified against a G7 spec sheet.** If wrong, the symptom is
  increasing false `.stale` classifications over very long uninterrupted connections — which fails
  CLOSED via `GlucoseFreshness` (a genuinely drifted reading ages out), never a silent wrong-dose.

- **Where:** `Shared/DexcomG7BLESource.swift` (`anchorBootstrapMaxAge`, `plausibleFrameAgeCeiling`,
  `implausibleAgeBound`, `handleGlucose`); mirrors G6's entries 9/10 above.
- **Verify (D-13 on-device UAT / Phase-11 bench):** confirm the first live G7 frame bootstraps the
  anchor promptly, that a delayed/batched frame is rejected (not shown as fresh), and that glucose
  keeps dating correctly across a long uninterrupted session with the anchor held stable — tune the
  three thresholds to the observed wake cadence if needed.

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

Every non-Closed row above (1, 2, 4, 5, 6, 7, 8) is tagged for the keep-off-narrow-main gating rule added
to the 999.5 per-surface checklist (`.planning/intel/prep/999.5-branch-model-reorg/PER-SURFACE-CHECKLIST.md`,
"Gating Rule: Unverified-Guess-Gated Features Stay Off Narrowed main") — none of these surfaces may be
promoted onto the narrowed `main` until its "Resolves via" step clears.

---
Remove an entry once it's been confirmed on hardware.
