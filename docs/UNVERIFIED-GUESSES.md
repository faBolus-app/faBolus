# Unverified best-guess values

These parameters were implemented from the protocol structs / references but **could not be
verified against a real pump or the Connect IQ simulator** in the environment they were built in.
They are surfaced with an ⚠️ note in the app. If a feature misbehaves, start here. Each item lists
the guess, where it lives, and how to verify.

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
- **`bolusIOB` — computed but NOT wired (FB-04, open):** `perform()` computes a bounded milliunit IOB
  (`bolusIobMu`, `TandemBackend.swift:462`) but the `InitiateBolusRequest` constructors still pass
  **`bolusIOB: 0`** (`:497`/`:500`) — the computed value is not sent. The oracle byte-lock
  (`InitiateBolusExtendedTests.carbBolusWithIobCargoMatchesOracle`, vector ID10653: `bolusIOB 130`) proves
  the *encoding* but the app does not populate it. FB-04 (frozen-IOB wiring) will thread the **frozen
  calculator IOB** — not the live snapshot — through the delivery API before this can be re-claimed as
  sent. Metadata only — never changes the delivered dose.
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

## 5. Passive Dexcom G6 direct BLE source (pre-existing, still experimental)
- Marked experimental in the CGM source picker; a passive G6 read may never connect (G6 needs an
  authenticated session). Prefer Dexcom Share or the xDrip App Group. See `docs/operate/cgm-failover.md`.

---
Remove an entry once it's been confirmed on hardware.
