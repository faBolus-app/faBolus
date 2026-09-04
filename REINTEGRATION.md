# REINTEGRATION.md — dev/mobi-surface

## Feature preserved

**Tandem Mobi support plus ALL advanced t:slim control** — temp-rate automation,
suspend/resume delivery, pump modes, and insulin-delivery-profile (IDP) editing — the full
surface as it exists before the narrow-main funnels and gate retirements remove it from `main`.

This is a **fresh, real frozen pointer** for the advanced-control cluster. The pre-existing
`dev/mobi` branch is retained untouched, but it is 493 behind `main` and its `REINTEGRATION.md`
frames the capability-model removal as "not yet touched"; this branch is cut from the tip that
demonstrably still contains the FULL temp-rate/suspend/IDP surface (see Base), so the documented
restore actually restores.

## Base

Cut from `experimental` — the ONLY candidate tip that still carries the full advanced-control
surface (13 files reference `TempRateAutomation`; `main` and the `main@49784cb` snapshot named
in the old `dev/mobi` row carry only 1 vestigial file, so a literal refresh onto `49784cb`
would have produced a HOLLOW pointer). `experimental` also predates `main`'s runtime Mobi reject
(`rejectMobiIfDetected` / `MobiRejectBackstop`), so the surface is un-blocked here.

## Actual symbols preserved (verified present on this branch)

- **Pump model** — `Packages/faBolusCore/.../Models.swift`: `enum PumpModel` (~:897) including
  its `.mobi` case and the Mobi capability-model plumbing through `faBolusCore` /
  `AccessPolicy` / `GatedPumpWrite`.
- **Temp-rate** — `ios/faBolus/Data/TempRateAutomation.swift`,
  `ios/faBolus/Intents/TempRateIntents.swift`,
  `Packages/faBolusCore/.../CiqPlusTempRateGateTests.swift`,
  `ios/faBolusAppTests/TempRateAutomationTests.swift`;
  `GatedPumpWrite.setTempBasal` / `stopTempBasal`.
- **Suspend / resume** — `GatedPumpWrite.suspendDelivery` / `resumeDelivery`;
  `Packages/faBolusCore/.../CiqSuspendAttributionTests.swift`,
  `ios/faBolusAppTests/CiqSuspendWireTests.swift`.
- **Modes** — `GatedPumpWrite.setMode`.
- **IDP (insulin-delivery profiles)** — `GatedPumpWrite.createProfile` / `setActiveProfile` /
  `renameProfile` / `deleteProfile` / `addProfileSegment` / `modifyProfileSegment` /
  `deleteProfileSegment`, and the `PumpBackend` IDP read/write methods (~:176–:184).

## Relationship to the existing dev/mobi branch

`dev/mobi` (b7ed041, 493 behind `main`) remains as the historical record and additionally
documents the Mobi **save-PIN** convenience deletion (Phase 33 plan 05) by symbol. That
save-PIN detail is not re-copied here; consult `dev/mobi`'s `REINTEGRATION.md` for it. This
branch exists specifically to give the advanced-control surface a frozen pointer whose tree
actually contains the full temp-rate/suspend/IDP feature.

## Reintegration steps

1. Mobi is a `PumpModel` **capability-model** change threaded through `faBolusCore` /
   `AccessPolicy` / `GatedPumpWrite` — all dose/signed-core paths under
   `scripts/check-dose-byte-identity.sh`'s `DOSE_PATHS`. Re-derive against the current
   capability model; hold byte-identity discipline; do not copy-back verbatim.
2. Re-derive whether `main`'s pairing-time Mobi reject (`rejectMobiIfDetected` /
   `MobiRejectBackstop`) must be removed/reworked first — otherwise a restored Mobi is
   disconnected the moment it is detected.
3. Re-confirm `swift test --package-path Packages/faBolusCore` (incl. `BolusMathParityTests`)
   and TandemKit oracle byte-parity green with the advanced surface restored.
