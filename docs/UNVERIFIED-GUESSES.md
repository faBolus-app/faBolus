# Unverified best-guess values

These parameters were implemented from the protocol structs / references but **could not be
verified against a real pump or the Connect IQ simulator** in the environment they were built in.
They are surfaced with an ⚠️ note in the app. If a feature misbehaves, start here. Each item lists
the guess, where it lives, and how to verify.

## 1. CGM alert type (high vs low)
- **Guess:** `alertType: 1` = High, `alertType: 0` = Low in `CgmHighLowAlertRequest`.
- **Where:** `ios/faBolus/Views/PumpWizardViews.swift` → `RemindersAlertsView` (CGM high/low section);
  backend `TandemBackend.setCgmHighLowAlert`. Rise/fall (`CgmRiseFallAlertRequest`) is not surfaced.
- **Risk:** low (only sets which threshold changes; non-insulin). Worst case: sets the wrong one.
- **Verify:** set a distinctive high/low threshold, then read it on the pump (Options → CGM alerts)
  and confirm which one moved. Flip the mapping if reversed.

## 2. IDP profile create + segment parameters
- **Guesses:**
  - `CreateIDPRequest`: `timeSegmentBitmask: 1`, `bolusSettingsBitmask: 0`, `carbEntry: 1`,
    `idpSourceId: 0`, `firstSegmentProfileStartTime: 0`.
  - `SetIDPSegmentRequest`: `idpStatusId: 0`, `profileIndex: 0`. operationId 0/1/2 = modify/create/
    delete is confirmed (pumpX2 `IDPSegmentOperation`), but `idpStatusId` semantics are not.
- **Where:** `TandemBackend.createProfile` / `setSegment`; UI in `PumpWizardViews.swift`
  (`ProfileCreateView`, `ProfileSegmentsView`, `SegmentEditSheet`).
- **Risk:** insulin-affecting (changes the basal schedule). Gated behind advanced-control + Mobi +
  hold-to-confirm. **Bench-validate on saline before real use.**
- **Verify:** create/edit a profile, then read it back on the pump and confirm every field (start
  time, basal, carb ratio, ISF, target, insulin duration) matches. Note whether `idpStatusId` needs
  a non-zero bitmask (see `IDPSegmentResponse.IDPSegmentStatus`).

## 3. Garmin complication `:unit` key + numeric color path
- **Guess:** publishing `Complications.updateComplication` with a numeric `:value` + a Latin trend
  arrow in `:unit` (singular) + restored `<range>` bands yields a range-colored value with trend.
  The SDK typedef (`api.mir`) says `:unit`; the HTML doc example says `:units` — unverified which the
  runtime honors.
- **Where:** `faBolusGarmin/source/app/BgComplication.mc` (`publish`),
  `resources-complications/complications/complications.xml` (`<range>` bands).
- **Fallback:** the in-app "Complication display" option (faBolus → Settings → Watch & Garmin) has a
  "value + trend" **string** mode that works without color if the numeric+color path fails.
- **Verify:** on a real Garmin watch, add the faBolus BG complication to a Face It watch face; confirm
  it shows the number + arrow and colors by range. If blank/0, switch to the string mode; if the unit
  arrow is missing, try `:units`.

## 4. Passive Dexcom G6 direct BLE source (pre-existing, still experimental)
- Marked experimental in the CGM source picker; a passive G6 read may never connect (G6 needs an
  authenticated session). Prefer Dexcom Share or the xDrip App Group. See `docs/operate/cgm-failover.md`.

---
Remove an entry once it's been confirmed on hardware.
