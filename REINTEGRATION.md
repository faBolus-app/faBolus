# REINTEGRATION.md — dev/mobi

## Feature preserved

Mobi pump support plus ALL advanced t:slim control at the capability-model level (Phase 9,
MOBI-01..04). `FABOLUS_MOBI` is currently a documented no-op placeholder gate (zero
`#if FABOLUS_MOBI` call sites exist anywhere on `main` as of this writing) — the full
capability-model removal shape has not been authored yet (Phase 9 has not executed).

## State at removal

**Not yet touched at the capability-model level** — Phase 9 has not executed and remains
sequenced last in the v0.5.0 narrow-main milestone. This branch still carries the full
pre-narrow tree at the capability level: `PumpModel.mobi` and its capability-model plumbing
through `faBolusCore`/`AccessPolicy`/`GatedPumpWrite` are all still present on `main` today,
unlike the framing this file originally carried ("not yet touched" is still accurate for that
part).

**What DID change on `main` since this branch was cut, and is relevant here:** `main` now
rejects a detected Mobi at pairing time via a runtime behavioral gate
(`AppModel.rejectMobiIfDetected()` / `MobiRejectBackstop`, added independently of Phase 9) —
this is a **behavioral** reject, not the anticipated Phase-9 capability-model deletion, and it
does not touch `PumpModel.mobi` or the capability plumbing above.

**A separate, narrower sub-surface WAS deleted from `main` in the dead-code programme's Phase
33 plan 05 (2026-09-03, D-18): the Mobi save-PIN convenience feature.** This is NOT the
capability-model removal Phase 9 will eventually do — it is a small opt-in convenience (save a
Mobi's fixed 6-digit PIN in the Keychain so re-pairing skips re-typing it), deleted because the
save-PIN offer can never fire once Mobi is rejected at pairing. Deleted by symbol:
- `PairingStore.swift`: the `"mobiPin"` Keychain CRUD — `pinAccount`, `savePin(_:)`,
  `loadPin()`, `clearPin()`, and the in-memory test backing `memPin`. Replaced with a minimal
  `purgeSavedPinForErase()` one-shot `SecItemDelete`, kept so "Erase everything" still purges
  any pre-retirement saved PIN from an install that set one before this deletion.
- `AppModel.swift`: `savedPin`, `clearSavedPin()`, `savePinPrompt`, `saveOfferedPin()`,
  `dismissSavePinPrompt()`, `enteredPairCode`, `evaluateSavePinOffer()`, and the
  `RefreshEffectsCoordinator` binding. `connectWithCode(_:)` — the pairing entry point — was
  KEPT, simplified to drop its now-unused `enteredPairCode` bookkeeping.
- `RefreshEffectsCoordinator.swift`: the `onEvaluateSavePinOffer` seam + its `recordStep`.
- `RefreshOrderingCharacterizationTests.swift`: the `"evaluateSavePinOffer"` spine entry.
- `App.swift`: the root `.alert("Save this pump's PIN?")`.
- `MainHUDView.swift`'s `PairingSheet`: the "Clear saved PIN" button, `hadSavedPin` state, and
  the `.onAppear` PIN-restore block.
- `Models.swift`'s `PumpModel.hasSavablePairingPin` is now a zero-production-caller orphan of
  this deletion (its only call site was inside the deleted `evaluateSavePinOffer`) — flagged for
  a future cleanup pass, NOT deleted in Phase 33 plan 05 (out of that plan's declared scope).

KEPT, explicitly, and still live on `main`: `PumpModelStore` and `UnpairAdvisory`'s Mobi branch
(`resolvedModel`/`requiresChargingBaseToRepair`/`confirmationMessage`) — they feed the unpair
confirmation's charging-base warning after a Mobi disconnects, independent of save-PIN or
pairing. `PumpPairingCode.isValid` and the 16-char legacy pairing scheme (a t:slim, not Mobi,
mechanism) are also untouched.

## Reintegration steps

**This is still the highest-complexity reintegration of all 8 `dev/<surface>` branches** —
flagged explicitly here so a future reintegrator does not underestimate it by analogy with the
simpler gate-flip branches (`dev/mac`, `dev/watch-remote`).

1. Mobi support is a `PumpModel` **capability-model** change, not a source-file-exclude or
   whole-target strip. It threads through dose-adjacent code: `faBolusCore`, `AccessPolicy`, and
   `GatedPumpWrite`. Reintegration is NOT a simple file restore or gate flip — it requires
   re-deriving how the capability model interacts with whatever `faBolusCore`/`AccessPolicy`/
   `GatedPumpWrite` look like on `main` at reintegration time (these are dose/signed-core paths
   under `scripts/check-dose-byte-identity.sh`'s `DOSE_PATHS`, so any restoration touching them
   must go through the same D-03/D-04 discipline as the original removal: byte-identity held,
   stubs/frozen-wire-fields un-stubbed carefully, not a direct copy-back).
2. **Additionally re-derive whether `main`'s pairing-time reject (`rejectMobiIfDetected` /
   `MobiRejectBackstop`) must be removed or reworked** — reintegrating Mobi support while that
   backstop is still active would silently disconnect every real Mobi the moment it is detected,
   which would make the rest of this reintegration invisible to any tester.
3. **If restoring the save-PIN convenience feature too** (it is NOT required for core Mobi
   support — re-pairing by re-typing the code always works): re-derive it against whatever
   `PairingStore`/`AppModel`/`RefreshEffectsCoordinator` look like at reintegration time; do not
   copy the deleted code back verbatim, since the surrounding seams (the coordinator's effect
   order, the ordering spine literal) will have moved. `git show <pre-33-05 faBolus commit>` is
   the reference for the exact shape that existed before this file's Phase 33 plan 05 entry.
4. A full oracle/parity re-run is required on reintegration — do not treat this as done until
   `swift test --package-path Packages/faBolusCore` (including `BolusMathParityTests`) and the
   TandemKit oracle byte-parity checks are re-confirmed green with Mobi support restored.
5. Cross-reference whatever Phase 9's own removal-time documentation says about the exact
   stub/frozen-field techniques it used (D-04) — that documentation, written when Phase 9 actually
   executes, is the authoritative un-stub checklist; this note only flags that the checklist will
   exist and must be followed precisely, not what it contains (Phase 9 hasn't run yet).
6. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`) after restoration, treating it as a
   full re-verification of dose behavior, not a mechanical smoke test.
