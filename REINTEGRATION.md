# REINTEGRATION.md — dev/stacking-guard

## Feature preserved

The **Insulin Stacking Guard friction disclosures** (SG1 / SG2 / SG3a) — the full, working
friction-tier UX as it exists before the narrow-main gate §6 retirement removes it from `main`.
On `main` the friction is force-pinned off (`stackingGuardFrictionEnabled = false`), which caps
the applied friction to at most `.disclose`; this branch carries the un-capped feature. The
`StackingGuard` *core* itself stays on `main` byte-identical — only the friction/disclosure
surface is what this branch exists to restore.

## Base

Cut from `experimental` (the pre-programme tip that demonstrably still contains the full,
un-hidden surface). On `experimental` the flag defaults **true**, so the friction tiers are
actually applied.

## Actual symbols preserved (verified present on this branch)

- **Stored flag** — `ios/faBolus/Data/AppSettings.swift`: `stackingGuardFrictionEnabled` stored
  property (~:476), its `defaults` load defaulting to **true** (~:1023), the force-pin in
  `AppSettings.init` (the §6 pin, set false), the envelope emit (~:1094), the restore hook
  (~:1177).
- **Settings catalog** — `ios/faBolus/Data/SettingsCatalog.swift`:
  `.init("stackingGuardFrictionEnabled", .bolus, from: .simple, backsUp: true)` (~:114).
- **Confirm-seam friction application** — `ios/faBolus/Views/BolusEntryView.swift`: the
  `sg3aAppliedFriction` computed tier (~:292–:298) that reads `stackingGuardFrictionEnabled`
  and, when off, caps the tier to `.disclose`; the SG3a `.disclose` message/band line (~:278);
  the SG1/SG2/SG3a disclosure rendering (~:1021 and surrounds).
- **Guard core (stays on `main`, snapshot preserved here for reference)** —
  `Packages/faBolusCore/.../StackingGuard.swift` and `StackingGuardTests.swift`;
  `ios/faBolusAppTests/StackingGuardDeliverInvariantTests.swift`.

## Reintegration steps

1. The `StackingGuard` core is NOT what this branch restores (it stays live on `main`). Restore
   is limited to the friction-tier application in `BolusEntryView` and the pinned flag: un-pin
   `stackingGuardFrictionEnabled` and re-derive `sg3aAppliedFriction`'s cap logic against
   whatever the confirm seam looks like at reintegration time.
2. `StackingGuardDeliverInvariantTests.swift` pins the `standardConfirmRoute(.disclose) ==
   .deliver` invariant — restoring the friction tiers must keep that invariant (or update it
   deliberately) rather than silently changing delivery routing.
3. Re-confirm `faBolusCore` StackingGuard tests + the app-side invariant tests green.
