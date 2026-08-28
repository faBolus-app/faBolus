# REINTEGRATION.md — dev/control-iq-awareness (faBolus repo, phone half of W1)

## Feature preserved

The Control-IQ auto-correction AWARENESS DISPLAY surface (W1, phone half), removed by Phase 23 Plan 01
(`NARROW-CIQ-23`):

- `Packages/faBolusCore/Sources/faBolusCore/AutoCorrectionDisclosure.swift`'s full pre-slim surface:
  `ambientIndicator` (O3 — "Control-IQ automatic correction is active") and `lockoutMessage` (S1 — "Bolusing
  now pauses Control-IQ's automatic correction for ~60 min"), plus the three constants they consumed:
  `discloseAtOrAbove`, `discloseRisingAtOrAbove`, `risingTrends`. `lockoutRemainingFraction` (the surviving
  wire-contract primitive on `main`) is present here too, unchanged.
- `Packages/faBolusCore/Tests/faBolusCoreTests/AutoCorrectionDisclosureTests.swift` — the dedicated test
  file for the two removed display fns (12+ assertions).
- `ios/faBolus/Data/Settings/ControlIQDisableWarning.swift` — the Settings "turning off Control-IQ…"
  warning type (zero production call sites at removal time — an orphaned-but-tested safety contract).
- `ios/faBolusAppTests/CiqDisableWarningTests.swift` — its dedicated test file.
- `ios/faBolus/Views/BolusEntryView.swift`'s `autoCorrectionAmbient`/`autoCorrectionLockout` computed
  props and `rankedWarnings`' `autoAmbient`/`autoLockout` params (body blocks + the one production call
  site that passed them).
- `ios/faBolusAppTests/Support/RemoteCommandWireFixture.swift`'s two matching computed props (mirroring
  the view-model surface for tests).
- `ios/faBolusAppTests/ControllerDisclosureWireTests.swift` — the wire round-trip test whose sole purpose
  was exercising those two fixture props.
- `ios/faBolusAppTests/BolusWarningRankingTests.swift` and
  `ios/faBolusAppTests/StackingGuardDisclosureHiddenBoundaryTests.swift` at their pre-removal state — all
  10 call sites here still pass `autoAmbient`/`autoLockout`, and `warnings.count` assertions here are the
  pre-removal `9`, not `main`'s post-removal `7`.
- `ios/faBolusAppTests/CiqAwarenessScopeGuardTests.swift` at its pre-retarget state — the catalog still
  carries the `ControlIQDisableWarning`/display-fn entries and `totalSignaturesChecked >= 6` (not `main`'s
  retargeted floor of 8).

## State at removal

Cut at faBolus `main`'s pre-removal HEAD, commit **`cc56f41`** (2026-08-28) — the parent of Plan 23-01's
first removal commit `9ae4343`. `main` has since (Phase 23 Plan 01, three commits + one self-fix):

1. Deleted `ControlIQDisableWarning.swift` and `CiqDisableWarningTests.swift` outright (`9ae4343`),
   retargeting `CiqAwarenessScopeGuardTests`' catalog (entry dropped) and its numeric floor (`6` → `8`,
   live-derived against the 5 surviving catalog sources in their final post-slim state) while leaving the
   load-bearing `signedDeliveryPathReferencesNoCiqAwarenessSymbol` scan + its forbidden-token denylist
   fully intact (D-06 — retarget, never weaken).
2. Slimmed `AutoCorrectionDisclosure.swift` to `lockoutRemainingFraction` alone (`bea4f0a`), deleting
   `ambientIndicator`/`lockoutMessage` and the three now-orphaned constants (whole-repo grep confirmed zero
   surviving consumers before deletion) and retiring `AutoCorrectionDisclosureTests.swift` (D-09).
3. Removed the app-target consumers (`ead01ec`): `BolusEntryView`'s two computed props + `rankedWarnings`'
   two params/body-blocks/call-site args; `RemoteCommandWireFixture`'s two matching props (kept
   `lockoutRemainingFraction`/`lockoutAvailableAt`, which have 4 other consumers); the now-orphaned
   `ControllerDisclosureWireTests.swift` (sole consumer of the two removed fixture props); all 10 test
   call sites across `BolusWarningRankingTests.swift` (`warnings.count` 9 → 7) and
   `StackingGuardDisclosureHiddenBoundaryTests.swift`.
4. A doc-comment self-fix (`54e24cc9`, not a plan task) reworded a historical-note comment that had
   literally named the two removed function identifiers, tripping the plan's own dangling-ref sweep.

No `Codable`/`RemoteCommand.swift`/`command.schema.json` change at any step (D-10) — this removal never
touched the byte-frozen wire; `lockoutUntilEpochSec` and the rest of the CIQ wire fields are untouched on
`main` and on this branch identically.

This branch's REINTEGRATION.md is scoped to **W1 only** — it does not describe the Garmin stacking-guard
(W2) surface, which is Garmin-only and never existed on the phone repo (D-08a keeps the phone's own,
unrelated `StackingGuard.swift`/`sg*Disclosure` friction logic live on `main`, untouched by this phase).

## Reintegration path (pure deletion — no stub to remove, D-03)

1. Restore `ControlIQDisableWarning.swift` + `CiqDisableWarningTests.swift` from this branch's tip at
   their original paths.
2. Restore the full `AutoCorrectionDisclosure.swift` (this branch's copy) — a hand-merge if `main`'s
   `lockoutRemainingFraction` has moved since the cut; re-add the 3 constants.
3. Restore `AutoCorrectionDisclosureTests.swift`.
4. Re-add `BolusEntryView`'s `autoCorrectionAmbient`/`autoCorrectionLockout` computed props and
   `rankedWarnings`' `autoAmbient`/`autoLockout` params + body blocks + the production call site (diff this
   branch against `9ae4343`'s parent, `cc56f41`, for exact insertion points if `main` has drifted).
5. Restore `RemoteCommandWireFixture`'s two computed props and `ControllerDisclosureWireTests.swift`.
6. Re-add the 10 stripped test call sites in `BolusWarningRankingTests.swift` (`warnings.count` 7 → 9) and
   `StackingGuardDisclosureHiddenBoundaryTests.swift` (3 sites) from this branch's copies.
7. Re-widen `CiqAwarenessScopeGuardTests`: re-add the dropped catalog entry, raise
   `totalSignaturesChecked` back to (or above) this branch's `6` floor — re-derive the exact live value the
   same way Plan 23-01 did (replicate the test's own signature-extraction regex over the restored catalog),
   do not guess a number.
8. Run the full exit gate: `swift test` (faBolusCore) + `./scripts/test-ios.sh` — confirm both display fns
   render again and the restored suites are green.

## Cross-repo note

The paired faBolusGarmin repo's own `dev/control-iq-awareness` branch carries the Garmin half of this same
W1 surface (lockout countdown bar/numeral, sleep/exercise activity line, `controllerDisclosureLine`). Both
halves are independent display surfaces (no shared wire change either half depends on) and can be
reintegrated separately or together. The Garmin repo's `dev/stacking-guard-disclosure` branch is a
**different** feature (W2, Garmin-only) — do not conflate the two when reintegrating.
