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
- **Now throw-safe (no bench needed for robustness):** `pushComplication` tries the arrow under `:unit`
  first and, if that firmware *rejects* the key (throws), retries under `:units` — so whichever spelling
  the runtime accepts wins, and step-1's numeric value always lands regardless (`BgComplication.enrich`).
  This removes the "one wrong key wipes the whole update" failure, but does NOT by itself confirm which
  key actually *renders* the arrow.
- **Fallback:** the in-app "Complication display" option (faBolus → Settings → Remotes & devices) has a
  "value + trend" **string** mode that works without color if the numeric+color path fails.
- **Verify (Connect IQ simulator — NOT pump-bench):** this is fully checkable without any pump. Build for
  a complications device (e.g. venu3s) and run in the CIQ simulator with a Face It face; confirm the
  number + arrow + range color render. If the arrow shows, the cascade picked the right key. Then confirm
  once on a real watch. (Only the *rendering* needs a screen; there is no pump dependency here.)

## 4. Carb-bolus pump metadata (FOOD1 / foodVolume / bolusIOB / isAutopopBg) — audit C-07
- **Now correct + oracle-locked:** a carb bolus sends `bolusTypeBitmask = FOOD1 (1)` (not FOOD2) with
  `foodVolume == totalVolume`, matching the reverse-engineered reference captures
  (`InitiateBolusExtendedTests.carbBolusFood1CargoMatchesOracle` / `…WithIobCargoMatchesOracle`). Carbs
  are bounded to [0, 1000] g and BG to [0, 600] mg/dL before conversion. Delivered dose is driven by
  `totalVolume` and is unchanged by these metadata fields.
- **`bolusIOB` now wired + oracle-locked (no bench needed):** `perform()` sends the pump's Control-IQ IOB
  (`snapshot.iobUnits`) in milliunits, exactly matching the reference app's captured request — byte-locked
  by `InitiateBolusExtendedTests.carbBolusWithIobCargoMatchesOracle` (vector ID10653: `bolusIOB 130` ==
  0.13 U). Verifiable purely against the oracle, so this is no longer a guess. Metadata only — never
  changes the delivered dose.
- **Still unverified (guesses, bench-gate before trusting the pump graph / Control-IQ carb awareness):**
  - `RemoteBgEntryRequest.isAutopopBg` is hard-coded **false** even for a CGM-sourced BG (provenance isn't
    threaded through the backend yet). The byte *format* is oracle-locked; whether the pump treats an
    autopop=true remote BG differently is the bench-only part, so it's left conservative (false).
  - **Extended + carbs**: `foodVolume` is left 0 for the extended path (no oracle vector for a combo bolus
    with carbs); the FOOD1|EXTENDED bit selection is applied but the component-volume split is a guess.
  - The `RemoteCarbEntry/BgEntry` inserts are best-effort `try?` (a rejected entry never aborts the
    bolus) with no ack/rollback.
- **Verify (saline):** deliver a carb bolus; confirm the carb amount shows on the pump / t:connect and
  Control-IQ treats it as a carb bolus; confirm the inserts don't disrupt delivery. Then thread CGM
  provenance into `isAutopopBg` and remove that bullet.

## 5. Passive Dexcom G6 direct BLE source (pre-existing, still experimental)
- Marked experimental in the CGM source picker; a passive G6 read may never connect (G6 needs an
  authenticated session). Prefer Dexcom Share or the xDrip App Group. See `docs/operate/cgm-failover.md`.

---
Remove an entry once it's been confirmed on hardware.
