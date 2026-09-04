# REINTEGRATION.md — dev/mode-selector

## Feature preserved

The **Simple / Standard experience-mode selector** (narrow-main gate §5) — the full
`AppMode` experience-tier feature as it exists before its retirement removes it from `main`.
On `main` the mode is force-pinned to `.advanced` (`appMode = .advanced`, unconditional) and
the Mode Gate is structurally inert; this branch carries the mode vocabulary and the selector
in their live, user-reachable form.

## Base

Cut from `experimental` (the pre-programme tip that demonstrably still contains the full,
un-pinned mode surface, including the mode-selector UI and a non-ceiling default).

## Actual symbols preserved (verified present on this branch)

- **Mode vocabulary** — `Packages/faBolusCore/.../SettingsTiers.swift`: `enum AppMode`
  (~:17, `Comparable`) and the `SettingTier` / `SettingsTier` ranking enums (the whole file,
  both enums).
- **Mode Gate** — `Packages/faBolusCore/.../AccessPolicy.swift`: `ModeGateContext` and the
  `activeMode < action.requiredMode` mode-gate branch (~:242–:254) with its `.childOnly`
  carve-out (~:247).
- **Tier bridge** — `Packages/faBolusCore/.../GatedPumpWriteTier.swift`:
  `GatedPumpWrite.requiredMode` (the `SettingTier` → `AppMode` mapping, ~:166–:175) and its
  tests `GatedPumpWriteTierTests.swift`.
- **Stored mode + pin** — `ios/faBolus/Data/AppSettings.swift`: the `appMode` stored property,
  its `.advanced` default (~:342) and the force-pin `appMode = .advanced` in `AppSettings.init`
  (the §5 pin, ~:1091).
- **Sole writer** — `ios/faBolus/Data/ModeStore.swift`: `ModeStore` (the documented `activeMode`
  writer, ~:38) and `ModeStoreTests.swift`.
- **Emit chain** — `ios/faBolus/Data/AppModel.swift` (~:471) →
  `RemoteStatusComposer.swift` → `cmd.activeMode = settings.activeModeRawValue` →
  `RemoteCommand.swift` (~:350) → `schema/command.schema.json` (~:323–:326). NOTE: this wire
  field has **no consumer** on any surviving surface (the Apple Watch target went in Phase
  17.5; faBolusGarmin has zero `activeMode` hits) — it is emit-only.
- **Tests** — `AccessPolicyTests.swift` (mode-gate `@Test`s ~:226/:236/:258/:272),
  `ModeCoherenceTests.swift` (whole file — both tests read `requiredMode`),
  `AppModelBehaviorTests.swift:337 modeGateRoutesThroughAppModelWiring`,
  `RemoteClientBolusGateTests.swift:49–72`.

## Reintegration steps

1. `SettingTier` is deleted one commit *before* the §5 mode-gate cut (it is `GatedPumpWriteTier`'s
   only other production consumer). Restoring the mode selector therefore requires restoring
   BOTH `SettingsTiers.swift` and `GatedPumpWriteTier.swift` together, or the package build breaks.
2. `AccessPolicy` / `GatedPumpWrite` are dose/signed-core evaluators — restoration must hold
   byte-identity discipline, not a verbatim copy-back.
3. Un-pin `appMode` in `AppSettings.init` and restore the selector UI. Re-derive the emit chain
   only if a consumer surface is being reintroduced (today it is emit-only).
4. For every action the restored Mode Gate denies, re-prove it is either deleted or still
   denied by a surviving gate (the reachability proof), and re-confirm `faBolusCore` + app
   tests green.
